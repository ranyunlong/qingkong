import AVFoundation
import Foundation
import Observation
import QingkongCore
#if os(iOS)
import MediaPlayer
#endif

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
    private(set) var playbackRevision: UInt64 = 0
    var playbackMode: AudioPlaybackMode {
        didSet {
            #if os(iOS)
            if let snapshot = desktopSnapshot, !applyingDesktopState {
                let requested = playbackMode
                applyingDesktopState = true; playbackMode = oldValue; applyingDesktopState = false
                Task { await executeDesktop(AudioCommand(action: .mode, playbackMode: requested), sessionID: snapshot.sessionID) }
                return
            }
            #endif
            state.playbackMode = playbackMode
            playbackRevision &+= 1
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
    private(set) var desktopSnapshot: DesktopPlaybackSnapshot?
    private(set) var desktopConnected = false
    private var pendingPhoneReturn: DesktopPlaybackSnapshot?
    @ObservationIgnored private var desktopReceivedAt = Date.distantPast
    @ObservationIgnored private var applyingDesktopState = false
    @ObservationIgnored private var desktopReturnAudio: AVPlayer?
    @ObservationIgnored private var desktopReturnBundled: AVAudioPlayer?
    @ObservationIgnored private var desktopReturnIdentity: String?
    @ObservationIgnored var desktopHandler: ((AudioCommand) async -> AudioReply)?
    @ObservationIgnored var desktopSelection: (([DesktopQueueItem], Int, Bool) async -> Void)?
    var isDesktopControlled: Bool { desktopSnapshot != nil }
    var playbackDeviceName: String? { desktopSnapshot?.deviceName }
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
    private(set) var airPlayRouteName: String?
    private(set) var airPlayRouteID: String?
    @ObservationIgnored private let phonePlaybackSessionID = UUID()
    @ObservationIgnored private var phonePlaybackRevision: UInt64 = 0
    @ObservationIgnored private var outputVolumeObservation: NSKeyValueObservation?
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
                Task { @MainActor in
                    #if os(iOS)
                    guard self?.isDesktopControlled != true else { return }
                    #endif
                    self?.pause()
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            #if os(iOS)
            Task { @MainActor in self?.refreshAirPlayRoute() }
            #endif
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in
                    #if os(iOS)
                    guard self?.isDesktopControlled != true else { return }
                    #endif
                    self?.pause()
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                #if os(iOS)
                guard self?.isDesktopControlled != true else { return }
                #endif
                self?.pause(); self?.player = nil
                self?.error = "音频服务已重置，请重新播放。"
            }
        })
        #if os(iOS)
        installRemoteCommands()
        // Configure audio-only route discovery even before the first song.
        // Activation still happens only when real playback starts.
        Self.audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        }
        refreshAirPlayRoute()
        outputVolumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isDesktopControlled, self.airPlayRouteID != nil else { return }
                // Notify current consumers without replacing the decoder's gain.
                self.didChangeState?(self.companionState)
            }
        }
        #endif
        if let data = defaults.data(forKey: Self.deadlineKey), let deadline = try? JSONDecoder().decode(SleepDeadline.self, from: data) {
            scheduleDeadline(deadline)
        }
    }

    func toggle() async {
        if state.playing || activating || buffering { pause() } else { await play() }
    }

    func play() async {
        #if os(iOS)
        if let snapshot = desktopSnapshot { await executeDesktop(AudioCommand(action: .play), sessionID: snapshot.sessionID); return }
        if var pending = pendingPhoneReturn {
            guard !activating else { return }
            pending.mode = playbackMode; pending.volume = state.volume; pending.deadline = state.deadline
            let attempt = UUID()
            activationID = attempt; activating = true; error = nil
            do {
                try await preparePhoneReturn(pending) {
                    self.activationID == attempt && self.pendingPhoneReturn?.sessionID == pending.sessionID
                }
                guard activationID == attempt, pendingPhoneReturn?.sessionID == pending.sessionID else { return }
                try await restoreFromDesktop(pending) {
                    self.activationID == attempt && self.pendingPhoneReturn?.sessionID == pending.sessionID
                }
                await play()
            } catch {
                guard activationID == attempt else { return }
                discardPhoneReturn(); activating = false
                self.error = "歌曲暂时无法在手机播放，请联网或下载后重试。"
            }
            return
        }
        #endif
        playbackRevision &+= 1
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
                        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
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
        #if os(iOS)
        if let snapshot = desktopSnapshot {
            Task { await executeDesktop(AudioCommand(action: .pause), sessionID: snapshot.sessionID) }
            return
        }
        #endif
        pauseLocalOutput()
    }

    private func pauseLocalOutput() {
        playbackRevision &+= 1
        wantsPlayback = false
        activationID = UUID(); activating = false
        player?.pause(); state.playing = false
        buffering = false
        #if os(iOS)
        onlinePlayer?.pause(); onlineTimeout?.cancel()
        // A pause (including the pause between songs) keeps the selected
        // AirPlay output. Deactivation would look like the user removed it.
        if airPlayRouteID == nil {
            Self.audioSessionQueue.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        #else
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        updateNowPlaying()
    }

    func reportPlaybackError(_ message: String) { pause(); error = message }

    var playbackDuration: TimeInterval {
        #if os(iOS)
        if let desktopSnapshot { return desktopSnapshot.duration }
        if let pendingPhoneReturn { return pendingPhoneReturn.duration }
        if let onlineTrack {
            if let duration = onlinePlayer?.currentItem?.duration.seconds, duration.isFinite, duration > 0 { return duration }
            return onlineTrack.durationSeconds.isFinite ? max(0, onlineTrack.durationSeconds) : 0
        }
        #endif
        return player?.duration ?? 0
    }

    var playbackPosition: TimeInterval {
        #if os(iOS)
        if let desktopSnapshot { return desktopSnapshot.projectedPosition(at: .now, receivedAt: desktopReceivedAt, connected: desktopConnected) }
        if let pendingPhoneReturn { return pendingPhoneReturn.position }
        #endif
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
        #if os(iOS)
        if let desktopSnapshot { return desktopConnected && !activating && desktopSnapshot.duration > 0 && !desktopSnapshot.buffering }
        #endif
        guard !activating, error == nil, playbackDuration > 0 else { return false }
        #if os(iOS)
        if let onlinePlayer { return onlinePlayer.currentItem?.status == .readyToPlay }
        #endif
        return player != nil
    }

    func seek(to seconds: TimeInterval) async {
        #if os(iOS)
        if let snapshot = desktopSnapshot { await executeDesktop(AudioCommand(action: .seek, amount: seconds), sessionID: snapshot.sessionID); return }
        #endif
        playbackRevision &+= 1
        guard seconds.isFinite, canSeek else { return }
        let position = min(playbackDuration, max(0, seconds))
        #if os(iOS)
        if let audio = onlinePlayer {
            let item = audio.currentItem
            let completed = await audio.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard onlinePlayer === audio, audio.currentItem === item else { return }
            guard completed else { error = "音乐进度未能调整，请重试。"; return }
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
        #if os(iOS)
        if isDesktopControlled {
            await desktopSelection?(Track.allCases.map { DesktopQueueItem(track: $0) }, Track.allCases.firstIndex(of: track) ?? 0, autoplay)
            return
        }
        #endif
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
        #if os(iOS)
        if let snapshot = desktopSnapshot {
            await executeDesktop(AudioCommand(action: step < 0 ? .previous : .next), sessionID: snapshot.sessionID); return
        }
        #endif
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
        #if os(iOS)
        if let snapshot = desktopSnapshot {
            Task { await executeDesktop(AudioCommand(action: .volume, amount: Double(value)), sessionID: snapshot.sessionID) }; return
        }
        #endif
        playbackRevision &+= 1
        guard value.isFinite else { return }
        state.volume = min(1, max(0, value))
        player?.volume = state.volume
        #if os(iOS)
        onlinePlayer?.volume = state.volume
        #endif
    }

    func setTimer(minutes: Int) {
        #if os(iOS)
        if let snapshot = desktopSnapshot {
            Task { await executeDesktop(AudioCommand(action: .timer, amount: Double(minutes)), sessionID: snapshot.sessionID) }; return
        }
        #endif
        playbackRevision &+= 1
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
        #if os(iOS)
        if isDesktopControlled { return }
        #endif
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
        #if os(iOS)
        if isDesktopControlled {
            guard let desktopHandler else { return AudioReply(id: command.id, state: state, error: "Mac 遥控暂不可用。") }
            return await desktopHandler(command)
        }
        #endif
        error = nil
        switch command.action {
        case .status: reconcileDeadline()
        case .play: await play()
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
        case .seek:
            if let amount = command.amount, amount.isFinite, amount >= 0 { await seek(to: amount) }
            else { error = "进度无效。" }
        case .mode:
            if let mode = command.playbackMode { playbackMode = mode }
            else { error = "播放模式无效。" }
        case .timer:
            if let amount = command.amount, [0.0, 15, 30, 60].contains(amount) { setTimer(minutes: Int(amount)) }
            else { error = "定时选项无效。" }
        }
        #if os(iOS)
        return AudioReply(id: command.id, state: companionState, error: error)
        #else
        return AudioReply(id: command.id, state: state, error: error)
        #endif
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
    private func executeDesktop(_ command: AudioCommand, sessionID: UUID) async {
        guard desktopSnapshot?.sessionID == sessionID, let desktopHandler else { return }
        let reply = await desktopHandler(command)
        if desktopSnapshot?.sessionID == sessionID { error = reply.error }
    }

    func desktopStart(serviceAddress: String) -> DesktopPlaybackStart? {
        if let snapshot = desktopSnapshot {
            return DesktopPlaybackStart(queue: snapshot.queue, index: snapshot.index, position: playbackPosition,
                playing: snapshot.playing, mode: snapshot.mode, deadline: snapshot.deadline, serviceAddress: serviceAddress)
        }
        guard hasSelection, !activating, !buffering, error == nil else { return nil }
        return localPlaybackStart(serviceAddress: serviceAddress)
    }

    private func localPlaybackStart(serviceAddress: String) -> DesktopPlaybackStart {
        if let pendingPhoneReturn {
            return DesktopPlaybackStart(queue: pendingPhoneReturn.queue, index: pendingPhoneReturn.index,
                position: pendingPhoneReturn.position, playing: false, mode: playbackMode,
                deadline: state.deadline, serviceAddress: serviceAddress)
        }
        let queue: [DesktopQueueItem]
        let index: Int
        if let onlineTrack {
            let tracks = onlineQueue.contains(where: { $0.cacheIdentity == onlineTrack.cacheIdentity }) ? onlineQueue : [onlineTrack]
            queue = tracks.map { DesktopQueueItem(onlineTrack: $0) }
            index = tracks.firstIndex(where: { $0.cacheIdentity == onlineTrack.cacheIdentity }) ?? 0
        } else {
            queue = Track.allCases.map { DesktopQueueItem(track: $0) }
            index = Track.allCases.firstIndex(of: state.track) ?? 0
        }
        return DesktopPlaybackStart(queue: queue, index: index, position: playbackPosition, playing: state.playing,
            mode: playbackMode, deadline: state.deadline, serviceAddress: serviceAddress)
    }

    func pauseForDesktopTransfer() { pauseLocalOutput() }

    func applyDesktop(_ snapshot: DesktopPlaybackSnapshot, connected: Bool) {
        guard snapshot.isValid, let item = snapshot.currentItem else { return }
        if let previous = desktopSnapshot, previous.sessionID == snapshot.sessionID, previous.revision > snapshot.revision { return }
        if desktopSnapshot == nil {
            pauseLocalOutput(); player = nil; clearOnline()
            stopTask?.cancel(); stopTask = nil
            defaults.removeObject(forKey: Self.deadlineKey)
        }
        desktopSnapshot = snapshot; desktopConnected = connected; desktopReceivedAt = .now
        applyingDesktopState = true; playbackMode = snapshot.mode; applyingDesktopState = false
        onlineTrack = item.onlineTrack
        var next = AudioState()
        next.track = item.track ?? state.track
        next.onlineTrackID = item.onlineTrack?.id; next.onlineTitle = item.onlineTrack?.title
        next.onlineArtworkURL = item.onlineTrack?.coverURL
        next.playing = snapshot.playing; next.buffering = snapshot.buffering ? true : nil
        next.volume = snapshot.volume; next.deadline = snapshot.deadline
        next.playbackDevice = snapshot.deviceName; next.playbackSessionID = snapshot.sessionID
        next.playbackPosition = snapshot.position; next.playbackDuration = snapshot.duration
        next.playbackMode = snapshot.mode; next.sampledAt = .now; next.remoteConnected = connected
        buffering = snapshot.buffering; hasSelection = true; error = nil; state = next
        refreshNowPlayingArtwork(); updateNowPlaying()
        if !connected { desktopConnectionLost("与 Mac 的连接已中断，可切回此 iPhone。") }
    }

    func desktopConnectionLost(_ message: String) {
        let position = playbackPosition
        desktopSnapshot?.position = position
        desktopSnapshot?.playing = false; desktopSnapshot?.buffering = false
        desktopConnected = false
        buffering = false; state.playing = false
        state.playbackPosition = position; state.remoteConnected = false
        error = message
        updateNowPlaying()
    }

    /// Relinquish an unreachable remote route without starting a second audio output.
    /// Keep a silent selection even when the local file is not currently available.
    func returnToPhonePaused(_ snapshot: DesktopPlaybackSnapshot) {
        guard snapshot.isValid, let item = snapshot.currentItem else { return }
        var paused = snapshot
        if desktopSnapshot?.sessionID == snapshot.sessionID { paused.position = playbackPosition }
        paused.playing = false; paused.buffering = false
        clearDesktopSelection()
        if let track = item.onlineTrack {
            onlineTrack = track; onlineQueue = snapshot.queue.compactMap(\.onlineTrack)
            updatePublicMetadata(track)
        } else if let track = item.track { state.track = track }
        pendingPhoneReturn = paused
        hasSelection = true
        playbackMode = snapshot.mode
        state.volume = snapshot.volume
        scheduleDeadline(snapshot.deadline)
        updateNowPlaying()
    }

    func clearDesktopSelection() {
        discardPhoneReturn()
        desktopSnapshot = nil; desktopConnected = false
        pauseLocalOutput(); clearOnline(); player = nil
        hasSelection = false; state = AudioState(); error = nil
        updateNowPlaying()
    }

    func preparePhoneReturn(_ snapshot: DesktopPlaybackSnapshot, isCurrent: () -> Bool = { true }) async throws {
        discardPhoneReturn()
        guard isCurrent() else { throw CancellationError() }
        guard snapshot.isValid, let item = snapshot.currentItem else { throw URLError(.cannotParseResponse) }
        if let track = item.onlineTrack {
            guard track.copyright.expiresAt.map({ $0 > .now }) ?? true,
                  let url = try onlineURLProvider?(track, false) else { throw PlaybackError.missingAsset }
            let asset = AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: false])
            let loaded = AVPlayerItem(asset: asset)
            let audio = AVPlayer(playerItem: loaded)
            let limit = ContinuousClock.now.advanced(by: .seconds(12))
            while loaded.status != .readyToPlay {
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                guard loaded.status != .failed, ContinuousClock.now < limit else { throw PlaybackError.cannotPlay }
                try await Task.sleep(for: .milliseconds(40))
            }
            guard isCurrent() else { throw CancellationError() }
            desktopReturnAudio = audio; desktopReturnIdentity = track.cacheIdentity
        } else if let track = item.track {
            guard let url = Bundle.main.url(forResource: track.rawValue, withExtension: "wav") else { throw PlaybackError.missingAsset }
            let audio = try AVAudioPlayer(contentsOf: url)
            guard audio.prepareToPlay() else { throw PlaybackError.cannotPlay }
            desktopReturnBundled = audio; desktopReturnIdentity = "builtin:\(track.rawValue)"
        }
    }

    func discardPhoneReturn() {
        desktopReturnAudio?.pause(); desktopReturnAudio = nil; desktopReturnIdentity = nil
        desktopReturnBundled?.stop(); desktopReturnBundled = nil
    }

    func restoreFromDesktop(_ snapshot: DesktopPlaybackSnapshot, isCurrent: () -> Bool) async throws {
        guard snapshot.isValid, let item = snapshot.currentItem else { throw URLError(.cannotParseResponse) }
        let preparedAudio = desktopReturnAudio
        let preparedBundled = desktopReturnBundled
        if let track = item.onlineTrack {
            guard desktopReturnIdentity == track.cacheIdentity,
                  preparedAudio?.currentItem?.status == .readyToPlay else { throw PlaybackError.cannotPlay }
            let completed = await preparedAudio!.seek(to: CMTime(seconds: snapshot.position, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
            guard completed else { throw PlaybackError.cannotPlay }
        } else if let track = item.track {
            guard let preparedBundled, desktopReturnIdentity == "builtin:\(track.rawValue)" else { throw PlaybackError.cannotPlay }
            preparedBundled.currentTime = min(snapshot.position, preparedBundled.duration)
        }
        // Keep the remote route until all asynchronous decoder work has completed.
        guard isCurrent(), desktopSnapshot?.sessionID == snapshot.sessionID || pendingPhoneReturn?.sessionID == snapshot.sessionID else { throw CancellationError() }
        desktopReturnAudio = nil; desktopReturnIdentity = nil; desktopReturnBundled = nil
        clearDesktopSelection()
        if let track = item.onlineTrack, let preparedAudio, let asset = preparedAudio.currentItem?.asset as? AVURLAsset {
            await selectOnline(track, queue: snapshot.queue.compactMap(\.onlineTrack), url: asset.url,
                allowCellular: false, autoplay: false, preparedAudio: preparedAudio)
        } else if let track = item.track, let preparedBundled {
            preparedBundled.delegate = self; player = preparedBundled
            state.track = track; hasSelection = true
        }
        applyingDesktopState = true; playbackMode = snapshot.mode; applyingDesktopState = false
        setVolume(snapshot.volume); scheduleDeadline(snapshot.deadline)
        updateNowPlaying()
    }

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
        var info: [String: Any] = [MPMediaItemPropertyTitle: state.displayTitle, MPMediaItemPropertyArtist: "小晴空 · 自然声音", MPNowPlayingInfoPropertyPlaybackRate: state.playing && state.remoteConnected != false ? 1.0 : 0.0, MPNowPlayingInfoPropertyIsLiveStream: onlineTrack == nil && !isDesktopControlled && airPlayRouteID == nil]
        if onlineTrack != nil || isDesktopControlled || airPlayRouteID != nil {
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
    func selectOnline(_ track: PublicAudioTrack, queue: [PublicAudioTrack], url: URL, allowCellular: Bool, autoplay: Bool = true, preparedAudio: AVPlayer? = nil) async {
        if isDesktopControlled {
            let selection = queue.contains(where: { $0.cacheIdentity == track.cacheIdentity }) ? queue : [track]
            await desktopSelection?(selection.map { DesktopQueueItem(onlineTrack: $0) }, selection.firstIndex(where: { $0.cacheIdentity == track.cacheIdentity }) ?? 0, autoplay)
            return
        }
        hasSelection = true
        pause(); clearOnline(clearMetadata: false); player = nil
        onlineTrack = track; onlineQueue = queue; cellularAllowed = allowCellular
        monitorOnlineLicense()
        updatePublicMetadata(track)
        error = nil
        let asset = AVURLAsset(url: url, options: [AVURLAssetAllowsCellularAccessKey: allowCellular])
        let item = preparedAudio?.currentItem ?? AVPlayerItem(asset: asset)
        let audio = preparedAudio ?? AVPlayer(playerItem: item)
        // Use the audio-session route, not video external playback (which can
        // present an empty receiver window for audio-only MP4 assets).
        audio.allowsExternalPlayback = false
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
        guard !isDesktopControlled else { return }
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
        discardPhoneReturn()
        pendingPhoneReturn = nil
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
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in await self?.seek(to: event.positionTime) }; return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.skip(1) }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in await self?.skip(-1) }; return .success }
    }

    func refreshAirPlayRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.filter { $0.portType == .airPlay }
        updateAirPlayRoute(name: outputs.count == 1 ? outputs[0].portName : nil,
                           id: outputs.isEmpty ? nil : outputs.map(\.uid).sorted().joined(separator: "|"))
    }

    func updateAirPlayRoute(name: String?, id: String?) {
        let leftAirPlay = airPlayRouteID != nil && id == nil
        airPlayRouteName = name
        airPlayRouteID = id
        // Stop the real decoder before publishing the route change so audio
        // cannot continue from the phone when its AirPlay output is removed.
        if leftAirPlay, !isDesktopControlled { pauseLocalOutput() }
        if state.airPlayRouteName != airPlayRouteName { state.airPlayRouteName = airPlayRouteName }
    }

    var companionState: AudioState {
        var result = state
        if !isDesktopControlled, airPlayRouteID != nil {
            result.airPlayRouteName = airPlayRouteName
            result.volume = AVAudioSession.sharedInstance().outputVolume
            result.playbackPosition = playbackPosition; result.playbackDuration = playbackDuration
            result.playbackMode = playbackMode; result.sampledAt = .now
        }
        return result
    }

    func phonePlaybackSnapshot() -> DesktopPlaybackSnapshot? {
        guard !isDesktopControlled, hasSelection else { return nil }
        // Buffering and failures still describe the current player. They must
        // not be mistaken for leaving the AirPlay route and clear the Mac UI.
        let start = localPlaybackStart(serviceAddress: "")
        phonePlaybackRevision &+= 1
        let duration = max(0, playbackDuration.isFinite ? playbackDuration : 0)
        return .init(sessionID: phonePlaybackSessionID, revision: phonePlaybackRevision,
            queue: start.queue, index: start.index, position: min(duration, max(0, playbackPosition)),
            duration: duration, playing: state.playing, buffering: buffering, mode: playbackMode,
            volume: AVAudioSession.sharedInstance().outputVolume, deadline: state.deadline, deviceName: UIDevice.current.name)
    }

    func handlePhonePlayback(_ command: PhonePlaybackCommand) async -> PhonePlaybackReply {
        guard command.isValid, command.sessionID == phonePlaybackSessionID,
              !isDesktopControlled, airPlayRouteID != nil, hasSelection else {
            return .init(id: command.id, sessionID: command.sessionID, error: "iPhone 的 AirPlay 播放已变化，未执行操作。")
        }
        error = nil
        switch command.action {
        case .status: reconcileDeadline()
        case .play: await play()
        case .pause, .release: pause()
        case .previous: await skip(-1)
        case .next: await skip(1)
        case .volume:
            return .init(id: command.id, sessionID: command.sessionID, snapshot: phonePlaybackSnapshot(),
                         error: "请在 iPhone 或 Apple Watch 调整 AirPlay 音量。")
        case .mode: playbackMode = command.mode!
        case .timer: scheduleDeadline(command.deadline)
        case .seek:
            guard canSeek else { return .init(id: command.id, sessionID: command.sessionID, error: "歌曲尚未准备好，未调整进度。") }
            await seek(to: command.amount!)
        case .stop:
            pause()
            if canSeek { await seek(to: 0) }
        case .select:
            let target = Int(command.amount!)
            if onlineTrack != nil {
                guard onlineQueue.indices.contains(target) else {
                    return .init(id: command.id, sessionID: command.sessionID, error: "播放队列已变化。")
                }
                let track = onlineQueue[target]
                do {
                    guard let url = try onlineURLProvider?(track, cellularAllowed) else { throw PlaybackError.missingAsset }
                    await selectOnline(track, queue: onlineQueue, url: url, allowCellular: cellularAllowed)
                } catch { self.error = "这首歌曲暂时无法在 iPhone 播放。" }
            } else if Track.allCases.indices.contains(target) {
                await select(Track.allCases[target], autoplay: true)
            } else { error = "播放队列已变化。" }
        }
        return .init(id: command.id, sessionID: command.sessionID, snapshot: phonePlaybackSnapshot(), error: error)
    }
    #endif

    private enum PlaybackError: Error { case noRoute, missingAsset, cannotPlay }
}
