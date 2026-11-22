import Foundation
import Testing
@testable import QingkongCore

struct SleepSummaryTests {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    func date(_ day: Int, _ hour: Int, calendar: Calendar? = nil, month: Int = 1) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    func sample(_ startDay: Int, _ startHour: Int, _ endDay: Int, _ endHour: Int, stage: SleepStage = .core, source: String = "Watch") -> SleepSample {
        SleepSample(start: date(startDay, startHour), end: date(endDay, endHour), stage: stage, source: source)
    }

    @Test func clipsTheNightWindowAndMergesOverlappingSleepAcrossSources() throws {
        let samples = [
            sample(1, 17, 1, 20), sample(1, 19, 2, 1, stage: .deep),
            sample(2, 11, 2, 13, stage: .asleepUnspecified, source: "Phone"),
            sample(2, 1, 2, 11, stage: .awake, source: "Awake source"),
            sample(1, 18, 2, 12, stage: .inBed, source: "Bed source")
        ]
        let night = try #require(SleepSummaryMath.night(samples: samples, endingOn: date(2, 15), calendar: calendar))
        #expect(night.endingOn == date(2, 0))
        #expect(night.window == DateInterval(start: date(1, 18), end: date(2, 12)))
        #expect(night.intervals == [DateInterval(start: date(1, 18), end: date(2, 1)), DateInterval(start: date(2, 11), end: date(2, 12))])
        #expect(night.asleepSeconds == 28_800)
        #expect(night.sources == ["Watch", "Phone"])
        #expect(night.latestSampleEnd == date(2, 13))
    }

    @Test func repeatedSamplesAndAdjacentStagesNeverCountTimeTwice() throws {
        let first = sample(1, 22, 2, 1)
        let samples = [first, first, sample(2, 1, 2, 2, stage: .rem), sample(2, 0, 2, 3, stage: .deep)]
        let night = try #require(SleepSummaryMath.night(samples: samples, endingOn: date(2, 0), calendar: calendar))
        #expect(night.asleepSeconds == 18_000)
        #expect(night.intervals == [DateInterval(start: date(1, 22), end: date(2, 3))])
    }

    @Test func awakeInBedInvalidAndOutsideSamplesDoNotInventSleep() {
        let samples = [sample(1, 18, 2, 12, stage: .awake), sample(1, 18, 2, 12, stage: .inBed),
                       sample(1, 15, 1, 18), sample(2, 12, 2, 14), sample(2, 5, 2, 4), sample(2, 4, 2, 4)]
        #expect(SleepSummaryMath.night(samples: samples, endingOn: date(2, 0), calendar: calendar) == nil)
        #expect(SleepSummaryMath.week(samples: samples, weekStarting: date(2, 0), calendar: calendar) == nil)
        #expect(SleepSummaryMath.night(samples: [], endingOn: date(2, 0), calendar: calendar) == nil)
    }

    @Test func windowAndSleepDurationsFollowDaylightSavingRatherThanFixedHourCounts() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let spring = SleepSample(start: date(7, 22, calendar: local, month: 3), end: date(8, 6, calendar: local, month: 3), stage: .asleepUnspecified, source: "Watch")
        let springNight = try #require(SleepSummaryMath.night(samples: [spring], endingOn: date(8, 0, calendar: local, month: 3), calendar: local))
        #expect(springNight.window.duration == 61_200)
        #expect(springNight.asleepSeconds == 25_200)
        let fall = SleepSample(start: date(31, 22, calendar: local, month: 10), end: date(1, 6, calendar: local, month: 11), stage: .core, source: "Watch")
        let fallNight = try #require(SleepSummaryMath.night(samples: [fall], endingOn: date(1, 0, calendar: local, month: 11), calendar: local))
        #expect(fallNight.window.duration == 68_400)
        #expect(fallNight.asleepSeconds == 32_400)
    }

    @Test func weeklyAverageUsesOnlyRecordedNightsAndExcludesTheNextWeek() throws {
        let samples = [sample(1, 23, 2, 5), sample(3, 22, 4, 6), sample(8, 20, 9, 6)]
        let week = try #require(SleepSummaryMath.week(samples: samples, weekStarting: date(2, 15), calendar: calendar))
        #expect(week.nights.map(\.endingOn) == [date(2, 0), date(4, 0)])
        #expect(week.recordedNightCount == 2)
        #expect(week.totalAsleepSeconds == 50_400)
        #expect(week.averageAsleepSeconds == 25_200)
    }

    @Test func sleepStagesAndLocalSamplesRoundTripWithTheirSources() throws {
        let samples = [sample(1, 22, 2, 5, stage: .deep, source: "Apple Watch")]
        #expect(try JSONDecoder().decode([SleepSample].self, from: JSONEncoder().encode(samples)) == samples)
        let night = try #require(SleepSummaryMath.night(samples: samples, endingOn: date(2, 0), calendar: calendar))
        #expect(try JSONDecoder().decode(SleepNightSummary.self, from: JSONEncoder().encode(night)) == night)
        #expect(SleepStage.allCases.filter(\.isAsleep) == [.asleepUnspecified, .core, .deep, .rem])
    }
}
