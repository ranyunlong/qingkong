import Foundation
import Observation
import WatchConnectivity
import QingkongCore
#if os(iOS)
import AVFoundation
import WidgetKit
#else
import WatchKit
#endif

@MainActor
protocol MoodMessageSession {
    var isReachable: Bool { get }
    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?)
}

extension WCSession: MoodMessageSession {}

@MainActor @Observable
final class Connectivity: NSObject, WCSessionDelegate {
    private(set) var reachable = false
    private(set) var remoteState: AudioState?
    private(set) var remoteStateReceivedAt: Date?
    private(set) var remoteBusy = false
    private(set) var remoteVolumeRevision: UInt = 0
    private(set) var batterySyncError: String?
    var error: String?
    var syncMessage = "等待设备连接"
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let player: AudioPlayer
    @ObservationIgnored private var session: WCSession?
    @ObservationIgnored private var replies: [UUID: CheckedContinuation<AudioReply, Error>] = [:]
    @ObservationIgnored private var timeouts: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var immediateRecords: [SyncReceipt] = []
    @ObservationIgnored private var remoteStateUpdatedAt: Date?
    @ObservationIgnored var preferencesReceived: (() -> Void)?
    @ObservationIgnored var publicContentAddressReceived: ((String) -> Void)?
    @ObservationIgnored private var publicContentAddress: String?
    @ObservationIgnored var reminderConfigurationReceived: ((ReminderRelayConfiguration) -> Void)?
    @ObservationIgnored var reminderReadyReceived: ((WatchReminderReady) -> Void)?
    @ObservationIgnored var reminderSignalReceived: ((ReminderSignal) -> Void)?
    @ObservationIgnored var watchReminderReportReceived: ((WatchReminderReport) -> Void)?
    @ObservationIgnored var reminderProbe: ((UUID) async -> Bool)?
    @ObservationIgnored private var reminderConfigurationData: Data?
    @ObservationIgnored private var watchReminderReportData: Data?
    @ObservationIgnored private var watchReadyData: Data?
    @ObservationIgnored private var pendingReminderSignals: [ReminderSignal] = []
    #if os(iOS)
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    #endif

    init(store: LocalStore, player: AudioPlayer) {
        self.store = store; self.player = player
        super.init()
        #if os(watchOS)
        if let data = UserDefaults.standard.data(forKey: "qingkong.reminder-outbox.v1") {
            pendingReminderSignals = (try? JSONDecoder().decode([ReminderSignal].self, from: data)) ?? []
        }
        #endif
        #if os(iOS)
        player.didChangeState = { [weak self] state in self?.sendAudioState(state) }
        // Native companion volume control changes system output, not AudioState.volume.
        // Forward only interaction activity so the watch can keep its volume row visible.
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let session = self?.session, session.activationState == .activated, session.isReachable else { return }
                session.sendMessage(["volumeChanged": true], replyHandler: nil, errorHandler: { _ in })
            }
        }
        #endif
    }

    private func sendAudioState(_ state: AudioState) {
        #if os(iOS)
        guard let session, session.activationState == .activated, session.isReachable,
              let data = try? JSONEncoder().encode(AudioReply(id: UUID(), state: player.companionState)) else { return }
        // Playback status is ephemeral. Never queue old play/pause states for later delivery.
        session.sendMessage(["audioState": data], replyHandler: nil, errorHandler: { _ in })
        #endif
    }

    func receiveAudioState(_ reply: AudioReply) {
        if let previous = remoteStateUpdatedAt, (reply.updatedAt ?? .distantPast) < previous { return }
        remoteStateUpdatedAt = reply.updatedAt
        remoteState = reply.state
        remoteStateReceivedAt = .now
    }

    func start() {
        guard WCSession.isSupported() else { syncMessage = "当前设备不支持配对同步"; return }
        let value = WCSession.default
        session = value
        value.delegate = self
        value.activate()
    }

    func flush() {
        guard let session, session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired && session.isWatchAppInstalled else { syncMessage = "配对并安装 Watch 应用后同步"; return }
        #else
        guard session.isCompanionAppInstalled else { syncMessage = "iPhone 安装小晴空后可同步"; return }
        #endif
        do {
            let queued = session.outstandingUserInfoTransfers.compactMap { transfer -> SyncPayload? in
                guard let data = transfer.userInfo["record"] as? Data else { return nil }
                return try? JSONDecoder().decode(SyncPayload.self, from: data)
            }
            let pending = try store.pendingRecords()
            for record in pending {
                let data = try JSONEncoder().encode(SyncPayload(record: record))
                if !queued.contains(SyncPayload(record: record)) { session.transferUserInfo(["record": data]) }
                #if os(watchOS)
                sendRecordImmediately(data, record: record, session: session, wakePhone: true)
                #else
                sendRecordImmediately(data, record: record, session: session, wakePhone: false)
                #endif
            }
            syncMessage = pending.isEmpty ? "记录已同步" : "\(pending.count) 条记录等待系统传送"
            var context: [String: Any] = ["preferences": try JSONEncoder().encode(store.preferences)]
            #if os(iOS)
            if let reminderConfigurationData { context["reminderConfiguration"] = reminderConfigurationData }
            if let publicContentAddress { context["publicContentAddress"] = publicContentAddress }
            #else
            if let watchReminderReportData { context["watchReminderReport"] = watchReminderReportData }
            if let watchReadyData { context["reminderReady"] = watchReadyData }
            if let battery = currentWatchBattery(), let data = try? JSONEncoder().encode(battery) {
                context["watchBattery"] = data
            }
            flushReminderSignals(session)
            #endif
            try session.updateApplicationContext(context)
            if session.isReachable {
                let reminderContext = context.filter { $0.key != "preferences" && $0.key != "publicContentAddress" }
                if !reminderContext.isEmpty { session.sendMessage(reminderContext, replyHandler: nil, errorHandler: { _ in }) }
                #if os(iOS)
                requestWatchBattery()
                #endif
            }
        } catch { self.error = "同步暂未完成，记录已保存在本机，将在下次连接时重试。" }
    }

    #if os(watchOS)
    private func currentWatchBattery() -> WatchBatterySnapshot? {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let value = WatchBatterySnapshot(level: Double(device.batteryLevel),
            charging: device.batteryState == .charging || device.batteryState == .full)
        return value.percentage() == nil ? nil : value
    }
    #else
    private var watchBatteryRequestAt: Date?
    private var batterySessionGeneration = UUID()

    private func reconcileBatteryWatch() {
        let key = "qingkong.battery-watch.v1"
        let identity = session?.watchDirectoryURL?.absoluteString
        if UserDefaults.standard.string(forKey: key) != identity {
            clearWatchBattery()
            UserDefaults.standard.set(identity, forKey: key)
        }
    }

    private func requestWatchBattery() {
        guard let session, session.isReachable,
              watchBatteryRequestAt.map({ Date.now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        watchBatteryRequestAt = .now
        let generation = batterySessionGeneration
        session.sendMessage(["watchBatteryRequest": true], replyHandler: { [weak self] payload in
            Task { @MainActor in
                guard let self, self.batterySessionGeneration == generation else { return }
                self.reconcileBatteryWatch()
                guard self.batterySessionGeneration == generation else { return }
                self.receiveWatchBattery(payload)
            }
        }, errorHandler: { _ in })
    }

    private func receiveWatchBattery(_ payload: [String: Any]) {
        guard let session, session.isPaired, session.isWatchAppInstalled,
              let data = payload["watchBattery"] as? Data, data.count <= 1024,
              let value = try? JSONDecoder().decode(WatchBatterySnapshot.self, from: data) else { return }
        do {
            if try WatchBatteryStorage.save(value) { WidgetCenter.shared.reloadTimelines(ofKind: WatchBatteryStorage.kind) }
            batterySyncError = nil
        } catch { batterySyncError = "手表电量暂未保存，请重新打开两端的小晴空。" }
    }

    private func clearWatchBattery() {
        batterySessionGeneration = UUID()
        do { try WatchBatteryStorage.clear(); batterySyncError = nil }
        catch { batterySyncError = "旧手表电量暂未清除，请重新打开小晴空。" }
        watchBatteryRequestAt = nil
        WidgetCenter.shared.reloadTimelines(ofKind: WatchBatteryStorage.kind)
    }
    #endif

    func publishReminderConfiguration(_ configuration: ReminderRelayConfiguration) {
        reminderConfigurationData = try? JSONEncoder().encode(configuration)
        flush()
    }

    func publishContentServiceAddress(_ address: String) {
        publicContentAddress = address
        flush()
    }

    private func receiveContentServiceAddress(_ payload: [String: Any]) {
        #if os(watchOS)
        guard let address = payload["publicContentAddress"] as? String, address.utf8.count <= 4096 else { return }
        publicContentAddressReceived?(address)
        #endif
    }

    func publishWatchReminderReport(_ report: WatchReminderReport) {
        watchReminderReportData = try? JSONEncoder().encode(report)
        flush()
    }

    func requestWatchMonitoring(_ ready: WatchReminderReady) {
        watchReadyData = try? JSONEncoder().encode(ready)
        flush()
    }

    /// Persist before returning; WC's user-info queue survives disconnection/process exit.
    func enqueueReminderSignal(_ signal: ReminderSignal) {
        #if os(watchOS)
        if !pendingReminderSignals.contains(where: { $0.id == signal.id }) { pendingReminderSignals.append(signal) }
        persistReminderOutbox()
        flush()
        #endif
    }

    private func persistReminderOutbox() {
        if let data = try? JSONEncoder().encode(pendingReminderSignals) {
            UserDefaults.standard.set(data, forKey: "qingkong.reminder-outbox.v1")
        }
    }

    private func flushReminderSignals(_ session: WCSession) {
        let queued = session.outstandingUserInfoTransfers.compactMap { transfer in
            (transfer.userInfo["reminderSignal"] as? Data).flatMap { try? JSONDecoder().decode(ReminderSignal.self, from: $0) }?.id
        }
        for signal in pendingReminderSignals where Date.now.timeIntervalSince(signal.sampleDate) <= signal.kind.maximumAge {
            guard let data = try? JSONEncoder().encode(signal) else { continue }
            if !queued.contains(signal.id) { session.transferUserInfo(["reminderSignal": data]) }
            if session.isReachable { session.sendMessage(["reminderSignal": data], replyHandler: nil, errorHandler: { _ in }) }
        }
        pendingReminderSignals.removeAll()
        persistReminderOutbox()
    }

    /// Probe has no notification side effects. Once delegated, an event never falls back locally.
    func confirmPhoneForReminder(configurationID: UUID) async -> ReminderProbeResult {
        guard let session else { return .unavailable }
        let deadline = Date.now.addingTimeInterval(3)
        while session.activationState != .activated && Date.now < deadline {
            if session.activationState == .notActivated { session.activate() }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return .unavailable }
        }
        guard session.activationState == .activated else { return .unavailable }
        guard reminderProbeReply == nil else { return .rejected }
        let remaining = max(0.05, deadline.timeIntervalSinceNow)
        return await withCheckedContinuation { continuation in
            let probeID = UUID()
            let timeout = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                self.finishReminderProbe(.unavailable, id: probeID)
            }
            // Watch serializes dispatches; only one probe can be in flight.
            reminderProbeID = probeID
            reminderProbeReply = { result in timeout.cancel(); continuation.resume(returning: result) }
            session.sendMessage(["reminderProbe": configurationID.uuidString], replyHandler: { [weak self] reply in
                let accepted = reply["accepted"] as? Bool == true
                Task { @MainActor in self?.finishReminderProbe(accepted ? .accepted : .rejected, id: probeID) }
            }, errorHandler: { [weak self] _ in
                Task { @MainActor in self?.finishReminderProbe(.unavailable, id: probeID) }
            })
        }
    }

    @ObservationIgnored private var reminderProbeID: UUID?
    @ObservationIgnored private var reminderProbeReply: ((ReminderProbeResult) -> Void)?
    private func finishReminderProbe(_ result: ReminderProbeResult, id: UUID) {
        guard id == reminderProbeID else { return }
        reminderProbeID = nil
        let reply = reminderProbeReply
        reminderProbeReply = nil
        reply?(result)
    }

    private func receiveReminderPayload(_ payload: [String: Any]) {
        #if os(iOS)
        if let data = payload["reminderReady"] as? Data, let ready = try? JSONDecoder().decode(WatchReminderReady.self, from: data) { reminderReadyReceived?(ready) }
        if let data = payload["reminderSignal"] as? Data, let signal = try? JSONDecoder().decode(ReminderSignal.self, from: data) { reminderSignalReceived?(signal) }
        if let data = payload["watchReminderReport"] as? Data, let report = try? JSONDecoder().decode(WatchReminderReport.self, from: data), report.version == 1 { watchReminderReportReceived?(report) }
        #else
        if let data = payload["reminderConfiguration"] as? Data, let configuration = try? JSONDecoder().decode(ReminderRelayConfiguration.self, from: data), configuration.version == 1 { reminderConfigurationReceived?(configuration) }
        #endif
    }

    func sendRecordImmediately(_ data: Data, record: MoodRecord, session: any MoodMessageSession, wakePhone: Bool) {
        let expectedReceipt = SyncReceipt(record: record)
        // An active Watch app can use sendMessage to wake its background iPhone app.
        // Reachability remains required in the opposite direction; failures keep the queue.
        guard wakePhone || session.isReachable, !immediateRecords.contains(expectedReceipt) else { return }
        immediateRecords.append(expectedReceipt)
        session.sendMessage(["record": data], replyHandler: { [weak self] response in
            let receiptData = response["receipt"] as? Data
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.immediateRecords.removeAll { $0 == expectedReceipt }
                guard let receiptData,
                      let receipt = try? JSONDecoder().decode(SyncReceipt.self, from: receiptData),
                      receipt == expectedReceipt else { return }
                do {
                    try self.store.acknowledge(receipt)
                    self.updateSyncMessage()
                } catch { self.error = "同步回执暂未保存，将在下次连接时核对。" }
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.immediateRecords.removeAll { $0 == expectedReceipt } }
            // The durable user-info queue remains responsible for disconnected delivery.
        })
    }

    private func receiveRecord(_ data: Data) throws -> Data {
        let payload = try JSONDecoder().decode(SyncPayload.self, from: data)
        guard payload.version == 1 else { throw LinkError.invalidReply }
        try store.save(payload.record, fromPeer: true)
        // Both transports acknowledge only after saving; duplicate delivery uses the same merge.
        return try JSONEncoder().encode(SyncReceipt(record: payload.record))
    }

    private func updateSyncMessage() {
        do { syncMessage = try store.pendingRecords().isEmpty ? "记录已同步" : "部分记录等待确认" }
        catch { self.error = "同步状态暂未读取，将在下次连接时核对。" }
    }

    func confirmPhoneForPlayback() async throws -> Bool {
        try await PhonePlaybackProbe.confirm { remaining in
            guard let session = self.session else { return false }
            if session.activationState == .notActivated { session.activate() }
            guard session.activationState == .activated else { return false }
            return await self.command(.status, timeout: remaining)
        }
    }

    @discardableResult
    func command(_ action: AudioCommand.Action, amount: Double? = nil, track: Track? = nil, playbackMode: AudioPlaybackMode? = nil, timeout: Duration = .seconds(8)) async -> Bool {
        guard !remoteBusy else { return false }
        error = nil
        #if os(watchOS)
        // A status probe has no playback side effects and can try to wake iOS.
        // Do not let a stale reachability flag skip the phone confirmation window.
        let canProbePhone = action == .status || remoteState?.playbackSessionID != nil
        #else
        let canProbePhone = false
        #endif
        guard let session, session.activationState == .activated, session.isReachable || canProbePhone else {
            markRemoteUnavailable()
            error = "暂时连不到 iPhone，遥控不可用。可在手表曲库选择本机声音。"
            return false
        }
        let request = AudioCommand(action: action, amount: amount, track: track, playbackMode: playbackMode)
        remoteBusy = true
        defer { remoteBusy = false }
        do {
            let data = try JSONEncoder().encode(request)
            let reply: AudioReply = try await withCheckedThrowingContinuation { continuation in
                replies[request.id] = continuation
                timeouts[request.id] = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(request.id, result: .failure(LinkError.timeout))
                }
                session.sendMessage(["audio": data], replyHandler: { [weak self] response in
                    let payload = response["audio"] as? Data
                    Task { @MainActor in
                        guard let payload, let reply = try? JSONDecoder().decode(AudioReply.self, from: payload), reply.id == request.id else {
                            self?.finish(request.id, result: .failure(LinkError.invalidReply)); return
                        }
                        self?.finish(request.id, result: .success(reply))
                    }
                }, errorHandler: { [weak self] error in
                    Task { @MainActor in self?.finish(request.id, result: .failure(error)) }
                })
            }
            receiveAudioState(reply)
            error = reply.error
            return reply.error == nil
        } catch {
            markRemoteUnavailable()
            self.error = "iPhone 未确认操作，请检查连接后重试。"
            return false
        }
    }

    private func markRemoteUnavailable() {
        if remoteState?.playbackSessionID != nil { remoteState?.remoteConnected = false }
        else { remoteState = nil }
    }

    private func finish(_ id: UUID, result: Result<AudioReply, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?.resume(with: result)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let connected = session.isReachable
        let context = session.receivedApplicationContext
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reachable = connected
            if let preferences = context["preferences"] as? Data { self.receivePreferences(preferences) }
            self.receiveContentServiceAddress(context)
            self.receiveReminderPayload(context)
            #if os(iOS)
            self.reconcileBatteryWatch()
            if !session.isPaired || !session.isWatchAppInstalled { self.clearWatchBattery() }
            else { self.receiveWatchBattery(context) }
            #endif
            if let error { self.error = "设备同步暂不可用：\(error.localizedDescription)" }
            else { self.flush(); self.sendAudioState(self.player.state) }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let connected = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reachable = connected
            self.flush()
            if connected { self.sendAudioState(self.player.state) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in
            if let data = applicationContext["preferences"] as? Data { self?.receivePreferences(data) }
            self?.receiveContentServiceAddress(applicationContext)
            self?.receiveReminderPayload(applicationContext)
            #if os(iOS)
            self?.receiveWatchBattery(applicationContext)
            #endif
        }
    }

    private func receivePreferences(_ data: Data) {
        guard let value = try? JSONDecoder().decode(Preferences.self, from: data) else { return }
        store.receivePreferences(value)
        preferencesReceived?()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["reminderSignal"] != nil || userInfo["reminderReady"] != nil {
            Task { @MainActor [weak self] in self?.receiveReminderPayload(userInfo) }
            return
        }
        if let data = userInfo["receipt"] as? Data {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let receipt = try JSONDecoder().decode(SyncReceipt.self, from: data)
                    try self.store.acknowledge(receipt)
                    self.updateSyncMessage()
                } catch { self.error = "同步回执暂未保存，将在下次连接时核对。" }
            }
            return
        }
        guard let data = userInfo["record"] as? Data else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let receipt = try self.receiveRecord(data)
                self.session?.transferUserInfo(["receipt": receipt])
            } catch { self.error = "有一条记录未能导入，请稍后重试同步。" }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if error != nil, let data = userInfoTransfer.userInfo["reminderSignal"] as? Data,
           let signal = try? JSONDecoder().decode(ReminderSignal.self, from: data) {
            Task { @MainActor [weak self] in
                guard let self, Date.now.timeIntervalSince(signal.sampleDate) <= signal.kind.maximumAge else { return }
                if !self.pendingReminderSignals.contains(where: { $0.id == signal.id }) { self.pendingReminderSignals.append(signal) }
                self.persistReminderOutbox()
                // Retry on the next activation/connection, never spin on transport failures.
            }
            return
        }
        guard let data = userInfoTransfer.userInfo["record"] as? Data else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if error != nil { self.error = "记录尚未传送，已保留在本机待重试。"; return }
                let payload = try JSONDecoder().decode(SyncPayload.self, from: data)
                if try self.store.pendingRecords().contains(where: { SyncReceipt(record: payload.record).matches($0) }) {
                    self.syncMessage = "已传送，等待对端保存确认"
                } else { self.updateSyncMessage() }
            } catch { self.error = "同步状态暂未保存，将在下次连接时核对。" }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let data = message["audioState"] as? Data
        let volumeChanged = message["volumeChanged"] as? Bool == true
        let hasReminder = message.keys.contains { $0.hasPrefix("reminder") || $0 == "watchReminderReport" }
        let hasBattery = message["watchBattery"] != nil
        guard data != nil || volumeChanged || hasReminder || hasBattery else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let data, let reply = try? JSONDecoder().decode(AudioReply.self, from: data) {
                self.receiveAudioState(reply)
            }
            if volumeChanged { self.remoteVolumeRevision &+= 1 }
            self.receiveReminderPayload(message)
            #if os(iOS)
            self.receiveWatchBattery(message)
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        #if os(watchOS)
        if message["watchBatteryRequest"] as? Bool == true {
            Task { @MainActor [weak self] in
                guard let battery = self?.currentWatchBattery(), let data = try? JSONEncoder().encode(battery) else {
                    replyHandler([:]); return
                }
                replyHandler(["watchBattery": data])
            }
            return
        }
        #endif
        if let value = message["reminderProbe"] as? String, let id = UUID(uuidString: value) {
            Task { @MainActor [weak self] in
                replyHandler(["accepted": await self?.reminderProbe?(id) ?? false])
            }
            return
        }
        if let data = message["record"] as? Data {
            Task { @MainActor [weak self] in
                guard let self else { replyHandler([:]); return }
                do { replyHandler(["receipt": try self.receiveRecord(data)]) }
                catch {
                    self.error = "有一条记录未能导入，请稍后重试同步。"
                    replyHandler([:])
                }
            }
            return
        }
        guard let data = message["audio"] as? Data, let request = try? JSONDecoder().decode(AudioCommand.self, from: data) else { replyHandler([:]); return }
        Task { @MainActor [weak self] in
            guard let self else { replyHandler([:]); return }
            #if os(iOS)
            let reply = await self.player.handle(request)
            if let encoded = try? JSONEncoder().encode(reply) { replyHandler(["audio": encoded]) }
            else { replyHandler([:]) }
            #else
            replyHandler([:])
            #endif
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.clearWatchBattery(); session.activate() }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            if !session.isPaired || !session.isWatchAppInstalled { self?.clearWatchBattery() }
            self?.flush()
        }
    }
    #endif

    private enum LinkError: Error { case timeout, invalidReply }
}
