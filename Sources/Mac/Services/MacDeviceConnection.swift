import AppKit
import Foundation
import Network
import Observation
import QingkongCore

/// An account-authenticated local server. It never pulls playback or personal reports.
@MainActor @Observable
final class MacDeviceConnection {
    private(set) var isConnected = false
    private(set) var connectedName: String?
    private(set) var status = "正在确认 Apple ID 设备信任…"
    private var hostedStatus = "正在准备设备连接"
    var serviceStatus: String { credential == nil ? (trust?.status ?? hostedStatus) : hostedStatus }
    private(set) var report: DesktopReport?
    private(set) var isSyncing = false
    private(set) var isTransferring = false
    private(set) var reportNotice: String?
    private(set) var isHosting = false
    private(set) var connectionIssue: String?
    private(set) var reportReceivedAt: Date?
    var trustReady: Bool { credential != nil }
    private(set) var reportSyncState: DesktopReportSyncState?
    private(set) var phoneSupportsMusicCatalog = false
    private(set) var catalogNotice: String?
    private(set) var catalogReceivedAt: Date?
    var catalogAlbumCount: Int { library?.musicCatalog?.albums.count ?? 0 }
    var hasMusicCatalog: Bool { library?.musicCatalog != nil }
    @ObservationIgnored private weak var library: MacLibrary?
    private let hostID: UUID
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var peers: [UUID: Peer] = [:]
    @ObservationIgnored private weak var player: MacAudioPlayer?
    @ObservationIgnored private weak var trust: DesktopAccountTrust?
    private var credential: Data?
    @ObservationIgnored private var accountScope: String?
    @ObservationIgnored private var accountChangeID: UUID?
    @ObservationIgnored private var ownerDeviceID: String?
    @ObservationIgnored private var ownerConnectionID: UUID?
    @ObservationIgnored private var phoneOwnerDeviceID: String?
    @ObservationIgnored private var phoneOwnerPeerID: UUID?
    @ObservationIgnored private var phoneCommands: [UUID: PendingPhoneCommand] = [:]
    private struct PendingPhoneCommand {
        let peerID: UUID
        let sessionID: UUID
        let continuation: CheckedContinuation<PhonePlaybackReply, Error>
        let timeout: Task<Void, Never>
    }
    @ObservationIgnored private var preparedDeviceID: String?
    @ObservationIgnored private var preparedSessionID: UUID?
    @ObservationIgnored private var preparedConnectionID: UUID?
    @ObservationIgnored private var inbox: [Incoming] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var processing: Task<Void, Never>?
    @ObservationIgnored private var processingPeerID: UUID?
    @ObservationIgnored private var publisher: Task<Void, Never>?
    @ObservationIgnored private var results: [String: DesktopMusicResponse] = [:]
    @ObservationIgnored private var resultOrder: [String] = []

    private final class Peer {
        let id = UUID()
        let connection: LocalPeerConnection
        var deviceID: String?
        var name = "iPhone"
        var queued = 0
        var observing = false
        var reportSyncState: DesktopReportSyncState?
        var supportsMusicCatalog = false
        var supportsPhonePlayback = false
        var catalogReceiver = DesktopMusicCatalogReceiver()
        var catalogActivityAt: Date?
        var catalogTransfer: DesktopMusicCatalogTransferInfo?
        init(_ connection: LocalPeerConnection) { self.connection = connection }
    }
    private struct Incoming {
        let peerID: UUID
        let request: DesktopMusicRequest
    }

    init() {
        let key = "qingkong.mac.host-id.v1"
        hostID = UserDefaults.standard.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        UserDefaults.standard.set(hostID.uuidString, forKey: key)
    }

    func startHosting(player: MacAudioPlayer, trust: DesktopAccountTrust, library: MacLibrary? = nil) async {
        guard self.trust == nil else { return }
        attachPlayer(player)
        self.trust = trust; self.library = library
        trust.didChange = { [weak self] in self?.applyTrust() }
        applyTrust()
        await trust.refresh()
        applyTrust()
        publisher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.publishSnapshot()
            }
        }
    }

    func attachPlayer(_ player: MacAudioPlayer) {
        guard self.player == nil else { return }
        self.player = player
        player.phoneCommandHandler = { [weak self] command in
            guard let self else { throw DesktopConnectionError.disconnected }
            return try await self.controlPhone(command)
        }
        player.didChange = { [weak self] in
            guard let self else { return }
            if self.ownerDeviceID != nil && self.player?.controlledSessionID == nil {
                self.ownerDeviceID = nil; self.ownerConnectionID = nil
            }
        }
    }

    func refreshTrust() async { await trust?.refresh(); applyTrust() }

    private func applyTrust() {
        guard let trust else { return }
        hostedStatus = trust.status
        let accountChanged = accountChangeID != nil && accountChangeID != trust.accountChangeID
        let scopeChanged = accountScope != nil && trust.accountScope != nil && accountScope != trust.accountScope
        accountChangeID = trust.accountChangeID
        if accountChanged || scopeChanged {
            stopHosting(); player?.discardControlledSession()
            report = nil; reportReceivedAt = nil
            clearReport(); results = [:]; resultOrder = []
            ownerDeviceID = nil; ownerConnectionID = nil
            credential = nil; accountScope = nil
        }
        guard let next = trust.credential else {
            if credential != nil { stopHosting() }
            credential = nil; report = nil; reportReceivedAt = nil; status = trust.status; return
        }
        guard credential != next || listener == nil else { return }
        stopHosting()
        credential = next; accountScope = trust.accountScope; connectionIssue = nil
        // Do not expose a disk cache until the current account has been verified.
        if let accountScope {
            do {
                let cached = try MacReportCache.load(accountScope: accountScope)
                report = cached?.report; reportReceivedAt = cached?.receivedAt
            } catch { reportNotice = "本机报表需要从 iPhone 重新同步。" }
        }
        do {
            let parameters = try DesktopPairing.parameters(secret: next)
            parameters.acceptLocalOnly = true
            parameters.prohibitedInterfaceTypes = [.cellular]
            let nextListener = try NWListener(using: parameters)
            let name = Host.current().localizedName ?? "Mac"
            nextListener.service = NWListener.Service(name: "小晴空 Mac · \(name)", type: DesktopPairing.serviceType)
            listener = nextListener
            nextListener.newConnectionHandler = { [weak self, weak nextListener] incoming in
                Task { @MainActor in
                    guard let self, let nextListener, self.listener === nextListener else { incoming.cancel(); return }
                    self.accept(incoming)
                }
            }
            nextListener.stateUpdateHandler = { [weak self, weak nextListener] state in
                Task { @MainActor in
                    guard let self, let nextListener, self.listener === nextListener else { return }
                    switch state {
                    case .ready:
                        self.isHosting = true; self.connectionIssue = nil
                        self.hostedStatus = "在 iPhone 小晴空的个性化 → 连接 Mac 中连接这台设备"
                        self.status = self.isConnected ? "已连接，等待 iPhone 操作。" : "等待 iPhone 连接"
                    case .failed:
                        self.stopHosting(); self.connectionIssue = "请检查 Wi-Fi 和本地网络权限后重试。"
                        self.hostedStatus = "设备连接不可用，请检查本地网络权限与 Wi-Fi 后刷新。"
                    default: break
                    }
                }
            }
            nextListener.start(queue: .main)
        } catch { connectionIssue = error.localizedDescription; hostedStatus = "设备连接暂时不可用：\(error.localizedDescription)" }
    }

    private func stopHosting() {
        listener?.cancel(); listener = nil; isHosting = false; processing?.cancel()
        let previous = Array(peers.values); peers.removeAll()
        for peer in previous { peer.connection.close() }
        failPhoneCommands()
        phoneOwnerPeerID = nil; phoneOwnerDeviceID = nil; player?.endPhonePlayback()
        player?.pauseControlledSession(); clearPreparedOwner()
        ownerConnectionID = nil; isConnected = false; connectedName = nil; reportSyncState = nil
    }

    func accept(_ incoming: NWConnection) {
        guard peers.count < 4 else { incoming.cancel(); return }
        let peer = Peer(LocalPeerConnection(incoming)); peers[peer.id] = peer
        peer.connection.onMessage = { [weak self, weak peer] data in
            guard let self, let peer, self.peers[peer.id] === peer else { return }
            self.receive(data, from: peer)
        }
        peer.connection.onClose = { [weak self, weak peer] message in
            guard let self, let peer, self.peers.removeValue(forKey: peer.id) != nil else { return }
            if self.processingPeerID == peer.id { self.processing?.cancel() }
            if self.preparedConnectionID == peer.id { self.player?.discardPreparation(); self.clearPreparedOwner() }
            self.failPhoneCommands(peerID: peer.id)
            if self.phoneOwnerPeerID == peer.id {
                self.phoneOwnerPeerID = nil
                self.player?.phonePlaybackDisconnected()
            }
            if self.ownerConnectionID == peer.id {
                self.player?.pauseControlledSession(); self.ownerConnectionID = nil
                self.status = "连接已断开，Mac 已暂停接续音乐。重新连接后可查看进度并继续。"
            } else { self.status = message }
            self.refreshConnectionStatus()
        }
        peer.connection.start()
    }

    func disconnect() {
        let previous = Array(peers.values)
        for peer in previous { peer.connection.close() }
        status = "已断开 iPhone 连接。"
    }

    private func receive(_ data: Data, from peer: Peer) {
        guard let request = try? JSONDecoder().decode(DesktopMusicRequest.self, from: data),
              request.version == 2, valid(request), inbox.count < 64, peer.queued < 16 else {
            peer.connection.close(message: DesktopConnectionError.invalidMessage.localizedDescription); return
        }
        guard peer.deviceID != nil || request.action == .hello else {
            send(DesktopMusicResponse(id: request.id, success: false, error: "请先确认设备身份。"), to: peer); return
        }
        if [.phonePlayback, .phonePlaybackEnd, .phoneCommandResult].contains(request.action) {
            receivePhonePlayback(request, from: peer)
            return
        }
        if [.catalogBegin, .catalogChunk, .catalogCommit, .catalogStatus].contains(request.action) {
            receiveCatalog(request, from: peer)
            return
        }
        // These synchronous operations stay responsive during silent preparation.
        if request.action == .observe {
            peer.observing = request.observing!
            let snapshot = ownerDeviceID == peer.deviceID ? player?.snapshot : nil
            send(DesktopMusicResponse(id: request.id, snapshot: snapshot), to: peer)
            return
        }
        if request.action == .reportSyncStatus {
            peer.reportSyncState = request.reportSyncState
            refreshConnectionStatus()
            send(DesktopMusicResponse(id: request.id), to: peer)
            return
        }
        if let command = request.command, command.action == .status {
            guard ownerDeviceID == peer.deviceID, command.sessionID == player?.controlledSessionID,
                  let snapshot = player?.snapshot else {
                send(DesktopMusicResponse(id: request.id, success: false, error: "这段播放已不属于当前设备。"), to: peer)
                return
            }
            send(DesktopMusicResponse(id: request.id, snapshot: snapshot), to: peer)
            return
        }
        peer.queued += 1; inbox.append(Incoming(peerID: peer.id, request: request))
        guard worker == nil else { return }
        // A single queue also covers requests arriving while prepare/seek suspends.
        worker = Task { [weak self] in
            guard let self else { return }
            while !self.inbox.isEmpty {
                let incoming = self.inbox.removeFirst()
                guard let peer = self.peers[incoming.peerID] else { continue }
                peer.queued = max(0, peer.queued - 1)
                let processing = Task { await self.process(incoming.request, from: peer) }
                self.processing = processing; self.processingPeerID = peer.id
                await processing.value
                self.processing = nil; self.processingPeerID = nil
            }
            self.worker = nil
        }
    }

    private func process(_ request: DesktopMusicRequest, from peer: Peer) async {
        if request.action == .hello {
            guard let deviceID = request.deviceID, let name = request.deviceName,
                  UUID(uuidString: deviceID) != nil,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
                  peer.deviceID == nil || peer.deviceID == deviceID else {
                peer.connection.close(message: DesktopConnectionError.invalidMessage.localizedDescription); return
            }
            peer.deviceID = deviceID; peer.name = name
            peer.supportsMusicCatalog = request.capabilities?.contains(DesktopMusicCatalog.capability) == true
            peer.supportsPhonePlayback = request.capabilities?.contains(PhoneAirPlay.capability) == true
            if ownerDeviceID == deviceID {
                if ownerConnectionID != peer.id { player?.pauseControlledSession() }
                ownerConnectionID = peer.id
                status = "已重新连接，播放状态已更新。"
            }
            refreshConnectionStatus()
            let state = ownerDeviceID == deviceID &&
                (request.sessionID == nil || request.sessionID == player?.controlledSessionID) ? player?.snapshot : nil
            send(DesktopMusicResponse(id: request.id, snapshot: state, hostID: hostID,
                capabilities: [DesktopReportSyncState.capability, DesktopMusicCatalog.capability, PhoneAirPlay.capability],
                airPlayReceiverName: Host.current().localizedName ?? "Mac"), to: peer)
            return
        }
        guard let deviceID = peer.deviceID, let player else { return }
        let key = "\(deviceID):\(request.id.uuidString)"
        if let cached = results[key], request.command?.action != .status {
            send(replay(cached, id: request.id, for: deviceID), to: peer); return
        }
        if let command = request.command, command.action != .status,
           let cached = results["command:\(deviceID):\(command.id.uuidString)"] {
            let response = replay(cached, id: request.id, for: deviceID)
            remember(response, key: key); send(response, to: peer); return
        }
        let response: DesktopMusicResponse
        do {
            switch request.action {
            case .hello: return
            case .phonePlayback, .phonePlaybackEnd, .phoneCommandResult: return
            case .prepare:
                guard let start = request.start else { throw DesktopConnectionError.invalidMessage }
                isTransferring = true; defer { isTransferring = false }
                let preparedID = try await player.prepare(start)
                guard peers[peer.id] === peer else { player.discardPreparation(); throw DesktopConnectionError.disconnected }
                preparedDeviceID = deviceID; preparedSessionID = preparedID; preparedConnectionID = peer.id
                response = DesktopMusicResponse(id: request.id, preparedID: preparedID)
                status = "声音已准备，等待 iPhone 确认接续。"
            case .commit:
                guard let sessionID = request.sessionID else { throw DesktopConnectionError.invalidMessage }
                if ownerDeviceID == deviceID, player.controlledSessionID == sessionID, let snapshot = player.snapshot {
                    response = DesktopMusicResponse(id: request.id, snapshot: snapshot)
                } else {
                    guard preparedDeviceID == deviceID, preparedSessionID == sessionID else { throw DesktopConnectionError.invalidMessage }
                    let snapshot = try await player.commit(sessionID: sessionID, latest: request.start)
                    ownerDeviceID = deviceID; ownerConnectionID = peer.id; clearPreparedOwner()
                    response = DesktopMusicResponse(id: request.id, snapshot: snapshot)
                    status = "iPhone 已把声音接续到这台 Mac。"
                }
            case .command:
                guard ownerDeviceID == deviceID, let command = request.command else { throw DesktopConnectionError.invalidMessage }
                let resumeOnRelease = command.action == .release ?
                    (player.playbackIntent && player.deadline?.expired() != true) : nil
                let snapshot = try await player.execute(command)
                if peers[peer.id] == nil { player.pauseControlledSession() }
                ownerConnectionID = peers[peer.id] == nil ? nil : peer.id
                response = DesktopMusicResponse(id: request.id, snapshot: snapshot, resumeOnRelease: resumeOnRelease)
            case .observe:
                guard let observing = request.observing else { throw DesktopConnectionError.invalidMessage }
                peer.observing = observing
                response = DesktopMusicResponse(id: request.id, snapshot: ownerDeviceID == deviceID ? player.snapshot : nil)
            case .reportUpload:
                guard let incoming = request.report else { throw DesktopConnectionError.invalidMessage }
                isSyncing = true; defer { isSyncing = false }
                let validated = try MacReportCache.validate(incoming)
                guard let accountScope else { throw DesktopConnectionError.disconnected }
                let receivedAt = Date.now
                do { try MacReportCache.save(validated, accountScope: accountScope, receivedAt: receivedAt) }
                catch {
                    reportNotice = "报表未能保存，请在 iPhone 重试。"
                    peer.reportSyncState = .failed
                    throw error
                }
                report = validated; reportNotice = nil; reportReceivedAt = receivedAt
                if peer.reportSyncState != nil && peer.reportSyncState != .disabled { peer.reportSyncState = .enabled }
                response = DesktopMusicResponse(id: request.id)
                status = "已保存 iPhone 发送的最新报表。"
            case .catalogBegin, .catalogChunk, .catalogCommit, .catalogStatus:
                return // Catalog traffic bypasses slow audio preparation.
            case .reportSyncStatus:
                peer.reportSyncState = request.reportSyncState
                response = DesktopMusicResponse(id: request.id)
            }
        } catch {
            response = DesktopMusicResponse(id: request.id, success: false, error: error.localizedDescription)
        }
        remember(response, key: key)
        if let command = request.command { remember(response, key: "command:\(deviceID):\(command.id.uuidString)") }
        if peers[peer.id] === peer { send(response, to: peer) }
        refreshConnectionStatus()
    }

    private func receiveCatalog(_ request: DesktopMusicRequest, from peer: Peer) {
        guard let library else {
            send(.init(id: request.id, success: false, error: "请更新 Mac 以同步专辑目录。"), to: peer)
            return
        }
        // Each authenticated connection owns a bounded, incomplete transfer. Its
        // state disappears on disconnect and never replaces a committed catalog.
        if let activity = peer.catalogActivityAt, Date.now.timeIntervalSince(activity) > 60 {
            peer.catalogReceiver.reset(); peer.catalogActivityAt = nil; peer.catalogTransfer = nil
        }
        do {
            var receipt: DesktopMusicCatalogTransferInfo?
            switch request.action {
            case .catalogBegin:
                try peer.catalogReceiver.begin(request.catalogTransfer!, current: library.musicCatalog)
                peer.catalogActivityAt = .now; peer.catalogTransfer = request.catalogTransfer
            case .catalogChunk:
                try peer.catalogReceiver.append(request.catalogChunk!)
                peer.catalogActivityAt = .now
            case .catalogCommit:
                let catalog = try peer.catalogReceiver.commit(transferID: request.catalogTransferID!, current: library.musicCatalog)
                _ = try library.acceptMusicCatalog(catalog)
                receipt = peer.catalogTransfer; peer.catalogTransfer = nil
                catalogReceivedAt = .now; catalogNotice = nil; peer.catalogActivityAt = nil
            case .catalogStatus: break
            default: throw DesktopConnectionError.invalidMessage
            }
            guard request.action == .catalogStatus || request.action == .catalogCommit else {
                send(.init(id: request.id), to: peer)
                return
            }
            let current = try library.musicCatalog.map { catalog in
                DesktopMusicCatalogStatus(catalog: catalog, digest: try catalog.contentDigest(),
                    syncedAt: catalogReceivedAt ?? catalog.checkedAt)
            }
            send(.init(id: request.id, catalogStatus: current, catalogReceipt: receipt), to: peer)
        } catch {
            peer.catalogReceiver.reset(); peer.catalogActivityAt = nil; peer.catalogTransfer = nil
            catalogNotice = "专辑目录未能同步，可在 iPhone 刷新后重试。"
            send(.init(id: request.id, success: false, error: error.localizedDescription), to: peer)
        }
    }

    private func valid(_ request: DesktopMusicRequest) -> Bool {
        guard request.version == 2, request.action == .reportSyncStatus || request.reportSyncState == nil else { return false }
        let phoneActions: [DesktopMusicRequest.Action] = [.phonePlayback, .phonePlaybackEnd, .phoneCommandResult]
        if phoneActions.contains(request.action) {
            guard request.start == nil, request.command == nil, request.report == nil, request.observing == nil,
                  request.catalogTransfer == nil, request.catalogChunk == nil, request.catalogTransferID == nil,
                  request.deviceID == nil, request.deviceName == nil, request.capabilities == nil else { return false }
            switch request.action {
            case .phonePlayback: return request.phonePlayback?.isValid == true && request.phoneReply == nil && request.sessionID == nil
            case .phonePlaybackEnd: return request.phonePlayback == nil && request.phoneReply == nil
            case .phoneCommandResult:
                guard let reply = request.phoneReply else { return false }
                return request.phonePlayback == nil && request.sessionID == nil &&
                    (reply.snapshot?.isValid ?? true) && (reply.error?.count ?? 0) <= 1000
            default: return false
            }
        }
        guard request.phonePlayback == nil, request.phoneReply == nil else { return false }
        let catalogActions: [DesktopMusicRequest.Action] = [.catalogBegin, .catalogChunk, .catalogCommit, .catalogStatus]
        if !catalogActions.contains(request.action),
           request.catalogTransfer != nil || request.catalogChunk != nil || request.catalogTransferID != nil { return false }
        switch request.action {
        case .phonePlayback, .phonePlaybackEnd, .phoneCommandResult: return false
        case .hello:
            return request.deviceID.flatMap(UUID.init(uuidString:)) != nil &&
                (request.deviceName.map { !$0.isEmpty && $0.count <= 100 } ?? false) &&
                request.start == nil && request.command == nil && request.report == nil && request.observing == nil
        case .prepare:
            return request.start?.isValid == true && request.command == nil && request.report == nil && request.observing == nil
        case .commit:
            return request.sessionID != nil && (request.start?.isValid ?? true) && request.command == nil && request.report == nil && request.observing == nil
        case .command:
            return request.command?.isValid == true && request.start == nil && request.report == nil && request.observing == nil
        case .reportUpload:
            return request.report != nil && request.start == nil && request.command == nil && request.observing == nil
        case .observe:
            return request.observing != nil && request.start == nil && request.command == nil && request.report == nil
        case .catalogBegin, .catalogChunk, .catalogCommit, .catalogStatus:
            guard request.start == nil, request.command == nil, request.report == nil,
                  request.observing == nil, request.sessionID == nil else { return false }
            switch request.action {
            case .catalogBegin: return request.catalogTransfer != nil && request.catalogChunk == nil && request.catalogTransferID == nil
            case .catalogChunk: return request.catalogChunk != nil && request.catalogTransfer == nil && request.catalogTransferID == nil
            case .catalogCommit: return request.catalogTransferID != nil && request.catalogTransfer == nil && request.catalogChunk == nil
            case .catalogStatus: return request.catalogTransfer == nil && request.catalogChunk == nil && request.catalogTransferID == nil
            default: return false
            }
        case .reportSyncStatus:
            return request.reportSyncState != nil && request.start == nil && request.command == nil &&
                request.report == nil && request.observing == nil && request.sessionID == nil
        }
    }

    private func receivePhonePlayback(_ request: DesktopMusicRequest, from peer: Peer) {
        guard peer.supportsPhonePlayback, let deviceID = peer.deviceID, let player else { return }
        switch request.action {
        case .phonePlayback:
            guard let update = request.phonePlayback,
                  update.routeName == (Host.current().localizedName ?? "Mac"),
                  phoneOwnerDeviceID == nil || phoneOwnerDeviceID == deviceID || phoneOwnerPeerID == nil else { return }
            // A snapshot only describes audio already routed by iOS. No prepare,
            // download, commit, resume, or audio decoder is invoked here.
            if phoneOwnerDeviceID != deviceID { failPhoneCommands() }
            if player.applyPhonePlayback(update.snapshot) {
                phoneOwnerDeviceID = deviceID; phoneOwnerPeerID = peer.id
            }
        case .phonePlaybackEnd:
            guard phoneOwnerDeviceID == deviceID,
                  request.sessionID == nil || request.sessionID == player.phoneSnapshot?.sessionID else { return }
            failPhoneCommands(); phoneOwnerDeviceID = nil; phoneOwnerPeerID = nil
            player.endPhonePlayback()
        case .phoneCommandResult:
            guard let reply = request.phoneReply, let pending = phoneCommands[reply.id],
                  pending.peerID == peer.id, pending.sessionID == reply.sessionID else { return }
            phoneCommands.removeValue(forKey: reply.id)
            pending.timeout.cancel(); pending.continuation.resume(returning: reply)
        default: return
        }
    }

    private func controlPhone(_ command: PhonePlaybackCommand) async throws -> PhonePlaybackReply {
        guard command.isValid, command.sessionID == player?.phoneSnapshot?.sessionID,
              let id = phoneOwnerPeerID, let peer = peers[id], peer.supportsPhonePlayback,
              phoneCommands.count < 16 else { throw DesktopConnectionError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                guard let pending = self?.phoneCommands.removeValue(forKey: command.id) else { return }
                pending.continuation.resume(throwing: DesktopConnectionError.timedOut)
            }
            phoneCommands[command.id] = PendingPhoneCommand(peerID: peer.id, sessionID: command.sessionID,
                continuation: continuation, timeout: timeout)
            send(.init(id: command.id, phoneCommand: command), to: peer)
        }
    }

    private func failPhoneCommands(peerID: UUID? = nil) {
        let cancelled = phoneCommands.filter { peerID == nil || $0.value.peerID == peerID }
        for (id, pending) in cancelled {
            phoneCommands.removeValue(forKey: id); pending.timeout.cancel()
            pending.continuation.resume(throwing: DesktopConnectionError.disconnected)
        }
    }

    private func replay(_ cached: DesktopMusicResponse, id: UUID, for deviceID: String) -> DesktopMusicResponse {
        if let prior = cached.snapshot,
           ownerDeviceID != deviceID || player?.controlledSessionID != prior.sessionID {
            return DesktopMusicResponse(id: id, success: false, error: "这段播放已被更换，请重新选择播放设备。")
        }
        let current = ownerDeviceID == deviceID ? player?.snapshot : nil
        let snapshot = current?.sessionID == cached.snapshot?.sessionID ? current : cached.snapshot
        return DesktopMusicResponse(id: id, success: cached.success, error: cached.error,
                                    snapshot: snapshot, preparedID: cached.preparedID, resumeOnRelease: cached.resumeOnRelease)
    }

    private func remember(_ response: DesktopMusicResponse, key: String) {
        if results[key] == nil { resultOrder.append(key) }
        results[key] = response
        while resultOrder.count > 256 { results.removeValue(forKey: resultOrder.removeFirst()) }
    }
    private func clearPreparedOwner() { preparedDeviceID = nil; preparedSessionID = nil; preparedConnectionID = nil }
    private func refreshConnectionStatus() {
        let authenticated = peers.values.filter { $0.deviceID != nil }
        isConnected = !authenticated.isEmpty
        let current = ownerConnectionID.flatMap { peers[$0] } ?? authenticated.first
        connectedName = current?.name
        phoneSupportsMusicCatalog = current?.supportsMusicCatalog == true
        reportSyncState = current?.reportSyncState
    }
    private func publishSnapshot() {
        guard let ownerConnectionID, let peer = peers[ownerConnectionID], peer.observing, let snapshot = player?.snapshot else { return }
        send(DesktopMusicResponse(id: UUID(), snapshot: snapshot), to: peer)
    }
    private func send(_ response: DesktopMusicResponse, to peer: Peer) {
        do { try peer.connection.send(JSONEncoder().encode(response)) }
        catch { peer.connection.close(message: error.localizedDescription) }
    }
    func clearReport() {
        do { try MacReportCache.clear(); report = nil; reportReceivedAt = nil; reportNotice = "已清除这台 Mac 上的报表缓存。" }
        catch { reportNotice = "缓存未能清除，请稍后重试。" }
    }
}

enum MacCompanionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}
