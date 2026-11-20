import Foundation
import Testing
@testable import QingkongCore

struct DumplingTests {
    let now = Date(timeIntervalSince1970: 1_795_200_000)

    @Test func moodSummaryUsesLatestLiveRecordAndIgnoresFuture() {
        let older = MoodRecord(mood: 2, stress: 5, note: "私密日记", createdAt: now.addingTimeInterval(-100))
        var removed = MoodRecord(mood: 5, stress: 1, note: "", createdAt: now.addingTimeInterval(-10))
        removed.isDeleted = true
        let future = MoodRecord(mood: 1, stress: 4, note: "", createdAt: now.addingTimeInterval(10))
        let summary = MoodSummary.latest(in: [future, removed, older], now: now)
        #expect(summary?.value == 2)
        #expect(summary?.date == older.createdAt)
        #expect(MoodSummary.latest(in: [removed, future], now: now) == nil)
    }

    @Test func snapshotContainsOnlyMoodValueAndTimeAndDecodesOldVersion() throws {
        let record = MoodRecord(mood: 4, stress: 5, note: "不能出现在组件摘要", createdAt: now)
        let snapshot = ComplicationSnapshot(generatedAt: now, readings: [], trends: [:], preferences: Preferences(), mood: MoodSummary.latest(in: [record], now: now))
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mood = try #require(object["mood"] as? [String: Any])
        #expect(Set(mood.keys) == Set(["value", "date"]))
        #expect(try JSONDecoder().decode(ComplicationSnapshot.self, from: data).mood?.value == 4)
        var legacy = object
        legacy.removeValue(forKey: "mood")
        #expect(try JSONDecoder().decode(ComplicationSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)).mood == nil)
    }

    @Test func invalidSummaryCannotSelectMissingArtwork() throws {
        let bad = Data("{\"value\":99,\"date\":0}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MoodSummary.self, from: bad) }
    }

    @Test func motionPlaysOnceAndReturnsToRest() {
        #expect(DumplingMotion.progress(elapsed: 0) == 0)
        #expect(DumplingMotion.progress(elapsed: 1.5) == 0.5)
        #expect(DumplingMotion.progress(elapsed: 3) == 0)
        #expect(DumplingMotion.progress(elapsed: 20) == 0)
        #expect(DumplingMotion.progress(elapsed: -1) == 0)
        #expect(DumplingMotion.progress(elapsed: .nan) == 0)
    }
}
