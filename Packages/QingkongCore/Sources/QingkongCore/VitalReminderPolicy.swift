import Foundation

public enum VitalReminderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case highHeartRate, lowHeartRate, lowOxygen
    public var id: String { rawValue }
    public var metric: HealthMetric { self == .lowOxygen ? .oxygen : .heartRate }
    public var title: String { switch self { case .highHeartRate: "静息心率偏高"; case .lowHeartRate: "静息心率偏低"; case .lowOxygen: "血氧读数偏低" } }
    public var defaultThreshold: Double { switch self { case .highHeartRate: 120; case .lowHeartRate: 50; case .lowOxygen: 90 } }
    public var thresholdRange: ClosedRange<Double> { switch self { case .highHeartRate: 100...150; case .lowHeartRate: 40...60; case .lowOxygen: 85...95 } }
    public var thresholdStep: Double { self == .lowOxygen ? 1 : 5 }
}

public struct VitalReminderRule: Codable, Sendable {
    public var threshold: Double
    public var delivery: RelaxationReminderState
    public init(kind: VitalReminderKind, now: Date = .now) {
        threshold = kind.defaultThreshold
        delivery = RelaxationReminderState(now: now)
    }
    public mutating func recordDelivery(_ candidate: VitalReminderCandidate, now: Date = .now) {
        delivery.recordDelivery(sampleDate: candidate.sampleDate, now: now)
    }
}

public struct VitalReminderCandidate: Sendable {
    public let kind: VitalReminderKind
    public let sampleID: UUID
    public let sampleDate: Date
}

public struct VitalReminderAssessment: Sendable {
    public let candidate: VitalReminderCandidate?
    public let reason: String
}

/// User-adjustable wellness prompts, not medical alarms or diagnostic thresholds.
public enum VitalReminderPolicy {
    public static func assess(kind: VitalReminderKind, readings: [HealthReading], rule: VitalReminderRule, now: Date = .now, calendar: Calendar = .current) -> VitalReminderAssessment {
        func skip(_ reason: String) -> VitalReminderAssessment { .init(candidate: nil, reason: reason) }
        let state = rule.delivery
        guard state.enabled else { return skip("提醒已关闭") }
        guard rule.threshold.isFinite, kind.thresholdRange.contains(rule.threshold) else { return skip("请检查提醒阈值设置") }
        guard state.mutedUntil.map({ now >= $0 }) ?? true else { return skip("今天已暂停提醒") }
        guard state.deliveries.filter({ calendar.isDate($0, inSameDayAs: now) }).count < 2,
              state.deliveries.max().map({ now.timeIntervalSince($0) >= 4 * 3600 }) ?? true else { return skip("处于提醒间隔或已达今日上限") }
        var seen: Set<UUID> = []
        let valid = readings.filter { $0.metric == kind.metric && $0.isValid && $0.wasUserEntered != true && $0.date <= now }
            .sorted { $0.date > $1.date }.filter { seen.insert($0.id).inserted }
        guard let latest = valid.first else { return skip("暂无可读取的自动\(kind.metric.name)记录") }
        guard latest.date > state.consumedThrough else { return skip("等待新的记录，不重复判断旧记录") }
        guard now.timeIntervalSince(latest.date) <= 15 * 60 else { return skip("最新记录已超过 15 分钟，不补发旧提醒") }
        let source = latest.sourceIdentifier ?? latest.source
        let recent = valid.filter { ($0.sourceIdentifier ?? $0.source) == source && $0.date > state.eligibleSince && now.timeIntervalSince($0.date) <= 30 * 60 }
        if kind != .lowOxygen && latest.isAtRest != true { return skip("缺少明确的静息记录，运动或未知状态不触发心率提醒") }
        func outsideThreshold(_ reading: HealthReading) -> Bool {
            guard kind == .lowOxygen || reading.isAtRest == true else { return false }
            return kind == .highHeartRate ? reading.value > rule.threshold : reading.value < rule.threshold
        }
        guard outsideThreshold(latest) else { return skip("最新记录未达到设置的提醒阈值") }
        let run = recent.prefix(while: outsideThreshold)
        let minimumInterval: TimeInterval = kind == .lowOxygen ? 60 : 600
        guard run.contains(where: { latest.date.timeIntervalSince($0.date) >= minimumInterval }) else { return skip(kind == .lowOxygen ? "等待至少相隔 1 分钟的第二条偏低读数" : "等待至少相隔 10 分钟的静息异常记录") }
        return .init(candidate: .init(kind: kind, sampleID: latest.id, sampleDate: latest.date), reason: "已达到提醒条件")
    }
}
