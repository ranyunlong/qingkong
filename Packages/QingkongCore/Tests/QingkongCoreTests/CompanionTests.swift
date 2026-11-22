import Foundation
import Testing
@testable import QingkongCore

struct CompanionTests {
    @Test func practiceRetainsLocalHeartRateWhenFeedbackChangesAndReadsLegacyRecords() throws {
        let heartRate = HealthReading(metric: .heartRate, date: start.addingTimeInterval(58), value: 68, source: "Apple Watch")
        var record = RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: start, completedAt: start.addingTimeInterval(60), finalHeartRate: heartRate)
        record.feedback = .better
        let encoded = try JSONEncoder().encode(record)
        let restored = try JSONDecoder().decode(RelaxationRecord.self, from: encoded)
        #expect(restored.finalHeartRate == heartRate)
        #expect(restored.feedback == .better)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "finalHeartRate")
        let oldRecord = try JSONDecoder().decode(RelaxationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(oldRecord.finalHeartRate == nil)
        #expect(oldRecord.id == record.id)
    }

    @Test func relaxationHeartRateOnlyUsesValidSamplesFromThisSession() {
        let end = start.addingTimeInterval(60)
        let samples: [HealthReading] = [
            .init(metric: .heartRate, date: start.addingTimeInterval(-1), value: 80, source: "Watch"),
            .init(metric: .heartRate, date: start.addingTimeInterval(12), value: 72, source: "Watch"),
            .init(metric: .heartRate, date: start.addingTimeInterval(58), value: 68, source: "Watch"),
            .init(metric: .heartRate, date: end, value: .nan, source: "Watch"),
            .init(metric: .oxygen, date: end, value: 98, source: "Watch"),
            .init(metric: .heartRate, date: end.addingTimeInterval(1), value: 90, source: "Watch")
        ]
        #expect(RelaxationHeartRate.latest(in: samples, startedAt: start, endedAt: end)?.value == 68)
        #expect(RelaxationHeartRate.latest(in: [samples[0]], startedAt: start, endedAt: end) == nil)
        #expect(RelaxationHeartRate.latest(in: samples, startedAt: end, endedAt: start) == nil)
        let decrease = RelaxationHeartRate.decreaseFraction(in: samples, startedAt: start, endedAt: end)
        #expect(abs((decrease ?? 0) - 4.0 / 72) < 0.0001)
        #expect(RelaxationHeartRate.decreaseFraction(in: [samples[2]], startedAt: start, endedAt: end) == nil)
    }

    @Test func breathingHapticsFollowTheSessionAndStopWhenUnavailable() {
        var session = RelaxationSession(duration: .oneMinute, mode: .breathing)
        #expect(session.hapticCue(at: start) == nil)
        session.start(at: start)
        #expect(session.hapticCue(at: start)?.kind == .inhale)
        #expect(session.hapticCue(at: start.addingTimeInterval(1))?.kind == .pulse)
        #expect(session.hapticCue(at: start.addingTimeInterval(3.9))?.id == 3)
        #expect(session.hapticCue(at: start.addingTimeInterval(4))?.kind == .exhale)
        #expect(session.hapticCue(at: start.addingTimeInterval(9.9))?.id == 4)
        #expect(session.hapticCue(at: start.addingTimeInterval(10))?.id == 5)
        session.pause(at: start.addingTimeInterval(12))
        #expect(session.hapticCue(at: start.addingTimeInterval(13)) == nil)
        session.resume(at: start.addingTimeInterval(20))
        session.hapticsEnabled = false
        #expect(session.hapticCue(at: start.addingTimeInterval(21)) == nil)
        session.hapticsEnabled = true
        #expect(session.hapticCue(at: start.addingTimeInterval(100)) == nil)
        session.exit(at: start.addingTimeInterval(21))
        #expect(session.hapticCue(at: start.addingTimeInterval(22)) == nil)
        var quiet = RelaxationSession(duration: .oneMinute, mode: .quiet)
        quiet.start(at: start)
        #expect(quiet.hapticCue(at: start) == nil)
    }

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    @Test func delayedUpdatesFinishAtTheRealDeadline() throws {
        var session = RelaxationSession(duration: .oneMinute, mode: .breathing)
        #expect(session.status == .ready)
        #expect(session.completedRecord() == nil)
        session.start(at: start)
        #expect(session.remaining(at: start.addingTimeInterval(15.5)) == 44.5)
        session.update(at: start.addingTimeInterval(95))
        #expect(session.status == .completed)
        let record = try #require(session.completedRecord())
        #expect(record.completedAt == start.addingTimeInterval(60))
        #expect(record.practicedSeconds == 60)
        #expect(record.feedback == nil)
    }

    @Test func repeatedPauseResumeExcludesPausedTimeAndKeepsFractions() throws {
        var session = RelaxationSession(duration: .threeMinutes, mode: .quiet)
        session.start(at: start)
        session.pause(at: start.addingTimeInterval(12.25))
        #expect(session.remaining(at: start.addingTimeInterval(5_000)) == 167.75)
        session.pause(at: start.addingTimeInterval(100))
        session.resume(at: start.addingTimeInterval(112.25))
        session.resume(at: start.addingTimeInterval(120))
        session.pause(at: start.addingTimeInterval(122.75))
        #expect(session.elapsed(at: start.addingTimeInterval(1_000)) == 22.75)
        session.resume(at: start.addingTimeInterval(222.75))
        #expect(session.deadline == start.addingTimeInterval(380))
        session.update(at: start.addingTimeInterval(400))
        let record = try #require(session.completedRecord(feedback: .same))
        #expect(record.completedAt == start.addingTimeInterval(380))
        #expect(record.practicedSeconds == 180)
        #expect(record.feedback == .same)
    }

    @Test func exitNeverCreatesACompletedPracticeEvenAfterAnUnobservedDeadline() {
        for offset in [20.0, 80.0] {
            var session = RelaxationSession(duration: .oneMinute, mode: .quiet)
            session.start(at: start)
            session.exit(at: start.addingTimeInterval(offset))
            session.update(at: start.addingTimeInterval(1_000))
            session.start(at: start.addingTimeInterval(1_000))
            session.resume(at: start.addingTimeInterval(1_000))
            #expect(session.status == .exited)
            #expect(session.completedRecord() == nil)
        }
    }

    @Test func quietModeHasNoBreathingPromptAndBreathingHasNoHoldPhase() {
        var breathing = RelaxationSession(duration: .fiveMinutes, mode: .breathing)
        breathing.start(at: start)
        #expect(breathing.phase(at: start) == .inhale)
        #expect(breathing.phase(at: start.addingTimeInterval(4)) == .exhale)
        #expect(breathing.phase(at: start.addingTimeInterval(10)) == .inhale)
        breathing.pause(at: start.addingTimeInterval(4))
        #expect(breathing.phase(at: start.addingTimeInterval(100)) == .exhale)
        var quiet = RelaxationSession(duration: .oneMinute, mode: .quiet)
        quiet.start(at: start)
        #expect(quiet.phase(at: start.addingTimeInterval(4)) == .quiet)
        #expect(RelaxationDuration.allCases.map(\.seconds) == [60, 180, 300])
    }

    @Test func restoredPausedSessionRetainsItsRealElapsedTimeAndOptions() throws {
        var session = RelaxationSession(duration: .fiveMinutes, mode: .breathing, guidanceSoundEnabled: false, hapticsEnabled: false)
        session.start(at: start)
        session.pause(at: start.addingTimeInterval(43.5))
        var restored = try JSONDecoder().decode(RelaxationSession.self, from: JSONEncoder().encode(session))
        #expect(restored.remaining(at: start.addingTimeInterval(10_000)) == 256.5)
        #expect(!restored.guidanceSoundEnabled)
        #expect(!restored.hapticsEnabled)
        restored.resume(at: start.addingTimeInterval(1_000))
        restored.update(at: start.addingTimeInterval(1_256.5))
        let record = try #require(restored.completedRecord(feedback: .better))
        #expect(try JSONDecoder().decode(RelaxationRecord.self, from: JSONEncoder().encode(record)) == record)
        #expect(record.id == session.id)
    }

    @Test func clockMovingBackwardsDoesNotAddPracticeTime() {
        var session = RelaxationSession(duration: .oneMinute, mode: .breathing)
        session.start(at: start)
        #expect(session.elapsed(at: start.addingTimeInterval(-100)) == 0)
        session.pause(at: start.addingTimeInterval(-100))
        #expect(session.elapsed(at: start) == 0)
        session.resume(at: start)
        session.update(at: start.addingTimeInterval(59))
        #expect(session.status == .running)
        #expect(session.remaining(at: start.addingTimeInterval(59)) == 1)
    }

    @Test func lifeTagsAreOptionalStableLocalValues() throws {
        #expect(LifeTag.allCases.map(\.rawValue) == ["work", "family", "exercise", "social", "coffee", "alcohol"])
        #expect(try JSONDecoder().decode([LifeTag].self, from: JSONEncoder().encode([LifeTag.work, .coffee])) == [.work, .coffee])
    }

    @Test func completedSessionIgnoresFurtherLifecycleCommands() throws {
        var session = RelaxationSession(duration: .oneMinute, mode: .quiet)
        session.start(at: start)
        session.update(at: start.addingTimeInterval(60))
        let original = try #require(session.completedRecord())
        session.exit(at: start.addingTimeInterval(61))
        session.pause(at: start.addingTimeInterval(62))
        session.resume(at: start.addingTimeInterval(63))
        #expect(session.completedRecord() == original)
    }

    @Test func timelineCombinesRealEventsWithSamplingAndSubmissionSemantics() throws {
        let mood = MoodRecord(mood: 3, stress: 2, note: "本地", createdAt: start)
        var deleted = MoodRecord(mood: 1, stress: 5, note: "已删除", createdAt: start)
        deleted.isDeleted = true
        let health = HealthChangeSummary(metric: .hrv, sampleDate: start.addingTimeInterval(-300), observedAt: start.addingTimeInterval(20), value: 25, referenceValue: 40, source: "Apple Watch")
        let submission = ReminderSubmissionRecord(kind: .hrv, sampleDate: health.sampleDate, submittedAt: start.addingTimeInterval(30))
        let practice = RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: start, completedAt: start.addingTimeInterval(60))
        let items = CompanionTimeline.items(moods: [mood, deleted], healthChanges: [health], reminderSubmissions: [submission], practices: [practice])
        #expect(items.map(\.date) == [practice.completedAt, submission.submittedAt, health.observedAt, mood.createdAt])
        #expect(items.count == 4)
        #expect(Set(items.map(\.id)).count == 4)
        #expect(health.interpretationNotice.contains("不用于诊断"))
        #expect(health.interpretationNotice.contains("因果"))
        #expect(submission.statusText == "提醒已提交")
        #expect(try JSONDecoder().decode([CompanionTimelineItem].self, from: JSONEncoder().encode(items)) == items)
    }

    @Test func weeklyReviewCountsActualLocalDaysAndObservedDistributionsOnly() {
        let weekStart = calendar.startOfDay(for: start)
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        var deleted = MoodRecord(mood: 5, stress: 5, note: "", createdAt: weekStart.addingTimeInterval(100))
        deleted.isDeleted = true
        let moods = [
            MoodRecord(mood: 2, stress: 4, note: "", createdAt: weekStart.addingTimeInterval(10)),
            MoodRecord(mood: 2, stress: 3, note: "", createdAt: weekStart.addingTimeInterval(20)),
            MoodRecord(mood: 4, stress: 3, note: "", createdAt: weekStart.addingTimeInterval(86_410)),
            MoodRecord(mood: 5, stress: 1, note: "", createdAt: end), deleted
        ]
        let practices = [RelaxationRecord(duration: .threeMinutes, mode: .quiet, startedAt: weekStart.addingTimeInterval(172_800), completedAt: weekStart.addingTimeInterval(172_980))]
        let review = WeeklyCompanionReview(weekStarting: weekStart, moods: moods, practices: practices, calendar: calendar)
        #expect(review.recordedDayCount == 3)
        #expect(review.moodRecordDayCount == 2)
        #expect(review.moodDistribution == [2: 2, 4: 1])
        #expect(review.stressDistribution == [4: 1, 3: 2])
        #expect(review.practiceCount == 1)
        #expect(review.practicedSeconds == 180)
        #expect(review.hasData)
    }

    @Test func emptyWeeklyReviewDoesNotFillMissingMoodsOrPractices() {
        let review = WeeklyCompanionReview(weekStarting: start, moods: [], practices: [], calendar: calendar)
        #expect(!review.hasData)
        #expect(review.recordedDayCount == 0)
        #expect(review.moodDistribution.isEmpty)
        #expect(review.stressDistribution.isEmpty)
        #expect(review.message == "这一周还没有记录，按自己的节奏开始就好。")
    }

    @Test func bedtimePlanRoundTripsAndBuildsAnAbsoluteStopDeadline() throws {
        let plan = BedtimePlan(name: "我的睡前", track: .rain, scene: .night, stopAfterMinutes: 30)
        let restored = try JSONDecoder().decode(BedtimePlan.self, from: JSONEncoder().encode(plan))
        #expect(restored == plan)
        #expect(restored.makeDeadline(at: start).date == start.addingTimeInterval(1_800))
        #expect(restored.makeDeadline(at: start).remaining(at: start.addingTimeInterval(1_200)) == 600)
    }

    @Test func basicActionIsAlwaysAvailableWithoutRecords() {
        #expect(CompanionActionAvailability(moods: [], practices: [], now: start).actions == [.greeting])
        var deleted = MoodRecord(mood: 4, stress: 1, note: "", createdAt: start)
        deleted.isDeleted = true
        let future = MoodRecord(mood: 4, stress: 1, note: "", createdAt: start.addingTimeInterval(1))
        #expect(CompanionActionAvailability(moods: [deleted, future], practices: [], now: start).actions == [.greeting])
    }

    @Test func firstMoodUnlocksANodWithoutRequiringDailyRecordsOrPositiveMood() {
        let record = MoodRecord(mood: 1, stress: 5, note: "", createdAt: start.addingTimeInterval(-365 * 86_400))
        let first = CompanionActionAvailability(moods: [record], practices: [], now: start)
        let later = CompanionActionAvailability(moods: [record], practices: [], now: start.addingTimeInterval(365 * 86_400))
        #expect(first.actions == [.greeting, .nod])
        #expect(later.actions == first.actions)
    }

    @Test func onlyACompletedPracticeUnlocksTheGentleSwayAndFeedbackIsOptional() {
        let completed = RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: start.addingTimeInterval(-60), completedAt: start)
        let incomplete = RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: start.addingTimeInterval(-20), completedAt: start)
        let future = RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: start, completedAt: start.addingTimeInterval(60))
        #expect(CompanionActionAvailability(moods: [], practices: [incomplete, future], now: start).actions == [.greeting])
        #expect(CompanionActionAvailability(moods: [], practices: [completed], now: start).actions == [.greeting, .sway])
    }

    @Test func bothMilestonesUnlockTwoDistinctReplayableActionsInStableOrder() {
        let mood = MoodRecord(mood: 3, stress: 2, note: "", createdAt: start)
        let practice = RelaxationRecord(duration: .oneMinute, mode: .breathing, startedAt: start.addingTimeInterval(-60), completedAt: start)
        let available = CompanionActionAvailability(moods: [mood, mood], practices: [practice, practice], now: start)
        #expect(available.actions == [.greeting, .nod, .sway])
        #expect(CompanionAction.nod.transform(elapsed: CompanionAction.nod.duration / 2).offsetY > 0)
        #expect(CompanionAction.sway.transform(elapsed: CompanionAction.sway.duration / 4).rotationDegrees > 0)
        #expect(CompanionAction.sway.transform(elapsed: CompanionAction.sway.duration / 4).offsetX > 0)
    }

    @Test func everyActionStopsAtRestAndReduceMotionDisablesAllMovement() {
        for action in CompanionAction.allCases {
            #expect(action.transform(elapsed: 0) == .rest)
            #expect(action.transform(elapsed: action.duration) == .rest)
            #expect(action.transform(elapsed: action.duration + 100) == .rest)
            #expect(action.transform(elapsed: -1) == .rest)
            #expect(action.transform(elapsed: .nan) == .rest)
            #expect(action.transform(elapsed: .infinity) == .rest)
            #expect(action.transform(elapsed: action.duration / 4, reduceMotion: true) == .rest)
        }
    }


    @Test func rememberedFirstMilestonesRemainAvailableAfterSourceRecordsAreDeleted() {
        let remembered = CompanionActionAvailability(moods: [], practices: [], now: start, rememberedActions: [.nod, .sway])
        #expect(remembered.actions == [.greeting, .nod, .sway])
    }

    @Test func newExpressionsAndSceneryRequireOnlyTheTwoExistingLocalMilestones() {
        let fresh = CompanionCollectionAvailability(actions: [.greeting])
        #expect(fresh.expressions.isEmpty)
        #expect(fresh.scenery.isEmpty)
        let mood = CompanionCollectionAvailability(actions: [.greeting, .nod])
        #expect(mood.expressions == [.gentleSmile])
        #expect(mood.scenery == [.morningMeadow])
        let practice = CompanionCollectionAvailability(actions: [.greeting, .sway])
        #expect(practice.expressions == [.brightEyes])
        #expect(practice.scenery == [.moonlitLake])
    }

    @Test func collectionOrderIsStableAndRememberedUnlocksSurviveDeletingRecords() {
        let actions = CompanionActionAvailability(moods: [], practices: [], now: start, rememberedActions: [.sway, .nod, .nod]).actions
        let collection = CompanionCollectionAvailability(actions: actions.reversed() + actions)
        #expect(collection.expressions == CompanionExpression.allCases)
        #expect(collection.scenery == CompanionScenery.allCases)
        #expect(CompanionExpression.gentleSmile.requiredAction == .nod)
        #expect(CompanionExpression.brightEyes.requiredAction == .sway)
        #expect(CompanionScenery.morningMeadow.requiredAction == .nod)
        #expect(CompanionScenery.moonlitLake.requiredAction == .sway)
    }

    @Test func aDifficultMoodUnlocksTheSameCollectionWithoutStreaksOrScores() {
        let low = MoodRecord(mood: 1, stress: 5, note: "", createdAt: start.addingTimeInterval(-365 * 86_400))
        let high = MoodRecord(mood: 5, stress: 1, note: "", createdAt: start)
        let lowActions = CompanionActionAvailability(moods: [low], practices: [], now: start).actions
        let highActions = CompanionActionAvailability(moods: [high], practices: [], now: start).actions
        #expect(CompanionCollectionAvailability(actions: lowActions) == CompanionCollectionAvailability(actions: highActions))
    }

}
