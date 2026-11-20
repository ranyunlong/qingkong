import XCTest
import UserNotifications
import QingkongCore
@testable import Qingkong

final class ServiceTests: XCTestCase {
    @MainActor
    func testReminderCheckSurvivesServiceRecreationWithoutSendingNotification() async throws {
        let suite = "qingkong.reminder-history-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let center = UNUserNotificationCenter.current()
        let previousDelegate = center.delegate
        defer {
            center.delegate = previousDelegate
            defaults.removePersistentDomain(forName: suite)
        }
        let service = RelaxationReminderService(defaultsOverride: defaults)
        await service.evaluate(readings: [], isDemo: false)
        let checkedAt = try XCTUnwrap(service.lastCheckedAt)
        XCTAssertEqual(service.checkResults["hrv"], "暂无可读取的自动 HRV 记录")
        let restored = RelaxationReminderService(defaultsOverride: defaults)
        XCTAssertEqual(restored.lastCheckedAt, checkedAt)
        XCTAssertEqual(restored.checkResults, service.checkResults)
        XCTAssertNil(restored.lastSubmittedAt, "没有健康记录不能提交健康提醒")
        XCTAssertTrue(restored.state.deliveries.isEmpty)
    }

    @MainActor
    func testOfflineRecordAndDeletionRemainPendingAfterReopening() throws {
        let store = try LocalStore(testing: true, reset: true)
        try store.add(mood: 4, stress: 2, note: "留在设备上")
        let original = try XCTUnwrap(store.entries.first)
        let reopened = try LocalStore(testing: true)
        XCTAssertEqual(try reopened.pendingRecords(), [original])
        try reopened.delete(original)
        let afterDelete = try LocalStore(testing: true)
        XCTAssertTrue(afterDelete.entries.isEmpty)
        let pending = try XCTUnwrap(afterDelete.pendingRecords().first)
        XCTAssertTrue(pending.isDeleted)
        XCTAssertEqual(pending.note, "")
        try afterDelete.acknowledge(SyncReceipt(record: original))
        XCTAssertEqual(try afterDelete.pendingRecords(), [pending])
        try afterDelete.acknowledge(SyncReceipt(record: pending))
        XCTAssertTrue(try afterDelete.pendingRecords().isEmpty)
    }

    @MainActor
    func testDuplicateAndOldPeerRecordsCannotResurrectDeletion() throws {
        let store = try LocalStore(testing: true, reset: true)
        let original = MoodRecord(mood: 3, stress: 2, note: "离线心情")
        try store.save(original, fromPeer: true)
        try store.save(original, fromPeer: true)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(try store.pendingRecords().isEmpty)
        try store.delete(original)
        try store.save(original, fromPeer: true)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try store.pendingRecords().count, 1)
    }

    @MainActor
    func testAudioCommandsRejectInvalidInputAndTimerSurvivesTrackChange() async {
        let player = AudioPlayer()
        defer { player.setTimer(minutes: 0); player.pause() }
        let timer = await player.handle(AudioCommand(action: .timer, amount: 30))
        XCTAssertNil(timer.error)
        let deadline = timer.state.deadline
        await player.skip(1)
        XCTAssertEqual(player.state.track, .ocean)
        XCTAssertEqual(player.state.deadline, deadline)
        XCTAssertFalse(player.state.playing)
        let invalid = await player.handle(AudioCommand(action: .timer, amount: -1))
        XCTAssertNotNil(invalid.error)
        XCTAssertEqual(player.state.deadline, deadline)
        _ = await player.handle(AudioCommand(action: .timer, amount: 0))
        XCTAssertNil(player.state.deadline)
    }

    @MainActor
    func testPreparingWatchFallbackKeepsOriginalCutoffWithoutStartingPlayback() async {
        let player = AudioPlayer()
        defer { player.setTimer(minutes: 0); player.pause() }
        var source = AudioState()
        source.track = .ocean
        source.volume = 0.3
        source.playing = true
        source.deadline = SleepDeadline(minutes: 30, now: .now.addingTimeInterval(-600))
        await player.prepareForPlayback(source)
        XCTAssertEqual(player.state.track, .ocean)
        XCTAssertEqual(player.state.volume, 0.3)
        XCTAssertEqual(player.state.deadline, source.deadline)
        XCTAssertFalse(player.state.playing, "切换可用设备不应根据旧状态自动开播")
    }

    @MainActor
    func testPreparingFallbackDoesNotRestartExpiredTimer() async {
        let player = AudioPlayer()
        defer { player.setTimer(minutes: 0); player.pause() }
        var source = AudioState()
        source.deadline = SleepDeadline(minutes: 15, now: .now.addingTimeInterval(-3600))
        await player.prepareForPlayback(source)
        XCTAssertNil(player.state.deadline)
        XCTAssertFalse(player.state.playing)
    }

    @MainActor
    func testUnavailablePhoneDoesNotConfirmRemotePlayback() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let player = AudioPlayer()
        let link = Connectivity(store: store, player: player)
        let confirmed = await link.command(.status)
        XCTAssertFalse(confirmed)
        XCTAssertNil(link.remoteState)
        XCTAssertFalse(player.state.playing)
    }

    @MainActor
    func testActualPlaybackStopsAtScheduledDeadline() async throws {
        let player = AudioPlayer()
        defer { player.setTimer(minutes: 0); player.pause() }
        await player.play()
        XCTAssertTrue(player.state.playing, player.error ?? "音频应实际开始播放")
        player.setTimer(minutes: 1)
        try await Task.sleep(for: .seconds(65))
        XCTAssertFalse(player.state.playing)
        XCTAssertNil(player.state.deadline)
    }
}
