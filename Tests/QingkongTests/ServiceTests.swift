import XCTest
import UserNotifications
import WatchConnectivity
import Observation
import QingkongCore
@testable import Qingkong

final class ServiceTests: XCTestCase {
    func testMusicWidgetSnapshotRoundTripAndMeaningfulChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state = AudioState()
        state.onlineTrackID = "song-a"
        state.onlineTitle = "测试歌曲"
        state.playing = true
        let snapshot = WidgetAudioSnapshot(state: state)
        XCTAssertTrue(try WidgetAudioStorage.save(snapshot, to: url))
        XCTAssertEqual(WidgetAudioStorage.load(from: url), snapshot)
        XCTAssertFalse(try WidgetAudioStorage.save(WidgetAudioSnapshot(state: state, now: snapshot.generatedAt.addingTimeInterval(60)), to: url))
        state.playing = false
        XCTAssertTrue(try WidgetAudioStorage.save(WidgetAudioSnapshot(state: state), to: url))
        XCTAssertEqual(WidgetAudioStorage.load(from: url)?.playing, false)
        XCTAssertEqual(WidgetAudioStorage.load(from: url)?.onlineTrackID, "song-a")
        try Data("broken".utf8).write(to: url)
        XCTAssertNil(WidgetAudioStorage.load(from: url))
    }

    @MainActor
    func testMusicWidgetControlsUseCurrentPlayerAndExplicitPlayPause() async throws {
        let player = AudioPlayer()
        defer { player.pause() }
        await player.select(.ocean)
        func unexpectedRestore() async throws { XCTFail("已有选择时不能另建播放来源") }
        try await WidgetPlaybackController.perform(.play, on: player, restoreSelection: unexpectedRestore)
        XCTAssertTrue(player.state.playing, player.error ?? "应使用现有播放器播放")
        XCTAssertEqual(player.state.track, .ocean)
        try await WidgetPlaybackController.perform(.play, on: player, restoreSelection: unexpectedRestore)
        XCTAssertTrue(player.state.playing, "组件过时的播放动作不能反向暂停")
        try await WidgetPlaybackController.perform(.next, on: player, restoreSelection: unexpectedRestore)
        XCTAssertEqual(player.state.track, .night)
        XCTAssertTrue(player.state.playing)
        try await WidgetPlaybackController.perform(.pause, on: player, restoreSelection: unexpectedRestore)
        try await WidgetPlaybackController.perform(.pause, on: player, restoreSelection: unexpectedRestore)
        XCTAssertFalse(player.state.playing, "重复暂停不能开始播放")
        try await WidgetPlaybackController.perform(.previous, on: player, restoreSelection: unexpectedRestore)
        XCTAssertEqual(player.state.track, .ocean)
        XCTAssertFalse(player.state.playing, "暂停时切歌不自动开始")
        player.reportPlaybackError("上次播放失败")
        try await WidgetPlaybackController.perform(.pause, on: player, restoreSelection: unexpectedRestore)
        XCTAssertFalse(player.state.playing, "之前的播放错误不能让暂停动作报错")
    }

    @MainActor
    func testMusicWidgetRestoresSelectionAndDoesNotFallbackAfterRestoreError() async throws {
        let player = AudioPlayer()
        defer { player.pause() }
        var restores = 0
        try await WidgetPlaybackController.perform(.pause, on: player) { restores += 1 }
        XCTAssertEqual(restores, 0, "冷启动暂停不恢复歌曲或开始声音")
        do {
            try await WidgetPlaybackController.perform(.play, on: player) {
                restores += 1
                throw WidgetPlaybackError.unavailable("歌曲已撤回")
            }
            XCTFail("恢复失败应向系统返回错误")
        } catch { XCTAssertEqual(error.localizedDescription, "歌曲已撤回") }
        XCTAssertFalse(player.state.playing)
        XCTAssertFalse(player.hasSelection)
        try await WidgetPlaybackController.perform(.play, on: player) {
            restores += 1
            await player.select(.night)
        }
        XCTAssertEqual(restores, 2)
        XCTAssertEqual(player.state.track, .night)
        XCTAssertTrue(player.state.playing)
    }

    @MainActor
    func testTrackChangesPublishCompleteMetadataWithoutBundledFallback() async throws {
        func track(_ id: String) throws -> PublicAudioTrack {
            let object: [String: Any] = ["id": id, "albumID": "album", "title": "Title " + id,
                "audioURL": "https://example.invalid/audio.wav", "durationSeconds": 30,
                "fileVersion": "1", "byteSize": 100, "sha256": String(repeating: "0", count: 64),
                "copyright": ["owner": "Test", "source": "Fixture", "license": "Test only"],
                "updatedAt": "2026-11-21T00:00:00Z", "publishedAt": "2026-11-21T00:00:00Z", "revision": 1, "sortOrder": 0]
            return try PublicContentSnapshot.decoder().decode(PublicAudioTrack.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let player = AudioPlayer()
        defer { player.pause() }
        let first = try track("first"), second = try track("second")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "rain", withExtension: "wav"))
        await player.selectOnline(first, queue: [first, second], url: url, allowCellular: false, autoplay: false)
        for _ in 0..<100 {
            if player.canSeek { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(player.canSeek, "AVPlayer 准备完成后应能定位")
        await player.seek(to: 8)
        XCTAssertEqual(player.playbackPosition, 8, accuracy: 0.1)
        XCTAssertFalse(player.state.playing, "线上播放器定位时也应保留暂停状态")
        var updates: [AudioState] = []
        player.didChangeState = { updates.append($0) }
        await player.selectOnline(second, queue: [first, second], url: url, allowCellular: false, autoplay: false)
        XCTAssertFalse(updates.isEmpty)
        for value in updates {
            XCTAssertTrue(value.onlineTrackID == first.id || value.onlineTrackID == second.id, "切歌中不能发布内置封面状态")
            XCTAssertEqual(value.onlineTitle, value.onlineTrackID == first.id ? first.title : second.title, "歌名与歌曲必须一起更新")
        }
        updates.removeAll()
        await player.select(.ocean)
        for value in updates where value.onlineTrackID == nil {
            XCTAssertEqual(value.track, .ocean, "切到内置曲目不能先闪上一首内置封面")
            XCTAssertNil(value.onlineTitle)
            XCTAssertNil(value.onlineArtworkURL)
        }
    }

    @MainActor
    func testPlaybackModesPersistAndShuffleSelectsAnotherTrack() async throws {
        let suite = "qingkong.playback-mode-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = AudioPlayer(defaultsOverride: defaults)
        defer { player.pause(); defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(player.playbackMode, .sequence)
        player.playbackMode = .shuffle
        XCTAssertEqual(player.playbackMode, .shuffle)
        await player.select(.rain)
        await player.skip(1)
        XCTAssertNotEqual(player.state.track, .rain)
        XCTAssertFalse(player.state.playing)
        player.playbackMode = .single
        XCTAssertEqual(player.playbackMode, .single)
        let reopened = AudioPlayer(defaultsOverride: defaults)
        defer { reopened.pause() }
        XCTAssertEqual(reopened.playbackMode, .single)
        reopened.playbackMode = .sequence
        XCTAssertEqual(reopened.playbackMode, .sequence)
    }

    @MainActor
    func testBundledPlaybackModesAdvanceAtTheRealEndOfAudio() async throws {
        let suite = "qingkong.loop-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = AudioPlayer(defaultsOverride: defaults)
        defer { player.pause(); defaults.removePersistentDomain(forName: suite) }
        for mode in AudioPlaybackMode.allCases {
            player.playbackMode = mode
            await player.select(.night, autoplay: true)
            XCTAssertTrue(player.state.playing, player.error ?? "本地声音应开始播放")
            await player.seek(to: player.playbackDuration - 0.1)
            for _ in 0..<100 {
                let expectedTrack = switch mode {
                case .single: player.state.track == .night
                case .sequence: player.state.track == .rain
                case .shuffle: player.state.track != .night
                }
                if expectedTrack && player.state.playing && player.playbackPosition < 2 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(player.state.playing)
            XCTAssertLessThan(player.playbackPosition, 2, "\(mode.title)应从头继续播放")
            switch mode {
            case .single: XCTAssertEqual(player.state.track, .night)
            case .sequence: XCTAssertEqual(player.state.track, .rain, "最后一首之后应循环到第一首")
            case .shuffle: XCTAssertNotEqual(player.state.track, .night)
            }
            player.pause()
        }
    }

    @MainActor
    func testLocalPlaybackSeekKeepsPauseAndRejectsInvalidPositions() async throws {
        let suite = "qingkong.seek-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = AudioPlayer(defaultsOverride: defaults)
        defer { player.pause(); defaults.removePersistentDomain(forName: suite) }
        await player.select(.rain, autoplay: true)
        XCTAssertTrue(player.state.playing, player.error ?? "本地音频应能播放")
        player.pause()
        XCTAssertTrue(player.canSeek)
        XCTAssertGreaterThan(player.playbackDuration, 8)

        await player.seek(to: 8)
        XCTAssertEqual(player.playbackPosition, 8, accuracy: 0.1)
        XCTAssertFalse(player.state.playing, "拖动暂停中的音频不应开始播放")
        await player.seek(to: .nan)
        await player.seek(to: .infinity)
        XCTAssertEqual(player.playbackPosition, 8, accuracy: 0.1)
        await player.seek(to: -4)
        XCTAssertEqual(player.playbackPosition, 0, accuracy: 0.1)

        await player.select(.ocean)
        XCTAssertEqual(player.playbackPosition, 0)
        XCTAssertTrue(player.canSeek, "暂停切歌后仍能定位，但不能沿用上一首的位置")
    }

    @MainActor
    func testWatchMoodAttemptsToWakeBackgroundPhoneAndKeepsDurableCopy() throws {
        let store = try LocalStore(testing: true, reset: true)
        let record = MoodRecord(mood: 5, stress: 1, note: "")
        try store.save(record)
        let link = Connectivity(store: store, player: AudioPlayer())
        let transport = TestMoodMessageSession(reachable: false)
        let data = try JSONEncoder().encode(SyncPayload(record: record))

        link.sendRecordImmediately(data, record: record, session: transport, wakePhone: true)

        XCTAssertEqual(transport.messages.count, 1, "手表应尝试通过即时消息唤醒后台手机，不能只等待后台队列")
        XCTAssertEqual(transport.messages.first?["record"] as? Data, data)
        XCTAssertEqual(try store.pendingRecords(), [record], "手机保存回执到达前保留持久副本")
    }

    @MainActor
    func testPhoneMoodDoesNotTryToWakeUnreachableWatch() throws {
        let store = try LocalStore(testing: true, reset: true)
        let record = MoodRecord(mood: 4, stress: 2, note: "")
        try store.save(record)
        let link = Connectivity(store: store, player: AudioPlayer())
        let transport = TestMoodMessageSession(reachable: false)

        link.sendRecordImmediately(try JSONEncoder().encode(SyncPayload(record: record)), record: record, session: transport, wakePhone: false)

        XCTAssertTrue(transport.messages.isEmpty)
        XCTAssertEqual(try store.pendingRecords(), [record])
    }

    @MainActor
    func testImmediateMoodDeduplicatesInFlightAndPersistsMatchingReceipt() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let record = MoodRecord(mood: 4, stress: 3, note: "")
        try store.save(record)
        let link = Connectivity(store: store, player: AudioPlayer())
        let transport = TestMoodMessageSession(reachable: true)
        let data = try JSONEncoder().encode(SyncPayload(record: record))

        link.sendRecordImmediately(data, record: record, session: transport, wakePhone: true)
        link.sendRecordImmediately(data, record: record, session: transport, wakePhone: true)
        XCTAssertEqual(transport.messages.count, 1)
        let acknowledged = expectation(description: "Matching receipt persisted")
        withObservationTracking { _ = link.syncMessage } onChange: { acknowledged.fulfill() }
        transport.replyHandler?(["receipt": try JSONEncoder().encode(SyncReceipt(record: record))])

        await fulfillment(of: [acknowledged], timeout: 2)
        XCTAssertTrue(try store.pendingRecords().isEmpty)
        XCTAssertTrue(try LocalStore(testing: true).pendingRecords().isEmpty)
    }

    @MainActor
    func testQueuedWatchMoodPersistsWidgetSummaryWithoutForegroundRefresh() async throws {
        let store = try LocalStore(testing: true, reset: true)
        let link = Connectivity(store: store, player: AudioPlayer())
        let record = MoodRecord(mood: 2, stress: 4, note: "", createdAt: .now.addingTimeInterval(-1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let published = expectation(description: "Background record publishes new widget summary")
        store.didChangeRecords = {
            do { try SnapshotStorage.saveMood(MoodSummary.latest(in: store.records), preferences: store.preferences, to: url) }
            catch { XCTFail("组件摘要未保存：\(error)") }
            published.fulfill()
        }

        link.session(WCSession.default, didReceiveUserInfo: ["record": try JSONEncoder().encode(SyncPayload(record: record))])

        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(SnapshotStorage.load(from: url)?.mood?.value, 2)
        XCTAssertEqual(SnapshotStorage.load(from: url)?.mood?.date, record.createdAt)
        XCTAssertEqual(try LocalStore(testing: true).entries, [record])
        XCTAssertTrue(try store.pendingRecords().isEmpty)
    }

    @MainActor
    func testMoodOnlyWidgetUpdatePreservesHealthAndHandlesDeletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date.now
        let reading = HealthReading(metric: .hrv, date: now.addingTimeInterval(-60), value: 45, source: "测试")
        let trends: [HealthMetric: [TrendBucket]] = [.hrv: [TrendBucket(date: reading.date, value: 45, segment: 0)]]
        let original = ComplicationSnapshot(readings: [reading], trends: trends, preferences: Preferences())
        try SnapshotStorage.save(original, to: url)
        let record = MoodRecord(mood: 5, stress: 1, note: "不进入组件的文字", createdAt: now)
        let mood = try XCTUnwrap(MoodSummary.latest(in: [record]))
        var preferences = Preferences()
        preferences.manualScene = .ocean

        XCTAssertTrue(try SnapshotStorage.saveMood(mood, preferences: preferences, to: url))
        let updated = try XCTUnwrap(SnapshotStorage.load(from: url))
        XCTAssertEqual(updated.mood, mood)
        XCTAssertEqual(updated.readings, [reading])
        XCTAssertEqual(updated.trends, trends)
        XCTAssertEqual(updated.preferences, preferences)
        XCTAssertFalse(try SnapshotStorage.saveMood(mood, preferences: preferences, to: url), "重复投递不重复请求组件刷新")
        XCTAssertTrue(try SnapshotStorage.saveMood(nil, preferences: preferences, to: url))
        XCTAssertNil(SnapshotStorage.load(from: url)?.mood)
        XCTAssertEqual(SnapshotStorage.load(from: url)?.readings, [reading])
    }

    @MainActor
    func testUnchangedSnapshotDoesNotConsumeAnotherWidgetReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var snapshot = ComplicationSnapshot(readings: [], trends: [:], preferences: Preferences())
        XCTAssertTrue(try SnapshotStorage.save(snapshot, to: url))
        snapshot.generatedAt = snapshot.generatedAt.addingTimeInterval(60)
        XCTAssertFalse(try SnapshotStorage.save(snapshot, to: url), "仅刷新时间变化不应反复刷新相同内容")
        snapshot.readings = [HealthReading(metric: .heartRate, date: .now, value: 65, source: "测试")]
        XCTAssertTrue(try SnapshotStorage.save(snapshot, to: url), "真实健康数据变化仍需刷新")
    }

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

@MainActor
private final class TestMoodMessageSession: MoodMessageSession {
    let isReachable: Bool
    private(set) var messages: [[String: Any]] = []
    private(set) var replyHandler: (([String: Any]) -> Void)?

    init(reachable: Bool) { isReachable = reachable }

    func sendMessage(_ message: [String: Any], replyHandler: (([String: Any]) -> Void)?, errorHandler: ((Error) -> Void)?) {
        messages.append(message)
        self.replyHandler = replyHandler
    }
}
