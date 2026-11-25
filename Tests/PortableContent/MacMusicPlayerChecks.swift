import AppKit
import Foundation
import MediaPlayer
import Network
import Observation
import QingkongCore

private enum CheckFailure: Error { case failed(String) }

/// Exercises the production player and real decoders, always with playing=false.
@main
struct MacMusicPlayerChecks {
    @MainActor static func main() async throws {
        try await checkPhoneAirPlayDisplay()
        try await checkPhoneAirPlayConnection()
        try checkReportCacheAccountIsolation()
        let player = MacAudioPlayer()
        var allowsSystemControl = true
        // Do not publish to the user's actual system panel or start audible playback in these checks.
        let systemPlayback = MacSystemPlayback(player: player, canControl: { allowsSystemControl })
        try check(systemPlayback.perform(.play) == .noSuchContent && MacSystemPlayback.metadata(for: player) == nil,
            "an idle app must not offer stale system content or start a default track")
        var observedQueueChange = false
        withObservationTracking {
            _ = player.queueItems; _ = player.currentIndex; _ = player.playbackIntent
        } onChange: {
            MainActor.assumeIsolated { observedQueueChange = true }
        }
        let queue = Track.allCases.map { DesktopQueueItem(track: $0) }
        let deadline = SleepDeadline(minutes: 12)
        var start = DesktopPlaybackStart(queue: queue, index: 0, position: 1,
            playing: false, mode: .sequence, deadline: deadline, serviceAddress: "")
        player.volume = 0.31
        _ = try await player.prepare(start)
        try check(player.snapshot == nil && !player.isPlaying, "silent preparation must not take over playback")
        start.position = 2
        var state = try await player.commit(sessionID: start.sessionID, latest: start)
        try check(observedQueueChange, "queue views must observe the committed queue")
        try check(!state.playing && abs(state.position - 2) < 0.05, "commit must preserve pause and latest position")
        try check(state.volume == Float(0.31) && state.deadline == deadline, "commit must preserve Mac volume and absolute deadline")
        print("PASS: silent preparation, latest position, Mac volume, absolute deadline")

        allowsSystemControl = false
        try check(systemPlayback.perform(.next) == .commandFailed && player.currentIndex == 0,
            "system controls must reject changes during handoff")
        allowsSystemControl = true
        try check(systemPlayback.perform(.seek(.nan)) == .commandFailed,
            "system seek must reject non-finite positions")
        try check(systemPlayback.perform(.seek(2.5)) == .success, "a valid system seek must be admitted")
        try await Task.sleep(for: .milliseconds(50))
        state = player.snapshot!
        try check(abs(state.position - 2.5) < 0.05 && !state.playing && state.sessionID == start.sessionID && state.deadline == deadline,
            "system seek must use the handoff player, preserve pause and retain its deadline")
        var observedSystemPause = false
        player.didChange = { observedSystemPause = true }
        try check(systemPlayback.perform(.pause) == .success && observedSystemPause,
            "system controls must preserve the existing connection change callback")
        player.didChange = nil
        let metadata = MacSystemPlayback.metadata(for: player)!
        try check(metadata[MPMediaItemPropertyTitle] as? String == queue[0].title &&
            metadata[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0 &&
            metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == state.position &&
            metadata[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == queue.count,
            "system metadata must reflect the authoritative paused title, queue and actual decoder position")
        print("PASS: idle system controls, handoff exclusion, paused seek, metadata and connection callback")
        try check(systemPlayback.perform(.next) == .success, "system next must be admitted")
        try await Task.sleep(for: .milliseconds(100))
        state = player.snapshot!
        try check(state.index == 1 && !state.playing && state.sessionID == start.sessionID && state.deadline == deadline,
            "system next must retain the phone session, pause and timer")
        try check(systemPlayback.perform(.previous) == .success, "system previous must be admitted")
        try await Task.sleep(for: .milliseconds(100))
        try check(player.currentIndex == 0 && !player.playbackIntent && player.volume == 0.31,
            "system previous must use the existing queue and preserve app volume")
        print("PASS: system next/previous share the paused handoff queue, app volume and absolute timer")

        state = try await player.execute(.init(sessionID: start.sessionID, action: .seek, amount: 3))
        try check(abs(state.position - 3) < 0.05 && !state.playing, "seek must preserve pause")
        state = try await player.execute(.init(sessionID: start.sessionID, action: .volume, amount: 0.62))
        try check(state.volume == Float(0.62), "volume must change the actual Mac app player")
        for mode in AudioPlaybackMode.allCases {
            state = try await player.execute(.init(sessionID: start.sessionID, action: .mode, mode: mode))
            try check(state.mode == mode && !state.playing, "all loop modes must preserve pause")
        }
        print("PASS: paused seek, app volume and three loop modes")

        _ = try await player.execute(.init(sessionID: start.sessionID, action: .next))
        player.stop()
        try await Task.sleep(for: .milliseconds(30))
        try check(player.error == nil && !player.isPlaying && !player.isBuffering,
            "stop during track loading must cancel without a spurious seek error")
        print("PASS: stop cancels pending track loading without an error")

        let staged = DesktopPlaybackStart(queue: queue, index: 1, position: 0,
            playing: false, mode: .single, deadline: nil, serviceAddress: "")
        _ = try await player.prepare(staged)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        var rejected = false
        do { _ = try await player.commit(sessionID: staged.sessionID) }
        catch { rejected = true }
        try check(rejected && !player.isPlaying, "system sleep must invalidate a pending handoff")
        print("PASS: sleep invalidates pending handoff and preserves silence")

        player.pauseControlledSession()
        state = try await player.execute(.init(sessionID: start.sessionID, action: .release))
        try check(state.sessionID == start.sessionID && !state.playing, "release must retain a paused recoverable session")
        do {
            _ = try await player.execute(.init(sessionID: UUID(), action: .next))
            throw CheckFailure.failed("a different session must be rejected")
        } catch is CheckFailure { throw CheckFailure.failed("a different session must be rejected") }
        catch { }
        print("PASS: paused release stays recoverable; wrong session is rejected")

        let priorRevision = state.revision
        player.play(Track.allCases[0], playing: false)
        state = try await player.execute(.init(sessionID: start.sessionID, action: .pause))
        try check(state.sessionID == start.sessionID && state.revision > priorRevision && state.index == 0,
            "Mac track selection must retain the controlled session and advance its revision")
        try check(state.deadline == deadline && state.volume == Float(0.62) && !state.playing,
            "Mac track selection must preserve the absolute deadline and app volume")
        state = try await player.execute(.init(sessionID: start.sessionID, action: .release))
        try check(!state.playing, "phone must still be able to release after a Mac track selection")
        print("PASS: Mac track selection keeps phone controls and release working")

        try check(player.queueItems.count == queue.count && player.currentIndex == 0 && player.currentItem == queue[0],
            "UI queue must expose the same authoritative selection")
        var observedSelectionChange = false
        withObservationTracking { _ = player.currentIndex } onChange: {
            MainActor.assumeIsolated { observedSelectionChange = true }
        }
        player.playQueueItem(at: 1, playing: false)
        try check(observedSelectionChange, "queue selection must invalidate the observed current row")
        try await Task.sleep(for: .milliseconds(150))
        state = try await player.execute(.init(sessionID: start.sessionID, action: .pause))
        try check(state.index == 1 && state.sessionID == start.sessionID && state.deadline == deadline,
            "queue selection must preserve the phone session and absolute deadline")
        try check(player.currentItem == queue[1] && state.volume == Float(0.62) && !state.playing,
            "queue selection preserves volume and a silent playback request")
        player.playQueueItem(at: -1, playing: false)
        try check(player.currentIndex == 1, "invalid queue rows cannot change selection")
        print("PASS: queue UI selection uses authoritative player and preserves session, timer and volume")

        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/PublicContent/snapshot.json"))
        let fixture = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: fixtureData).validated()
        let track = fixture.tracks[0]
        let onlineQueue = fixture.tracks.filter { $0.albumID == track.albumID }
        player.playOnlineQueue(onlineQueue, index: 0, serviceAddress: "https://example.invalid", playing: false)
        try check(player.controlledSessionID == start.sessionID && player.currentItem?.onlineTrack == track,
            "Mac online album selection must retain the controlled session and publish its queue")
        try check(player.deadline == deadline && player.volume == 0.62 && !player.playbackIntent,
            "online album selection preserves the absolute timer, volume and pause")
        player.reconcileOnlineCatalog([], serviceAddress: "https://example.invalid")
        try check(!player.isPlaying && !player.isBuffering && !player.hasSelection && player.error != nil,
            "withdrawn online selection must release the decoder and disable local resume")
        state = try await player.execute(.init(sessionID: start.sessionID, action: .play))
        try check(state.isValid && !state.playing && !state.buffering && state.position == 0 && state.duration == 0,
            "withdrawal must retain a valid paused v2 receipt and phone play cannot revive withdrawn audio")
        try check(player.controlledSessionID == start.sessionID,
            "withdrawal must not silently discard the phone controlled session")
        print("PASS: online selection retains controlled session; withdrawal emits a valid paused receipt")

        player.discardControlledSession()
        try check(player.snapshot == nil && !player.hasSelection && !player.playbackIntent,
            "account invalidation must discard the old controlled queue and decoder")
        player.toggle()
        try check(!player.isPlaying && !player.hasSelection, "Mac play cannot revive the previous account session")
        print("PASS: account invalidation prevents local resume of old handoff")
    }

    @MainActor private static func checkPhoneAirPlayConnection() async throws {
        let player = MacAudioPlayer()
        let service = MacDeviceConnection()
        service.attachPlayer(player)
        let secret = Data(repeating: 0x35, count: 32)
        let parameters = try DesktopPairing.parameters(secret: secret)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        var ready = false
        listener.stateUpdateHandler = { state in
            Task { @MainActor in if case .ready = state { ready = true } }
        }
        listener.newConnectionHandler = { incoming in
            Task { @MainActor in service.accept(incoming) }
        }
        listener.start(queue: .main)
        defer { service.disconnect(); listener.cancel() }
        try await waitFor { ready }
        let receiverName = Host.current().localizedName ?? "Mac"
        let client = PhoneMacPeer(id: "airplay-loopback", name: receiverName,
            endpoint: .hostPort(host: .ipv4(.loopback), port: listener.port!), secret: secret,
            deviceID: UUID().uuidString, deviceName: "Test iPhone")
        defer { client.close() }
        client.connect()
        var connecting = [client.id: client]
        try check(PhoneMacPeer.removeMissing(from: &connecting, visible: [], keeping: []).isEmpty,
            "temporary discovery disappearance cannot cancel an in-flight connection")
        try await waitFor { client.isConnected }
        try check(client.airPlayReceiverName == receiverName, "production hello must advertise the receiver name and mirror capability")
        var actual = DesktopPlaybackSnapshot(sessionID: UUID(), revision: 1,
            queue: [.init(track: .rain), .init(track: .ocean)], index: 0, position: 3, duration: 120,
            playing: true, mode: .sequence, volume: 0.4, deadline: SleepDeadline(minutes: 12), deviceName: "Test iPhone")
        var actions: [PhonePlaybackCommand.Action] = []
        client.onPhoneCommand = { command in
            actions.append(command.action); actual.revision += 1
            if command.action == .next { actual.index = 1; actual.position = 0 }
            if command.action == .pause { actual.playing = false }
            if command.action == .play { actual.playing = true }
            return .init(id: command.id, sessionID: command.sessionID, snapshot: actual)
        }
        try client.publishPhonePlayback(.init(routeName: "Wrong Receiver", snapshot: actual))
        try await Task.sleep(for: .milliseconds(50))
        try check(!player.hasSelection, "a different AirPlay receiver cannot acquire the production Mac display")
        let displayID = PhoneAirPlay.matchingReceiver("AirPlay", receivers: [client.id: receiverName])
        try check(displayID == client.id, "generic iPhone AirPlay route must resolve the sole connected trusted display")
        try client.publishPhonePlayback(.init(routeName: client.airPlayReceiverName!, snapshot: actual))
        try await waitFor { player.isPhonePlayback }
        await player.next()
        try check(actions == [.next] && player.currentIndex == 1 && player.error == nil,
            "the production Mac service must send and accept a real TLS reverse command receipt")
        actual.revision += 1; actual.volume = 0.67
        try client.publishPhonePlayback(.init(routeName: receiverName, snapshot: actual))
        try await waitFor { abs(player.volume - 0.67) < 0.001 }
        try check(player.currentIndex == 1 && player.isPlaying,
            "TLS output-volume updates must preserve the mirrored song and playback state")
        var discovered = [client.id: client]
        let removed = PhoneMacPeer.removeMissing(from: &discovered, visible: [], keeping: [])
        try check(removed.isEmpty && discovered[client.id] === client && client.isConnected && player.phoneConnected,
            "temporary Bonjour disappearance must not close an authenticated playback connection")
        actual.revision += 1; actual.playing = false
        try client.publishPhonePlayback(.init(routeName: receiverName, snapshot: actual))
        try await waitFor { !player.isPlaying }
        try check(player.isPhonePlayback && player.currentIndex == 1 && player.controlsAvailable,
            "phone pause must update Mac without releasing the AirPlay display")
        player.toggle()
        try await waitFor { player.isPlaying && !player.phoneControlBusy }
        player.pause()
        try await waitFor { !player.isPlaying && !player.phoneControlBusy }
        player.toggle()
        try await waitFor { player.isPlaying && !player.phoneControlBusy }
        let confirmedActions = actions
        try check(confirmedActions == [.next, .play, .pause, .play],
            "Mac play/pause must use actual phone receipts over TLS")
        client.observe(false)
        client.close()
        try await waitFor { !player.phoneConnected }
        try check(actual.playing && actions == confirmedActions && player.snapshot == nil,
            "real transport close must not pause phone AirPlay or create a Mac decoder")
        client.connect()
        try await waitFor { client.isConnected }
        actual.revision += 1; actual.position = 42
        try client.publishPhonePlayback(.init(routeName: receiverName, snapshot: actual))
        try await waitFor { player.phoneConnected && player.position >= 42 }
        try check(actual.playing && actions == confirmedActions, "production reconnect cannot pause or replay a phone command")
        actual.revision += 1; actual.playing = false
        try client.publishPhonePlayback(.init(routeName: receiverName, snapshot: actual))
        try await waitFor { !player.isPlaying }
        client.endPhonePlayback(sessionID: actual.sessionID)
        try await waitFor { !player.isPhonePlayback }
        try check(!player.hasSelection && !player.isPlaying && player.controlsAvailable && !actual.playing && actions == confirmedActions,
            "AirPlay detach must restore independent Mac controls without starting either decoder")
        var offline = [client.id: client]
        client.close()
        try check(PhoneMacPeer.removeMissing(from: &offline, visible: [], keeping: [client.id]).isEmpty,
            "the mirrored endpoint remains available to reconnect")
        try check(PhoneMacPeer.removeMissing(from: &offline, visible: [], keeping: []).contains(client.id) && offline.isEmpty,
            "missing disconnected peers without a selection must be released")
        print("PASS: production TLS song/volume/play/pause sync, discovery retention, reverse receipts, socket close without pause, reconnect and independent controls after AirPlay detach")
    }

    @MainActor private static func waitFor(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < limit else { throw CheckFailure.failed("AirPlay connection check timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private static func checkPhoneAirPlayDisplay() async throws {
        let player = MacAudioPlayer()
        let queue = Track.allCases.map { DesktopQueueItem(track: $0) }
        let deadline = SleepDeadline(minutes: 12)
        var actual = DesktopPlaybackSnapshot(sessionID: UUID(), revision: 3, queue: queue, index: 0,
            position: 5, duration: 120, playing: true, mode: .sequence, volume: 0.4,
            deadline: deadline, deviceName: "Test iPhone")
        try check(player.applyPhonePlayback(actual), "phone state must be accepted")
        try check(player.isPhonePlayback && player.controlledSessionID == nil && player.snapshot == nil,
            "AirPlay display cannot become a Mac decoder or a legacy Mac-owned session")
        try check(player.title == queue[0].title && player.queueItems == queue && player.deadline == deadline,
            "phone artwork selection, queue and absolute timer must drive Mac display")
        try check(MacSystemPlayback.metadata(for: player) == nil,
            "AirPlay receiver must not publish a second local Now Playing session")
        var actions: [PhonePlaybackCommand.Action] = []
        player.phoneCommandHandler = { command in
            actions.append(command.action)
            actual.revision += 1
            switch command.action {
            case .next: actual.index = (actual.index + 1) % queue.count; actual.position = 0
            case .select: actual.index = Int(command.amount!); actual.position = 0
            case .seek: actual.position = command.amount!
            case .mode: actual.mode = command.mode!
            case .volume: actual.volume = Float(command.amount!)
            case .timer: actual.deadline = command.deadline
            case .pause, .release: actual.playing = false
            default: break
            }
            return .init(id: command.id, sessionID: command.sessionID, snapshot: actual)
        }
        await player.next()
        try check(actions == [.next] && player.currentIndex == 1 && player.deadline == deadline,
            "Mac next must be acknowledged by the phone without resetting its timer")
        await player.seek(to: 24)
        try check(player.position == 24, "seek must apply phone-confirmed position")
        player.setMode(.shuffle)
        try await Task.sleep(for: .milliseconds(30))
        try check(player.mode == .shuffle, "loop mode must come from the phone receipt")
        let beforeVolume = actions
        player.volume = 0.62
        try await Task.sleep(for: .milliseconds(230))
        try check(abs(player.volume - 0.4) < 0.001 && actions == beforeVolume,
            "AirPlay output volume is read-only on Mac and must never send decoder-gain commands")
        actual.revision += 1; actual.volume = 0.73
        player.applyPhonePlayback(actual)
        try check(abs(player.volume - 0.73) < 0.001,
            "phone output-volume changes must update the Mac volume display")
        let lastRevision = actual.revision
        var stale = actual; stale.revision = lastRevision - 1; stale.index = 0; stale.volume = 0.1
        try check(!player.applyPhonePlayback(stale) && player.currentIndex == 1 && abs(player.volume - 0.73) < 0.001,
            "late phone snapshots cannot restore a stale track or output volume")
        let beforeDisconnect = actions
        player.phonePlaybackDisconnected()
        let frozen = player.playbackPosition
        try await Task.sleep(for: .milliseconds(100))
        try check(actions == beforeDisconnect && !player.controlsAvailable && player.playbackPosition == frozen,
            "companion disconnect freezes display and cannot send Pause to AirPlay")
        await player.next()
        try check(actions == beforeDisconnect, "disconnected controls cannot pretend to execute")
        actual.revision += 1; actual.position = 41
        player.applyPhonePlayback(actual)
        try check(player.controlsAvailable && player.isPlaying && player.position == 41,
            "reconnect must reflect actual continuing phone playback without replaying commands")
        player.endPhonePlayback()
        try check(!player.hasSelection && !player.isPhonePlayback, "ending AirPlay display only clears its mirror")
        player.play(.rain, playing: false)
        player.volume = 0.29
        try check(player.hasSelection && !player.isPlaying && !player.isPhonePlayback,
            "Mac independent playback must remain available")
        try check(abs(player.volume - 0.29) < 0.001, "independent Mac volume must remain adjustable")
        player.stop()
        print("PASS: AirPlay display, no duplicate decoder/system session, real control receipts, volume, stale state, disconnect freeze and independent Mac")
    }

    private static func checkReportCacheAccountIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appending(path: "report.json")
        let report = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [])
        let received = Date.now
        try MacReportCache.save(report, accountScope: "account-a", receivedAt: received, to: cacheURL)
        let saved = try MacReportCache.load(accountScope: "account-a", from: cacheURL)
        try check(saved?.report == report && saved?.receivedAt == received, "same account can restore its cached report and actual receipt time")
        try check(try MacReportCache.load(accountScope: "account-b", from: cacheURL) == nil,
            "a newly signed-in account cannot see the previous account report")
        // Older caches have no owner. Never assign them to whichever account launches next.
        try JSONEncoder().encode(report).write(to: cacheURL, options: .atomic)
        var legacyRejected = false
        do { _ = try MacReportCache.load(accountScope: "account-a", from: cacheURL) }
        catch { legacyRejected = true }
        try check(legacyRejected, "an unscoped legacy cache must require a fresh phone sync")
        print("PASS: account-scoped cache, receipt time, other-account and legacy rejection")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
}
