import Foundation
import Network
import Observation
import QingkongCore
import UIKit

struct PhoneMacDevice: Identifiable {
    let id: String
    let name: String
    var hostID: UUID?
    var supportsAutoReport = false
    var supportsMusicCatalog = false
}

struct PhoneReportMac: Identifiable {
    let id: UUID
    let name: String
    let connectedDeviceID: String?
}

/// Music connections survive scene changes; health reports are pushed only in the foreground.
@MainActor @Observable
final class PhoneDesktopSync {
    private(set) var devices: [PhoneMacDevice] = []
    private(set) var message = "正在检查同一 Apple ID 的 Mac…"
    private(set) var isTransferring = false
    private(set) var isSyncing = false
    private(set) var selectedDeviceID: String?
    var selectedReportDeviceID: String?
    private(set) var reportStates: [String: DesktopReportSyncState] = [:]
    private(set) var reportErrors: [String: String] = [:]
    private(set) var reportSyncedAt: [String: Date] = [:]
    private(set) var reportFeedback: String?
    private(set) var catalogSyncedAt: [String: Date] = [:]
    private(set) var catalogErrors: [String: String] = [:]
    @ObservationIgnored private var catalogTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var catalogPending: Set<String> = []
    @ObservationIgnored private var catalogTokens: [String: UUID] = [:]
    private var reportAuthorization = DesktopReportAuthorization()
    private var reportMacNames: [String: String] = [:]
    @ObservationIgnored private var reportTask: Task<Void, Never>?
    @ObservationIgnored private var reportEpoch = UUID()
    @ObservationIgnored private var reportCheckPending = false
    @ObservationIgnored private var needsReportRefresh = false
    @ObservationIgnored private var lastReportContent: [String: Data] = [:]
    @ObservationIgnored private var trustChangeID: UUID?
    private static let reportAuthorizationKey = "qingkong.desktop.report-authorization.v1"
    private static let reportNamesKey = "qingkong.desktop.report-mac-names.v1"
    var isConnected: Bool { clients.values.contains(where: { $0.isConnected }) }
    var trustStatus: String { trust.status }
    var selectedName: String? { player.playbackDeviceName }

    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let health: HealthService
    @ObservationIgnored private let companion: CompanionStore
    @ObservationIgnored private let sleepHealth: SleepHealthService
    @ObservationIgnored private let player: AudioPlayer
    @ObservationIgnored private let content: ContentLibrary
    @ObservationIgnored private let trust = DesktopAccountTrust()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var clients: [String: PhoneMacPeer] = [:]
    @ObservationIgnored private var foreground = UIApplication.shared.applicationState == .active
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var operating = false
    @ObservationIgnored private var refreshingTrust = false
    @ObservationIgnored private var accountGeneration = UUID()
    @ObservationIgnored private var restored: SavedSession?
    @ObservationIgnored private var mirroredClientID: String?
    @ObservationIgnored private var mirroredSessionID: UUID?
    @ObservationIgnored private var suppressedAirPlayRouteID: String?
    @ObservationIgnored private var phoneCommandResults: [UUID: PhonePlaybackReply] = [:]
    @ObservationIgnored private var phoneCommandOrder: [UUID] = []
    @ObservationIgnored private var playbackPublisher: Task<Void, Never>?
    @ObservationIgnored private var clearedPhoneClients: Set<String> = []
    #if DEBUG
    @ObservationIgnored private var playbackDebugState: String?
    #endif
    private static let savedKey = "qingkong.desktop.music-session.v2"
    private static let deviceKey = "qingkong.desktop.device.v2"
    private let deviceID: String

    private struct SavedSession: Codable {
        let account: String
        let serviceName: String
        let serviceType: String
        let serviceDomain: String
        let snapshot: DesktopPlaybackSnapshot
        var id: String { "\(serviceName)|\(serviceType)|\(serviceDomain)" }
    }

    init(store: LocalStore, health: HealthService, companion: CompanionStore,
         sleepHealth: SleepHealthService, player: AudioPlayer, content: ContentLibrary) {
        self.store = store; self.health = health; self.companion = companion
        self.sleepHealth = sleepHealth; self.player = player; self.content = content
        if let data = UserDefaults.standard.data(forKey: Self.reportAuthorizationKey),
           let saved = try? JSONDecoder().decode(DesktopReportAuthorization.self, from: data) {
            reportAuthorization = saved
        }
        reportMacNames = UserDefaults.standard.dictionary(forKey: Self.reportNamesKey) as? [String: String] ?? [:]
        let existing = UserDefaults.standard.string(forKey: Self.deviceKey)
        deviceID = existing.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: Self.deviceKey)
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let saved = try? JSONDecoder().decode(SavedSession.self, from: data), saved.snapshot.isValid {
            restored = saved; selectedDeviceID = saved.id
            player.applyDesktop(saved.snapshot, connected: false)
            player.desktopConnectionLost("正在重新确认 Mac 播放状态。")
        }
        trust.didChange = { [weak self] in self?.accountChanged() }
        player.desktopHandler = { [weak self] command in
            guard let self else { return AudioReply(id: command.id, state: AudioState(), error: "Mac 遥控不可用。") }
            return await self.handle(command)
        }
        player.desktopSelection = { [weak self] queue, index, playing in
            guard let self, let selected = self.selectedDeviceID else { return }
            let start = DesktopPlaybackStart(queue: queue, index: index, position: 0, playing: playing,
                mode: self.player.playbackMode, deadline: self.player.state.deadline, serviceAddress: self.content.serviceAddress)
            await self.handoff(to: selected, selection: start)
        }
        let previousStateHandler = player.didChangeState
        player.didChangeState = { [weak self] state in
            previousStateHandler?(state)
            // Do not recurse through AudioState while sampling progress.
            self?.publishPhonePlayback()
        }
        playbackPublisher = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.publishPhonePlayback()
            }
        }
    }

    func start() async {
        guard !refreshingTrust else { return }
        refreshingTrust = true
        await trust.refresh()
        #if DEBUG
        NSLog("[AirPlay check] Device trust: %@", trust.status)
        #endif
        refreshingTrust = false
        if trust.credential != nil { startBrowsing() }
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                if self.foreground || (self.player.airPlayRouteID != nil && (self.player.state.playing || self.player.buffering)) {
                    for client in self.clients.values where !client.isConnected { client.connect() }
                }
            }
        }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        for client in clients.values { client.observe(active) }
        if active {
            Task {
                // Account-change notifications revoke trust immediately. A
                // scene transition alone must not revalidate a working session
                // against CloudKit and tear it down on a transient cloud error.
                if trust.credential == nil { await start() }
                guard foreground else { return }
                await refreshPlayback()
                scheduleReportSync(refreshData: true)
                catalogDataChanged()
            }
        } else {
            reportEpoch = UUID(); reportTask?.cancel(); reportTask = nil; reportCheckPending = false
            cancelCatalogSync()
        }
    }

    private func accountChanged() {
        mirroredClientID = nil; mirroredSessionID = nil
        clearedPhoneClients = []
        phoneCommandResults = [:]; phoneCommandOrder = []
        cancelCatalogSync(); catalogSyncedAt = [:]; catalogErrors = [:]
        reportEpoch = UUID(); reportTask?.cancel(); reportTask = nil
        lastReportContent = [:]; reportStates = [:]; reportErrors = [:]; reportSyncedAt = [:]; reportFeedback = nil
        if let prior = trustChangeID, prior != trust.accountChangeID {
            reportAuthorization.confirmAccount(nil)
            reportMacNames = [:]
            saveReportAuthorization()
        }
        trustChangeID = trust.accountChangeID
        if let scope = trust.accountScope {
            if reportAuthorization.accountScope != scope { reportMacNames = [:] }
            reportAuthorization.confirmAccount(scope)
            saveReportAuthorization()
        }
        accountGeneration = UUID()
        let previous = clients.values; clients.removeAll()
        for client in previous { client.close() }
        browser?.cancel(); browser = nil; devices = []
        guard trust.credential != nil, let account = trust.accountScope else {
            message = trust.status
            if restored != nil || player.isDesktopControlled {
                player.desktopConnectionLost("正在核对 iCloud 账号，Mac 遥控暂不可用。")
            }
            return
        }
        if let saved = restored {
            if saved.account == account {
                let endpoint = NWEndpoint.service(name: saved.serviceName, type: saved.serviceType, domain: saved.serviceDomain, interface: nil)
                addClient(id: saved.id, name: saved.snapshot.deviceName, endpoint: endpoint)
            } else {
                restored = nil; selectedDeviceID = nil
                UserDefaults.standard.removeObject(forKey: Self.savedKey)
                player.clearDesktopSelection()
            }
        }
        startBrowsing()
    }

    private func startBrowsing() {
        guard browser == nil, trust.credential != nil else { return }
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let next = NWBrowser(for: .bonjour(type: DesktopPairing.serviceType, domain: nil), using: parameters)
        browser = next
        next.browseResultsChangedHandler = { [weak self, weak next] results, _ in
            Task { @MainActor in
                guard let self, let next, self.browser === next else { return }
                let visible = Set(results.compactMap { result -> String? in
                    guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                    return "\(name)|\(type)|\(domain)"
                })
                let kept = Set([self.selectedDeviceID, self.mirroredClientID].compactMap { $0 })
                for id in PhoneMacPeer.removeMissing(from: &self.clients, visible: visible, keeping: kept) {
                    self.cancelCatalogSync(for: id)
                }
                self.refreshDevices()
                for result in results {
                    guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                    self.addClient(id: "\(name)|\(type)|\(domain)", name: name, endpoint: result.endpoint)
                }
            }
        }
        next.stateUpdateHandler = { [weak self, weak next] state in
            Task { @MainActor in
                guard let self, let next, self.browser === next else { return }
                switch state {
                case .failed: self.message = "无法发现 Mac，请检查 Wi-Fi 和本地网络权限。"
                case .ready: self.message = "打开同一 Wi-Fi 下 Mac 上的小晴空即可自动连接。"
                default: break
                }
            }
        }
        next.start(queue: .main)
    }

    private func addClient(id: String, name: String, endpoint: NWEndpoint) {
        guard clients[id] == nil, clients.count < 8, let secret = trust.credential else { return }
        let client = PhoneMacPeer(id: id, name: name, endpoint: endpoint, secret: secret, deviceID: deviceID, deviceName: UIDevice.current.name)
        clients[id] = client
        client.onPhoneCommand = { [weak self, weak client] command in
            guard let self, let client else { return .init(id: command.id, sessionID: command.sessionID, error: "iPhone 不可用。") }
            return await self.receivePhoneCommand(command, from: client)
        }
        client.onSnapshot = { [weak self, weak client] snapshot in
            guard let self, let client, self.selectedDeviceID == client.id else { return }
            self.accept(snapshot, from: client)
        }
        client.onChange = { [weak self, weak client] in
            guard let self, let client, self.clients[id] === client else { return }
            self.refreshDevices()
            if client.isConnected {
                client.observe(self.foreground)
                self.message = ""
                if let hostID = client.hostID {
                    self.reportMacNames[hostID.uuidString] = client.name
                    self.saveReportAuthorization()
                }
                self.lastReportContent.removeValue(forKey: id)
                self.scheduleReportSync(refreshData: true)
                self.scheduleCatalogSync(to: client)
                self.clearedPhoneClients.remove(id)
                self.publishPhonePlayback()
                if self.selectedDeviceID == id { Task { await self.refreshPlayback() } }
            } else {
                self.clearedPhoneClients.remove(id)
                self.cancelCatalogSync(for: id)
                if self.selectedDeviceID == id {
                    self.player.desktopConnectionLost("与 Mac 的连接已中断，正在重新确认。")
                    self.message = client.message
                }
            }
        }
        client.connect()
    }

    private func refreshDevices() {
        devices = clients.values.filter(\.isConnected).map {
            PhoneMacDevice(id: $0.id, name: $0.name, hostID: $0.hostID, supportsAutoReport: $0.supportsAutoReport, supportsMusicCatalog: $0.supportsMusicCatalog)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let selectedReportDeviceID, !devices.contains(where: { $0.id == selectedReportDeviceID }) {
            self.selectedReportDeviceID = nil
        }
    }

    private func accept(_ snapshot: DesktopPlaybackSnapshot, from client: PhoneMacPeer) {
        guard snapshot.isValid, let current = player.desktopSnapshot,
              current.sessionID == snapshot.sessionID, snapshot.revision >= current.revision else { return }
        player.applyDesktop(snapshot, connected: client.isConnected)
        persist(snapshot, client: client)
    }

    private func persist(_ snapshot: DesktopPlaybackSnapshot, client: PhoneMacPeer) {
        guard let account = trust.accountScope,
              case let .service(name, type, domain, _) = client.endpoint else { return }
        let saved = SavedSession(account: account, serviceName: name, serviceType: type, serviceDomain: domain, snapshot: snapshot)
        let needsSave = restored?.snapshot.revision != snapshot.revision || restored?.snapshot.sessionID != snapshot.sessionID
        restored = saved
        if needsSave, let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    func handoff(to id: String) async { await handoff(to: id, selection: nil) }

    private func handoff(to id: String, selection: DesktopPlaybackStart?) async {
        guard !operating, let client = clients[id], client.isConnected else {
            message = "Mac 尚未连接，请检查同一 Apple ID 和 Wi-Fi。"; return
        }
        guard selectedDeviceID == nil || selectedDeviceID == id else {
            message = "请先切回此 iPhone，再选择另一台 Mac。"; return
        }
        guard let start = selection ?? player.desktopStart(serviceAddress: content.serviceAddress), start.isValid,
              start.deadline?.expired() != true else {
            message = "请先选择一首音乐，等待准备完成后重试。"; return
        }
        operating = true; isTransferring = true
        defer { operating = false; isTransferring = false }
        let generation = accountGeneration
        let sourceRevision = player.playbackRevision
        let wasRemote = player.isDesktopControlled
        do {
            let prepared = try await client.request(.init(action: .prepare, start: start), timeout: 35)
            guard prepared.success, prepared.preparedID == start.sessionID,
                  accountGeneration == generation else { throw PhoneMacError.message(prepared.error ?? "Mac 未完成准备。") }
            guard wasRemote || player.playbackRevision == sourceRevision else {
                client.close(); throw PhoneMacError.message("手机播放已变化，未切换播放设备。")
            }
            var latest = start
            if !wasRemote { latest.position = player.playbackPosition }
            // No phone audio is allowed after this point, even if the commit acknowledgement is lost.
            if !wasRemote { player.pauseForDesktopTransfer() }
            selectedDeviceID = id
            var pending = DesktopPlaybackSnapshot(sessionID: start.sessionID, revision: 0, queue: start.queue,
                index: start.index, position: start.position, duration: max(start.position, player.playbackDuration),
                playing: false, mode: start.mode, volume: player.state.volume, deadline: start.deadline, deviceName: client.name)
            pending.buffering = true
            player.applyDesktop(pending, connected: false); persist(pending, client: client)
            let committed = try await client.request(.init(action: .commit, start: latest, sessionID: start.sessionID))
            guard committed.success, let snapshot = committed.snapshot, snapshot.sessionID == start.sessionID,
                  snapshot.isValid, accountGeneration == generation else {
                throw PhoneMacError.message(committed.error ?? "Mac 未确认接力，请重新确认播放设备。")
            }
            player.applyDesktop(snapshot, connected: true); persist(snapshot, client: client)
            message = "正在 \(snapshot.deviceName) 播放，手机和手表可遥控。"
        } catch {
            message = "接力未完成：\(error.localizedDescription)"
            if selectedDeviceID == id, accountGeneration == generation { player.desktopConnectionLost(message) }
        }
    }

    func usePhone() async {
        guard let original = player.desktopSnapshot else { return }
        let id = selectedDeviceID
        let client = id.flatMap { clients[$0] }
        // A status request may still be timing out after the network has gone away.
        // Exiting an unavailable route must not wait for that request's operation lock.
        if !player.desktopConnected || client == nil {
            finishPausedPhoneReturn(original, confirmed: false)
            return
        }
        guard !operating else { message = "正在确认 Mac 状态，请稍后再切回。"; return }
        operating = true; isTransferring = true
        let generation = accountGeneration
        var released: DesktopPlaybackSnapshot?
        defer { operating = false; isTransferring = false; player.discardPhoneReturn() }
        do {
            guard let client, player.desktopConnected else { throw PhoneMacError.message("Mac 连接已中断。") }
            try await client.ensureConnected()
            // Prepare a silent phone decoder before asking the Mac to relinquish audio.
            try await player.preparePhoneReturn(original) {
                generation == self.accountGeneration && self.selectedDeviceID == id &&
                    self.player.desktopSnapshot?.sessionID == original.sessionID
            }
            guard generation == accountGeneration, selectedDeviceID == id,
                  player.desktopSnapshot?.sessionID == original.sessionID else { throw CancellationError() }
            let response = try await client.request(.init(action: .command,
                command: .init(sessionID: original.sessionID, action: .release)))
            guard response.success, let snapshot = response.snapshot, snapshot.isValid,
                  snapshot.sessionID == original.sessionID, !snapshot.playing,
                  generation == accountGeneration, selectedDeviceID == id else {
                throw PhoneMacError.message(response.error ?? "Mac 未确认暂停，未在手机开始播放。")
            }
            released = snapshot
            accept(snapshot, from: client)
            try await player.restoreFromDesktop(snapshot) {
                generation == self.accountGeneration && self.selectedDeviceID == id
            }
            guard generation == accountGeneration, selectedDeviceID == id else {
                player.pauseForDesktopTransfer(); throw CancellationError()
            }
            selectedDeviceID = nil; restored = nil
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
            if response.resumeOnRelease == true, snapshot.deadline?.expired() != true {
                await player.play()
                if generation != accountGeneration { player.pauseForDesktopTransfer() }
            }
            message = player.error ?? "已切回此 iPhone。"
        } catch {
            guard generation == accountGeneration, selectedDeviceID == id,
                  player.desktopSnapshot?.sessionID == original.sessionID else { return }
            if error is CancellationError { return }
            let snapshot = released ?? player.desktopSnapshot ?? original
            finishPausedPhoneReturn(snapshot, confirmed: released != nil)
        }
    }

    private func finishPausedPhoneReturn(_ snapshot: DesktopPlaybackSnapshot, confirmed: Bool) {
        // Detach before late peer callbacks arrive. Failed commands are never replayed.
        selectedDeviceID = nil; restored = nil
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
        player.returnToPhonePaused(snapshot)
        message = confirmed ? "已切回此 iPhone，播放已暂停。" : "已切回此 iPhone，播放已暂停；未能确认 Mac 状态。"
    }

    func refreshPlayback() async {
        publishPhonePlayback()
        guard player.isDesktopControlled else { return }
        _ = await handle(AudioCommand(action: .status))
    }

    private func publishPhonePlayback() {
        if suppressedAirPlayRouteID != player.airPlayRouteID { suppressedAirPlayRouteID = nil }
        let receivers = clients.filter { $0.value.isConnected }.compactMapValues(\.airPlayReceiverName)
        let target = player.airPlayRouteName.flatMap { PhoneAirPlay.matchingReceiver($0, receivers: receivers) }
        let snapshot = player.phonePlaybackSnapshot()
        #if DEBUG
        let debugState = "route=\(player.airPlayRouteName ?? "none"); receivers=\(receivers.values.sorted()); matched=\(target != nil); peers=\(clients.count); playing=\(snapshot?.playing == true); buffering=\(snapshot?.buffering == true); volume=\(snapshot?.volume ?? 0); legacy=\(player.isDesktopControlled); selection=\(snapshot != nil); valid=\(snapshot?.isValid == true)"
        if playbackDebugState != debugState {
            playbackDebugState = debugState
            NSLog("[AirPlay check] %@", debugState)
            // Latest diagnosis only: no credentials, account IDs or personal data.
            if let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                try? debugState.write(to: directory.appending(path: "airplay-state.txt"), atomically: true, encoding: .utf8)
            }
        }
        #endif
        let activeTarget = suppressedAirPlayRouteID == nil && snapshot != nil ? target : nil
        for (id, client) in clients where client.isConnected && id != activeTarget && !clearedPhoneClients.contains(id) {
            client.endPhonePlayback()
            clearedPhoneClients.insert(id)
        }
        guard suppressedAirPlayRouteID == nil, player.airPlayRouteID != nil, let snapshot else {
            if let id = mirroredClientID, let session = mirroredSessionID { clients[id]?.endPhonePlayback(sessionID: session) }
            mirroredClientID = nil; mirroredSessionID = nil
            return
        }
        // Keep the mirror's endpoint for reconnecting while the system route
        // still exists. A companion socket failure is not an AirPlay detach.
        guard let target, let client = clients[target], let routeName = client.airPlayReceiverName else { return }
        if let previous = mirroredClientID, previous != target, let session = mirroredSessionID {
            clients[previous]?.endPhonePlayback(sessionID: session)
        }
        do {
            try client.publishPhonePlayback(.init(routeName: routeName, snapshot: snapshot))
            clearedPhoneClients.remove(target)
            mirroredClientID = target; mirroredSessionID = snapshot.sessionID
        } catch {
            // Companion transport is never a reason to stop the real AirPlay audio.
        }
    }

    private func receivePhoneCommand(_ command: PhonePlaybackCommand, from client: PhoneMacPeer) async -> PhonePlaybackReply {
        let receivers = clients.filter { $0.value.isConnected }.compactMapValues(\.airPlayReceiverName)
        let target = player.airPlayRouteName.flatMap { PhoneAirPlay.matchingReceiver($0, receivers: receivers) }
        guard clients[client.id] === client, client.isConnected, mirroredClientID == client.id,
              mirroredSessionID == command.sessionID, target == client.id,
              suppressedAirPlayRouteID == nil else {
            return .init(id: command.id, sessionID: command.sessionID, error: "这台 Mac 不是当前 AirPlay 输出，未执行操作。")
        }
        if let cached = phoneCommandResults[command.id] { return cached }
        let generation = accountGeneration
        let background = UIApplication.shared.beginBackgroundTask(withName: "AirPlay 播放控制")
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        let reply = await player.handlePhonePlayback(command)
        guard generation == accountGeneration, clients[client.id] === client else {
            return .init(id: command.id, sessionID: command.sessionID, error: "设备信任已变化，请重新连接。")
        }
        phoneCommandResults[command.id] = reply; phoneCommandOrder.append(command.id)
        while phoneCommandOrder.count > 128 { phoneCommandResults.removeValue(forKey: phoneCommandOrder.removeFirst()) }
        if command.action == .release, reply.success {
            suppressedAirPlayRouteID = player.airPlayRouteID
            mirroredClientID = nil; mirroredSessionID = nil
        }
        return reply
    }

    private func handle(_ command: AudioCommand) async -> AudioReply {
        if trust.credential == nil {
            Task { await start() }
            return AudioReply(id: command.id, state: player.state, error: "正在核对同账号连接，未执行操作，请稍后重试。")
        }
        guard !operating, let id = selectedDeviceID, let client = clients[id], let snapshot = player.desktopSnapshot else {
            return AudioReply(id: command.id, state: player.state, error: "Mac 尚未确认连接，未执行操作。")
        }
        operating = true
        let generation = accountGeneration
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Mac 音乐遥控")
        defer {
            operating = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        do {
            try await client.ensureConnected()
            let action: DesktopPlaybackCommand.Action
            var amount: Double?
            var mode: AudioPlaybackMode?
            var deadline: SleepDeadline?
            switch command.action {
            case .status: action = .status
            case .play: action = .play
            case .playPause: action = snapshot.playing || snapshot.buffering ? .pause : .play
            case .pause: action = .pause
            case .previous: action = .previous
            case .next: action = .next
            case .seek: action = .seek; amount = command.amount
            case .volume: action = .volume; amount = command.amount
            case .mode: action = .mode; mode = command.playbackMode
            case .timer:
                guard let minutes = command.amount, [0.0, 15, 30, 60].contains(minutes) else { throw PhoneMacError.message("定时选项无效。") }
                action = .timer; deadline = minutes > 0 ? SleepDeadline(minutes: Int(minutes)) : nil
            case .select: throw PhoneMacError.message("请在手机曲库选择要在 Mac 播放的音乐。")
            }
            let control = DesktopPlaybackCommand(id: command.id, sessionID: snapshot.sessionID, action: action,
                amount: amount, mode: mode, deadline: deadline)
            guard control.isValid else { throw PhoneMacError.message("播放操作无效。") }
            let response = try await client.request(.init(action: .command, command: control), timeout: 4)
            guard response.success, let incoming = response.snapshot, incoming.isValid,
                  incoming.sessionID == snapshot.sessionID, accountGeneration == generation, selectedDeviceID == id else {
                throw PhoneMacError.message(response.error ?? "Mac 未确认操作，请更新两端小晴空。")
            }
            accept(incoming, from: client)
            return AudioReply(id: command.id, state: player.state)
        } catch {
            message = error.localizedDescription
            if (command.action != .status || !client.isConnected),
               accountGeneration == generation, selectedDeviceID == id,
               player.desktopSnapshot?.sessionID == snapshot.sessionID { player.desktopConnectionLost(message) }
            return AudioReply(id: command.id, state: player.state, error: message)
        }
    }

    /// Called after the public content service refreshes, independently of health consent.
    func catalogDataChanged() {
        for client in clients.values { scheduleCatalogSync(to: client) }
    }

    private func cancelCatalogSync(for id: String) {
        catalogTokens.removeValue(forKey: id)
        catalogPending.remove(id)
        catalogTasks.removeValue(forKey: id)?.cancel()
    }

    private func cancelCatalogSync() {
        let tasks = catalogTasks.values
        catalogTasks.removeAll(); catalogPending.removeAll(); catalogTokens.removeAll()
        for task in tasks { task.cancel() }
    }

    private func scheduleCatalogSync(to client: PhoneMacPeer) {
        guard foreground, client.isConnected, client.supportsMusicCatalog, trust.credential != nil else { return }
        if catalogTasks[client.id] != nil { catalogPending.insert(client.id); return }
        let generation = accountGeneration, token = UUID()
        catalogTokens[client.id] = token
        catalogTasks[client.id] = Task { [weak self, weak client] in
            guard let self, let client else { return }
            defer {
                if generation == self.accountGeneration, self.catalogTokens[client.id] == token {
                    self.catalogTokens.removeValue(forKey: client.id)
                    self.catalogTasks.removeValue(forKey: client.id)
                    if self.catalogPending.remove(client.id) != nil, let current = self.clients[client.id] {
                        self.scheduleCatalogSync(to: current)
                    }
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard self.foreground, generation == self.accountGeneration,
                      self.clients[client.id] === client, client.isConnected,
                      let snapshot = self.content.snapshot, let checkedAt = self.content.lastCheckedAt else { return }
                let catalog = try DesktopMusicCatalog(snapshot: snapshot,
                    serviceAddress: self.content.serviceAddress, checkedAt: checkedAt)
                let status = try await client.syncMusicCatalog(catalog)
                guard generation == self.accountGeneration, self.catalogTokens[client.id] == token,
                      self.clients[client.id] === client, !Task.isCancelled else { return }
                self.catalogSyncedAt[client.id] = status?.syncedAt
                self.catalogErrors.removeValue(forKey: client.id)
            } catch is CancellationError { }
            catch {
                guard generation == self.accountGeneration, self.catalogTokens[client.id] == token,
                      self.clients[client.id] === client, !Task.isCancelled else { return }
                self.catalogErrors[client.id] = error.localizedDescription
            }
        }
    }

    var authorizedReportMacs: [PhoneReportMac] {
        reportMacNames.compactMap { key, name in
            guard let host = UUID(uuidString: key), reportAuthorization.isEnabled(for: host) else { return nil }
            return PhoneReportMac(id: host, name: name,
                connectedDeviceID: devices.first(where: { $0.hostID == host })?.id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func automaticReportEnabled(for hostID: UUID) -> Bool {
        reportAuthorization.isEnabled(for: hostID)
    }

    func setAutomaticReport(_ enabled: Bool, hostID: UUID) {
        if enabled {
            guard foreground, trust.credential != nil, let scope = trust.accountScope else { return }
            reportAuthorization.confirmAccount(scope)
        }
        reportAuthorization.setEnabled(enabled, for: hostID)
        saveReportAuthorization()
        // Invalidate pending work before any asynchronous status notification.
        reportEpoch = UUID(); reportTask?.cancel(); reportTask = nil
        for client in clients.values where client.hostID == hostID {
            lastReportContent.removeValue(forKey: client.id)
            reportStates[client.id] = enabled ? .enabled : .disabled
            reportErrors.removeValue(forKey: client.id)
            if !enabled { Task { await self.announceReportState(.disabled, to: client) } }
        }
        scheduleReportSync(refreshData: enabled)
    }

    func reportDataChanged() { scheduleReportSync() }

    private func saveReportAuthorization() {
        if let data = try? JSONEncoder().encode(reportAuthorization) {
            UserDefaults.standard.set(data, forKey: Self.reportAuthorizationKey)
        }
        UserDefaults.standard.set(reportMacNames, forKey: Self.reportNamesKey)
    }

    private func scheduleReportSync(refreshData: Bool = false) {
        guard foreground, trust.credential != nil, !health.isDemo else { return }
        needsReportRefresh = needsReportRefresh || refreshData
        if isSyncing { reportCheckPending = true; return }
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self else { return }
            let targets = self.clients.values.filter { client in
                guard let host = client.hostID, client.supportsAutoReport else { return false }
                return self.reportAuthorization.maySend(to: host, foreground: self.foreground,
                    connected: client.isConnected, isDemo: self.health.isDemo)
            }
            // Let a connected Mac display consent state even before the first report.
            for client in self.clients.values where client.isConnected && client.supportsAutoReport {
                guard let host = client.hostID, !self.reportAuthorization.isEnabled(for: host) else { continue }
                await self.announceReportState(.disabled, to: client)
            }
            guard !Task.isCancelled else { return }
            let refresh = self.needsReportRefresh; self.needsReportRefresh = false
            await self.performReportSync(targets: targets, automatic: true, refreshData: refresh)
        }
    }

    func syncReport(to id: String? = nil) async {
        reportFeedback = nil
        let targetID = id ?? selectedReportDeviceID
        let available = clients.values.filter(\.isConnected)
        let targets: [PhoneMacPeer]
        if let targetID, let client = clients[targetID], client.isConnected { targets = [client] }
        else if targetID == nil, available.count == 1 { targets = available }
        else { reportFeedback = "请先选择接收报表的 Mac。"; return }
        await performReportSync(targets: targets, automatic: false, refreshData: true)
    }

    private func announceReportState(_ state: DesktopReportSyncState, to client: PhoneMacPeer) async {
        guard foreground, UIApplication.shared.applicationState == .active,
              client.isConnected, client.supportsAutoReport else { return }
        _ = try? await client.request(.init(action: .reportSyncStatus, reportSyncState: state), closeOnCancel: false, closeOnTimeout: false)
    }

    private func performReportSync(targets: [PhoneMacPeer], automatic: Bool, refreshData: Bool) async {
        guard !isSyncing, !targets.isEmpty, foreground,
              UIApplication.shared.applicationState == .active, !health.isDemo,
              trust.credential != nil else { return }
        let generation = accountGeneration, epoch = reportEpoch
        isSyncing = true
        defer {
            isSyncing = false
            if reportCheckPending { reportCheckPending = false; scheduleReportSync() }
        }
        if refreshData {
            await health.refresh()
            await sleepHealth.refresh()
        }
        guard epoch == reportEpoch, generation == accountGeneration, !Task.isCancelled else { return }
        let report = DesktopReport.build(readings: health.readings, moods: store.records,
            practices: companion.practices, sleepSamples: sleepHealth.samples)
        guard let identity = try? report.contentIdentity() else { return }
        for client in targets {
            guard foreground, UIApplication.shared.applicationState == .active,
                  epoch == reportEpoch, generation == accountGeneration, !Task.isCancelled,
                  clients[client.id] === client, client.isConnected else { return }
            if automatic {
                guard let host = client.hostID, client.supportsAutoReport,
                      reportAuthorization.maySend(to: host, foreground: foreground,
                        connected: client.isConnected, isDemo: health.isDemo) else { continue }
                if lastReportContent[client.id] == identity { continue }
            }
            reportStates[client.id] = .syncing; reportErrors.removeValue(forKey: client.id)
            await announceReportState(.syncing, to: client)
            guard epoch == reportEpoch, generation == accountGeneration, foreground,
                  UIApplication.shared.applicationState == .active, !Task.isCancelled else { return }
            do {
                let response = try await client.request(.init(action: .reportUpload, report: report), closeOnCancel: false, closeOnTimeout: false)
                guard response.success else { throw PhoneMacError.message(response.error ?? "Mac 未保存汇总。") }
                guard epoch == reportEpoch, generation == accountGeneration, !Task.isCancelled else { return }
                lastReportContent[client.id] = identity
                reportSyncedAt[client.id] = .now
                let enabled = client.hostID.map { reportAuthorization.isEnabled(for: $0) } ?? false
                reportStates[client.id] = enabled ? .enabled : .disabled
                await announceReportState(enabled ? .enabled : .disabled, to: client)
                if !automatic { reportFeedback = "报表已保存到 \(client.name)。" }
            } catch is CancellationError { return }
            catch {
                guard epoch == reportEpoch, generation == accountGeneration else { return }
                reportStates[client.id] = .failed; reportErrors[client.id] = error.localizedDescription
                await announceReportState(.failed, to: client)
                if !automatic { reportFeedback = error.localizedDescription }
            }
        }
    }

}
