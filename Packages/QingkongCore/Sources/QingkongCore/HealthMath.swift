import Foundation

public enum HealthMath {
    public static func dailyMean(_ samples: [HealthReading], metric: HealthMetric, day: Date, now: Date = .now, calendar: Calendar = .current) -> Double? {
        let valid = samples.filter { $0.metric == metric && $0.isValid && $0.date <= now && calendar.isDate($0.date, inSameDayAs: day) }
        return mean(valid.map(\.value))
    }

    public static func hrvBaseline(_ samples: [HealthReading], now: Date = .now, calendar: Calendar = .current) -> Double? {
        let today = calendar.startOfDay(for: now)
        let daily = (1...7).compactMap { offset -> Double? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return dailyMean(samples, metric: .hrv, day: day, now: now, calendar: calendar)
        }
        return daily.count >= 3 ? mean(daily) : nil
    }

    public static func buckets(_ samples: [HealthReading], metric: HealthMetric, period: TrendPeriod, now: Date = .now, calendar: Calendar = .current) -> [TrendBucket] {
        let today = calendar.startOfDay(for: now)
        let component: Calendar.Component = period == .day ? .hour : .day
        let count = period == .week ? 7 : 30
        let start = period == .day ? today : calendar.date(byAdding: .day, value: -(count - 1), to: today)!
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let valid = samples.filter { $0.metric == metric && $0.isValid && $0.date <= now && $0.date >= start && $0.date < end }
        var cursor = start
        var result: [TrendBucket] = []
        var segment = 0
        while cursor < end {
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor) else { break }
            let value = mean(valid.filter { $0.date >= cursor && $0.date < next }.map(\.value))
            if value == nil { segment += 1 }
            result.append(TrendBucket(date: cursor, value: value, segment: segment))
            cursor = next
        }
        return result
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
