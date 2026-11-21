import XCTest
import UserNotifications
import WatchConnectivity
import Observation
import QingkongCore
@testable import Qingkong

final class ServiceTests: XCTestCase {
    @MainActor
    func testPhoneAudioPushUpdatesWatchDisplayWithoutStartingLocalPlayer() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let player = AudioPlayer()
        let link = Connectivity(store: store, player: player)
        var phone = AudioState()
        phone.track = .ocean
        phone.playing = true
        let received = expectation(description: "Phone playback status becomes observable")
        withObservationTracking { _ = link.remoteState } onChange: { received.fulfill() }
        let data = try JSONEncoder().encode(AudioReply(id: UUID(), state: phone))
        link.session(WCSession.default, didReceiveMessage: ["audioState": data])
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(link.remoteState?.track, .ocean)
        XCTAssertEqual(link.remoteState?.playing, true)
        XCTAssertFalse(player.state.playing, "同步状态不能在手表启动本地播放")
        XCTAssertEqual(player.state.track, .rain)
    }

    @MainActor
    func testDelayedAudioReplyCannotOverwriteNewerPhonePause() throws {
        let store = try LocalStore(testing: true, reset: true)
        let player = AudioPlayer()
        let link = Connectivity(store: store, player: player)
        let now = Date.now
        var phone = AudioState()
        phone.track = .night
        phone.deadline = SleepDeadline(minutes: 15, now: now)
        link.receiveAudioState(AudioReply(id: UUID(), state: phone, updatedAt: now))
        var old = AudioState()
        old.playing = true
        link.receiveAudioState(AudioReply(id: UUID(), state: old, updatedAt: now.addingTimeInterval(-1)))
        link.receiveAudioState(AudioReply(id: UUID(), state: old, updatedAt: nil))
        XCTAssertEqual(link.remoteState, phone)
        XCTAssertFalse(player.state.playing)
    }

    @MainActor
    func testAudioStateChangesNotifyForTrackTimerAndVolume() async {
        let player = AudioPlayer()
        var updates: [AudioState] = []
        player.didChangeState = { updates.append($0) }
        defer { player.didChangeState = nil; player.setTimer(minutes: 0); player.pause() }
        await player.select(.ocean)
        player.setTimer(minutes: 15)
        player.setVolume(0.7)
        XCTAssertEqual(updates.count, 3)
        guard updates.count == 3 else { return }
        XCTAssertEqual(updates.map(\.track), [.ocean, .ocean, .ocean])
        XCTAssertNil(updates[0].deadline)
        XCTAssertNotNil(updates[1].deadline)
        XCTAssertEqual(updates[2].volume, 0.7)
        let count = updates.count
        player.pause()
        XCTAssertEqual(updates.count, count, "相同播放状态不重复通知")
    }

    @MainActor
    func testForegroundMoodMessageUpdatesObservedRecordBeforeReply() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let link = Connectivity(store: store, player: AudioPlayer())
        let pageOpenedAt = Date.now.addingTimeInterval(-60)
        let previous = MoodRecord(mood: 2, stress: 2, note: "", createdAt: pageOpenedAt.addingTimeInterval(-60))
        try store.save(previous, fromPeer: true)
        let current = MoodRecord(mood: 5, stress: 1, note: "", createdAt: .now.addingTimeInterval(-1))
        let observed = expectation(description: "Foreground view observes incoming mood")
        withObservationTracking {
            _ = MoodSummary.latest(in: store.records)
        } onChange: { observed.fulfill() }
        let replied = expectation(description: "Reply follows persistence")
        link.session(WCSession.default, didReceiveMessage: ["record": try JSONEncoder().encode(SyncPayload(record: current))]) { response in
            MainActor.assumeIsolated {
                XCTAssertEqual(MoodSummary.latest(in: store.records)?.value, 5)
                XCTAssertEqual(MoodSummary.latest(in: store.records, now: pageOpenedAt)?.value, 2,
                               "页面打开时的旧时间会错误排除新收到的心情")
                let receipt = (response["receipt"] as? Data).flatMap { try? JSONDecoder().decode(SyncReceipt.self, from: $0) }
                XCTAssertEqual(receipt, SyncReceipt(record: current))
                XCTAssertTrue((try? store.pendingRecords().isEmpty) == true)
            }
            replied.fulfill()
        }
        await fulfillment(of: [observed, replied], timeout: 2)
    }

    @MainActor
    func testImmediateDeletionAndDelayedDuplicateCannotRestoreMood() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let link = Connectivity(store: store, player: AudioPlayer())
        let original = MoodRecord(mood: 4, stress: 2, note: "", createdAt: .now.addingTimeInterval(-60))
        var deleted = original
        deleted.isDeleted = true
        deleted.updatedAt = original.updatedAt.addingTimeInterval(1)
        for record in [original, deleted, original] {
            let replied = expectation(description: "Saved record acknowledged")
            link.session(WCSession.default, didReceiveMessage: ["record": try JSONEncoder().encode(SyncPayload(record: record))]) { response in
                XCTAssertNotNil(response["receipt"])
                replied.fulfill()
            }
            await fulfillment(of: [replied], timeout: 2)
        }
        XCTAssertNil(MoodSummary.latest(in: store.records))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertTrue(store.records[0].isDeleted)
        let reopened = try LocalStore(testing: true)
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    @MainActor
    func testInvalidImmediateRecordIsNotAcknowledged() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let link = Connectivity(store: store, player: AudioPlayer())
        var payload = SyncPayload(record: MoodRecord(mood: 4, stress: 2, note: ""))
        payload.version = 99
        let replied = expectation(description: "Unsupported payload rejected")
        link.session(WCSession.default, didReceiveMessage: ["record": try JSONEncoder().encode(payload)]) { response in
            XCTAssertNil(response["receipt"])
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertTrue(store.records.isEmpty)
    }

    @MainActor
    func testRecordObserverReceivesLocalPeerAndDeletionChanges() throws {
        let store = try LocalStore(testing: true, reset: true)
        var changes = 0
        store.didChangeRecords = { changes += 1 }
        let local = MoodRecord(mood: 4, stress: 2, note: "本地")
        try store.save(local)
        XCTAssertEqual(changes, 1)
        try store.save(local, fromPeer: true)
        XCTAssertEqual(changes, 1, "重复同步不刷新摘要")
        let peer = MoodRecord(mood: 2, stress: 3, note: "来自配对端")
        try store.save(peer, fromPeer: true)
        XCTAssertEqual(changes, 2)
        try store.delete(peer)
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(MoodSummary.latest(in: store.records)?.value, 4)
    }

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
    func testWatchHandoffStopsPhoneEvaluationAndSurvivesRelaunch() async throws {
        let suite = "qingkong.watch-handoff-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let center = UNUserNotificationCenter.current()
        let delegate = center.delegate
        defer { center.delegate = delegate; defaults.removePersistentDomain(forName: suite) }
        let service = RelaxationReminderService(defaultsOverride: defaults)
        let watchID = UUID()
        let original = service.relayConfiguration.id
        service.acceptWatchMonitoring(.init(watchID: watchID, configurationID: UUID()))
        XCTAssertNil(service.relayConfiguration.watchOwnerID, "旧设置不能发起交接")
        service.acceptWatchMonitoring(.init(watchID: watchID, configurationID: original))
        XCTAssertEqual(service.relayConfiguration.watchOwnerID, watchID)
        XCTAssertNotEqual(service.relayConfiguration.id, original)
        await service.evaluate(readings: [], isDemo: false)
        XCTAssertNil(service.lastCheckedAt, "交接后手机不再独立评估同一批健康数据")
        let restored = RelaxationReminderService(defaultsOverride: defaults)
        XCTAssertEqual(restored.relayConfiguration.watchOwnerID, watchID)
        XCTAssertEqual(restored.relayConfiguration.id, service.relayConfiguration.id)
        restored.setVitalThreshold(.highHeartRate, 125)
        XCTAssertEqual(restored.relayConfiguration.watchOwnerID, watchID)
        XCTAssertEqual(restored.relayConfiguration.vitalRules[.highHeartRate]?.threshold, 125)
        XCTAssertNotEqual(restored.relayConfiguration.id, service.relayConfiguration.id)
        XCTAssertNil(restored.lastSubmittedAt)
    }

    @MainActor
    func testOldWatchSignalCannotNotifyAfterPhoneSettingsChange() throws {
        let suite = "qingkong.watch-revision-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let center = UNUserNotificationCenter.current()
        let delegate = center.delegate
        defer { center.delegate = delegate; defaults.removePersistentDomain(forName: suite) }
        let service = RelaxationReminderService(defaultsOverride: defaults)
        service.acceptWatchMonitoring(.init(watchID: UUID(), configurationID: service.relayConfiguration.id))
        let old = service.relayConfiguration.id
        service.setVitalThreshold(.lowOxygen, 89)
        let stale = ReminderSignal(kind: .lowOxygen, sampleID: UUID(), sampleDate: .now, detectedAt: .now, configurationID: old)
        service.receiveWatchSignal(stale)
        XCTAssertNil(service.lastWatchSignalAt)
        XCTAssertNil(service.lastSubmittedAt)
    }

    @MainActor
    func testReminderContextPreservesPreferencesAndAcceptsReportWithoutPreferences() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let link = Connectivity(store: store, player: AudioPlayer())
        var preferences = Preferences()
        preferences.selectScene(.forest)
        let report = WatchReminderReport(configurationID: UUID(), checkedAt: .now, results: ["hrv": "基线不足"], signals: [], newestSamples: [:])
        let received = expectation(description: "Report and preferences both received")
        received.expectedFulfillmentCount = 2
        link.watchReminderReportReceived = { value in
            XCTAssertEqual(value.configurationID, report.configurationID)
            received.fulfill()
        }
        let data = try JSONEncoder().encode(report)
        link.session(WCSession.default, didReceiveApplicationContext: ["preferences": try JSONEncoder().encode(preferences), "watchReminderReport": data])
        link.session(WCSession.default, didReceiveApplicationContext: ["watchReminderReport": data])
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(store.preferences.manualScene, .forest)
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
