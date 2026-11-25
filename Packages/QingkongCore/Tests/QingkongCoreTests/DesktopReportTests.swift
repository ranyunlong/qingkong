import Foundation
import Testing
@testable import QingkongCore

struct DesktopReportTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 0, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func emptyReportKeepsMissingMeasurementsAbsentAcross38LocalDays() throws {
        let now = date(11, 24, 10)
        let report = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [], now: now, calendar: calendar)
        #expect(report.generatedAt == now)
        #expect(report.timeZoneIdentifier == "Asia/Shanghai")
        #expect(report.days.count == 38)
        #expect(report.days.first?.date == date(10, 18))
        #expect(report.days.last?.date == date(11, 24))
        #expect(report.days.map(\.date) == report.days.map(\.date).sorted())
        #expect(Set(report.days.map(\.id)).count == 38)
        #expect(report.days.allSatisfy {
            $0.hrv == nil && $0.heartRate == nil && $0.oxygen == nil && $0.asleepSeconds == nil
                && $0.moodCounts.isEmpty && $0.stressCounts.isEmpty
                && $0.practiceCount == 0 && $0.practicedSeconds == 0
        })
    }

    @Test func healthMeansExcludeInvalidFutureAndOutOfWindowReadings() throws {
        let now = date(11, 24, 10)
        let readings = [
            HealthReading(metric: .hrv, date: now, value: 30, source: "Watch"),
            HealthReading(metric: .hrv, date: now.addingTimeInterval(-60), value: 50, source: "Watch"),
            HealthReading(metric: .heartRate, date: now, value: 65, source: "Watch"),
            HealthReading(metric: .oxygen, date: now, value: 97, source: "Watch"),
            HealthReading(metric: .oxygen, date: now, value: 101, source: "Watch"),
            HealthReading(metric: .hrv, date: now, value: 0, source: "Watch"),
            HealthReading(metric: .hrv, date: now, value: -.infinity, source: "Watch"),
            HealthReading(metric: .hrv, date: now, value: .nan, source: "Watch"),
            HealthReading(metric: .hrv, date: now.addingTimeInterval(1), value: 999, source: "Watch"),
            HealthReading(metric: .hrv, date: Date(timeIntervalSince1970: .nan), value: 999, source: "Watch"),
            HealthReading(metric: .hrv, date: date(10, 18), value: 20, source: "Watch"),
            HealthReading(metric: .hrv, date: date(10, 18).addingTimeInterval(-1), value: 999, source: "Watch")
        ]
        let report = DesktopReport.build(readings: readings, moods: [], practices: [], sleepSamples: [], now: now, calendar: calendar)
        let today = try #require(report.days.last)
        #expect(today.hrv == 40)
        #expect(today.heartRate == 65)
        #expect(today.oxygen == 97)
        #expect(report.days.first?.hrv == 20)
        #expect(report.days.filter { $0.hrv != nil }.count == 2)
    }

    @Test func moodHistogramsExcludeDeletedInvalidFutureAndOlderRecords() throws {
        let now = date(11, 24, 10)
        var deleted = MoodRecord(mood: 1, stress: 5, note: "deleted", createdAt: now)
        deleted.isDeleted = true
        var invalid = MoodRecord(mood: 1, stress: 1, note: "invalid", createdAt: now)
        invalid.mood = 0
        var invalidDate = MoodRecord(mood: 1, stress: 1, note: "invalid date", createdAt: now)
        invalidDate.createdAt = Date(timeIntervalSince1970: .nan)
        var futureEdit = MoodRecord(mood: 1, stress: 1, note: "future edit", createdAt: now)
        futureEdit.updatedAt = now.addingTimeInterval(1)
        let moods = [
            MoodRecord(mood: 2, stress: 4, note: "private", createdAt: now),
            MoodRecord(mood: 2, stress: 3, note: "private", createdAt: now.addingTimeInterval(-1)),
            MoodRecord(mood: 5, stress: 1, note: "first day", createdAt: date(10, 18)),
            MoodRecord(mood: 1, stress: 5, note: "older", createdAt: date(10, 18).addingTimeInterval(-1)),
            MoodRecord(mood: 1, stress: 5, note: "future", createdAt: now.addingTimeInterval(1)),
            deleted, invalid, invalidDate, futureEdit
        ]
        let report = DesktopReport.build(readings: [], moods: moods, practices: [], sleepSamples: [], now: now, calendar: calendar)
        let today = try #require(report.days.last)
        #expect(today.moodCounts == [2: 2])
        #expect(today.stressCounts == [3: 1, 4: 1])
        #expect(report.days.first?.moodCounts == [5: 1])
        #expect(report.days.reduce(0) { $0 + $1.moodCounts.values.reduce(0, +) } == 3)
    }

    @Test func practicesCountOnlyCompletedSessionsAndUseActivePlannedDuration() throws {
        let now = date(11, 24, 10)
        let practices = [
            RelaxationRecord(duration: .oneMinute, mode: .breathing, startedAt: now.addingTimeInterval(-240), completedAt: now),
            RelaxationRecord(duration: .threeMinutes, mode: .quiet, startedAt: now.addingTimeInterval(-180), completedAt: now),
            RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: now.addingTimeInterval(-59), completedAt: now),
            RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: now, completedAt: now.addingTimeInterval(-1)),
            RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: now.addingTimeInterval(-60), completedAt: now.addingTimeInterval(1)),
            RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: Date(timeIntervalSince1970: -.infinity), completedAt: now),
            RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: date(10, 18).addingTimeInterval(-60), completedAt: date(10, 18)),
            RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: date(10, 18).addingTimeInterval(-120), completedAt: date(10, 18).addingTimeInterval(-60))
        ]
        let report = DesktopReport.build(readings: [], moods: [], practices: practices, sleepSamples: [], now: now, calendar: calendar)
        #expect(report.days.last?.practiceCount == 2)
        #expect(report.days.last?.practicedSeconds == 240)
        #expect(report.days.first?.practiceCount == 1)
        #expect(report.days.first?.practicedSeconds == 60)
        #expect(report.days.reduce(0) { $0 + $1.practiceCount } == 3)
    }

    @Test func sleepUsesNightWindowAndMergesSourcesWithoutCountingFutureObservations() throws {
        let now = date(11, 24, 10)
        let samples = [
            SleepSample(start: date(11, 23, 22), end: date(11, 24, 3), stage: .deep, source: "Watch"),
            SleepSample(start: date(11, 24, 2), end: date(11, 24, 6), stage: .core, source: "Phone"),
            SleepSample(start: date(11, 24, 6), end: date(11, 24, 9), stage: .inBed, source: "Phone"),
            SleepSample(start: date(11, 24, 7), end: date(11, 24, 11), stage: .core, source: "Future end"),
            SleepSample(start: date(11, 24, 11), end: date(11, 24, 12), stage: .core, source: "Future start"),
            SleepSample(start: date(11, 24, 7), end: date(11, 24, 6), stage: .core, source: "Reversed"),
            SleepSample(start: Date(timeIntervalSince1970: .nan), end: now, stage: .core, source: "Invalid"),
            SleepSample(start: date(10, 17, 17), end: date(10, 18, 2), stage: .core, source: "First night"),
            SleepSample(start: date(10, 16, 22), end: date(10, 17, 6), stage: .core, source: "Older night")
        ]
        let report = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: samples, now: now, calendar: calendar)
        #expect(report.days.last?.asleepSeconds == 28_800)
        #expect(report.days.first?.asleepSeconds == 28_800)
        #expect(report.days.filter { $0.asleepSeconds != nil }.count == 2)
    }

    @Test(arguments: [true, false])
    func phoneTimeZoneControlsDaysAndSleepAcrossDaylightSaving(spring: Bool) throws {
        var local = calendar
        local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = spring ? date(3, 7, 22, calendar: local) : date(10, 31, 22, calendar: local)
        let end = spring ? date(3, 8, 6, calendar: local) : date(11, 1, 6, calendar: local)
        let now = spring ? date(3, 9, 12, calendar: local) : date(11, 2, 12, calendar: local)
        let sleep = SleepSample(start: start, end: end, stage: .core, source: "Watch")
        let reading = HealthReading(metric: .hrv, date: start, value: 42, source: "Watch")
        let report = DesktopReport.build(readings: [reading], moods: [], practices: [], sleepSamples: [sleep], now: now, calendar: local)
        #expect(report.timeZoneIdentifier == "America/Los_Angeles")
        try #require(report.days.count == 38)
        #expect(report.days.dropLast().last?.asleepSeconds == (spring ? 25_200 : 32_400))
        #expect(report.days.dropLast(2).last?.hrv == 42)
        let lastDays = Array(report.days.suffix(3))
        #expect(lastDays[2].date.timeIntervalSince(lastDays[1].date) == (spring ? 82_800 : 90_000))
    }

    @Test func serializedReportContainsOnlyDailyAggregatesAndRoundTrips() throws {
        let now = date(11, 24, 10)
        let reading = HealthReading(metric: .hrv, date: now, value: 43, source: "Secret health source", sourceIdentifier: "private.bundle")
        let mood = MoodRecord(mood: 3, stress: 2, note: "Never send my diary", createdAt: now, tags: [.work])
        let practice = RelaxationRecord(duration: .oneMinute, mode: .breathing, startedAt: now.addingTimeInterval(-60), completedAt: now, finalHeartRate: HealthReading(metric: .heartRate, date: now, value: 64, source: "Secret session source"))
        let sleep = SleepSample(start: date(11, 23, 22), end: date(11, 24, 6), stage: .core, source: "Secret sleep source")
        let report = DesktopReport.build(readings: [reading], moods: [mood], practices: [practice], sleepSamples: [sleep], now: now, calendar: calendar)
        let data = try JSONEncoder().encode(report)
        let text = try #require(String(data: data, encoding: .utf8))
        for secret in [mood.note, reading.source, "private.bundle", "Secret session source", sleep.source, reading.id.uuidString, mood.id.uuidString, practice.id.uuidString, sleep.id.uuidString] {
            #expect(!text.contains(secret))
        }
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["generatedAt", "timeZoneIdentifier", "days"])
        let days = try #require(object["days"] as? [[String: Any]])
        let today = try #require(days.last)
        #expect(Set(today.keys) == ["date", "hrv", "asleepSeconds", "moodCounts", "stressCounts", "practiceCount", "practicedSeconds"])
        #expect(try JSONDecoder().decode(DesktopReport.self, from: data) == report)
        #expect(report.days.last?.heartRate == nil)
    }
}
