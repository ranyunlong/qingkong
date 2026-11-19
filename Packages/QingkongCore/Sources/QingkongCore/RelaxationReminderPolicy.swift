import Foundation

public struct RelaxationReminderCandidate: Sendable {
    public let sampleID: UUID
    public let sampleDate: Date
    public let baseline: Double
}

/// Local product heuristics, not a validated psychological stress or clinical threshold.
public enum RelaxationReminderPolicy {
    public static func candidate(readings: [HealthReading], state: RelaxationReminderState, now: Date = .now, calendar: Calendar = .current) -> RelaxationReminderCandidate? {
        guard state.enabled, state.mutedUntil.map({ now >= $0 }) ?? true,
              state.deliveries.filter({ calendar.isDate($0, inSameDayAs: now) }).count < 2,
              state.deliveries.max().map({ now.timeIntervalSince($0) >= 4 * 3600 }) ?? true else { return nil }
        var seen: Set<UUID> = []
        let valid = readings.filter { $0.metric == .hrv && $0.isValid && $0.wasUserEntered != true && $0.date <= now }
            .sorted { $0.date > $1.date }
            .filter { seen.insert($0.id).inserted }
        guard let latest = valid.first,
              latest.date > state.consumedThrough,
              now.timeIntervalSince(latest.date) <= 15 * 60 else { return nil }
        let source = latest.sourceIdentifier ?? latest.source
        let sameSource = valid.filter { ($0.sourceIdentifier ?? $0.source) == source }
        let recent = sameSource.filter { $0.date > state.eligibleSince && now.timeIntervalSince($0.date) <= 3600 }
        guard recent.count >= 2,
              recent[0].date.timeIntervalSince(recent[1].date) >= 10 * 60,
              let baseline = HealthMath.hrvBaseline(sameSource, now: now, calendar: calendar),
              baseline.isFinite, baseline > 0,
              recent[0].value <= baseline * 0.7, recent[1].value <= baseline * 0.7 else { return nil }
        return RelaxationReminderCandidate(sampleID: latest.id, sampleDate: latest.date, baseline: baseline)
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
    public mutating func recordDelivery(_ candidate: RelaxationReminderCandidate, now: Date = .now) {
        consume(through: candidate.sampleDate)
        deliveries = deliveries.filter { now.timeIntervalSince($0) < 3 * 86400 }
        deliveries.append(now)
    }
}
