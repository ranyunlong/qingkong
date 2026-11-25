import AppKit
import MediaPlayer
import QingkongCore

/// System controls share the authoritative player used by the window and iPhone.
@MainActor
final class MacSystemPlayback {
    enum Action { case play, pause, toggle, stop, previous, next, seek(TimeInterval) }

    private weak var player: MacAudioPlayer?
    private let canControl: () -> Bool
    private var targets: [(MPRemoteCommand, Any)] = []
    private var published = false
    private var artworkItem: DesktopQueueItem?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private struct Publication: Equatable {
        let item: DesktopQueueItem?
        let title: String
        let duration: TimeInterval
        let playing: Bool
        let index: Int
        let count: Int
    }
    private var publication: Publication?
    private var publicationDate = Date.distantPast
    private var publishedPosition: TimeInterval = 0

    init(player: MacAudioPlayer, canControl: @escaping () -> Bool) {
        self.player = player
        self.canControl = canControl
    }

    func update() {
        guard let player, player.hasSelection, !player.isPhonePlayback else { clear(); return }
        // A silent selection or handoff preparation must not replace another app's music.
        guard published || player.isPlaying else { return }
        if !published { installCommands(); published = true }
        refreshArtwork(player.currentItem)
        let state = Publication(item: player.currentItem, title: player.title, duration: player.duration,
            playing: player.isPlaying, index: player.currentIndex, count: player.queueItems.count)
        let now = Date.now
        let elapsed = now.timeIntervalSince(publicationDate)
        let position = player.playbackPosition
        let expected = publishedPosition + (publication?.playing == true ? elapsed : 0)
        // The system extrapolates progress. Publish transitions/seeks immediately, with occasional calibration.
        if state != publication || abs(position - expected) > 0.05 || elapsed >= 5 {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.metadata(for: player, artwork: artwork)
            MPNowPlayingInfoCenter.default().playbackState = player.isPlaying ? .playing : .paused
            publication = state; publicationDate = now; publishedPosition = position
        }
        let enabled = canControl() && !player.isPreparing
        for (command, _) in targets { command.isEnabled = enabled }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = enabled && !player.isBuffering && player.duration > 0
    }

    static func metadata(for player: MacAudioPlayer, artwork: MPMediaItemArtwork? = nil) -> [String: Any]? {
        guard player.hasSelection, !player.isPhonePlayback else { return nil }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.title,
            MPMediaItemPropertyArtist: "小晴空",
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.playbackPosition,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: player.currentIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: player.queueItems.count
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        return info
    }

    @discardableResult
    func perform(_ action: Action) -> MPRemoteCommandHandlerStatus {
        guard let player, player.hasSelection else { return .noSuchContent }
        guard canControl(), !player.isPreparing, !player.isPhonePlayback else { return .commandFailed }
        switch action {
        case .play: if !player.playbackIntent { player.toggle() }
        case .pause: player.pause()
        case .toggle: player.toggle()
        case .stop: player.stop()
        case .previous, .next, .seek:
            if case .seek(let seconds) = action {
                guard seconds.isFinite, player.duration > 0, !player.isBuffering else { return .commandFailed }
            }
            Task { [weak self, weak player] in
                guard let self, let player, self.canControl(), !player.isPreparing, player.hasSelection else { return }
                switch action {
                case .previous: await player.previous()
                case .next: await player.next()
                case .seek(let seconds): await player.seek(to: seconds)
                default: break
                }
            }
        }
        return .success
    }

    private func installCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, Action.play), (center.pauseCommand, .pause),
                                  (center.togglePlayPauseCommand, .toggle), (center.stopCommand, .stop),
                                  (center.previousTrackCommand, .previous), (center.nextTrackCommand, .next)] {
            register(command) { _ in action }
        }
        register(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek($0.positionTime) }
        }
    }

    private func register(_ command: MPRemoteCommand, action: @escaping (MPRemoteCommandEvent) -> Action?) {
        let target = command.addTarget { [weak self] event in
            guard let action = action(event) else { return .commandFailed }
            // MediaPlayer may deliver on a background queue; return the main player's admission result.
            if Thread.isMainThread {
                return MainActor.assumeIsolated { self?.perform(action) ?? .commandFailed }
            }
            return DispatchQueue.main.sync { self?.perform(action) ?? .commandFailed }
        }
        targets.append((command, target))
    }

    private func refreshArtwork(_ item: DesktopQueueItem?) {
        guard artworkItem != item else { return }
        artworkTask?.cancel(); artworkTask = nil
        artworkItem = item; artwork = nil
        if let track = item?.track, let image = NSImage(named: track.image) {
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else if let track = item?.onlineTrack, let url = track.coverURL {
            artworkTask = Task { [weak self] in
                guard let cgImage = try? await MacAlbumArtworkCache.shared.image(for: url,
                    identity: "\(track.albumID)|\(track.revision)|\(track.updatedAt.timeIntervalSince1970)"),
                      !Task.isCancelled, let self, self.artworkItem == item else { return }
                let image = NSImage(cgImage: cgImage, size: .zero)
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publication = nil
                self.update()
            }
        }
    }

    private func clear() {
        artworkTask?.cancel(); artworkTask = nil
        artworkItem = nil; artwork = nil
        publication = nil
        guard published else { return }
        for (command, target) in targets { command.removeTarget(target); command.isEnabled = false }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        published = false
    }
}
