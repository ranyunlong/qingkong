import AVFoundation
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import QingkongCore

/// Independent Mac audio, or a display/controller for the iPhone's AirPlay decoder.
@MainActor @Observable
final class MacAudioPlayer {
    private(set) var title = "选择一种声音"
    private(set) var subtitle = ""
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var isBuffering = false
    private(set) var hasSelection = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var error: String?
    private(set) var deadline: SleepDeadline?
    private(set) var mode: AudioPlaybackMode = .single
    private(set) var controlledSessionID: UUID?
    private(set) var phoneSnapshot: DesktopPlaybackSnapshot?
    private(set) var phoneConnected = false
    private(set) var phoneControlBusy = false
    var isPhonePlayback: Bool { phoneSnapshot != nil }
    var controlsAvailable: Bool { !isPhonePlayback || (phoneConnected && !phoneControlBusy) }
    @ObservationIgnored var phoneCommandHandler: ((PhonePlaybackCommand) async throws -> PhonePlaybackReply)?
    @ObservationIgnored private var phoneReceivedAt = Date.distantPast
    @ObservationIgnored private var applyingPhoneState = false
    var volume: Double = 0.45 {
        didSet {
            guard !applyingPhoneState else { return }
            if isPhonePlayback {
                applyingPhoneState = true; volume = oldValue; applyingPhoneState = false
                return
            }
            active?.bundled?.volume = Float(volume); active?.streamed?.volume = Float(volume)
            markChanged()
        }
    }
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored var onlineCatalogProvider: ((String) -> [PublicAudioTrack]?)?
    @ObservationIgnored var localAudioURLProvider: ((PublicAudioTrack, String) -> URL?)?
    @ObservationIgnored var didSelectOnline: ((PublicAudioTrack?) -> Void)?
    @ObservationIgnored var didStartOnline: ((PublicAudioTrack) -> Void)?
    @ObservationIgnored private var active: LoadedAudio?
    @ObservationIgnored private var prepared: PreparedAudio?
    @ObservationIgnored private var preparingStart: DesktopPlaybackStart?
    private var queue: [DesktopQueueItem] = []
    private var index = 0
    @ObservationIgnored private var serviceAddress = ""
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var preparation = UUID()
    @ObservationIgnored private var advancing = false
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    private var wantsPlayback = false
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var systemPlayback: MacSystemPlayback?

    func enableSystemPlayback(canControl: @escaping () -> Bool) {
        guard systemPlayback == nil else { return }
        systemPlayback = MacSystemPlayback(player: self, canControl: canControl)
        systemPlayback?.update()
    }

    @MainActor private final class LoadedAudio: NSObject, AVAudioPlayerDelegate {
        var bundled: AVAudioPlayer?
        var streamed: AVPlayer?
        // Only player-created temporary files belong to this decoder. Downloads own persistent files.
        var temporaryFile: URL?
        var duration: TimeInterval = 0
        var expiresAt: Date?
        var ended = false
        var endObserver: NSObjectProtocol?
        nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor [weak self] in self?.ended = true }
        }
        func dispose() {
            bundled?.stop(); streamed?.pause()
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
            temporaryFile = nil
        }
    }
    private struct PreparedAudio {
        let start: DesktopPlaybackStart
        let audio: LoadedAudio
        let preparedAt: Date
    }

    var playbackPosition: TimeInterval {
        if let phoneSnapshot {
            return phoneSnapshot.projectedPosition(at: .now, receivedAt: phoneReceivedAt, connected: phoneConnected)
        }
        let seconds = active?.bundled?.currentTime ?? active?.streamed?.currentTime().seconds ?? position
        return seconds.isFinite ? min(max(0, seconds), max(0, duration)) : 0
    }
    var playbackIntent: Bool { wantsPlayback }
    var queueItems: [DesktopQueueItem] { queue }
    var currentIndex: Int { index }
    var currentItem: DesktopQueueItem? { queue.indices.contains(index) ? queue[index] : nil }

    func playQueueItem(at target: Int, playing: Bool = true) {
        guard queue.indices.contains(target), !isPreparing else { return }
        if isPhonePlayback {
            Task { _ = await sendPhoneCommand(.select, amount: Double(target)) }
            return
        }
        beginLoading(index: target, playing: playing)
    }
    var snapshot: DesktopPlaybackSnapshot? {
        updateProgress()
        guard let sessionID = controlledSessionID, !queue.isEmpty else { return nil }
        return DesktopPlaybackSnapshot(sessionID: sessionID, revision: revision, queue: queue,
            index: index, position: playbackPosition, duration: duration, playing: isPlaying,
            buffering: isBuffering, mode: mode, volume: Float(volume), deadline: deadline,
            deviceName: Host.current().localizedName ?? "Mac")
    }

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            }
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pauseControlledSession() }
            })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateProgress() }
            })
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                self.updateProgress()
            }
        }
    }

    func play(_ track: Track, playing: Bool = true) {
        if isPhonePlayback {
            takeOverPhonePlayback { [weak self] in self?.play(track, playing: playing) }
            return
        }
        if controlledSessionID == nil { reset() }
        do {
            guard let url = Bundle.main.url(forResource: track.rawValue, withExtension: "wav") else {
                throw MacCompanionError.message("内置声音文件缺失，请重新安装小晴空。")
            }
            let audio = LoadedAudio(); let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else { throw MacCompanionError.message("这首声音暂时无法播放。") }
            audio.bundled = player; player.delegate = audio; audio.duration = player.duration
            // A Mac selection remains part of the authoritative handoff session.
            // Keep its identity, revision, volume and absolute stop time.
            cancelLoading(); discardPreparation(); active?.dispose(); active = nil
            queue = Track.allCases.map { DesktopQueueItem(track: $0) }
            index = Track.allCases.firstIndex(of: track) ?? 0
            didSelectOnline?(nil)
            install(audio, playing: playing)
        } catch { self.error = error.localizedDescription }
    }

    /// Selecting an album locally preserves any authenticated phone control session.
    func playOnlineQueue(_ tracks: [PublicAudioTrack], index target: Int, serviceAddress: String, playing: Bool = true) {
        guard tracks.indices.contains(target), !tracks.isEmpty,
              Set(tracks.map(\.id)).count == tracks.count,
              tracks.allSatisfy({ $0.copyright.expiresAt.map { $0 > .now } ?? true }),
              (try? PublicContentURL.snapshotURL(from: serviceAddress)) != nil else {
            error = "音轨目录无效或授权已到期，请刷新后重试。"; return
        }
        if isPhonePlayback {
            takeOverPhonePlayback { [weak self] in self?.playOnlineQueue(tracks, index: target, serviceAddress: serviceAddress, playing: playing) }
            return
        }
        if controlledSessionID == nil { reset() }
        discardPreparation()
        queue = tracks.map { DesktopQueueItem(onlineTrack: $0) }
        self.serviceAddress = serviceAddress
        beginLoading(index: target, playing: playing)
    }

    func reconcileOnlineCatalog(_ tracks: [PublicAudioTrack], serviceAddress: String) {
        guard !isPhonePlayback else { return }
        let sameService = canonicalService(self.serviceAddress) == canonicalService(serviceAddress)
        if let pending = preparingStart ?? prepared?.start, pending.queue.contains(where: { $0.onlineTrack != nil }) {
            let preparationService = canonicalService(pending.serviceAddress) == canonicalService(serviceAddress)
            if !preparationService || pending.queue.compactMap(\.onlineTrack).contains(where: { old in
                !tracks.contains { $0.cacheIdentity == old.cacheIdentity && $0.albumID == old.albumID }
            }) { discardPreparation() }
        }
        guard let selected = currentItem?.onlineTrack else { return }
        let available = Dictionary(uniqueKeysWithValues: tracks.map { ($0.cacheIdentity, $0) })
        guard sameService, let current = available[selected.cacheIdentity],
              current.copyright.expiresAt.map({ $0 > .now }) ?? true else {
            cancelLoading(); active?.dispose(); active = nil; didSelectOnline?(nil)
            // Keep the last legal queue for v2 phone receipts, while disabling local resume.
            if controlledSessionID == nil { queue = []; index = 0 }
            position = 0; duration = 0
            wantsPlayback = false; isPlaying = false; isBuffering = false; hasSelection = false
            title = "请选择其他声音"; error = "当前音轨已下架、版本更换或授权到期，播放已停止。"
            markChanged(); return
        }
        let nextQueue = queue.compactMap { item -> DesktopQueueItem? in
            if let online = item.onlineTrack { return available[online.cacheIdentity].map { DesktopQueueItem(onlineTrack: $0) } }
            return item
        }
        let nextIndex = nextQueue.firstIndex { $0.onlineTrack?.cacheIdentity == current.cacheIdentity } ?? 0
        if nextQueue != queue || nextIndex != index {
            queue = nextQueue; index = nextIndex; title = current.title; markChanged()
        }
        active?.expiresAt = current.copyright.expiresAt
    }

    func toggle() {
        guard hasSelection else { return }
        if isPhonePlayback {
            let action: PhonePlaybackCommand.Action = wantsPlayback ? .pause : .play
            Task { _ = await sendPhoneCommand(action) }
            return
        }
        if wantsPlayback { pause() } else { resume() }
    }
    private func resume() {
        guard hasSelection else { return }
        guard let active else {
            if loadingTask != nil { wantsPlayback = true; isBuffering = true; markChanged() }
            else if !queue.isEmpty { beginLoading(index: index, playing: true) }
            return
        }
        if deadline?.expired() == true { deadline = nil }
        guard active.expiresAt.map({ $0 > .now }) ?? true else {
            pause(); error = "这首音轨授权已到期，请重新从 iPhone 接播。"; return
        }
        wantsPlayback = true
        if let player = active.bundled {
            if player.currentTime >= player.duration { player.currentTime = 0 }
            isPlaying = player.play()
        } else { active.streamed?.play() }
        updateProgress(); markChanged()
    }
    func pause() {
        if isPhonePlayback { Task { _ = await sendPhoneCommand(.pause) }; return }
        cancelLoading()
        wantsPlayback = false; active?.bundled?.pause(); active?.streamed?.pause()
        isPlaying = false; isBuffering = false; position = playbackPosition; markChanged()
    }
    func stop() {
        if isPhonePlayback { Task { _ = await sendPhoneCommand(.stop) }; return }
        guard controlledSessionID != nil else { reset(); return }
        pause(); discardPreparation()
        if active != nil { Task { [weak self] in await self?.seek(to: 0) } }
    }
    private func reset() {
        phoneSnapshot = nil; phoneConnected = false
        cancelLoading(); preparation = UUID(); active?.dispose(); prepared?.audio.dispose()
        active = nil; prepared = nil; preparingStart = nil; didSelectOnline?(nil); controlledSessionID = nil; queue = []; index = 0
        wantsPlayback = false; isPlaying = false; isPreparing = false; isBuffering = false
        hasSelection = false; position = 0; duration = 0; deadline = nil; error = nil
        title = "选择一种声音"; subtitle = ""; markChanged()
    }
    func setTimer(minutes: Int) {
        if isPhonePlayback {
            let deadline = minutes > 0 ? SleepDeadline(minutes: minutes) : nil
            Task { _ = await sendPhoneCommand(.timer, deadline: deadline) }; return
        }
        deadline = minutes > 0 ? SleepDeadline(minutes: minutes) : nil; markChanged()
    }
    func setMode(_ value: AudioPlaybackMode) {
        if isPhonePlayback { Task { _ = await sendPhoneCommand(.mode, mode: value) }; return }
        mode = value; markChanged()
    }
    func previous() async { await moveFromUI(by: -1) }
    func next() async { await moveFromUI(by: 1) }
    private func moveFromUI(by offset: Int) async {
        if isPhonePlayback { _ = await sendPhoneCommand(offset < 0 ? .previous : .next); return }
        do { try scheduleMove(by: offset) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func seek(to seconds: TimeInterval) async {
        if isPhonePlayback { _ = await sendPhoneCommand(.seek, amount: seconds); return }
        do { try await seekChecked(to: seconds) }
        catch { self.error = error.localizedDescription }
    }
    private func seekChecked(to seconds: TimeInterval) async throws {
        guard seconds.isFinite, hasSelection, let active else { throw DesktopConnectionError.invalidMessage }
        try await seek(active, to: min(max(0, seconds), duration))
        position = playbackPosition; markChanged()
    }
    private func seek(_ audio: LoadedAudio, to seconds: TimeInterval) async throws {
        if let player = audio.bundled { player.currentTime = seconds; audio.ended = false }
        else if let player = audio.streamed {
            let completed = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard completed else { throw MacCompanionError.message("音乐进度未能恢复，请重试。") }
            audio.ended = false
        }
    }

    /// Preparation never changes the currently audible player or the local volume.
    func prepare(_ start: DesktopPlaybackStart) async throws -> UUID {
        guard !isPhonePlayback, start.isValid, start.deadline?.expired() != true else { throw DesktopConnectionError.invalidMessage }
        prepared?.audio.dispose(); prepared = nil
        try validateCatalogQueue(start)
        let attempt = UUID(); preparation = attempt; preparingStart = start; isPreparing = true
        defer { if preparation == attempt { isPreparing = false; preparingStart = nil } }
        let audio = try await load(start.queue[start.index], serviceAddress: start.serviceAddress)
        do {
            guard preparation == attempt else { throw CancellationError() }
            try validateCatalogQueue(start)
            guard start.position < audio.duration else { throw MacCompanionError.message("手机已接近曲尾，请重新选择音乐。") }
            try await seek(audio, to: start.position)
            guard preparation == attempt, start.deadline?.expired() != true,
                  audio.expiresAt.map({ $0 > .now }) ?? true else { throw CancellationError() }
            try validateCatalogQueue(start)
            prepared = PreparedAudio(start: start, audio: audio, preparedAt: .now)
            return start.sessionID
        } catch { audio.dispose(); throw error }
    }

    private func validateCatalogQueue(_ start: DesktopPlaybackStart) throws {
        guard let available = onlineCatalogProvider?(start.serviceAddress) else { return }
        guard start.queue.compactMap(\.onlineTrack).allSatisfy({ old in
            available.contains { $0.cacheIdentity == old.cacheIdentity && $0.albumID == old.albumID &&
                ($0.copyright.expiresAt.map { $0 > .now } ?? true) }
        }) else { throw MacCompanionError.message("接播队列中的音轨已更新、下架或授权到期，请重新选择。") }
    }

    private func canonicalService(_ address: String) -> String? {
        guard let url = try? PublicContentURL.snapshotURL(from: address),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        return parts.url?.absoluteString
    }

    func discardPreparation() {
        preparation = UUID(); preparingStart = nil; prepared?.audio.dispose(); prepared = nil; isPreparing = false
    }
    func commit(sessionID: UUID, latest: DesktopPlaybackStart? = nil) async throws -> DesktopPlaybackSnapshot {
        guard let prepared, prepared.start.sessionID == sessionID,
              Date.now.timeIntervalSince(prepared.preparedAt) < 30,
              prepared.start.deadline?.expired() != true,
              prepared.audio.expiresAt.map({ $0 > .now }) ?? true else {
            discardPreparation(); throw MacCompanionError.message("接播准备已过期，请重新发起。")
        }
        do { try validateCatalogQueue(prepared.start) }
        catch { discardPreparation(); throw error }
        let attempt = preparation
        if let latest {
            let staged = prepared.start
            guard latest.isValid, latest.sessionID == sessionID, latest.queue == staged.queue,
                  latest.index == staged.index, latest.mode == staged.mode, latest.deadline == staged.deadline,
                  latest.serviceAddress == staged.serviceAddress, latest.playing == staged.playing,
                  latest.position < prepared.audio.duration else { throw DesktopConnectionError.invalidMessage }
            try await seek(prepared.audio, to: latest.position)
        }
        // Any await may let the directory shorten rights without changing the cache identity.
        // Validate at the installation boundary, before disposing the currently audible player.
        do {
            guard preparation == attempt, self.prepared?.start.sessionID == sessionID,
                  Date.now.timeIntervalSince(prepared.preparedAt) < 30,
                  prepared.start.deadline?.expired() != true,
                  prepared.audio.expiresAt.map({ $0 > .now }) ?? true else {
                throw MacCompanionError.message("接播准备已过期，请重新发起。")
            }
            try validateCatalogQueue(prepared.start)
        } catch {
            if preparation == attempt { discardPreparation() }
            throw error
        }
        cancelLoading(); active?.dispose(); self.prepared = nil
        queue = prepared.start.queue; index = prepared.start.index; mode = prepared.start.mode
        didSelectOnline?(queue[index].onlineTrack)
        serviceAddress = prepared.start.serviceAddress; deadline = prepared.start.deadline
        controlledSessionID = sessionID; revision = 0
        install(prepared.audio, playing: prepared.start.playing)
        guard let snapshot else { throw DesktopConnectionError.invalidMessage }
        return snapshot
    }

    func execute(_ command: DesktopPlaybackCommand) async throws -> DesktopPlaybackSnapshot {
        guard command.isValid, command.sessionID == controlledSessionID else { throw DesktopConnectionError.invalidMessage }
        switch command.action {
        case .status: updateProgress()
        case .play:
            guard active?.expiresAt.map({ $0 > .now }) ?? true else {
                throw MacCompanionError.message("这首音轨授权已到期，请重新从 iPhone 接播。")
            }
            resume()
        case .pause: pause()
        case .previous: try scheduleMove(by: -1)
        case .next: try scheduleMove(by: 1)
        case .seek: try await seekChecked(to: command.amount!)
        case .volume: volume = command.amount!
        case .mode: setMode(command.mode!)
        case .timer:
            deadline = command.deadline
            if deadline?.expired() == true { pause(); deadline = nil }
            markChanged()
        case .release: pause()
        }
        guard let snapshot else { throw DesktopConnectionError.invalidMessage }
        return snapshot
    }
    func pauseControlledSession() { if controlledSessionID != nil { pause() }; discardPreparation() }
    func discardControlledSession() {
        if controlledSessionID != nil { reset() }
        else { discardPreparation() }
    }

    private func move(by offset: Int, naturalEnd: Bool = false) async throws {
        guard !queue.isEmpty else { throw DesktopConnectionError.invalidMessage }
        if naturalEnd && (mode == .single || queue.count == 1), let active {
            guard !advancing else { return }
            advancing = true; defer { advancing = false }
            let attempt = operation
            try await seek(active, to: 0)
            guard operation == attempt else { throw CancellationError() }
            resume(); return
        }
        try scheduleMove(by: offset, naturalEnd: naturalEnd)
    }
    private func scheduleMove(by offset: Int, naturalEnd: Bool = false) throws {
        guard !queue.isEmpty else { throw DesktopConnectionError.invalidMessage }
        let nextIndex: Int
        if mode == .shuffle && queue.count > 1 {
            nextIndex = queue.indices.filter { $0 != index }.randomElement() ?? index
        } else { nextIndex = (index + offset + queue.count) % queue.count }
        beginLoading(index: nextIndex, playing: naturalEnd || wantsPlayback)
    }

    /// Acknowledges entry into actual loading immediately, so Watch commands stay bounded.
    private func beginLoading(index target: Int, playing: Bool) {
        cancelLoading(); active?.dispose(); active = nil
        index = target; position = 0
        didSelectOnline?(queue[target].onlineTrack)
        let length = queue[target].onlineTrack?.durationSeconds ?? 0
        duration = length.isFinite && length > 0 ? length : 0
        hasSelection = true; wantsPlayback = playing; isPlaying = false; isBuffering = true
        title = queue[target].title; error = nil
        let attempt = operation; let item = queue[target]; let address = serviceAddress
        markChanged()
        loadingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.load(item, serviceAddress: address)
                guard self.operation == attempt, !Task.isCancelled else { audio.dispose(); return }
                self.loadingTask = nil
                self.install(audio, playing: self.wantsPlayback)
            } catch is CancellationError { }
            catch {
                guard self.operation == attempt else { return }
                self.loadingTask = nil; self.wantsPlayback = false
                self.isPlaying = false; self.isBuffering = false; self.error = error.localizedDescription
                self.markChanged()
            }
        }
    }
    private func cancelLoading() {
        operation = UUID(); loadingTask?.cancel(); loadingTask = nil
    }
    private func install(_ audio: LoadedAudio, playing: Bool) {
        if let selected = currentItem?.onlineTrack,
           let catalog = onlineCatalogProvider?(serviceAddress),
           let current = catalog.first(where: { $0.cacheIdentity == selected.cacheIdentity }) {
            audio.expiresAt = current.copyright.expiresAt
        }
        active = audio; duration = audio.duration; position = playbackPosition
        hasSelection = true; title = queue[index].title; error = nil
        subtitle = controlledSessionID == nil ? "" : "iPhone 遥控 · 在这台 Mac 上播放"
        audio.bundled?.volume = Float(volume); audio.streamed?.volume = Float(volume)
        wantsPlayback = false; isPlaying = false; isBuffering = false
        if deadline?.expired() == true { deadline = nil }
        else if playing { resume() }
        markChanged()
    }
    private func load(_ item: DesktopQueueItem, serviceAddress: String) async throws -> LoadedAudio {
        let audio = LoadedAudio()
        do {
            if let track = item.onlineTrack {
                let current: PublicAudioTrack
                if let catalog = onlineCatalogProvider?(serviceAddress) {
                    guard let valid = catalog.first(where: { $0.cacheIdentity == track.cacheIdentity && $0.albumID == track.albumID }),
                          valid.copyright.expiresAt.map({ $0 > .now }) ?? true else {
                        throw MacCompanionError.message("音轨已下架、版本更新或授权到期，请刷新曲库。")
                    }
                    current = valid
                } else {
                    let checked = try await validatedOnlineTrack(track, serviceAddress: serviceAddress)
                    current = checked.track
                }
                let file: URL
                if let local = localAudioURLProvider?(current, serviceAddress) { file = local }
                else { file = try await download(current); audio.temporaryFile = file }
                audio.expiresAt = current.copyright.expiresAt
                let playerItem = AVPlayerItem(url: file)
                let player = AVPlayer(playerItem: playerItem); audio.streamed = player; player.volume = 0
                let limit = Date.now.addingTimeInterval(8)
                while playerItem.status != .readyToPlay {
                    try Task.checkCancellation()
                    guard playerItem.status != .failed, .now < limit else { throw MacCompanionError.message("音轨无法在 Mac 上解码。") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let length = playerItem.duration.seconds
                guard length.isFinite, length > 0 else { throw DesktopConnectionError.invalidMessage }
                audio.duration = length
                audio.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                    object: playerItem, queue: .main) { [weak audio] _ in
                        MainActor.assumeIsolated { audio?.ended = true }
                    }
            } else if let track = item.track,
                      let url = Bundle.main.url(forResource: track.rawValue, withExtension: "wav") {
                let player = try AVAudioPlayer(contentsOf: url)
                player.volume = 0; player.numberOfLoops = 0
                guard player.prepareToPlay() else { throw MacCompanionError.message("内置声音无法准备。") }
                audio.bundled = player; player.delegate = audio; audio.duration = player.duration
            } else { throw MacCompanionError.message("这台 Mac 缺少对应声音。") }
            return audio
        } catch { audio.dispose(); throw error }
    }

    private nonisolated func validatedOnlineTrack(_ track: PublicAudioTrack, serviceAddress: String) async throws -> (track: PublicAudioTrack, snapshot: PublicContentSnapshot, checkedAt: Date) {
        let url = try PublicContentURL.snapshotURL(from: serviceAddress)
        let session = URLSession(configuration: .ephemeral, delegate: MacHTTPSOnlyDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url.map(PublicContentURL.isHTTPS) == true, data.count <= 10_000_000 else { throw PublicContentError.invalidSnapshot }
        let snapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: data).validated()
        guard let current = snapshot.tracks.first(where: { $0.id == track.id && $0.albumID == track.albumID && $0.cacheIdentity == track.cacheIdentity }),
              current.copyright.expiresAt.map({ $0 > .now }) ?? true,
              PublicContentURL.isHTTPS(current.audioURL) else {
            throw MacCompanionError.message("音轨已下架、版本更新或授权到期，请刷新手机曲库。")
        }
        return (current, snapshot, .now)
    }

    private nonisolated func download(_ track: PublicAudioTrack) async throws -> URL {
        guard track.byteSize > 0, track.byteSize <= 128_000_000 else { throw MacCompanionError.message("这首音轨暂不支持 Mac 接续。") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 18
        let session = URLSession(configuration: configuration, delegate: MacHTTPSOnlyDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: URLRequest(url: track.audioURL, timeoutInterval: 18))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url.map(PublicContentURL.isHTTPS) == true,
              response.expectedContentLength < 0 || response.expectedContentLength == track.byteSize else {
            throw MacCompanionError.message("音轨下载响应无效，请刷新曲库。")
        }
        let supported = ["mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "mp4"]
        let suffix = [track.audioURL.pathExtension.lowercased(),
            response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? ""]
            .first { supported.contains($0) }
        guard let suffix else { throw MacCompanionError.message("无法识别音轨格式，请刷新曲库。") }
        let file = URL.temporaryDirectory.appending(path: "qingkong-mac-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var buffer = Data(); var count: Int64 = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                count += 1
                guard count <= track.byteSize else { throw PublicContentError.invalidSnapshot }
                buffer.append(byte)
                if buffer.count == 65_536 { try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
            guard try AudioFileIntegrity.matches(fileURL: file, byteSize: track.byteSize, sha256: track.sha256) else {
                throw MacCompanionError.message("音轨完整性检查失败，请重试。")
            }
            return file
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    private func updateProgress() {
        if let phoneSnapshot {
            let projected = phoneSnapshot.projectedPosition(at: .now, receivedAt: phoneReceivedAt, connected: phoneConnected)
            if position != projected { position = projected }
            // The iPhone owns its timer and decoder. A missing display update
            // must never pause AirPlay or start a local Mac track.
            return
        }
        if let prepared, Date.now.timeIntervalSince(prepared.preparedAt) >= 30 { discardPreparation() }
        if deadline?.expired() == true { pause(); deadline = nil; markChanged() }
        guard let active else { return }
        if active.expiresAt.map({ $0 <= .now }) == true {
            if wantsPlayback || isPlaying || isBuffering { pause() }
            if error != "当前音轨授权已到期，播放已停止。" {
                error = "当前音轨授权已到期，播放已停止。"; markChanged()
            }
            return
        }
        let previousPlaying = isPlaying; let previousBuffering = isBuffering; let previousPosition = position
        if let player = active.bundled {
            position = playbackPosition; isPlaying = player.isPlaying; isBuffering = false
            if wantsPlayback && !player.isPlaying && player.currentTime >= player.duration - 0.1 { active.ended = true }
        } else if let player = active.streamed {
            position = playbackPosition; isPlaying = player.timeControlStatus == .playing
            isBuffering = wantsPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if player.currentItem?.status == .failed {
                if wantsPlayback || isPlaying || isBuffering { pause() }
                if error != "这首音轨暂时无法播放。" { error = "这首音轨暂时无法播放。"; markChanged() }
                return
            }
        }
        if !previousPlaying && isPlaying, let track = currentItem?.onlineTrack { didStartOnline?(track) }
        if previousPlaying != isPlaying || previousBuffering != isBuffering || abs(previousPosition - position) >= 0.1 { markChanged() }
        if active.ended && wantsPlayback && !advancing {
            active.ended = false
            let attempt = operation
            Task { [weak self] in
                guard let self, self.operation == attempt else { return }
                do { try await self.move(by: 1, naturalEnd: true) }
                catch is CancellationError { }
                catch { self.pause(); self.error = error.localizedDescription }
            }
        }
    }
    private func markChanged() {
        revision &+= 1
        systemPlayback?.update()
        didChange?()
    }

    @discardableResult
    func applyPhonePlayback(_ snapshot: DesktopPlaybackSnapshot) -> Bool {
        guard snapshot.isValid else { return false }
        if let prior = phoneSnapshot, prior.sessionID == snapshot.sessionID, prior.revision > snapshot.revision { return false }
        if phoneSnapshot == nil { reset() }
        phoneSnapshot = snapshot; phoneReceivedAt = .now; phoneConnected = true
        queue = snapshot.queue; index = snapshot.index; position = snapshot.position; duration = snapshot.duration
        title = snapshot.currentItem?.title ?? "iPhone 音乐"
        subtitle = "AirPlay · \(snapshot.deviceName)"
        isPlaying = snapshot.playing; isBuffering = snapshot.buffering; wantsPlayback = snapshot.playing || snapshot.buffering
        mode = snapshot.mode; deadline = snapshot.deadline; hasSelection = true; error = nil
        applyingPhoneState = true; volume = Double(snapshot.volume); applyingPhoneState = false
        markChanged()
        return true
    }

    func phonePlaybackDisconnected() {
        guard isPhonePlayback else { return }
        position = playbackPosition
        phoneSnapshot?.position = position
        phoneConnected = false
        subtitle = "AirPlay · 等待 iPhone 状态"
        // Display uncertainty; do not send Pause to the actual player.
        markChanged()
    }

    func endPhonePlayback() { if isPhonePlayback { reset() } }

    @discardableResult
    private func sendPhoneCommand(_ action: PhonePlaybackCommand.Action, amount: Double? = nil,
                                  mode: AudioPlaybackMode? = nil, deadline: SleepDeadline? = nil) async -> Bool {
        guard let sessionID = phoneSnapshot?.sessionID, phoneConnected, !phoneControlBusy,
              let phoneCommandHandler else { error = "iPhone 暂不可遥控，请在手机确认播放状态。"; return false }
        let command = PhonePlaybackCommand(sessionID: sessionID, action: action, amount: amount, mode: mode, deadline: deadline)
        guard command.isValid else { error = "播放操作无效。"; return false }
        phoneControlBusy = true
        defer { phoneControlBusy = false }
        do {
            let reply = try await phoneCommandHandler(command)
            guard phoneSnapshot?.sessionID == sessionID else { return false }
            guard reply.id == command.id, reply.sessionID == sessionID, reply.success, let snapshot = reply.snapshot else {
                throw MacCompanionError.message(reply.error ?? "iPhone 未确认操作。")
            }
            if action == .release, snapshot.playing || snapshot.buffering {
                throw MacCompanionError.message("iPhone 尚未确认暂停，未开始 Mac 独立播放。")
            }
            applyPhonePlayback(snapshot)
            return true
        } catch {
            if phoneSnapshot?.sessionID == sessionID { self.error = error.localizedDescription }
            return false
        }
    }

    private func takeOverPhonePlayback(_ start: @escaping @MainActor () -> Void) {
        Task {
            guard await sendPhoneCommand(.release) else { return }
            endPhonePlayback()
            start()
        }
    }

}

private final class MacHTTPSOnlyDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(PublicContentURL.isHTTPS) == true ? request : nil)
    }
}
