import Foundation

public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case inBed, awake, asleepUnspecified, core, deep, rem
    public var isAsleep: Bool {
        switch self {
        case .inBed, .awake: false
        case .asleepUnspecified, .core, .deep, .rem: true
        }
    }
}

/// Device-local sleep observations. Being in bed does not establish sleep.
public struct SleepSample: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let start: Date
    public let end: Date
    public let stage: SleepStage
    public let source: String

    public init(id: UUID = UUID(), start: Date, end: Date, stage: SleepStage, source: String) {
        self.id = id; self.start = start; self.end = end; self.stage = stage; self.source = source
    }
}

public struct SleepNightSummary: Codable, Equatable, Sendable {
    public let endingOn: Date
    public let window: DateInterval
    public let intervals: [DateInterval]
    public let sources: Set<String>
    public let latestSampleEnd: Date
    public var asleepSeconds: TimeInterval { intervals.reduce(0) { $0 + $1.duration } }
}

public struct SleepWeeklySummary: Codable, Equatable, Sendable {
    public let nights: [SleepNightSummary]
    public var recordedNightCount: Int { nights.count }
    public var totalAsleepSeconds: TimeInterval { nights.reduce(0) { $0 + $1.asleepSeconds } }
    public var averageAsleepSeconds: TimeInterval { totalAsleepSeconds / Double(recordedNightCount) }
}

public enum SleepSummaryMath {
    /// The window is local 18:00 on the preceding day through local 12:00.
    /// Only actual sleep stages contribute; overlapping observations are counted once.
    public static func night(samples: [SleepSample], endingOn date: Date, calendar: Calendar = .current) -> SleepNightSummary? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let day = calendar.startOfDay(for: date)
        guard let precedingDay = calendar.date(byAdding: .day, value: -1, to: day),
              let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: precedingDay),
              let end = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) else { return nil }
        var intervals: [DateInterval] = []
        var sources = Set<String>()
        var latestSampleEnd: Date?
        for sample in samples {
            guard sample.stage.isAsleep,
                  sample.start.timeIntervalSince1970.isFinite, sample.end.timeIntervalSince1970.isFinite,
                  sample.end > sample.start else { continue }
            let clippedStart = max(start, sample.start), clippedEnd = min(end, sample.end)
            guard clippedEnd > clippedStart else { continue }
            intervals.append(DateInterval(start: clippedStart, end: clippedEnd))
            sources.insert(sample.source)
            latestSampleEnd = max(latestSampleEnd ?? sample.end, sample.end)
        }
        guard let latestSampleEnd else { return nil }
        intervals.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in intervals {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return SleepNightSummary(endingOn: day, window: DateInterval(start: start, end: end), intervals: merged, sources: sources, latestSampleEnd: latestSampleEnd)
    }

    /// Missing nights stay absent and never enter the denominator as zero hours.
    public static func week(samples: [SleepSample], weekStarting date: Date, calendar: Calendar = .current) -> SleepWeeklySummary? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let start = calendar.startOfDay(for: date)
        let nights = (0..<7).compactMap { offset -> SleepNightSummary? in
            guard let ending = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return night(samples: samples, endingOn: ending, calendar: calendar)
        }
        return nights.isEmpty ? nil : SleepWeeklySummary(nights: nights)
    }
}
