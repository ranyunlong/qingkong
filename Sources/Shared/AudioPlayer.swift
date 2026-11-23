import AVFoundation
import Foundation
import Observation
import QingkongCore
#if os(iOS)
import MediaPlayer
#endif

enum AudioPlaybackMode: String, CaseIterable {
    case single, sequence, shuffle
    var title: String { switch self { case .single: "单曲循环"; case .sequence: "顺序循环"; case .shuffle: "随机循环" } }
    var symbol: String { switch self { case .single: "repeat.1"; case .sequence: "repeat"; case .shuffle: "shuffle" } }
}

@MainActor @Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var state = AudioState() {
        didSet { if state != oldValue { didChangeState?(state) } }
    }
    @ObservationIgnored var didChangeState: ((AudioState) -> Void)?
    @ObservationIgnored var albumArtworkURLProvider: ((PublicAudioTrack) -> URL?)?
    private(set) var error: String?
    private(set) var activating = false
    private(set) var hasSelection = false
    var playbackMode: AudioPlaybackMode {
        didSet {
            defaults.set(playbackMode.rawValue, forKey: "qingkong.audio.playback-mode.v1")
            player?.numberOfLoops = playbackMode == .single ? -1 : 0
        }
    }
    private(set) var buffering = false {
        didSet { state.buffering = buffering ? true : nil }
    }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var activationID = UUID()
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private let defaults: UserDefaults
    private static let deadlineKey = "qingkong.audio.deadline.v1"
    #if os(watchOS)
    private(set) var downloadedTrack: PublicAudioTrack?
    private(set) var localPlaybackSelected = false
    @ObservationIgnored var downloadedURLProvider: ((PublicAudioTrack) throws -> URL)?
    @ObservationIgnored var didSelectDownloaded: ((PublicAudioTrack?) -> Void)?
    @ObservationIgnored private var downloadedQueue: [PublicAudioTrack] = []
    @ObservationIgnored private var downloadedLicenseTask: Task<Void, Never>?
    #endif
    #if os(iOS)
    // Audio-session changes can block on the system audio service. Keep them
    // off the main actor and ordered across rapid play/pause requests.
    private static let audioSessionQueue = DispatchQueue(label: "cn.geckoai.qingkong.audio-session", qos: .userInitiated)
    private(set) var onlineTrack: PublicAudioTrack?
    @ObservationIgnored var onlineURLProvider: ((PublicAudioTrack, Bool) throws -> URL)?
    @ObservationIgnored var didStartOnline: ((PublicAudioTrack) -> Void)?
    @ObservationIgnored var didSelectOnline: ((PublicAudioTrack?) -> Void)?
    @ObservationIgnored private var onlineQueue: [PublicAudioTrack] = []
    @ObservationIgnored private var onlinePlayer: AVPlayer?
    @ObservationIgnored private var onlineObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var onlineEndObserver: NSObjectProtocol?
    @ObservationIgnored private var onlineTimeout: Task<Void, Never>?
    @ObservationIgnored private var licenseTask: Task<Void, Never>?
    @ObservationIgnored private var cellularAllowed = false
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingArtworkURL: URL?
    @ObservationIgnored private var nowPlayingArtwork: UIImage?
    #endif

    init(defaultsOverride: UserDefaults? = nil) {
        let defaults = defaultsOverride ?? (ProcessInfo.processInfo.arguments.contains("--ui-testing") ? UserDefaults(suiteName: "qingkong.audio.testing")! : .standard)
        self.defaults = defaults
        playbackMode = defaults.string(forKey: "qingkong.audio.playback-mode.v1").flatMap(AudioPlaybackMode.init(rawValue:)) ?? .sequence
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
        if let data = defaults.data(forKey: Self.deadlineKey), let deadline = try? JSONDecoder().decode(SleepDeadline.self, from: data) {
            scheduleDeadline(deadline)
        }
    }

    func toggle() async {
        if state.playing || activating || buffering { pause() } else { await play() }
    }

    func play() async {
        guard !activating else { return }
        wantsPlayback = true
        activating = true
        let attempt = UUID()
        activationID = attempt
        defer { if activationID == attempt { activating = false } }
        error = nil
        if state.deadline?.expired() == true { setTimer(minutes: 0) }
        do {
            #if os(watchOS)
            guard downloadedTrack?.copyright.expiresAt.map({ $0 > .now }) ?? true else { throw PlaybackError.cannotPlay }
            #endif
            #if os(watchOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.activate(options: []) { active, error in
                    if let error { continuation.resume(throwing: error) }
                    else if active { continuation.resume() }
                    else { continuation.resume(throwing: PlaybackError.noRoute) }
                }
            }
            #else
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Self.audioSessionQueue.async {
                    do {
                        let session = AVAudioSession.sharedInstance()
                        try session.setCategory(.playback, mode: .default, options: [])
                        try session.setActive(true)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            #endif
            guard activationID == attempt else { return }
            #if os(iOS)
            if let onlinePlayer {
                guard onlineTrack?.copyright.expiresAt.map({ $0 > .now }) ?? true else { throw PlaybackError.cannotPlay }
                buffering = true
                onlinePlayer.play()
                monitorOnlineTimeout()
                return
            }
            #endif
            if player == nil { try loadTrack() }
            guard let player, player.play() else { throw PlaybackError.cannotPlay }
            hasSelection = true
            state.playing = true
            updateNowPlaying()
        } catch {
            guard activationID == attempt else { return }
            wantsPlayback = false
            state.playing = false
            self.error = "播放未开始，请检查音频输出设备后重试。"
        }
    }

    func pause() {
        wantsPlayback = false
        activationID = UUID(); activating = false
        player?.pause(); state.playing = false
        buffering = false
        #if os(iOS)
        onlinePlayer?.pause(); onlineTimeout?.cancel()
        Self.audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #else
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        updateNowPlaying()
    }

    func reportPlaybackError(_ message: String) { pause(); error = message }

    var playbackDuration: TimeInterval {
        #if os(iOS)
        if let onlineTrack {
            if let duration = onlinePlayer?.currentItem?.duration.seconds, duration.isFinite, duration > 0 { return duration }
            return onlineTrack.durationSeconds.isFinite ? max(0, onlineTrack.durationSeconds) : 0
        }
        #endif
        return player?.duration ?? 0
    }

    var playbackPosition: TimeInterval {
        let position: TimeInterval
        #if os(iOS)
        if let onlinePlayer { position = onlinePlayer.currentTime().seconds }
        else { position = player?.currentTime ?? 0 }
        #else
        position = player?.currentTime ?? 0
        #endif
        return position.isFinite ? min(playbackDuration, max(0, position)) : 0
    }

    var canSeek: Bool {
        guard !activating, error == nil, playbackDuration > 0 else { return false }
        #if os(iOS)
        if let onlinePlayer { return onlinePlayer.currentItem?.status == .readyToPlay }
        #endif
        return player != nil
    }

    func seek(to seconds: TimeInterval) async {
        guard seconds.isFinite, canSeek else { return }
        let position = min(playbackDuration, max(0, seconds))
        #if os(iOS)
        if let audio = onlinePlayer {
            let item = audio.currentItem
            let completed = await audio.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard completed, onlinePlayer === audio, audio.currentItem === item else { return }
        } else { player?.currentTime = position }
        #else
        player?.currentTime = position
        #endif
        updateNowPlaying()
    }

    private func nextIndex(after current: Int, count: Int, step: Int = 1) -> Int {
        guard count > 1 else { return 0 }
        if playbackMode == .shuffle {
            let offset = Int.random(in: 1..<count)
            return (current + offset) % count
        }
        return ((current + step) % count + count) % count
    }

    func select(_ track: Track, autoplay: Bool = false) async {
        hasSelection = true
        pause()
        #if os(iOS)
        clearOnline(clearMetadata: false)
        #else
        clearDownloaded(clearMetadata: false)
        #endif
        var selection = state
        selection.track = track
        selection.onlineTrackID = nil
        selection.onlineTitle = nil
        selection.onlineArtworkURL = nil
        state = selection
        player = nil
        error = nil
        do { try loadTrack() }
        catch { self.error = "音频暂时无法准备，请重新选择。" }
        if autoplay { await play() }
        updateNowPlaying()
    }

    func skip(_ step: Int) async {
        #if os(watchOS)
        if let downloadedTrack, !downloadedQueue.isEmpty {
            let index = downloadedQueue.firstIndex(where: { $0.id == downloadedTrack.id }) ?? 0
            let next = downloadedQueue[nextIndex(after: index, count: downloadedQueue.count, step: step)]
            let autoplay = state.playing
            await selectDownloaded(next, queue: downloadedQueue, autoplay: autoplay)
            return
        }
        #endif
        #if os(iOS)
        if let onlineTrack, !onlineQueue.isEmpty {
            let index = onlineQueue.firstIndex(where: { $0.id == onlineTrack.id }) ?? 0
            let next = onlineQueue[nextIndex(after: index, count: onlineQueue.count, step: step)]
            let autoplay = state.playing || buffering
            do {
                guard let url = try onlineURLProvider?(next, cellularAllowed) else { throw PlaybackError.missingAsset }
                await selectOnline(next, queue: onlineQueue, url: url, allowCellular: cellularAllowed, autoplay: autoplay)
            } catch { pause(); self.error = "下一首尚未完整缓存或网络不可用，请在曲库重试。" }
            return
        }
        #endif
        let tracks = Track.allCases
        let current = tracks.firstIndex(of: state.track) ?? 0
        let wasPlaying = state.playing
        await select(tracks[nextIndex(after: current, count: tracks.count, step: step)], autoplay: wasPlaying)
    }

    func setVolume(_ value: Float) {
        guard value.isFinite else { return }
        state.volume = min(1, max(0, value))
        player?.volume = state.volume
        #if os(iOS)
        onlinePlayer?.volume = state.volume
        #endif
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
        persistDeadline()
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
            persistDeadline()
        }
    }

    private func persistDeadline() {
        if let deadline = state.deadline, let data = try? JSONEncoder().encode(deadline) { defaults.set(data, forKey: Self.deadlineKey) }
        else { defaults.removeObject(forKey: Self.deadlineKey) }
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
        #if os(watchOS)
        if let downloadedTrack {
            guard let url = try downloadedURLProvider?(downloadedTrack), url.isFileURL else { throw PlaybackError.missingAsset }
            let audio = try AVAudioPlayer(contentsOf: url)
            guard audio.prepareToPlay() else { throw PlaybackError.cannotPlay }
            audio.volume = state.volume
            audio.numberOfLoops = playbackMode == .single ? -1 : 0
            audio.delegate = self
            player = audio
            return
        }
        #endif
        guard let url = Bundle.main.url(forResource: state.track.rawValue, withExtension: "wav") else { throw PlaybackError.missingAsset }
        let audio = try AVAudioPlayer(contentsOf: url)
        audio.numberOfLoops = playbackMode == .single ? -1 : 0
        audio.volume = state.volume
        audio.delegate = self
        audio.prepareToPlay()
        player = audio
    }

    #if os(watchOS)
    func selectLocally(_ track: Track, autoplay: Bool = true) async {
        localPlaybackSelected = true
        await select(track, autoplay: autoplay)
    }

    func useAutomaticPlaybackSelection() async {
        await select(state.track)
        localPlaybackSelected = false
    }

    func selectDownloaded(_ track: PublicAudioTrack, queue: [PublicAudioTrack], autoplay: Bool = true) async {
        guard track.copyright.expiresAt.map({ $0 > .now }) ?? true else {
            reportPlaybackError("这首音轨授权已到期，请刷新曲库。"); return
        }
        hasSelection = true
        localPlaybackSelected = true
        pause(); clearDownloaded(clearMetadata: false); player = nil
        error = nil
        downloadedTrack = track
        downloadedQueue = queue
        updatePublicMetadata(track)
        do {
            try loadTrack()
            didSelectDownloaded?(track)
            monitorDownloadedLicense()
            if autoplay { await play() }
        } catch {
            clearDownloaded(); player = nil
            self.error = "这首音轨尚未完整下载或无法在手表播放，请重新下载。"
        }
    }

    func reconcileDownloadedCatalog(_ tracks: [PublicAudioTrack]) {
        guard let selected = downloadedTrack else { return }
        guard let updated = tracks.first(where: { $0.cacheIdentity == selected.cacheIdentity }),
              updated.copyright.expiresAt.map({ $0 > .now }) ?? true else {
            pause(); clearDownloaded(); player = nil
            error = "当前音轨已下架、版本更换或授权到期，请重新选择。"; return
        }
        downloadedTrack = updated
        updatePublicMetadata(updated)
        downloadedQueue = tracks.filter { track in
            track.albumID == updated.albumID && (try? downloadedURLProvider?(track)) != nil
        }.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        monitorDownloadedLicense()
    }

    private func clearDownloaded(clearMetadata: Bool = true) {
        downloadedLicenseTask?.cancel(); downloadedLicenseTask = nil
        downloadedTrack = nil; downloadedQueue = []
        if clearMetadata { clearPublicMetadata() }
        didSelectDownloaded?(nil)
    }

    private func monitorDownloadedLicense() {
        downloadedLicenseTask?.cancel()
        guard let expires = downloadedTrack?.copyright.expiresAt else { return }
        downloadedLicenseTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = expires.timeIntervalSinceNow
                guard remaining > 0 else {
                    self?.reportPlaybackError("当前音轨授权已到期，请刷新曲库并选择其他声音。")
                    return
                }
                do { try await Task.sleep(for: .seconds(min(remaining, 60))) } catch { return }
            }
        }
    }

    #endif

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identifier else { return }
            guard self.wantsPlayback else { return }
            guard flag else { self.reportPlaybackError("音轨播放未完成，请重新选择。"); return }
            guard self.state.deadline?.expired() != true else { self.reconcileDeadline(); return }
            #if os(watchOS)
            if let track = self.downloadedTrack,
               let index = self.downloadedQueue.firstIndex(where: { $0.id == track.id }) {
                let next = self.playbackMode == .single ? index : self.nextIndex(after: index, count: self.downloadedQueue.count)
                await self.selectDownloaded(self.downloadedQueue[next], queue: self.downloadedQueue)
                return
            }
            #endif
            if self.playbackMode == .single {
                self.player?.currentTime = 0
                await self.play()
            } else { await self.skip(1) }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.pause(); self?.player = nil; self?.error = "音频暂时无法播放，请重新选择。"
        }
    }

    private func updatePublicMetadata(_ track: PublicAudioTrack) {
        var selection = state
        selection.onlineTrackID = track.id
        selection.onlineTitle = track.title
        selection.onlineArtworkURL = [track.coverURL, albumArtworkURLProvider?(track)]
            .compactMap { $0 }.first(where: PublicContentURL.isHTTPS)
        state = selection
        #if os(iOS)
        refreshNowPlayingArtwork()
        #endif
    }

    private func clearPublicMetadata() {
        var selection = state
        selection.onlineTrackID = nil
        selection.onlineTitle = nil
        selection.onlineArtworkURL = nil
        state = selection
    }

    #if os(iOS)
    private func refreshNowPlayingArtwork() {
        guard nowPlayingArtworkURL != state.onlineArtworkURL else { return }
        artworkTask?.cancel()
        nowPlayingArtwork = nil
        nowPlayingArtworkURL = state.onlineArtworkURL
        guard let url = state.onlineArtworkURL, let trackID = state.onlineTrackID else { return }
        artworkTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
                guard !Task.isCancelled, let self,
                      self.state.onlineTrackID == trackID, self.state.onlineArtworkURL == url,
                      let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                      response.url.map(PublicContentURL.isHTTPS) == true,
                      data.count <= 8_000_000, let image = UIImage(data: data) else { return }
                self.nowPlayingArtwork = image
                self.updateNowPlaying()
            } catch { /* Audio remains usable if its optional cover cannot load. */ }
        }
    }
    #endif

    private func updateNowPlaying() {
        #if os(iOS)
        var info: [String: Any] = [MPMediaItemPropertyTitle: state.displayTitle, MPMediaItemPropertyArtist: "小晴空 · 自然声音", MPNowPlayingInfoPropertyPlaybackRate: state.playing ? 1.0 : 0.0, MPNowPlayingInfoPropertyIsLiveStream: onlineTrack == nil]
        if onlineTrack != nil {
            info[MPMediaItemPropertyPlaybackDuration] = playbackDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackPosition
        }
        let image: UIImage?
        switch state.artwork {
        case .bundled(let name): image = UIImage(named: name)
        case .remote: image = nowPlayingArtwork
        case .placeholder: image = nil
        }
        if let image {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #endif
    }

    #if os(iOS)
    func selectOnline(_ track: PublicAudioTrack, queue: [PublicAudioTrack], url: URL, allowCellular: Bool, autoplay: Bool = true) async {
        hasSelection = true
        pause(); clearOnline(clearMetadata: false); player = nil
        onlineTrack = track; onlineQueue = queue; cellularAllowed = allowCellular
        monitorOnlineLicense()
        updatePublicMetadata(track)
        error = nil
        let asset = AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: allowCellular])
        let item = AVPlayerItem(asset: asset)
        let audio = AVPlayer(playerItem: item)
        audio.volume = state.volume
        onlinePlayer = audio
        didSelectOnline?(track)
        onlineObservations = [
            audio.observe(\.timeControlStatus, options: [.new]) { [weak self, weak audio] _, _ in
                Task { @MainActor in
                    guard let self, let audio, self.onlinePlayer === audio else { return }
                    self.state.playing = audio.timeControlStatus == .playing
                    self.buffering = audio.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    if self.buffering { self.monitorOnlineTimeout() }
                    if self.state.playing {
                        self.onlineTimeout?.cancel()
                        if let track = self.onlineTrack { self.didStartOnline?(track) }
                    }
                    self.updateNowPlaying()
                }
            },
            item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                Task { @MainActor in
                    guard let self, let item, self.onlinePlayer?.currentItem === item else { return }
                    if item.status == .failed { self.pause(); self.error = "音轨加载失败，请检查网络或下载后重试。" }
                }
            }
        ]
        onlineEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.onlinePlayer?.currentItem === item else { return }
                await self.advanceOnlineAfterEnd()
            }
        }
        if autoplay { await play() }
        updateNowPlaying()
    }

    func reconcileOnlineCatalog(_ tracks: [PublicAudioTrack]) {
        guard let selected = onlineTrack else { return }
        guard let updated = tracks.first(where: { $0.cacheIdentity == selected.cacheIdentity }),
              updated.copyright.expiresAt.map({ $0 > .now }) ?? true else {
            pause(); clearOnline(); error = "当前音轨已下架、版本更换或授权到期，请重新选择。"; return
        }
        onlineTrack = updated
        updatePublicMetadata(updated)
        onlineQueue = tracks.filter { $0.albumID == updated.albumID }.sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        monitorOnlineLicense()
        updateNowPlaying()
    }

    private func advanceOnlineAfterEnd() async {
        guard wantsPlayback, let onlineTrack else { return }
        guard state.deadline?.expired() != true else { reconcileDeadline(); return }
        guard let index = onlineQueue.firstIndex(where: { $0.id == onlineTrack.id }) else {
            pause(); await onlinePlayer?.seek(to: .zero); return
        }
        if playbackMode == .single {
            let audio = onlinePlayer
            let attempt = activationID
            await seek(to: 0)
            guard onlinePlayer === audio, activationID == attempt, wantsPlayback else { return }
            await play()
            return
        }
        let next = onlineQueue[nextIndex(after: index, count: onlineQueue.count)]
        do {
            guard let url = try onlineURLProvider?(next, cellularAllowed) else { throw PlaybackError.missingAsset }
            await selectOnline(next, queue: onlineQueue, url: url, allowCellular: cellularAllowed)
        } catch { pause(); self.error = "下一首尚未完整缓存或网络不可用，请在曲库重试。" }
    }

    private func clearOnline(clearMetadata: Bool = true) {
        artworkTask?.cancel(); artworkTask = nil
        nowPlayingArtworkURL = nil; nowPlayingArtwork = nil
        licenseTask?.cancel(); licenseTask = nil
        onlineTimeout?.cancel(); onlineTimeout = nil
        onlineObservations = []
        if let onlineEndObserver { NotificationCenter.default.removeObserver(onlineEndObserver) }
        onlineEndObserver = nil; onlinePlayer = nil; onlineTrack = nil; onlineQueue = []
        if clearMetadata { clearPublicMetadata() }
        didSelectOnline?(nil)
    }

    private func monitorOnlineLicense() {
        licenseTask?.cancel()
        guard let expires = onlineTrack?.copyright.expiresAt else { return }
        licenseTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = expires.timeIntervalSinceNow
                guard remaining > 0 else {
                    self?.reportPlaybackError("当前音轨授权已到期，请刷新曲库并选择其他声音。")
                    return
                }
                do { try await Task.sleep(for: .seconds(min(remaining, 60))) } catch { return }
            }
        }
    }

    private func monitorOnlineTimeout() {
        onlineTimeout?.cancel()
        onlineTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.buffering else { return }
            self.pause(); self.error = "缓冲不足，播放已暂停。请连接网络或完整下载后重试。"
        }
    }

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
