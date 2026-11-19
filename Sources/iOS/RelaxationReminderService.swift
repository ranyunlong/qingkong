import Foundation
import Observation
import UserNotifications
import UIKit
import QingkongCore

// Notifications originate on iPhone; the system handles Watch mirroring.
enum ReminderDestination: String, Identifiable { case advice, sounds; var id: String { rawValue } }

@MainActor @Observable
final class RelaxationReminderService: NSObject, UNUserNotificationCenterDelegate {
    private(set) var state: RelaxationReminderState
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var error: String?
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

    var enabled: Bool { state.enabled }
    var pausedToday: Bool { state.mutedUntil.map { $0 > .now } ?? false }
    var authorized: Bool { [.authorized, .provisional, .ephemeral].contains(authorization) }
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
        super.init()
        guard !disabledForTesting else { return }
        persist()
        center.delegate = self
        let advice = UNNotificationAction(identifier: "advice", title: "放松一下", options: .foreground)
        let sounds = UNNotificationAction(identifier: "sounds", title: "听听自然", options: .foreground)
        let mute = UNNotificationAction(identifier: "mute-today", title: "今天不再提醒")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [advice, sounds, mute], intentIdentifiers: [])])
    }

    // Only called from a foreground UI action, never from a HealthKit observer.
    func requestPermissionIfNeeded() async {
        guard !disabledForTesting, !requestingAuthorization, UIApplication.shared.applicationState == .active else { return }
        requestingAuthorization = true
        defer { requestingAuthorization = false }
        await refreshAuthorization()
        guard state.enabled, authorization == .notDetermined else { return }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { self.error = "未能完成通知授权，请稍后在系统设置中检查。" }
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        guard !disabledForTesting else { return }
        authorization = await center.notificationSettings().authorizationStatus
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

    func evaluate(readings: [HealthReading], isDemo: Bool) async {
        guard !disabledForTesting, !isDemo, !evaluating else { return }
        evaluating = true
        defer { evaluating = false }
        let revision = generation
        await refreshAuthorization()
        let now = Date.now
        let candidate = RelaxationReminderPolicy.candidate(readings: readings, state: state, now: now)
        // A suppressed or unsuccessful notification is not queued for later replay.
        if let newest = readings.filter({ $0.metric == .hrv && $0.isValid && $0.wasUserEntered != true && $0.date <= now }).map(\.date).max() {
            state.consume(through: newest)
        }
        persist()
        guard revision == generation, authorized, state.enabled, let candidate else { return }
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
            persist()
            error = nil
        } catch { self.error = "这次提醒未能交给系统，将等待新的健康记录后再判断。" }
    }

    private func persist() {
        guard !disabledForTesting, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func clearReminders() async {
        guard !disabledForTesting else { return }
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(Self.prefix) }.map(\.identifier)
        let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix(Self.prefix) }.map { $0.request.identifier }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor [weak self] in
            guard let self, self.enabled, !self.pausedToday else { completionHandler([]); return }
            completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, category == Self.category else { return }
            switch action {
            case "mute-today": await self.pauseToday()
            case "sounds": self.destination = .sounds
            case "advice", UNNotificationDefaultActionIdentifier: self.destination = .advice
            default: break
            }
        }
    }
}
