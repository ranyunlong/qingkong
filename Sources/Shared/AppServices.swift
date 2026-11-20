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
            #if os(iOS)
            await self.reminders.evaluate(readings: self.health.readings, isDemo: self.health.isDemo)
            #endif
        }
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
        #endif
        #if os(iOS)
        await reminders.refreshAuthorization()
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
