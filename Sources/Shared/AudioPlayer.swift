import AVFoundation
import Foundation
import Observation
import QingkongCore
#if os(iOS)
import MediaPlayer
#endif

@MainActor @Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var state = AudioState()
    private(set) var error: String?
    private(set) var activating = false
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var activationID = UUID()

    override init() {
        super.init()
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if kind == AVAudioSession.InterruptionType.began.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.pause(); self?.player = nil
                self?.error = "音频服务已重置，请重新播放。"
            }
        })
        #if os(iOS)
        installRemoteCommands()
        #endif
    }

    func toggle() async {
        if state.playing || activating { pause() } else { await play() }
    }

    func play() async {
        guard !activating else { return }
        activating = true
        let attempt = UUID()
        activationID = attempt
        defer { if activationID == attempt { activating = false } }
        error = nil
        if state.deadline?.expired() == true { setTimer(minutes: 0) }
        do {
            let session = AVAudioSession.sharedInstance()
            #if os(watchOS)
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.activate(options: []) { active, error in
                    if let error { continuation.resume(throwing: error) }
                    else if active { continuation.resume() }
                    else { continuation.resume(throwing: PlaybackError.noRoute) }
                }
            }
            #else
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            #endif
            guard activationID == attempt else { return }
            if player == nil { try loadTrack() }
            guard let player, player.play() else { throw PlaybackError.cannotPlay }
            state.playing = true
            updateNowPlaying()
        } catch {
            state.playing = false
            self.error = "播放未开始，请检查音频输出设备后重试。"
        }
    }

    func pause() {
        activationID = UUID(); activating = false
        player?.pause(); state.playing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        updateNowPlaying()
    }

    func select(_ track: Track, autoplay: Bool = false) async {
        pause()
        state.track = track
        player = nil
        error = nil
        if autoplay { await play() }
        updateNowPlaying()
    }

    func skip(_ step: Int) async {
        let tracks = Track.allCases
        let current = tracks.firstIndex(of: state.track) ?? 0
        let wasPlaying = state.playing
        await select(tracks[(current + step + tracks.count) % tracks.count], autoplay: wasPlaying)
    }

    func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        state.volume = min(1, max(0, value))
        player?.volume = state.volume
    }

    func setTimer(minutes: Int) {
        scheduleDeadline(minutes > 0 ? SleepDeadline(minutes: min(120, minutes)) : nil)
    }

    func prepareForPlayback(_ source: AudioState) async {
        await select(source.track)
        setVolume(source.volume)
        scheduleDeadline(source.deadline)
    }

    private func scheduleDeadline(_ deadline: SleepDeadline?) {
        stopTask?.cancel()
        state.deadline = deadline?.expired() == true ? nil : deadline
        guard let deadline = state.deadline else { return }
        stopTask = Task { [weak self] in
            // Wall-clock reconciliation also runs when the scene becomes active.
            while !Task.isCancelled {
                let remaining = deadline.remaining()
                if remaining <= 0 { self?.reconcileDeadline(); return }
                do { try await Task.sleep(for: .seconds(min(remaining, 5))) }
                catch { return }
            }
        }
    }

    func reconcileDeadline() {
        if state.deadline?.expired() == true {
            pause(); state.deadline = nil; stopTask?.cancel(); stopTask = nil
        }
    }

    func handle(_ command: AudioCommand) async -> AudioReply {
        error = nil
        switch command.action {
        case .status: reconcileDeadline()
        case .playPause: await toggle()
        case .pause: pause()
        case .previous: await skip(-1)
        case .next: await skip(1)
        case .select:
            if let track = command.track { await select(track, autoplay: true) }
            else { error = "未选择音频。" }
        case .volume:
            if let amount = command.amount, amount.isFinite { setVolume(Float(amount)) }
            else { error = "音量无效。" }
        case .timer:
            if let amount = command.amount, [0.0, 15, 30, 60].contains(amount) { setTimer(minutes: Int(amount)) }
            else { error = "定时选项无效。" }
        }
        return AudioReply(id: command.id, state: state, error: error)
    }

    private func loadTrack() throws {
        guard let url = Bundle.main.url(forResource: state.track.rawValue, withExtension: "wav") else { throw PlaybackError.missingAsset }
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.numberOfLoops = -1
        audio.volume = state.volume
        audio.delegate = self
        audio.prepareToPlay()
        player = audio
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.pause(); self?.player = nil; self?.error = "音频暂时无法播放，请重新选择。"
        }
    }

    private func updateNowPlaying() {
        #if os(iOS)
        var info: [String: Any] = [MPMediaItemPropertyTitle: state.track.name, MPMediaItemPropertyArtist: "自然声音", MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0, MPNowPlayingInfoPropertyIsLiveStream: true]
        if let image = UIImage(named: state.track.image) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    #if os(iOS)
    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.toggle() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.skip(1) }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.skip(-1) }; return .success }
    }
    #endif

    private enum PlaybackError: Error { case noRoute, missingAsset, cannotPlay }
}
