import Foundation
import Observation
import QingkongCore
import WidgetKit

@MainActor @Observable
final class AppServices {
    let store: LocalStore
    let health: HealthService
    let player: AudioPlayer
    let link: Connectivity
    #if os(watchOS)
    let watchReminders: WatchHealthReminderService
    #endif
    #if os(iOS)
    let reminders: RelaxationReminderService
    var healthIntroductionActive = false
    var needsHealthIntroduction: Bool {
        (!testing || ProcessInfo.processInfo.arguments.contains("--ui-health-introduction")) && !health.isDemo && health.needsConnectionIntroduction
    }
    #endif
    var snapshotError: String?
    private(set) var today = Date.now
    @ObservationIgnored private let testing: Bool

    var scene: SceneTheme { store.preferences.scene(entries: store.records, now: today) }

    init() throws {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        testing = args.contains("--ui-testing")
        #else
        testing = false
        #endif
        store = try LocalStore(testing: testing, reset: args.contains("--ui-reset"))
        health = HealthService(testing: testing, demo: args.contains("--demo-health"))
        #if os(watchOS)
        watchReminders = WatchHealthReminderService(disabled: testing || health.isDemo)
        #endif
        #if os(iOS)
        reminders = RelaxationReminderService(disabledForTesting: testing || health.isDemo)
        #endif
        player = AudioPlayer()
        link = Connectivity(store: store, player: player)
        store.didChange = { [weak self] in self?.link.flush() }
        store.didChangeRecords = { [weak self] in self?.writeSnapshot() }
        store.didChangePreferences = { [weak self] in self?.link.flush(); self?.writeSnapshot() }
        health.didRefresh = { [weak self] in
            guard let self else { return }
            self.writeSnapshot()
        }
        health.didUpdateForReminders = { [weak self] readings in
            guard let self else { return }
            #if os(iOS)
            await self.reminders.evaluate(readings: readings, isDemo: self.health.isDemo)
            #else
            await self.watchReminders.evaluate(readings: readings, healthConnected: self.health.requested, isDemo: self.health.isDemo)
            #endif
        }
        #if os(iOS)
        reminders.configurationDidChange = { [weak self] configuration in self?.link.publishReminderConfiguration(configuration) }
        link.reminderReadyReceived = { [weak self] ready in self?.reminders.acceptWatchMonitoring(ready) }
        link.reminderSignalReceived = { [weak self] signal in self?.reminders.receiveWatchSignal(signal) }
        link.watchReminderReportReceived = { [weak self] report in self?.reminders.receiveWatchReport(report) }
        link.reminderProbe = { [weak self] id in await self?.reminders.canDispatchWatchReminder(configurationID: id) ?? false }
        if !testing && !health.isDemo { link.publishReminderConfiguration(reminders.relayConfiguration) }
        #else
        watchReminders.requestOwnership = { [weak self] ready in self?.link.requestWatchMonitoring(ready) }
        watchReminders.probePhone = { [weak self] id in await self?.link.confirmPhoneForReminder(configurationID: id) ?? .unavailable }
        watchReminders.delegateToPhone = { [weak self] signal in self?.link.enqueueReminderSignal(signal) }
        watchReminders.publishReport = { [weak self] report in self?.link.publishWatchReminderReport(report) }
        link.reminderConfigurationReceived = { [weak self] configuration in
            guard let self else { return }
            if self.watchReminders.receive(configuration) {
                Task { await self.health.refreshReminderReadings() }
            }
        }
        #endif
        link.preferencesReceived = { [weak self] in self?.writeSnapshot() }
        // Activate at process launch so background transfers do not depend on a visible screen.
        if !testing { link.start() }
    }

    func start() async {
        await activate()
    }

    func activate() async {
        today = .now
        #if os(watchOS)
        refreshComplications()
        await watchReminders.activate(healthConnected: health.requested)
        #endif
        #if os(iOS)
        await reminders.refreshAuthorization()
        await reminders.resumePendingDispatches()
        if !needsHealthIntroduction && !healthIntroductionActive { await reminders.requestPermissionIfNeeded() }
        #endif
        player.reconcileDeadline()
        if !testing { link.flush() }
        await health.restoreBackgroundDelivery()
        await health.refresh()
        writeSnapshot()
    }

    func updateClock() { today = .now; player.reconcileDeadline() }

    #if os(watchOS)
    func refreshComplications() {
        guard !testing else { return }
        WidgetCenter.shared.invalidateConfigurationRecommendations()
        writeSnapshot()
    }
    #endif

    private func writeSnapshot() {
        guard !health.isDemo else { return }
        let latest = HealthMetric.allCases.compactMap { health.latest($0) }
        let trends = Dictionary(uniqueKeysWithValues: HealthMetric.allCases.map { metric in
            (metric, HealthMath.buckets(health.readings, metric: metric, period: .week))
        })
        do {
            try SnapshotStorage.save(ComplicationSnapshot(readings: latest, trends: trends, preferences: store.preferences, mood: MoodSummary.latest(in: store.records)))
            WidgetCenter.shared.reloadAllTimelines()
            snapshotError = nil
        } catch { snapshotError = "表盘数据暂未保存，请重新打开应用后重试。" }
    }
}
