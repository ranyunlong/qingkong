import Foundation

/// Daily aggregates shared directly between the user's devices. Raw records stay local.
public struct DesktopReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let timeZoneIdentifier: String
    public let days: [DesktopReportDay]

    public static func build(readings: [HealthReading], moods: [MoodRecord], practices: [RelaxationRecord], sleepSamples: [SleepSample], now: Date = .now, calendar: Calendar = .current) -> DesktopReport {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -37, to: today) else {
            return DesktopReport(generatedAt: now, timeZoneIdentifier: calendar.timeZone.identifier, days: [])
        }
        let validReadings = readings.filter {
            $0.date.timeIntervalSince1970.isFinite && $0.date >= start && $0.date <= now && $0.isValid
        }
        let validMoods = moods.filter {
            !$0.isDeleted && (1...5).contains($0.mood) && (1...5).contains($0.stress)
                && $0.createdAt.timeIntervalSince1970.isFinite && $0.updatedAt.timeIntervalSince1970.isFinite
                && $0.createdAt >= start && $0.createdAt <= now
                && $0.updatedAt >= $0.createdAt && $0.updatedAt <= now
        }
        let validPractices = practices.filter {
            $0.startedAt.timeIntervalSince1970.isFinite && $0.completedAt.timeIntervalSince1970.isFinite
                && $0.completedAt >= start && $0.completedAt <= now
                && $0.completedAt.timeIntervalSince($0.startedAt) >= $0.duration.seconds
        }
        // The first reported night includes the preceding evening, as on the phone.
        let firstNightStart = calendar.date(byAdding: .day, value: -1, to: start)
            .flatMap { calendar.date(bySettingHour: 18, minute: 0, second: 0, of: $0) } ?? start
        let validSleep = sleepSamples.filter {
            $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
                && $0.end > $0.start && $0.end > firstNightStart && $0.end <= now
        }
        let days = (0..<38).compactMap { offset -> DesktopReportDay? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let dailyMoods = validMoods.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
            let dailyPractices = validPractices.filter { calendar.isDate($0.completedAt, inSameDayAs: day) }
            return DesktopReportDay(
                date: day,
                hrv: HealthMath.dailyMean(validReadings, metric: .hrv, day: day, now: now, calendar: calendar),
                heartRate: HealthMath.dailyMean(validReadings, metric: .heartRate, day: day, now: now, calendar: calendar),
                oxygen: HealthMath.dailyMean(validReadings, metric: .oxygen, day: day, now: now, calendar: calendar),
                asleepSeconds: SleepSummaryMath.night(samples: validSleep, endingOn: day, calendar: calendar)?.asleepSeconds,
                moodCounts: dailyMoods.reduce(into: [:]) { $0[$1.mood, default: 0] += 1 },
                stressCounts: dailyMoods.reduce(into: [:]) { $0[$1.stress, default: 0] += 1 },
                practiceCount: dailyPractices.count,
                practicedSeconds: dailyPractices.reduce(0) { $0 + $1.practicedSeconds }
            )
        }
        return DesktopReport(generatedAt: now, timeZoneIdentifier: calendar.timeZone.identifier, days: days)
    }
}

public struct DesktopReportDay: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let hrv: Double?
    public let heartRate: Double?
    public let oxygen: Double?
    public let asleepSeconds: TimeInterval?
    public let moodCounts: [Int: Int]
    public let stressCounts: [Int: Int]
    public let practiceCount: Int
    public let practicedSeconds: TimeInterval
}
