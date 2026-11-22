import Foundation
import Observation
import QingkongCore

enum CompanionActionMemory {
    static let nodKey = "companion.actions.nodUnlocked"
    static let swayKey = "companion.actions.swayUnlocked"

    static func remember(moods: [MoodRecord] = [], practices: [RelaxationRecord] = [], defaults: UserDefaults) {
        let actions = CompanionActionAvailability(moods: moods, practices: practices).actions
        if actions.contains(.nod) { defaults.set(true, forKey: nodKey) }
        if actions.contains(.sway) { defaults.set(true, forKey: swayKey) }
    }
}

struct LocalTimelineEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case health, reminder }
    let id: String
    let date: Date
    let title: String
    let detail: String
    let kind: Kind
}

/// Device-only records; never included in WatchConnectivity or public-content requests.
@MainActor @Observable
final class CompanionStore {
    private struct Archive: Codable {
        var practices: [RelaxationRecord] = []
        var events: [LocalTimelineEvent] = []
        var deletedEventIDs: Set<String> = []
        var bedtimePlans: [BedtimePlan] = []
        var calmHome = true
    }
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let defaults: UserDefaults
    private var archive: Archive
    var practices: [RelaxationRecord] { archive.practices.sorted { $0.completedAt > $1.completedAt } }
    var events: [LocalTimelineEvent] { archive.events.sorted { $0.date > $1.date } }
    var bedtimePlans: [BedtimePlan] { archive.bedtimePlans }
    var calmHome: Bool { archive.calmHome }
    var error: String?

    init(url: URL? = nil, testing: Bool = false, reset: Bool = false, defaultsOverride: UserDefaults? = nil) throws {
        defaults = defaultsOverride ?? (testing ? UserDefaults(suiteName: "cn.geckoai.qingkong.uitests")! : .standard)
        self.url = url ?? URL.applicationSupportDirectory.appending(path: "Qingkong/" + (testing ? "companion-testing.json" : "companion.json"))
        if testing && reset && FileManager.default.fileExists(atPath: self.url.path) {
            try FileManager.default.removeItem(at: self.url)
        }
        if FileManager.default.fileExists(atPath: self.url.path) {
            archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.url))
        } else { archive = Archive() }
        CompanionActionMemory.remember(practices: archive.practices, defaults: defaults)
    }

    func savePractice(_ record: RelaxationRecord) throws {
        try edit { value in
            value.practices.removeAll { $0.id == record.id }
            value.practices.append(record)
        }
        CompanionActionMemory.remember(practices: [record], defaults: defaults)
    }

    func deletePractice(_ id: UUID) throws { try edit { $0.practices.removeAll { $0.id == id } } }
    func setCalmHome(_ enabled: Bool) throws { try edit { $0.calmHome = enabled } }
    func savePlan(_ plan: BedtimePlan) throws {
        try edit { value in
            value.bedtimePlans.removeAll { $0.id == plan.id }
            value.bedtimePlans.append(plan)
        }
    }
    func deletePlan(_ id: UUID) throws { try edit { $0.bedtimePlans.removeAll { $0.id == id } } }

    func saveEvent(_ event: LocalTimelineEvent) throws {
        guard !archive.deletedEventIDs.contains(event.id) else { return }
        guard archive.events.first(where: { $0.id == event.id }) != event else { return }
        try edit { value in
            value.events.removeAll { $0.id == event.id }
            value.events.append(event)
        }
    }

    func deleteEvent(_ id: String) throws {
        try edit { value in
            value.events.removeAll { $0.id == id }
            value.deletedEventIDs.insert(id)
        }
    }

    func captureHealthSummary(_ readings: [HealthReading], now: Date = .now, calendar: Calendar = .current) {
        let days = Set(readings.filter { $0.isValid && $0.date <= now }.map { calendar.startOfDay(for: $0.date) })
        do {
            for day in days {
                for metric in HealthMetric.allCases {
                    let samples = readings.filter { $0.metric == metric && $0.isValid && $0.date <= now && calendar.isDate($0.date, inSameDayAs: day) }
                    guard let sampledAt = samples.map(\.date).max(), !samples.isEmpty else { continue }
                    let mean = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
                    let sources = Set(samples.map(\.source)).sorted().joined(separator: "、")
                    try saveEvent(.init(id: "health-\(metric.rawValue)-\(Int(day.timeIntervalSince1970))", date: sampledAt,
                        title: "\(metric.name) 日均 \(mean.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)",
                        detail: "依据当日 \(samples.count) 条有效采样；来源：\(sources)。采样时间 \(sampledAt.formatted(date: .abbreviated, time: .shortened))。仅呈现变化，不用于诊断。", kind: .health))
                }
            }
        } catch { self.error = "健康摘要暂未保存，请稍后重试。" }
    }

    private func edit(_ mutation: (inout Archive) -> Void) throws {
        var next = archive
        mutation(&next)
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        archive = next
        error = nil
    }
}
