import Foundation
import Network
import QingkongCore

enum PhoneMacError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

@MainActor
final class PhoneMacPeer {
    let id: String
    private(set) var name: String
    private(set) var hostID: UUID?
    private(set) var supportsAutoReport = false
    private(set) var supportsMusicCatalog = false
    private(set) var airPlayReceiverName: String?
    var onPhoneCommand: ((PhonePlaybackCommand) async -> PhonePlaybackReply)?
    private var phoneCommandTail: Task<Void, Never>?
    private var phoneCommandsQueued = 0
    let endpoint: NWEndpoint
    private let secret: Data
    private let deviceID: String
    private let deviceName: String
    private(set) var isConnected = false
    private var isConnecting = false
    private(set) var message = "Mac 尚未连接。"
    var onSnapshot: ((DesktopPlaybackSnapshot) -> Void)?
    var onChange: (() -> Void)?
    private var peer: LocalPeerConnection?
    private var requests: [UUID: Pending] = [:]
    private struct Pending {
        let continuation: CheckedContinuation<DesktopMusicResponse, Error>
        let timeout: Task<Void, Never>
    }

    init(id: String, name: String, endpoint: NWEndpoint, secret: Data, deviceID: String, deviceName: String) {
        self.id = id; self.name = name; self.endpoint = endpoint; self.secret = secret; self.deviceID = deviceID; self.deviceName = deviceName
    }

    /// Discovery and transport have separate lifetimes. Return removed IDs so
    /// their catalog work can be cancelled by the owning service.
    static func removeMissing(from peers: inout [String: PhoneMacPeer], visible: Set<String>, keeping: Set<String>) -> [String] {
        let removed = peers.keys.filter {
            guard let peer = peers[$0] else { return false }
            return !visible.contains($0) && !keeping.contains($0) && !peer.isConnected && !peer.isConnecting
        }
        for id in removed { peers.removeValue(forKey: id)?.close() }
        return removed
    }

    func connect() {
        guard peer == nil, !isConnecting else { return }
        do {
            let parameters = try DesktopPairing.parameters(secret: secret)
            parameters.prohibitedInterfaceTypes = [.cellular]
            let next = LocalPeerConnection(NWConnection(to: endpoint, using: parameters))
            peer = next; isConnecting = true
            next.onReady = { [weak self, weak next] in
                Task { @MainActor in
                    guard let self, let next, self.peer === next else { return }
                    do {
                        let reply = try await self.request(.init(action: .hello, deviceID: self.deviceID, deviceName: self.deviceName, capabilities: [DesktopMusicCatalog.capability, PhoneAirPlay.capability]), allowHandshake: true)
                        guard self.peer === next else { return }
                        guard reply.success, reply.version == 2 else { throw PhoneMacError.message(reply.error ?? "请更新 Mac 上的小晴空。") }
                        self.hostID = reply.hostID
                        self.supportsAutoReport = reply.hostID != nil && (reply.capabilities?.contains(DesktopReportSyncState.capability) == true)
                        self.supportsMusicCatalog = reply.capabilities?.contains(DesktopMusicCatalog.capability) == true
                        self.airPlayReceiverName = reply.capabilities?.contains(PhoneAirPlay.capability) == true ? reply.airPlayReceiverName : nil
                        self.isConnecting = false; self.isConnected = true
                        #if DEBUG
                        NSLog("[AirPlay check] Mac handshake accepted; receiver=%@", self.airPlayReceiverName ?? "unsupported")
                        #endif
                        if let snapshot = reply.snapshot { self.name = snapshot.deviceName; self.onSnapshot?(snapshot) }
                        self.onChange?()
                    } catch {
                        #if DEBUG
                        NSLog("[AirPlay check] Mac handshake failed: %@", error.localizedDescription)
                        #endif
                        next.close(message: error.localizedDescription)
                    }
                }
            }
            next.onMessage = { [weak self, weak next] data in
                guard let self, let next, self.peer === next else { return }
                guard let response = try? JSONDecoder().decode(DesktopMusicResponse.self, from: data), response.version == 2 else {
                    next.close(message: "两端协议不兼容，请更新小晴空。"); return
                }
                if let command = response.phoneCommand {
                    guard self.isConnected, self.airPlayReceiverName != nil, command.isValid,
                          self.phoneCommandsQueued < 16 else { return }
                    self.phoneCommandsQueued += 1
                    let previous = self.phoneCommandTail
                    self.phoneCommandTail = Task { [weak self, weak next] in
                        await previous?.value
                        guard let self, let next else { return }
                        defer { self.phoneCommandsQueued = max(0, self.phoneCommandsQueued - 1) }
                        guard self.peer === next, self.isConnected, !Task.isCancelled,
                              let handler = self.onPhoneCommand else { return }
                        let reply = await handler(command)
                        guard self.peer === next, self.isConnected,
                              let encoded = try? JSONEncoder().encode(DesktopMusicRequest(action: .phoneCommandResult, phoneReply: reply)) else { return }
                        try? next.send(encoded)
                    }
                    return
                }
                if let pending = self.requests.removeValue(forKey: response.id) {
                    pending.timeout.cancel(); pending.continuation.resume(returning: response)
                } else if self.isConnected, let snapshot = response.snapshot, snapshot.isValid {
                    self.onSnapshot?(snapshot)
                }
            }
            next.onClose = { [weak self, weak next] message in
                guard let self, let next, self.peer === next else { return }
                self.peer = nil; self.isConnected = false; self.isConnecting = false; self.message = message
                #if DEBUG
                NSLog("[AirPlay check] Companion connection closed: %@", message)
                #endif
                let pending = self.requests.values; self.requests.removeAll()
                for request in pending { request.timeout.cancel(); request.continuation.resume(throwing: PhoneMacError.message(message)) }
                self.onChange?()
            }
            next.start()
        } catch { message = error.localizedDescription; onChange?() }
    }

    func ensureConnected() async throws {
        if isConnected { return }
        connect()
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while !isConnected {
            guard ContinuousClock.now < limit, peer != nil else { throw PhoneMacError.message("Mac 暂不可达，未执行操作。") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    func observe(_ active: Bool) {
        guard isConnected, let peer, let data = try? JSONEncoder().encode(DesktopMusicRequest(action: .observe, observing: active)) else { return }
        try? peer.send(data)
    }

    func publishPhonePlayback(_ update: PhonePlaybackUpdate) throws {
        guard isConnected, airPlayReceiverName != nil, update.isValid, let peer else { throw DesktopConnectionError.disconnected }
        try peer.send(JSONEncoder().encode(DesktopMusicRequest(action: .phonePlayback, phonePlayback: update)))
    }

    func endPhonePlayback(sessionID: UUID? = nil) {
        guard isConnected, airPlayReceiverName != nil, let peer,
              let data = try? JSONEncoder().encode(DesktopMusicRequest(action: .phonePlaybackEnd, sessionID: sessionID)) else { return }
        try? peer.send(data)
    }

    func close() { peer?.close(); peer = nil; isConnected = false; isConnecting = false }

    /// Public metadata uses its own acknowledgement policy so a slow catalog
    /// operation never invalidates an otherwise healthy playback connection.
    func syncMusicCatalog(_ catalog: DesktopMusicCatalog) async throws -> DesktopMusicCatalogStatus? {
        guard supportsMusicCatalog else { return nil }
        let catalog = try catalog.validated()
        let digest = try catalog.contentDigest()
        let current = try await catalogRequest(.init(action: .catalogStatus))
        if let status = current.catalogStatus, status.serviceAddress == catalog.serviceAddress,
           status.revision > catalog.revision || status.digest == digest { return status }
        let transfer = try DesktopMusicCatalogTransfer(catalog: catalog)
        _ = try await catalogRequest(.init(action: .catalogBegin, catalogTransfer: transfer.info))
        for chunk in transfer.chunks {
            try Task.checkCancellation()
            _ = try await catalogRequest(.init(action: .catalogChunk, catalogChunk: chunk))
        }
        try Task.checkCancellation()
        let result = try await catalogRequest(.init(action: .catalogCommit, catalogTransferID: transfer.info.id))
        guard result.catalogReceipt == transfer.info,
              let status = result.catalogStatus, status.serviceAddress == catalog.serviceAddress,
              status.revision == catalog.revision else {
            throw PhoneMacError.message("Mac 尚未确认保存专辑目录。")
        }
        return status
    }

    private func catalogRequest(_ request: DesktopMusicRequest) async throws -> DesktopMusicResponse {
        try Task.checkCancellation()
        let response = try await self.request(request, closeOnCancel: false, closeOnTimeout: false)
        guard response.success else { throw PhoneMacError.message(response.error ?? "专辑目录同步失败，可稍后重试。") }
        return response
    }

    func request(_ request: DesktopMusicRequest, timeout seconds: Double = 8, allowHandshake: Bool = false, closeOnCancel: Bool = true, closeOnTimeout: Bool = true) async throws -> DesktopMusicResponse {
        guard let peer, isConnected || allowHandshake else { throw PhoneMacError.message("Mac 尚未连接。") }
        // A suspended observer may resume after its read deadline. Closing a
        // healthy connection here would make the Mac pause on foregrounding.
        // Mutating commands still close on an unconfirmed execution result.
        let isStatusRead = request.action == .command && request.command?.action == .status
        let invalidatesOnTimeout = closeOnTimeout && !isStatusRead
        let invalidatesOnCancel = closeOnCancel && !isStatusRead
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self, let pending = self.requests.removeValue(forKey: request.id) else { return }
                    pending.continuation.resume(throwing: PhoneMacError.message("Mac 未在时限内确认操作，请重新确认播放状态。"))
                    if invalidatesOnTimeout { peer.close(message: "设备通信确认失败，正在重新确认 Mac 状态。") }
                }
                requests[request.id] = Pending(continuation: continuation, timeout: timeout)
                do { try peer.send(JSONEncoder().encode(request)) }
                catch {
                    if let pending = requests.removeValue(forKey: request.id) { pending.timeout.cancel(); pending.continuation.resume(throwing: error) }
                    peer.close()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let pending = self?.requests.removeValue(forKey: request.id) else { return }
                pending.timeout.cancel(); pending.continuation.resume(throwing: CancellationError())
                if invalidatesOnCancel { self?.peer?.close(message: "操作已取消，正在重新确认 Mac 状态。") }
            }
        }
    }
}
