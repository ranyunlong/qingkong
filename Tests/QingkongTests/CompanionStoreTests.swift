import XCTest
import QingkongCore
@testable import Qingkong

final class CompanionStoreTests: XCTestCase {
    @MainActor
    func testStopDeadlineRestoresWithoutAutoplayAndKeepsOriginalDate() throws {
        let suite = "qingkong.audio-deadline-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer(defaultsOverride: defaults)
        player.setTimer(minutes: 30)
        let expected = try XCTUnwrap(player.state.deadline?.date)
        let restored = AudioPlayer(defaultsOverride: defaults)
        XCTAssertEqual(restored.state.deadline?.date, expected)
        XCTAssertFalse(restored.state.playing)
        restored.setTimer(minutes: 0)
        XCTAssertNil(AudioPlayer(defaultsOverride: defaults).state.deadline)
        player.setTimer(minutes: 0)
    }

    @MainActor
    func testCompletedPracticeSurvivesReloadAndDeletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CompanionStore(url: url)
        let reading = HealthReading(metric: .heartRate, date: Date(timeIntervalSince1970: 158), value: 68, source: "Apple Watch")
        var record = RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: Date(timeIntervalSince1970: 100), completedAt: Date(timeIntervalSince1970: 160), finalHeartRate: reading)
        try store.savePractice(record)
        record.feedback = .better
        try store.savePractice(record)
        XCTAssertEqual(try CompanionStore(url: url).practices, [record])
        XCTAssertEqual(try CompanionStore(url: url).practices.first?.finalHeartRate, reading)
        try store.deletePractice(record.id)
        XCTAssertTrue(try CompanionStore(url: url).practices.isEmpty)
    }

    @MainActor
    func testDeletedTimelineSummaryDoesNotReappearAfterRefresh() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try CompanionStore(url: url)
        let event = LocalTimelineEvent(id: "sample", date: .now, title: "HRV 日均", detail: "实际采样摘要", kind: .health)
        try store.saveEvent(event)
        try store.deleteEvent(event.id)
        try store.saveEvent(event)
        XCTAssertTrue(try CompanionStore(url: url).events.isEmpty)
    }

    @MainActor
    func testCorruptArchiveIsNotSilentlyReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try CompanionStore(url: url))
        XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
    }
}
