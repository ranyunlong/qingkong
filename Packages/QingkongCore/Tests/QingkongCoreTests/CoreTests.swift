import Foundation
import Testing
@testable import QingkongCore

struct CoreTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }
    func reading(_ day: Int, _ value: Double, hour: Int = 12) -> HealthReading {
        HealthReading(metric: .hrv, date: date(day, hour: hour), value: value, source: "测试")
    }

    @Test func baselineUsesDailyMeansAndExcludesTodayAndOldSamples() {
        let samples = [reading(12, 20), reading(12, 40), reading(13, 60), reading(18, 90), reading(11, 999), reading(19, 999)]
        #expect(HealthMath.hrvBaseline(samples, now: date(19), calendar: calendar) == 60)
    }
    @Test func insufficientBaselineIsNil() {
        #expect(HealthMath.hrvBaseline([reading(17, 20), reading(18, 30)], now: date(19), calendar: calendar) == nil)
    }
    @Test func gapsAreNotZeroAndBreakLines() {
        let buckets = HealthMath.buckets([reading(17, 30), reading(19, 60)], metric: .hrv, period: .week, now: date(19), calendar: calendar)
        #expect(buckets.count == 7)
        #expect(buckets[5].value == nil)
        #expect(buckets[4].value == 30)
        #expect(buckets[6].value == 60)
        #expect(buckets[4].segment != buckets[6].segment)
    }
    @Test func baselineRespectsLocalCalendarBoundary() {
        #expect(HealthMath.hrvBaseline([reading(16, 10), reading(17, 20), reading(18, 30), reading(19, 900, hour: 0)], now: date(19, hour: 1), calendar: calendar) == 20)
    }
    @Test func dayBucketsHandleDaylightSaving() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23))!
        let autumn = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23))!
        #expect(HealthMath.buckets([], metric: .hrv, period: .day, now: spring, calendar: cal).count == 23)
        #expect(HealthMath.buckets([], metric: .hrv, period: .day, now: autumn, calendar: cal).count == 25)
    }
    @Test func futureAndInvalidReadingsAreIgnored() {
        let values = [reading(18, .nan), reading(18, -1), reading(19, 100, hour: 23), reading(19, 40, hour: 8)]
        #expect(HealthMath.dailyMean(values, metric: .hrv, day: date(19), now: date(19), calendar: calendar) == 40)
    }
    @Test func automaticThemeUsesOnlyLatestLiveEntryToday() {
        var preferences = Preferences()
        preferences.automaticScene = true
        preferences.relaxingScene = .ocean
        let stressed = MoodRecord(mood: 2, stress: 4, note: "", createdAt: date(19, hour: 8))
        let calm = MoodRecord(mood: 3, stress: 2, note: "", createdAt: date(19, hour: 10))
        #expect(preferences.scene(entries: [stressed], now: date(19), calendar: calendar) == .ocean)
        #expect(preferences.scene(entries: [stressed, calm], now: date(19), calendar: calendar) == .clear)
        #expect(preferences.scene(entries: [stressed], now: date(20), calendar: calendar) == .clear)
    }
    @Test func manualThemeDisablesAutomation() {
        var preferences = Preferences()
        preferences.automaticScene = true
        preferences.selectScene(.night)
        #expect(!preferences.automaticScene)
        #expect(preferences.manualScene == .night)
    }
    @Test func tombstoneWinsAndOlderRecordsCannotResurrect() {
        let original = MoodRecord(mood: 3, stress: 2, note: "", createdAt: date(18))
        var deleted = original
        deleted.updatedAt = date(19)
        deleted.isDeleted = true
        #expect(RecordMerge.resolve(local: deleted, incoming: original) == deleted)
        #expect(RecordMerge.resolve(local: original, incoming: deleted) == deleted)
        var sameVersion = deleted
        sameVersion.isDeleted = false
        #expect(RecordMerge.resolve(local: deleted, incoming: sameVersion).isDeleted)
    }
    @Test func invalidMoodIsRejectedOnDecode() throws {
        let record = MoodRecord(mood: 3, stress: 2, note: "", createdAt: date(19))
        let data = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["stress"] = 99
        let bad = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MoodRecord.self, from: bad) }
    }
    @Test func deadlineUsesWallClock() {
        let deadline = SleepDeadline(minutes: 15, now: date(19))
        #expect(!deadline.expired(at: date(19).addingTimeInterval(899)))
        #expect(deadline.expired(at: date(19).addingTimeInterval(901)))
        #expect(deadline.remaining(at: date(19).addingTimeInterval(1000)) == 0)
    }
    @Test func deadlineTransportsOriginalDurationWithoutResettingCutoff() throws {
        let deadline = SleepDeadline(minutes: 30, now: date(19))
        let encoded = try JSONEncoder().encode(deadline)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["durationMinutes"] as? Int == 30)
        let received = try JSONDecoder().decode(SleepDeadline.self, from: encoded)
        #expect(received.date == date(19).addingTimeInterval(1800))
        #expect(received.remaining(at: date(19).addingTimeInterval(600)) == 1200)
    }
    @Test func deadlineFromPreviousVersionStillDecodes() throws {
        let deadline = SleepDeadline(minutes: 15, now: date(19))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(deadline)) as? [String: Any])
        let legacy = try JSONSerialization.data(withJSONObject: ["date": object["date"]!])
        let received = try JSONDecoder().decode(SleepDeadline.self, from: legacy)
        #expect(received.date == deadline.date)
    }
    @Test func transportRoundTripsDeletionAndPlayerCommand() throws {
        var record = MoodRecord(mood: 1, stress: 5, note: "离线记录", createdAt: date(19))
        record.isDeleted = true
        let payload = SyncPayload(record: record)
        #expect(try JSONDecoder().decode(SyncPayload.self, from: JSONEncoder().encode(payload)) == payload)
        let command = AudioCommand(action: .timer, amount: 30)
        #expect(try JSONDecoder().decode(AudioCommand.self, from: JSONEncoder().encode(command)) == command)
    }
    @Test func staleReceiptCannotConfirmNewerDeletion() {
        let original = MoodRecord(mood: 3, stress: 2, note: "", createdAt: date(18))
        let receipt = SyncReceipt(record: original)
        var deleted = original
        deleted.updatedAt = date(19)
        deleted.isDeleted = true
        #expect(receipt.matches(original))
        #expect(!receipt.matches(deleted))
    }
}
