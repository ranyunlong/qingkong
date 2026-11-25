import AppIntents
import Foundation
import QingkongCore

@MainActor
enum PhoneAppRuntime {
    private static var current: AppServices?

    static func services() throws -> AppServices {
        if let current { return current }
        let services = try AppServices()
        current = services
        return services
    }
}

enum WidgetPlaybackError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

@MainActor
enum WidgetPlaybackController {
    static func perform(_ action: WidgetAudioAction, on player: AudioPlayer,
                        restoreSelection: () async throws -> Void) async throws {
        if player.isDesktopControlled {
            let command: AudioCommand.Action
            switch action {
            case .play: command = .play
            case .pause: command = .pause
            case .previous: command = .previous
            case .next: command = .next
            }
            let receipt = await player.handle(AudioCommand(action: command))
            if let error = receipt.error { throw WidgetPlaybackError.unavailable(error) }
            return
        }
        if action != .pause && !player.hasSelection { try await restoreSelection() }
        switch action {
        case .play:
            if !player.state.playing && !player.buffering { await player.play() }
        case .pause:
            player.pause()
            return
        case .previous: await player.skip(-1)
        case .next: await player.skip(1)
        }
        if let error = player.error { throw WidgetPlaybackError.unavailable(error) }
    }
}

extension AppServices {
    func performWidgetPlayback(_ action: WidgetAudioAction) async throws {
        try await WidgetPlaybackController.perform(action, on: player) {
            guard let previous = WidgetAudioStorage.load() else { return }
            if let id = previous.onlineTrackID {
                guard let track = content.tracks.first(where: { $0.id == id }),
                      let album = content.albums.first(where: { $0.id == track.albumID }) else {
                    throw WidgetPlaybackError.unavailable("这首歌曲已不可用，请在小晴空重新选择。")
                }
                let url = try downloads.playbackURL(for: track, allowCellular: false)
                await player.selectOnline(track, queue: content.tracks(in: album), url: url, allowCellular: false, autoplay: false)
            } else {
                await player.select(previous.track)
            }
        }
        updateMusicWidget()
    }
}

extension MusicPlaybackIntent {
    @MainActor
    func perform() async throws -> some IntentResult {
        try await PhoneAppRuntime.services().performWidgetPlayback(action)
        return .result()
    }
}
