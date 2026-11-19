import Foundation
import Testing
@testable import QingkongCore

struct RelaxationReminderTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 14))! }
    func reading(_ date: Date, _ value: Double, source: String = "Watch") -> HealthReading {
        HealthReading(metric: .hrv, date: date, value: value, source: source)
    }
    var baseline: [HealthReading] {
        (1...3).map { reading(calendar.date(byAdding: .day, value: -$0, to: now)!, 50) }
    }
    var low: [HealthReading] { [reading(now.addingTimeInterval(-1200), 34), reading(now.addingTimeInterval(-60), 35)] }
    func state() -> RelaxationReminderState { RelaxationReminderState(now: now.addingTimeInterval(-3600)) }
    func candidate(_ readings: [HealthReading], _ state: RelaxationReminderState? = nil, at: Date? = nil) -> RelaxationReminderCandidate? {
        RelaxationReminderPolicy.candidate(readings: readings, state: state ?? self.state(), now: at ?? now, calendar: calendar)
    }

    @Test func enabledByDefaultAndPersistsDisabledState() throws {
        var value = state()
        #expect(value.enabled)
        value.setEnabled(false, now: now)
        let restored = try JSONDecoder().decode(RelaxationReminderState.self, from: JSONEncoder().encode(value))
        #expect(!restored.enabled)
        #expect(candidate(baseline + low, restored) == nil)
    }
    @Test func sustainedLargeDropProducesCandidate() throws {
        let samples = baseline + low
        let result = try #require(candidate(samples))
        #expect(result.sampleID == samples.last!.id)
        #expect(result.baseline == 50)
    }
    @Test func smallDropSingleSampleRecoveryAndShortIntervalDoNotNotify() {
        #expect(candidate(baseline + low.map { reading($0.date, 36) }) == nil)
        #expect(candidate(baseline + [low[0]]) == nil)
        #expect(candidate(baseline + [low[0], reading(now.addingTimeInterval(-60), 48)]) == nil)
        #expect(candidate(baseline + [reading(now.addingTimeInterval(-300), 30), low[1]]) == nil)
    }
    @Test func insufficientOrMixedSourceBaselineCannotNotify() {
        #expect(candidate(Array(baseline.prefix(2)) + low) == nil)
        #expect(candidate(baseline + low.map { reading($0.date, $0.value, source: "Other") }) == nil)
        #expect(candidate(baseline + [low[0], reading(low[1].date, 30, source: "Other")]) == nil)
    }
    @Test func repeatedUUIDsAreNotIndependentEvidence() {
        let original = low[0]
        var duplicate = original
        duplicate.date = now.addingTimeInterval(-60)
        #expect(candidate(baseline + [original, duplicate]) == nil)
    }
    @Test func oldFutureInvalidAndPreActivationSamplesDoNotNotify() {
        #expect(candidate(baseline + low, at: now.addingTimeInterval(3600)) == nil)
        #expect(candidate(baseline + [reading(now.addingTimeInterval(60), 20)]) == nil)
        #expect(candidate(baseline + [reading(low[0].date, .nan), low[1]]) == nil)
        var value = state()
        value.setEnabled(false, now: now.addingTimeInterval(-30))
        value.setEnabled(true, now: now)
        #expect(candidate(baseline + low, value) == nil)
    }
    @Test func mutedDaySuppressesAndConsumedSamplesAreNotReplayed() {
        var value = state()
        value.mutedUntil = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        #expect(candidate(baseline + low, value) == nil)
        value.mutedUntil = nil
        value.consume(through: low[1].date)
        #expect(candidate(baseline + low, value) == nil)
    }
    @Test func successfulDeliverySurvivesRelaunchAndEnforcesCooldownAndDailyLimit() throws {
        let readings = baseline + low
        var value = state()
        let first = try #require(candidate(readings, value))
        value.recordDelivery(first, now: now)
        value = try JSONDecoder().decode(RelaxationReminderState.self, from: JSONEncoder().encode(value))
        #expect(candidate(readings, value) == nil)
        let later = now.addingTimeInterval(3 * 3600)
        let laterReadings = baseline + [reading(later.addingTimeInterval(-1200), 30), reading(later.addingTimeInterval(-60), 30)]
        #expect(candidate(laterReadings, value, at: later) == nil)
        let next = now.addingTimeInterval(4 * 3600)
        let nextReadings = baseline + [reading(next.addingTimeInterval(-1200), 30), reading(next.addingTimeInterval(-60), 30)]
        value.recordDelivery(try #require(candidate(nextReadings, value, at: next)), now: next)
        let third = now.addingTimeInterval(8 * 3600)
        #expect(candidate(baseline + [reading(third.addingTimeInterval(-1200), 30), reading(third.addingTimeInterval(-60), 30)], value, at: third) == nil)
    }
    @Test func manualHealthEntriesAreDisplayedButCannotTriggerAutomaticReminders() {
        let samples = low.map { sample -> HealthReading in
            var result = sample; result.wasUserEntered = true; return result
        }
        #expect(samples.allSatisfy { $0.isValid })
        #expect(candidate(baseline + samples) == nil)
        let manualBaseline = baseline.map { sample -> HealthReading in
            var result = sample; result.wasUserEntered = true; return result
        }
        #expect(candidate(manualBaseline + low) == nil)
    }
    @Test func sameDisplayNameDoesNotMixDifferentHealthKitSources() {
        let history = baseline.map { sample -> HealthReading in
            var result = sample; result.sourceIdentifier = "source.one"; return result
        }
        let recent = low.map { sample -> HealthReading in
            var result = sample; result.sourceIdentifier = "source.two"; return result
        }
        #expect(candidate(history + recent) == nil)
        #expect(candidate(history + recent.map { sample in
            var result = sample; result.sourceIdentifier = "source.one"; return result
        }) != nil)
    }
    @Test func oldHealthSnapshotsStillDecodeWithoutSourceIdentifier() throws {
        let original = reading(now, 40)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        #expect(object["sourceIdentifier"] == nil)
        let decoded = try JSONDecoder().decode(HealthReading.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == original)
    }
    @Test func mutedDayExpiresAtStoredDeadlineEvenWhenTimeZoneChanges() {
        var value = state()
        value.mutedUntil = now.addingTimeInterval(1)
        #expect(candidate(baseline + low, value) == nil)
        #expect(candidate(baseline + low, value, at: now.addingTimeInterval(2)) != nil)
    }
    @Test func baselineGivesEachCalendarDayEqualWeightAndIgnoresToday() throws {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let history = [reading(yesterday, 20), reading(yesterday.addingTimeInterval(-3600), 60),
                       reading(calendar.date(byAdding: .day, value: -2, to: now)!, 50),
                       reading(calendar.date(byAdding: .day, value: -3, to: now)!, 90)]
        let result = try #require(candidate(history + [reading(now.addingTimeInterval(-7200), 200)] + low))
        #expect(result.baseline == 60)
    }
    @Test func dailyCountResetsAtLocalMidnightButCooldownDoesNot() {
        var value = state()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        value.deliveries = [yesterday, yesterday.addingTimeInterval(3600)]
        #expect(candidate(baseline + low, value) != nil)
        value.deliveries = [now.addingTimeInterval(-1800)]
        #expect(candidate(baseline + low, value) == nil)
        var other = calendar
        other.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        value.deliveries = []
        value.mutedUntil = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        #expect(RelaxationReminderPolicy.candidate(readings: baseline + low, state: value, now: now, calendar: other) == nil)
    }
}
