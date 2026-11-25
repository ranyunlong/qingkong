import Foundation
import HealthKit
import Observation
import QingkongCore

@MainActor @Observable
final class SleepHealthService {
    private(set) var samples: [SleepSample] = []
    private(set) var requested: Bool
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored var didRefresh: (() -> Void)?
    @ObservationIgnored private let healthStore = HKHealthStore()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let testing: Bool

    init(testing: Bool = false) {
        self.testing = testing
        defaults = testing ? UserDefaults(suiteName: "qingkong.sleep-health.testing")! : .standard
        requested = defaults.bool(forKey: "sleep.reading-requested")
    }

    func authorize(weekStarting: Date? = nil) async {
        guard HKHealthStore.isHealthDataAvailable(), !testing else { return }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!])
            requested = true; defaults.set(true, forKey: "sleep.reading-requested")
            await refresh(weekStarting: weekStarting)
        } catch { self.error = "睡眠读取授权未完成，你仍可以使用其他功能。" }
    }

    func refresh(weekStarting: Date? = nil) async {
        guard requested, !testing else { return }
        while loading {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        let now = Date.now
        let since = Calendar.current.date(byAdding: .day, value: weekStarting == nil ? -38 : -1, to: weekStarting ?? now)!
        let until = weekStarting.map { min(now, Calendar.current.date(byAdding: .day, value: 8, to: $0)!) } ?? now
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        do {
            let values: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
                let query = HKSampleQuery(sampleType: type,
                    predicate: HKQuery.predicateForSamples(withStart: since, end: until), limit: HKObjectQueryNoLimit,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: (samples as? [HKCategorySample]) ?? []) }
                }
                healthStore.execute(query)
            }
            guard !Task.isCancelled else { return }
            let updated = values.compactMap { sample -> SleepSample? in
                guard sample.startDate < now else { return nil }
                let stage: SleepStage
                switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                case .inBed: stage = .inBed
                case .awake: stage = .awake
                case .asleepUnspecified: stage = .asleepUnspecified
                case .asleepCore: stage = .core
                case .asleepDeep: stage = .deep
                case .asleepREM: stage = .rem
                default: return nil
                }
                return SleepSample(id: sample.uuid, start: sample.startDate, end: min(sample.endDate, now), stage: stage, source: sample.sourceRevision.source.name)
            }
            samples.removeAll { $0.start < until && $0.end > since }
            let replacingIDs = Set(updated.map(\.id))
            samples.removeAll { replacingIDs.contains($0.id) }
            samples += updated
            error = nil
            didRefresh?()
        } catch { self.error = "暂时无法更新睡眠记录。" }
    }
}
