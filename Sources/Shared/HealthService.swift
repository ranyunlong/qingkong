import Foundation
import HealthKit
import Observation
import QingkongCore

struct ECGRecord: Identifiable {
    let sample: HKElectrocardiogram
    var id: UUID { sample.uuid }
    var date: Date { sample.startDate }
    var source: String { sample.sourceRevision.source.name }
    var classification: String {
        switch sample.classification {
        case .sinusRhythm: "窦性心律"
        case .atrialFibrillation: "房颤"
        case .inconclusiveLowHeartRate: "心率偏低，未能分类"
        case .inconclusiveHighHeartRate: "心率偏高，未能分类"
        case .inconclusivePoorReading: "记录质量不足"
        case .inconclusiveOther: "未能分类"
        default: "暂无系统分类"
        }
    }
}

struct VoltagePoint: Identifiable {
    let seconds: Double
    let millivolts: Double
    var id: Double { seconds }
}

@MainActor @Observable
final class HealthService {
    private(set) var readings: [HealthReading] = []
    private(set) var ecgs: [ECGRecord] = []
    private(set) var loading = false
    private(set) var requested: Bool
    private(set) var error: String?
    private(set) var isDemo = false
    private(set) var backgroundDeliveryWarning: String?
    private(set) var lastObserverUpdateAt: Date?
    private(set) var observerWarning: String?
    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    @ObservationIgnored var didRefresh: (() async -> Void)?
    @ObservationIgnored var didUpdateForReminders: (([HealthReading]) async -> Void)?
    @ObservationIgnored private var reminderRefreshRequested = false
    @ObservationIgnored private var reminderTask: Task<Void, Never>?
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var observers: [HKObserverQuery] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let testing: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var registeringBackgroundDelivery = false

    init(testing: Bool = false, demo: Bool = false) {
        self.testing = testing
        defaults = testing ? UserDefaults(suiteName: "qingkong.health.testing")! : .standard
        if testing && ProcessInfo.processInfo.arguments.contains("--ui-reset") {
            defaults.removeObject(forKey: "health.authorizationRequested")
            defaults.removeObject(forKey: "health.connectionIntroductionShown")
        }
        requested = defaults.bool(forKey: "health.authorizationRequested")
        lastObserverUpdateAt = defaults.object(forKey: "health.lastObserverUpdateAt") as? Date
        observerWarning = defaults.string(forKey: "health.observerWarning")
        backgroundDeliveryWarning = defaults.string(forKey: "health.backgroundDeliveryWarning")
        #if DEBUG
        isDemo = demo
        #endif
        if available && requested && !testing && !isDemo {
            installObservers()
            Task { await restoreBackgroundDelivery() }
        }
    }

    func latest(_ metric: HealthMetric) -> HealthReading? {
        readings.filter { $0.metric == metric && $0.isValid && $0.date <= .now }.max { $0.date < $1.date }
    }
    var dailyHRV: Double? { HealthMath.dailyMean(readings, metric: .hrv, day: .now) }
    var baseline: Double? { HealthMath.hrvBaseline(readings) }
    var needsConnectionIntroduction: Bool {
        available && !requested && !defaults.bool(forKey: "health.connectionIntroductionShown")
    }
    func completeConnectionIntroduction() { defaults.set(true, forKey: "health.connectionIntroductionShown") }

    func authorize() async {
        guard available && !testing && !isDemo else { return }
        error = nil
        let types: Set<HKObjectType> = Set(HealthMetric.allCases.map { quantityType($0) } + [HKObjectType.electrocardiogramType()])
        do {
            try await store.requestAuthorization(toShare: [], read: types)
            requested = true
            defaults.set(true, forKey: "health.authorizationRequested")
            installObservers()
            await restoreBackgroundDelivery()
            await refresh()
        } catch { self.error = "健康数据连接未完成，请稍后重试。" }
    }

    func refresh() async {
        // Every observer waits for the same refresh, including notification evaluation,
        // before reporting its background delivery complete to HealthKit.
        if let refreshTask { await refreshTask.value; return }
        let task = Task { await self.loadReadings() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func loadReadings() async {
        if isDemo { readings = Self.demoReadings(); await didRefresh?(); return }
        guard available && requested && !testing else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            var collected: [HealthReading] = []
            for metric in HealthMetric.allCases {
                let since = Calendar.current.date(byAdding: .day, value: -38, to: .now)!
                let samples = try await query(type: quantityType(metric), since: since)
                collected += samples.compactMap { ($0 as? HKQuantitySample).flatMap { reading(from: $0, metric: metric) } }
            }
            readings = collected
            // Reminders must not wait for the unrelated ECG history query.
            await didUpdateForReminders?(collected)
            let ecgSamples = try await query(type: HKObjectType.electrocardiogramType(), since: nil, limit: 100)
            ecgs = ecgSamples.compactMap { ($0 as? HKElectrocardiogram).map { ECGRecord(sample: $0) } }
            await didRefresh?()
            installObservers()
        } catch { self.error = "暂时无法更新健康记录，请稍后刷新。" }
    }

    /// Small, independent observer path: seven calendar days for the HRV baseline,
    /// thirty minutes for vital confirmation. ECG/monthly charts cannot block it.
    func refreshReminderReadings() async {
        if let reminderTask { reminderRefreshRequested = true; await reminderTask.value; return }
        let task = Task {
            repeat {
                self.reminderRefreshRequested = false
                await self.loadReminderReadings()
            } while self.reminderRefreshRequested
        }
        reminderTask = task
        await task.value
        reminderTask = nil
    }

    private func loadReminderReadings() async {
        guard available && requested && !testing && !isDemo else { return }
        let now = Date.now
        var collected: [HealthReading] = []
        var failed: [String] = []
        for metric in HealthMetric.allCases {
            let since = metric == .hrv
                ? Calendar.current.date(byAdding: .day, value: -7, to: Calendar.current.startOfDay(for: now))!
                : now.addingTimeInterval(-30 * 60)
            do {
                let samples = try await query(type: quantityType(metric), since: since)
                let recent = samples.compactMap { ($0 as? HKQuantitySample).flatMap { reading(from: $0, metric: metric) } }
                collected += recent
                readings.removeAll { $0.metric == metric && $0.date >= since }
                readings += recent
            } catch { failed.append(metric.name) }
        }
        observerWarning = failed.isEmpty ? nil : "\(failed.joined(separator: "、"))本次提醒检查未能读取，等待后续健康更新。"
        defaults.set(observerWarning, forKey: "health.observerWarning")
        // Failed types contribute no stale cached samples to the decision.
        await didUpdateForReminders?(collected)
        await didRefresh?()
    }

    private func reading(from sample: HKQuantitySample, metric: HealthMetric) -> HealthReading? {
        let value = sample.quantity.doubleValue(for: unit(metric))
        let motion = (sample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber).flatMap { HKHeartRateMotionContext(rawValue: $0.intValue) }
        let resting: Bool? = motion == .sedentary ? true : motion == .active ? false : nil
        let reading = HealthReading(id: sample.uuid, metric: metric, date: sample.startDate, value: metric == .oxygen ? value * 100 : value,
                                    source: sample.sourceRevision.source.name, sourceIdentifier: sample.sourceRevision.source.bundleIdentifier,
                                    wasUserEntered: sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool, isAtRest: resting)
        return reading.isValid ? reading : nil
    }

    func waveform(for record: ECGRecord) async throws -> [VoltagePoint] {
        try await withCheckedThrowingContinuation { continuation in
            var points: [VoltagePoint] = []
            let query = HKElectrocardiogramQuery(record.sample) { _, result in
                switch result {
                case .measurement(let measurement):
                    if let value = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                        points.append(VoltagePoint(seconds: measurement.timeSinceSampleStart, millivolts: value.doubleValue(for: .voltUnit(with: .milli))))
                    }
                case .done: continuation.resume(returning: points)
                case .error(let error): continuation.resume(throwing: error)
                @unknown default: break
                }
            }
            store.execute(query)
        }
    }

    private func query(type: HKSampleType, since: Date?, limit: Int = HKObjectQueryNoLimit) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = since.map { HKQuery.predicateForSamples(withStart: $0, end: .now, options: .strictStartDate) }
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
    }

    private func quantityType(_ metric: HealthMetric) -> HKQuantityType {
        switch metric {
        case .hrv: HKQuantityType(.heartRateVariabilitySDNN)
        case .heartRate: HKQuantityType(.heartRate)
        case .oxygen: HKQuantityType(.oxygenSaturation)
        }
    }
    private func unit(_ metric: HealthMetric) -> HKUnit {
        switch metric {
        case .hrv: .secondUnit(with: .milli)
        case .heartRate: .count().unitDivided(by: .minute())
        case .oxygen: .percent()
        }
    }

    private func installObservers() {
        guard observers.isEmpty && !testing && !isDemo else { return }
        for metric in HealthMetric.allCases {
            let type = quantityType(metric)
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                Task { @MainActor in
                    if let self {
                        self.lastObserverUpdateAt = .now
                        self.defaults.set(self.lastObserverUpdateAt, forKey: "health.lastObserverUpdateAt")
                        self.observerWarning = error == nil ? nil : "最近一次健康更新回调未完成，请打开应用刷新；若仍无数据，请检查 Apple 健康连接。"
                        self.defaults.set(self.observerWarning, forKey: "health.observerWarning")
                    }
                    if error == nil { await self?.refreshReminderReadings() }
                    completion()
                }
            }
            observers.append(query)
            store.execute(query)
        }
    }

    // Retry independently of observer creation: an earlier registration may have
    // failed before health access was changed in Settings.
    func restoreBackgroundDelivery() async {
        guard available && requested && !testing && !isDemo && !registeringBackgroundDelivery else { return }
        registeringBackgroundDelivery = true
        defer { registeringBackgroundDelivery = false }
        installObservers()
        var failed: [String] = []
        for metric in HealthMetric.allCases {
            let success: Bool = await withCheckedContinuation { continuation in
                store.enableBackgroundDelivery(for: quantityType(metric), frequency: .immediate) { success, _ in
                    continuation.resume(returning: success)
                }
            }
            if !success { failed.append(metric.name) }
        }
        backgroundDeliveryWarning = failed.isEmpty ? nil : "\(failed.joined(separator: "、"))后台健康更新暂未启用；打开应用时会重试，系统仍决定实际交付时间。"
        defaults.set(backgroundDeliveryWarning, forKey: "health.backgroundDeliveryWarning")
    }

    private static func demoReadings() -> [HealthReading] {
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<30).flatMap { offset -> [HealthReading] in
            guard offset % 8 != 4 else { return [] }
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
            return HealthMetric.allCases.map { metric in
                let base: Double = metric == .hrv ? 45 : metric == .heartRate ? 68 : 97
                let oscillation = metric == .oxygen ? Double(offset % 3) : sin(Double(offset)) * 7
                return HealthReading(metric: metric, date: day.addingTimeInterval(offset == 0 ? min(Date.now.timeIntervalSince(today), 8 * 3600) : 12 * 3600), value: base + oscillation, source: "演示数据")
            }
        }
    }
}
