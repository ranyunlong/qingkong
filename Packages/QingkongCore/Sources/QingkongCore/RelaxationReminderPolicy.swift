import Foundation

public struct RelaxationReminderCandidate: Sendable {
    public let sampleID: UUID
    public let sampleDate: Date
    public let baseline: Double
}

public struct RelaxationReminderAssessment: Sendable {
    public let candidate: RelaxationReminderCandidate?
    public let reason: String
}

/// Local product heuristics, not a validated psychological stress or clinical threshold.
public enum RelaxationReminderPolicy {
    public static func candidate(readings: [HealthReading], state: RelaxationReminderState, now: Date = .now, calendar: Calendar = .current) -> RelaxationReminderCandidate? {
        assess(readings: readings, state: state, now: now, calendar: calendar).candidate
    }

    public static func assess(readings: [HealthReading], state: RelaxationReminderState, now: Date = .now, calendar: Calendar = .current) -> RelaxationReminderAssessment {
        func skip(_ reason: String) -> RelaxationReminderAssessment { .init(candidate: nil, reason: reason) }
        guard state.enabled else { return skip("提醒已关闭") }
        guard state.mutedUntil.map({ now >= $0 }) ?? true else { return skip("今天已暂停提醒") }
        guard
              state.deliveries.filter({ calendar.isDate($0, inSameDayAs: now) }).count < 2,
              state.deliveries.max().map({ now.timeIntervalSince($0) >= 4 * 3600 }) ?? true else { return skip("处于提醒间隔或已达今日上限") }
        var seen: Set<UUID> = []
        let valid = readings.filter { $0.metric == .hrv && $0.isValid && $0.wasUserEntered != true && $0.date <= now }
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }
        guard let latest = valid.first else { return skip("暂无可读取的自动 HRV 记录") }
        guard latest.date > state.consumedThrough else { return skip("等待新的 HRV 记录，不重复判断旧记录") }
        guard latest.date > state.eligibleSince else { return skip("不补发启用前的 HRV 记录") }
        guard now.timeIntervalSince(latest.date) <= 60 * 60 else { return skip("最新 HRV 已超过 1 小时，不补发旧提醒") }
        let source = latest.sourceIdentifier ?? latest.source
        let sameSource = valid.filter { ($0.sourceIdentifier ?? $0.source) == source }
        guard let baseline = HealthMath.hrvBaseline(sameSource, now: now, calendar: calendar), baseline.isFinite, baseline > 0 else { return skip("同一来源的个人基线不足 3 个有效日") }
        guard latest.value <= baseline * 0.7 else { return skip("最新 HRV 未明显低于个人基线") }
        // HRV measurements are not guaranteed to arrive in a dense sequence.
        // This is a gentle change reminder, not confirmation of psychological stress.
        return .init(candidate: RelaxationReminderCandidate(sampleID: latest.id, sampleDate: latest.date, baseline: baseline), reason: "已达到 HRV 变化提醒条件")
    }
}

public struct RelaxationReminderState: Codable, Sendable {
    public private(set) var enabled = true
    public private(set) var eligibleSince: Date
    public private(set) var consumedThrough: Date
    public var deliveries: [Date] = []
    public var mutedUntil: Date?

    public init(now: Date = .now) { eligibleSince = now; consumedThrough = now }
    public mutating func setEnabled(_ enabled: Bool, now: Date = .now) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        eligibleSince = now
        consumedThrough = now
    }
    public mutating func consume(through date: Date) { consumedThrough = max(date, consumedThrough) }
    public mutating func resetWindow(now: Date = .now) { eligibleSince = now; consumedThrough = now }
    public mutating func recordDelivery(_ candidate: RelaxationReminderCandidate, now: Date = .now) {
        recordDelivery(sampleDate: candidate.sampleDate, now: now)
    }
    public mutating func recordDelivery(sampleDate: Date, now: Date = .now) {
        consume(through: sampleDate)
        deliveries = deliveries.filter { now.timeIntervalSince($0) < 3 * 86400 }
        deliveries.append(now)
    }
}
