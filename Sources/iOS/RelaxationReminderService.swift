import Foundation
import Observation
import UserNotifications
import UIKit
import QingkongCore

// Notifications originate on iPhone; the system handles Watch mirroring.
enum ReminderDestination: String, Identifiable { case advice, sounds, heartRate, oxygen; var id: String { rawValue } }

@MainActor @Observable
final class RelaxationReminderService: NSObject, UNUserNotificationCenterDelegate {
    private(set) var state: RelaxationReminderState
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var error: String?
    private(set) var vitalRules: [VitalReminderKind: VitalReminderRule]
    private(set) var lastCheckedAt: Date?
    private(set) var checkResults: [String: String] = [:]
    private(set) var deliveryText = "尚未检查系统通知设置"
    private(set) var testStatus: String?
    var destination: ReminderDestination?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let disabledForTesting: Bool
    @ObservationIgnored private var evaluating = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var requestingAuthorization = false
    private static let key = "qingkong.relaxation-reminders.v1"
    private static let category = "qingkong.relaxation"
    private static let prefix = "qingkong.relaxation."
    private static let vitalKey = "qingkong.vital-reminders.v1"
    private static let vitalCategory = "qingkong.vital"
    private static let vitalPrefix = "qingkong.vital."
    private static let testCategory = "qingkong.notification-test"

    var enabled: Bool { state.enabled }
    var pausedToday: Bool { state.mutedUntil.map { $0 > .now } ?? false }
    var authorized: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }
    var anyEnabled: Bool { state.enabled || vitalRules.values.contains { $0.delivery.enabled } }
    var permissionText: String {
        switch authorization {
        case .authorized, .ephemeral: "系统通知已允许"
        case .provisional: "系统通知以安静方式送达"
        case .denied: "系统通知未允许"
        case .notDetermined: "需要允许系统通知"
        @unknown default: "请在系统设置中检查通知"
        }
    }

    init(disabledForTesting: Bool = false) {
        self.disabledForTesting = disabledForTesting
        defaults = disabledForTesting ? UserDefaults(suiteName: "qingkong.reminders.testing")! : .standard
        if !disabledForTesting, let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(RelaxationReminderState.self, from: data) {
            state = saved
        } else { state = RelaxationReminderState() }
        if !disabledForTesting, let data = defaults.data(forKey: Self.vitalKey),
           let saved = try? JSONDecoder().decode([VitalReminderKind: VitalReminderRule].self, from: data) {
            vitalRules = saved
        } else { vitalRules = [:] }
        super.init()
        for kind in VitalReminderKind.allCases where vitalRules[kind] == nil { vitalRules[kind] = .init(kind: kind) }
        guard !disabledForTesting else { return }
        persist()
        center.delegate = self
        let advice = UNNotificationAction(identifier: "advice", title: "放松一下", options: .foreground)
        let sounds = UNNotificationAction(identifier: "sounds", title: "听听自然", options: .foreground)
        let mute = UNNotificationAction(identifier: "mute-today", title: "今天不再提醒")
        let viewHealth = UNNotificationAction(identifier: "view-health", title: "查看趋势", options: .foreground)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [advice, sounds, mute], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.vitalCategory, actions: [viewHealth, mute], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.testCategory, actions: [], intentIdentifiers: [])
        ])
    }

    // Only called from a foreground UI action, never from a HealthKit observer.
    func requestPermissionIfNeeded(forTest: Bool = false) async {
        guard !disabledForTesting, !requestingAuthorization, UIApplication.shared.applicationState == .active else { return }
        requestingAuthorization = true
        defer { requestingAuthorization = false }
        await refreshAuthorization()
        guard (anyEnabled || forTest), authorization == .notDetermined else { return }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { self.error = "未能完成通知授权，请稍后在系统设置中检查。" }
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        guard !disabledForTesting else { return }
        let settings = await center.notificationSettings()
        authorization = settings.authorizationStatus
        deliveryText = settings.alertSetting == .enabled ? "系统允许显示提醒；声音和展示仍遵循专注设置" : "系统未开启提醒展示，请检查横幅、通知中心及声音设置"
    }

    func setEnabled(_ enabled: Bool) async {
        generation += 1
        state.setEnabled(enabled)
        persist()
        if enabled { await requestPermissionIfNeeded() }
        else { await clearReminders() }
    }

    func pauseToday() async {
        generation += 1
        state.mutedUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
        state.consume(through: .now)
        persist()
        await clearReminders()
    }

    func resumeToday() {
        generation += 1
        state.mutedUntil = nil
        state.consume(through: .now)
        persist()
    }

    func setVitalEnabled(_ kind: VitalReminderKind, _ enabled: Bool) async {
        generation += 1
        vitalRules[kind]?.delivery.setEnabled(enabled)
        persist()
        if enabled { await requestPermissionIfNeeded() }
        else { await clearNotifications(prefix: Self.vitalPrefix + kind.rawValue + ".") }
    }

    func setVitalThreshold(_ kind: VitalReminderKind, _ threshold: Double) {
        guard threshold.isFinite, kind.thresholdRange.contains(threshold), vitalRules[kind]?.threshold != threshold else { return }
        generation += 1
        vitalRules[kind]?.threshold = threshold
        vitalRules[kind]?.delivery.resetWindow()
        persist()
    }

    func resumeVitalToday(_ kind: VitalReminderKind) {
        generation += 1
        vitalRules[kind]?.delivery.mutedUntil = nil
        vitalRules[kind]?.delivery.consume(through: .now)
        persist()
    }

    func sendTestNotification() async {
        guard !disabledForTesting else { return }
        await requestPermissionIfNeeded(forTest: true)
        await refreshAuthorization()
        guard authorized else { testStatus = "请先在系统设置中允许通知。"; return }
        let content = UNMutableNotificationContent()
        content.title = "晴空通知测试"
        content.body = "通知功能已连接。这是一条送达测试，不代表检测到健康数据异常。"
        content.sound = .default
        content.categoryIdentifier = Self.testCategory
        do {
            try await center.add(UNNotificationRequest(identifier: "qingkong.test." + UUID().uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
            testStatus = "已交给系统，将在 3 秒后发送测试通知。"
        } catch { testStatus = "测试通知未能交给系统，请稍后重试。" }
    }

    func evaluate(readings: [HealthReading], isDemo: Bool) async {
        guard !disabledForTesting, !isDemo, !evaluating else { return }
        evaluating = true
        defer { evaluating = false }
        let revision = generation
        await refreshAuthorization()
        guard revision == generation else { return }
        let now = Date.now
        let assessment = RelaxationReminderPolicy.assess(readings: readings, state: state, now: now)
        lastCheckedAt = now
        checkResults["hrv"] = assessment.reason
        var vitalCandidates: [VitalReminderCandidate] = []
        for kind in VitalReminderKind.allCases {
            guard let rule = vitalRules[kind] else { continue }
            let result = VitalReminderPolicy.assess(kind: kind, readings: readings, rule: rule, now: now)
            checkResults[kind.rawValue] = result.reason
            if let candidate = result.candidate { vitalCandidates.append(candidate) }
            if let newest = readings.filter({ $0.metric == kind.metric && $0.isValid && $0.wasUserEntered != true && $0.date <= now }).map(\.date).max() {
                vitalRules[kind]?.delivery.consume(through: newest)
            }
        }
        // A suppressed or unsuccessful notification is not queued for later replay.
        if let newest = readings.filter({ $0.metric == .hrv && $0.isValid && $0.wasUserEntered != true && $0.date <= now }).map(\.date).max() {
            state.consume(through: newest)
        }
        persist()
        guard revision == generation, authorized else { return }
        if state.enabled, let candidate = assessment.candidate {
            let content = UNMutableNotificationContent()
            content.title = "给自己一点放松时间"
            content.body = "最近的 HRV 较个人参考水平有明显变化。可以先休息片刻，按舒服的节奏呼吸，或听一段自然声音。这不代表你一定有心理压力。"
            content.sound = .default
            content.interruptionLevel = .active
            content.categoryIdentifier = Self.category
            content.threadIdentifier = Self.category
            let id = Self.prefix + candidate.sampleID.uuidString
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                // The user may have disabled reminders while the system was accepting it.
                guard revision == generation, state.enabled else {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    center.removeDeliveredNotifications(withIdentifiers: [id])
                    return
                }
                state.recordDelivery(candidate, now: now)
                checkResults["hrv"] = "本次 HRV 提醒已交给系统"
                persist()
                error = nil
            } catch { self.error = "这次提醒未能交给系统，将等待新的健康记录后再判断。" }
        }
        for candidate in vitalCandidates {
            guard revision == generation, vitalRules[candidate.kind]?.delivery.enabled == true else { return }
            let kind = candidate.kind
            let content = UNMutableNotificationContent()
            content.title = kind.title
            content.body = kind == .lowOxygen
                ? "近期有重复偏低的血氧读数。请静坐、确认佩戴后复测；若持续偏低或感觉不适，请及时寻求医疗帮助。"
                : "近期有重复的静息心率变化记录。可以先休息片刻并复测；若持续异常或感觉不适，请及时寻求医疗帮助。"
            content.sound = .default
            content.interruptionLevel = .active
            content.categoryIdentifier = Self.vitalCategory
            content.threadIdentifier = Self.vitalPrefix + kind.rawValue
            content.userInfo = ["kind": kind.rawValue]
            let id = Self.vitalPrefix + kind.rawValue + "." + candidate.sampleID.uuidString
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                guard revision == generation, vitalRules[kind]?.delivery.enabled == true else {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    center.removeDeliveredNotifications(withIdentifiers: [id])
                    return
                }
                vitalRules[kind]?.recordDelivery(candidate, now: now)
                checkResults[kind.rawValue] = "本次提醒已交给系统"
                persist()
            } catch { self.error = "这次健康提醒未能交给系统，将等待新的记录后再判断。" }
        }
    }

    private func persist() {
        guard !disabledForTesting, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
        if let vitalData = try? JSONEncoder().encode(vitalRules) { defaults.set(vitalData, forKey: Self.vitalKey) }
    }

    private func clearReminders() async {
        await clearNotifications(prefix: Self.prefix)
    }

    private func clearNotifications(prefix: String) async {
        guard !disabledForTesting else { return }
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
        let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix(prefix) }.map { $0.request.identifier }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let category = notification.request.content.categoryIdentifier
        let kind = (notification.request.content.userInfo["kind"] as? String).flatMap(VitalReminderKind.init(rawValue:))
        Task { @MainActor [weak self] in
            guard let self else { completionHandler([]); return }
            if category == Self.vitalCategory {
                guard let kind, let rule = self.vitalRules[kind], rule.delivery.enabled,
                      rule.delivery.mutedUntil.map({ $0 <= .now }) ?? true else { completionHandler([]); return }
            } else if category != Self.testCategory {
                guard self.enabled, !self.pausedToday else { completionHandler([]); return }
            }
            completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let kind = (response.notification.request.content.userInfo["kind"] as? String).flatMap(VitalReminderKind.init(rawValue:))
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self else { return }
            if category == Self.vitalCategory, let kind {
                if action == "mute-today" {
                    self.generation += 1
                    self.vitalRules[kind]?.delivery.mutedUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
                    self.persist()
                    await self.clearNotifications(prefix: Self.vitalPrefix + kind.rawValue + ".")
                } else if action == "view-health" || action == UNNotificationDefaultActionIdentifier {
                    self.destination = kind == .lowOxygen ? .oxygen : .heartRate
                }
                return
            }
            guard category == Self.category else { return }
            switch action {
            case "mute-today": await self.pauseToday()
            case "sounds": self.destination = .sounds
            case "advice", UNNotificationDefaultActionIdentifier: self.destination = .advice
            default: break
            }
        }
    }
}
