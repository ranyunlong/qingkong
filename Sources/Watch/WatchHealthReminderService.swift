import Foundation
import Observation
import UserNotifications
import WatchKit
import QingkongCore

/// Watch is the sole evaluator after a persisted ownership handoff from iPhone.
/// Connection probing has no side effects; each decision then keeps one dispatch route.
@MainActor @Observable
final class WatchHealthReminderService: NSObject, UNUserNotificationCenterDelegate {
    private struct SavedState: Codable {
        let watchID: UUID
        var configuration: ReminderRelayConfiguration?
        var pending: [PendingReminderDispatch] = []
        var report: WatchReminderReport?
    }
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var error: String?
    var destination: ReminderSignalKind?
    @ObservationIgnored var requestOwnership: ((WatchReminderReady) -> Void)?
    @ObservationIgnored var probePhone: ((UUID) async -> ReminderProbeResult)?
    @ObservationIgnored var delegateToPhone: ((ReminderSignal) -> Void)?
    @ObservationIgnored var publishReport: ((WatchReminderReport) -> Void)?
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let disabled: Bool
    private var saved: SavedState
    @ObservationIgnored private var dispatching = false
    @ObservationIgnored private var requestingPermission = false
    @ObservationIgnored private var healthConnected = false
    private static let key = "qingkong.watch-health-reminders.v1"

    var statusText: String {
        guard healthConnected else { return "先连接 Apple 健康" }
        guard authorized else { return "需要允许手表通知，才能接手健康检测" }
        guard let config = saved.configuration else { return "等待 iPhone 同步提醒设置" }
        return config.watchOwnerID == saved.watchID ? "手表检测已开启" : "等待 iPhone 确认交接"
    }
    var lastCheckedAt: Date? { saved.report?.checkedAt }
    var authorized: Bool { [.authorized, .provisional].contains(authorization) }

    init(disabled: Bool = false, defaults: UserDefaults = .standard) {
        self.disabled = disabled; self.defaults = defaults
        if !disabled, let data = defaults.data(forKey: Self.key), let state = try? JSONDecoder().decode(SavedState.self, from: data) {
            saved = state
        } else { saved = .init(watchID: UUID()) }
        super.init()
        guard !disabled else { return }
        center.delegate = self
        persist()
    }

    @discardableResult
    func receive(_ incoming: ReminderRelayConfiguration) -> Bool {
        guard !disabled, incoming.version == 1 else { return false }
        if let current = saved.configuration {
            guard incoming.id != current.id, incoming.updatedAt > current.updatedAt else { return false }
        }
        var incoming = incoming
        if let current = saved.configuration, current.watchOwnerID == saved.watchID {
            incoming.mergeProgress(from: current)
        }
        saved.configuration = incoming
        // A settings revision invalidates queued decisions rather than replaying an old threshold.
        saved.pending.removeAll { $0.signal.configurationID != incoming.id }
        persist()
        requestOwnershipIfReady()
        return true
    }

    func activate(healthConnected: Bool) async {
        self.healthConnected = healthConnected
        guard !disabled else { return }
        await refreshAuthorization()
        if healthConnected, authorization == .notDetermined, !requestingPermission,
           WKApplication.shared().applicationState == .active {
            requestingPermission = true
            do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
            catch { self.error = "手表通知授权未完成，请稍后重试。" }
            requestingPermission = false
            await refreshAuthorization()
        }
        requestOwnershipIfReady()
        if let report = saved.report { publishReport?(report) }
        await dispatchPending()
    }

    func evaluate(readings: [HealthReading], healthConnected: Bool, isDemo: Bool) async {
        self.healthConnected = healthConnected
        guard !disabled, !isDemo else { return }
        await refreshAuthorization()
        requestOwnershipIfReady()
        guard authorized, var config = saved.configuration, config.watchOwnerID == saved.watchID else { return }
        let report = config.assess(readings: readings)
        saved.configuration = config
        saved.report = report
        for signal in report.signals where !saved.pending.contains(where: { $0.id == signal.id }) {
            saved.pending.append(.init(signal: signal))
        }
        persist()
        publishReport?(report)
        await dispatchPending()
    }

    private func requestOwnershipIfReady() {
        guard healthConnected, authorized, let config = saved.configuration,
              config.watchOwnerID == nil else { return }
        requestOwnership?(.init(watchID: saved.watchID, configurationID: config.id))
    }

    private func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    private func dispatchPending() async {
        guard !disabled, !dispatching else { return }
        dispatching = true
        defer { dispatching = false }
        while let pending = saved.pending.first {
            let signal = pending.signal
            guard let config = saved.configuration, config.watchOwnerID == saved.watchID,
                  config.id == signal.configurationID,
                  signal.sampleDate <= .now,
                  Date.now.timeIntervalSince(signal.sampleDate) <= signal.kind.maximumAge,
                  authorized,
                  saved.report?.newestSamples[signal.kind.metric].map({ $0 <= signal.sampleDate }) ?? true else {
                saved.pending.removeFirst(); persist(); continue
            }
            var route = pending.route
            if route == .undecided {
                let result = await probePhone?(config.id) ?? .unavailable
                // Settings may have changed during the probe. Never dispatch an invalidated decision.
                guard saved.pending.first?.id == signal.id, saved.configuration?.id == config.id else { continue }
                guard Date.now.timeIntervalSince(signal.sampleDate) <= signal.kind.maximumAge,
                      saved.report?.newestSamples[signal.kind.metric].map({ $0 <= signal.sampleDate }) ?? true else {
                    saved.pending.removeFirst(); persist(); continue
                }
                var assigned = pending
                guard assigned.assignRoute(after: result) else {
                    saved.pending.removeFirst(); persist()
                    updateReport(signal, result: "iPhone 未接受当前提醒设置或通知权限，未补发旧提醒")
                    continue
                }
                route = assigned.route
                saved.pending[0] = assigned
                persist()
            }
            if route == .phone {
                // Durable phone queue, no timeout-based Watch fallback for this decision.
                delegateToPhone?(signal)
                saved.pending.removeFirst()
                persist()
                updateReport(signal, result: "已交给 iPhone 通知，显示设备由系统决定")
            } else {
                // Consume before submitting. A crash must not alert twice on relaunch.
                saved.pending.removeFirst()
                persist()
                do {
                    try await center.add(UNNotificationRequest(identifier: "qingkong.watch." + signal.id, content: notification(for: signal), trigger: nil))
                    if saved.configuration?.id != signal.configurationID {
                        center.removeDeliveredNotifications(withIdentifiers: ["qingkong.watch." + signal.id])
                        center.removePendingNotificationRequests(withIdentifiers: ["qingkong.watch." + signal.id])
                    } else { updateReport(signal, result: "手表本地提醒已交给系统"); error = nil }
                } catch {
                    self.error = "本次手表提醒未能提交，等待新记录后再判断。"
                    updateReport(signal, result: self.error!)
                }
            }
        }
    }

    private func notification(for signal: ReminderSignal) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if let kind = signal.kind.vitalKind {
            content.title = kind.title
            content.body = kind == .lowOxygen
                ? "近期有重复偏低的血氧读数。请静坐、确认佩戴后复测；若持续偏低或感觉不适，请及时寻求医疗帮助。"
                : "近期有重复的静息心率变化记录。可以先休息片刻并复测；若持续异常或感觉不适，请及时寻求医疗帮助。"
        } else {
            content.title = "给自己一点放松时间"
            content.body = "最近的 HRV 较个人参考水平有明显变化。可以休息片刻，按舒服的节奏呼吸，或听一段自然声音。这不代表你一定有心理压力。"
        }
        content.sound = .default
        content.interruptionLevel = .active
        content.threadIdentifier = "qingkong.watch." + signal.kind.rawValue
        content.userInfo = ["kind": signal.kind.rawValue]
        return content
    }

    private func updateReport(_ signal: ReminderSignal, result: String) {
        guard let previous = saved.report, previous.configurationID == signal.configurationID else { return }
        var results = previous.results
        results[signal.kind.rawValue] = result
        let report = WatchReminderReport(configurationID: previous.configurationID, checkedAt: previous.checkedAt, results: results, signals: [], newestSamples: previous.newestSamples)
        saved.report = report
        persist()
        publishReport?(report)
    }

    private func persist() {
        guard !disabled, let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.key)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let kind = (notification.request.content.userInfo["kind"] as? String).flatMap(ReminderSignalKind.init(rawValue:))
        Task { @MainActor [weak self] in
            guard let self, let config = self.saved.configuration, config.watchOwnerID == self.saved.watchID, let kind else { completionHandler([]); return }
            let state = kind.vitalKind.flatMap { config.vitalRules[$0]?.delivery } ?? config.hrv
            completionHandler(state.enabled && (state.mutedUntil.map { $0 <= .now } ?? true) ? [.banner, .list, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = (response.notification.request.content.userInfo["kind"] as? String).flatMap(ReminderSignalKind.init(rawValue:))
        Task { @MainActor [weak self] in self?.destination = kind; completionHandler() }
    }
}
