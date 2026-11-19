import Foundation
import Testing
@testable import QingkongCore

struct VitalReminderTests {
    let now = Date(timeIntervalSince1970: 1_795_060_800)
    func rule(_ kind: VitalReminderKind) -> VitalReminderRule { .init(kind: kind, now: now.addingTimeInterval(-3600)) }
    func reading(_ kind: VitalReminderKind, _ value: Double, ago: Double, resting: Bool? = true, source: String = "watch") -> HealthReading {
        HealthReading(metric: kind.metric, date: now.addingTimeInterval(-ago), value: value, source: source, sourceIdentifier: source, isAtRest: resting)
    }
    func candidate(_ kind: VitalReminderKind, _ readings: [HealthReading], rule: VitalReminderRule? = nil) -> VitalReminderCandidate? {
        VitalReminderPolicy.assess(kind: kind, readings: readings, rule: rule ?? self.rule(kind), now: now).candidate
    }

    @Test func confirmsEachKindUsingSeparateLimits() {
        for (kind, value) in [(VitalReminderKind.highHeartRate, 130.0), (.lowHeartRate, 45), (.lowOxygen, 88)] {
            #expect(candidate(kind, [reading(kind, value, ago: 1200), reading(kind, value, ago: 60)]) != nil)
        }
    }
    @Test func singleCloseOrRecoveredReadingsDoNotNotify() {
        let kind = VitalReminderKind.highHeartRate
        #expect(candidate(kind, [reading(kind, 130, ago: 60)]) == nil)
        #expect(candidate(kind, [reading(kind, 130, ago: 300), reading(kind, 130, ago: 60)]) == nil)
        #expect(candidate(kind, [reading(kind, 130, ago: 1200), reading(kind, 70, ago: 300), reading(kind, 130, ago: 60)]) == nil)
        #expect(candidate(.lowOxygen, [reading(.lowOxygen, 88, ago: 80), reading(.lowOxygen, 88, ago: 60)]) == nil)
    }
    @Test func exerciseAndUnknownMotionCannotBeTreatedAsRest() {
        for context: Bool? in [false, nil] {
            #expect(candidate(.highHeartRate, [reading(.highHeartRate, 140, ago: 1200, resting: context), reading(.highHeartRate, 140, ago: 60, resting: context)]) == nil)
        }
        let samples = [reading(.highHeartRate, 140, ago: 1200), reading(.highHeartRate, 140, ago: 600, resting: false), reading(.highHeartRate, 140, ago: 60)]
        #expect(candidate(.highHeartRate, samples) == nil)
    }
    @Test func sourcesManualValuesAndDuplicateSamplesDoNotConfirm() {
        let older = reading(.lowOxygen, 88, ago: 1200)
        let latest = reading(.lowOxygen, 88, ago: 60)
        #expect(candidate(.lowOxygen, [older, reading(.lowOxygen, 88, ago: 60, source: "other")]) == nil)
        var manual = latest; manual.wasUserEntered = true
        #expect(candidate(.lowOxygen, [older, manual]) == nil)
        var duplicate = older; duplicate.date = latest.date
        #expect(candidate(.lowOxygen, [older, duplicate]) == nil)
    }
    @Test func staleFutureAndPreEnableReadingsDoNotNotify() {
        #expect(candidate(.lowOxygen, [reading(.lowOxygen, 88, ago: 1600), reading(.lowOxygen, 88, ago: 1000)]) == nil)
        #expect(candidate(.lowOxygen, [reading(.lowOxygen, 88, ago: 1200), reading(.lowOxygen, 88, ago: -60)]) == nil)
        #expect(candidate(.lowOxygen, [reading(.lowOxygen, 88, ago: 1200), reading(.lowOxygen, 88, ago: 60)], rule: .init(kind: .lowOxygen, now: now)) == nil)
    }
    @Test func customThresholdStrictBoundaryAndPersistence() throws {
        var value = rule(.lowOxygen)
        let samples = [reading(.lowOxygen, 91, ago: 1200), reading(.lowOxygen, 91, ago: 60)]
        #expect(candidate(.lowOxygen, samples, rule: value) == nil)
        value.threshold = 92
        let restored = try JSONDecoder().decode(VitalReminderRule.self, from: JSONEncoder().encode(value))
        #expect(candidate(.lowOxygen, samples, rule: restored) != nil)
        #expect(candidate(.lowOxygen, samples.map { var copy = $0; copy.value = 92; return copy }, rule: restored) == nil)
    }
    @Test func eachKindCanBeDisabledPausedAndDeduplicated() throws {
        let samples = [reading(.lowOxygen, 88, ago: 1200), reading(.lowOxygen, 88, ago: 60)]
        var value = rule(.lowOxygen)
        value.delivery.setEnabled(false, now: now.addingTimeInterval(-3600))
        #expect(candidate(.lowOxygen, samples, rule: value) == nil)
        value.delivery.setEnabled(true, now: now.addingTimeInterval(-3600))
        value.delivery.mutedUntil = now.addingTimeInterval(3600)
        #expect(candidate(.lowOxygen, samples, rule: value) == nil)
        value.delivery.mutedUntil = nil
        let result = try #require(candidate(.lowOxygen, samples, rule: value))
        value.recordDelivery(result, now: now)
        #expect(candidate(.lowOxygen, samples, rule: value) == nil)
        let newer = [reading(.lowOxygen, 88, ago: 30), reading(.lowOxygen, 88, ago: 100)]
        #expect(candidate(.lowOxygen, newer, rule: value) == nil)
    }

    @Test func invalidThresholdsAndResetWindowDoNotNotify() {
        let samples = [reading(.lowOxygen, 88, ago: 1200), reading(.lowOxygen, 88, ago: 60)]
        for threshold in [Double.nan, .infinity, 84, 96] {
            var value = rule(.lowOxygen)
            value.threshold = threshold
            #expect(candidate(.lowOxygen, samples, rule: value) == nil)
        }
        var value = rule(.lowOxygen)
        value.delivery.resetWindow(now: now)
        #expect(candidate(.lowOxygen, samples, rule: value) == nil)
    }

    @Test func independentDailyLimitAndNextDayRecovery() {
        let samples = [reading(.lowOxygen, 88, ago: 1200), reading(.lowOxygen, 88, ago: 60)]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        var value = rule(.lowOxygen)
        value.delivery.deliveries = [start.addingTimeInterval(1), start.addingTimeInterval(2)]
        #expect(VitalReminderPolicy.assess(kind: .lowOxygen, readings: samples, rule: value, now: now, calendar: calendar).candidate == nil)
        value.delivery.deliveries = [start.addingTimeInterval(-86400), start.addingTimeInterval(-86400 + 2)]
        #expect(VitalReminderPolicy.assess(kind: .lowOxygen, readings: samples, rule: value, now: now, calendar: calendar).candidate != nil)
        #expect(candidate(.highHeartRate, [reading(.highHeartRate, 130, ago: 1200), reading(.highHeartRate, 130, ago: 60)]) != nil)
    }

    @Test func oldHealthReadingDecodesWithoutMotionMetadata() throws {
        let original = reading(.highHeartRate, 80, ago: 60, resting: nil)
        let decoded = try JSONDecoder().decode(HealthReading.self, from: JSONEncoder().encode(original))
        #expect(decoded.isAtRest == nil)
    }
}
