import Foundation
import Observation
import WatchConnectivity
import QingkongCore
#if os(iOS)
import AVFoundation
#endif

@MainActor @Observable
final class Connectivity: NSObject, WCSessionDelegate {
    private(set) var reachable = false
    private(set) var remoteState: AudioState?
    private(set) var remoteBusy = false
    private(set) var remoteVolumeRevision: UInt = 0
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
    #if os(iOS)
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    #endif

    init(store: LocalStore, player: AudioPlayer) {
        self.store = store; self.player = player
        super.init()
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
              let data = try? JSONEncoder().encode(AudioReply(id: UUID(), state: state)) else { return }
        // Playback status is ephemeral. Never queue old play/pause states for later delivery.
        session.sendMessage(["audioState": data], replyHandler: nil, errorHandler: { _ in })
        #endif
    }

    func receiveAudioState(_ reply: AudioReply) {
        if let previous = remoteStateUpdatedAt, (reply.updatedAt ?? .distantPast) < previous { return }
        remoteStateUpdatedAt = reply.updatedAt
        remoteState = reply.state
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
        guard session.isCompanionAppInstalled else { syncMessage = "iPhone 安装晴空后可同步"; return }
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
                sendRecordImmediately(data, record: record, session: session)
            }
            syncMessage = pending.isEmpty ? "记录已同步" : "\(pending.count) 条记录等待系统传送"
            try session.updateApplicationContext(["preferences": JSONEncoder().encode(store.preferences)])
        } catch { self.error = "同步暂未完成，记录已保存在本机，将在下次连接时重试。" }
    }

    private func sendRecordImmediately(_ data: Data, record: MoodRecord, session: WCSession) {
        let expectedReceipt = SyncReceipt(record: record)
        guard session.isReachable, !immediateRecords.contains(expectedReceipt) else { return }
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
    func command(_ action: AudioCommand.Action, amount: Double? = nil, track: Track? = nil, timeout: Duration = .seconds(8)) async -> Bool {
        guard !remoteBusy else { return false }
        error = nil
        #if os(watchOS)
        // A status probe has no playback side effects and can try to wake iOS.
        // Do not let a stale reachability flag skip the phone confirmation window.
        let canProbePhone = action == .status
        #else
        let canProbePhone = false
        #endif
        guard let session, session.activationState == .activated, session.isReachable || canProbePhone else {
            remoteState = nil
            error = "暂时连不到 iPhone，可使用手表内置声音。"
            return false
        }
        let request = AudioCommand(action: action, amount: amount, track: track)
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
            remoteState = nil
            self.error = "iPhone 未确认操作，请检查连接后重试。"
            return false
        }
    }

    private func finish(_ id: UUID, result: Result<AudioReply, Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        replies.removeValue(forKey: id)?.resume(with: result)
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let connected = session.isReachable
        let context = session.receivedApplicationContext["preferences"] as? Data
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reachable = connected
            if let context { self.receivePreferences(context) }
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
        guard let data = applicationContext["preferences"] as? Data else { return }
        Task { @MainActor [weak self] in self?.receivePreferences(data) }
    }

    private func receivePreferences(_ data: Data) {
        guard let value = try? JSONDecoder().decode(Preferences.self, from: data) else { return }
        store.receivePreferences(value)
        preferencesReceived?()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
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
        guard data != nil || volumeChanged else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let data, let reply = try? JSONDecoder().decode(AudioReply.self, from: data) {
                self.receiveAudioState(reply)
            }
            if volumeChanged { self.remoteVolumeRevision &+= 1 }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
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
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.flush() }
    }
    #endif

    private enum LinkError: Error { case timeout, invalidReply }
}
