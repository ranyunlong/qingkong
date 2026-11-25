import Foundation
import Network
import QingkongCore

private enum CheckFailure: Error { case failed(String) }

/// Uses the phone's production transport against an authenticated local stub.
/// No health data, CloudKit, real devices, or audio output is involved.
@main @MainActor
struct ReportConnectionChecks {
    static func main() async throws {
        let secret = Data(repeating: 0x41, count: 32)
        let parameters = try DesktopPairing.parameters(secret: secret)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        var ready = false
        var server: LocalPeerConnection?
        var heldRequests: [DesktopMusicRequest] = []
        listener.stateUpdateHandler = { state in
            Task { @MainActor in if case .ready = state { ready = true } }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let peer = LocalPeerConnection(connection)
                server = peer
                peer.onMessage = { data in
                    guard let request = try? JSONDecoder().decode(DesktopMusicRequest.self, from: data) else { return }
                    if request.action == .hello || request.action == .observe {
                        let response = DesktopMusicResponse(id: request.id, hostID: UUID(),
                            capabilities: [DesktopReportSyncState.capability, PhoneAirPlay.capability],
                            airPlayReceiverName: "Test Mac")
                        try? peer.send(JSONEncoder().encode(response))
                    } else { heldRequests.append(request) }
                }
                peer.start()
            }
        }
        listener.start(queue: .main)
        defer { server?.close(); listener.cancel() }
        try await waitUntil { ready }
        let client = PhoneMacPeer(id: "loopback", name: "Test Mac",
            endpoint: .hostPort(host: .ipv4(.loopback), port: listener.port!),
            secret: secret, deviceID: UUID().uuidString, deviceName: "Test iPhone")
        defer { client.close() }
        client.connect()
        try await waitUntil { client.isConnected }
        try check(client.airPlayReceiverName == "Test Mac", "AirPlay display requires an advertised receiver capability")
        let phoneSession = UUID()
        var phoneState = DesktopPlaybackSnapshot(sessionID: phoneSession, revision: 1,
            queue: [.init(track: .rain), .init(track: .ocean)], index: 0, position: 3, duration: 120,
            playing: true, mode: .sequence, volume: 0.4, deadline: SleepDeadline(minutes: 12), deviceName: "Test iPhone")
        try client.publishPhonePlayback(.init(routeName: "Test Mac", snapshot: phoneState))
        try await waitUntil { heldRequests.contains { $0.action == .phonePlayback } }
        try check(heldRequests.first(where: { $0.action == .phonePlayback })?.phonePlayback?.snapshot == phoneState,
            "the real encrypted transport must carry phone-owned progress and absolute deadline")
        var phoneActions: [PhonePlaybackCommand.Action] = []
        client.onPhoneCommand = { command in
            if command.action == .next { try? await Task.sleep(for: .milliseconds(30)); phoneState.index = 1 }
            phoneActions.append(command.action); phoneState.revision += 1
            return .init(id: command.id, sessionID: command.sessionID, snapshot: phoneState)
        }
        let next = PhonePlaybackCommand(sessionID: phoneSession, action: .next)
        let pause = PhonePlaybackCommand(sessionID: phoneSession, action: .pause)
        try server?.send(JSONEncoder().encode(DesktopMusicResponse(id: next.id, phoneCommand: next)))
        try server?.send(JSONEncoder().encode(DesktopMusicResponse(id: pause.id, phoneCommand: pause)))
        try await waitUntil { heldRequests.filter { $0.action == .phoneCommandResult }.count == 2 }
        let receipts = heldRequests.filter { $0.action == .phoneCommandResult }.compactMap(\.phoneReply)
        try check(phoneActions == [.next, .pause] && receipts.map(\.id) == [next.id, pause.id] && receipts.allSatisfy(\.success),
            "reverse commands must execute serially and return their own actual phone receipts")
        client.observe(false)
        try check(client.isConnected && !heldRequests.contains { $0.action == .prepare || $0.action == .commit || $0.action == .command },
            "background display observation must not prepare, commit or pause a Mac decoder")
        print("PASS: real TLS phone-owned state, capability negotiation, serial reverse control and actual receipts without legacy handoff")

        // A slow music prepare can hold the server queue. A report timeout must
        // fail only that report, preserving music and subsequent commands.
        let slow = DesktopMusicRequest(action: .reportSyncStatus, reportSyncState: .syncing)
        var timedOut = false
        do { _ = try await client.request(slow, timeout: 0.1, closeOnCancel: false, closeOnTimeout: false) }
        catch { timedOut = true }
        try check(timedOut && client.isConnected, "report timeout must preserve the music connection")
        let response = try await client.request(.init(action: .observe, observing: true))
        try check(response.success, "music controls remain usable after a report timeout")
        print("PASS: report timeout preserves authenticated music connection and next control reply")

        let report = DesktopReport.build(readings: [], moods: [], practices: [], sleepSamples: [])
        let upload = DesktopMusicRequest(action: .reportUpload, report: report)
        let pending = Task {
            try await client.request(upload, closeOnCancel: false, closeOnTimeout: false)
        }
        try await waitUntil { heldRequests.contains(where: { $0.id == upload.id }) }
        pending.cancel()
        var cancelled = false
        do { _ = try await pending.value }
        catch is CancellationError { cancelled = true }
        try check(cancelled && client.isConnected, "foreground report cancellation must not pause music")
        // A late save acknowledgement must not resurrect the cancelled request.
        try server?.send(JSONEncoder().encode(DesktopMusicResponse(id: upload.id)))
        let afterCancellation = try await client.request(.init(action: .observe, observing: true))
        try check(afterCancellation.success && client.isConnected, "late report reply cannot disrupt later control replies")
        print("PASS: background-style cancellation and late acknowledgement preserve music controls")

        // Returning to the foreground reads the authoritative state. A delayed
        // read must not close the socket and make the Mac pause its session.
        let sessionID = UUID()
        let status = DesktopMusicRequest(action: .command,
            command: .init(sessionID: sessionID, action: .status))
        var statusTimedOut = false
        do { _ = try await client.request(status, timeout: 0.1) }
        catch { statusTimedOut = true }
        try check(statusTimedOut && client.isConnected, "foreground status timeout must not disconnect or pause Mac playback")
        let state = DesktopPlaybackSnapshot(sessionID: sessionID, revision: 1,
            queue: [.init(track: .rain)], index: 0, position: 12, duration: 120,
            playing: true, mode: .sequence, volume: 0.5, deadline: nil)
        var receivedState: DesktopPlaybackSnapshot?
        client.onSnapshot = { receivedState = $0 }
        try server?.send(JSONEncoder().encode(DesktopMusicResponse(id: status.id, snapshot: state)))
        try await waitUntil { receivedState == state }
        let afterStatus = try await client.request(.init(action: .observe, observing: true))
        try check(afterStatus.success && client.isConnected, "late authoritative state remains usable without reconnecting")
        print("PASS: delayed foreground status preserves connection and accepts Mac state")

        let cancelledStatus = DesktopMusicRequest(action: .command,
            command: .init(sessionID: sessionID, action: .status))
        let reading = Task { try await client.request(cancelledStatus) }
        try await waitUntil { heldRequests.contains(where: { $0.id == cancelledStatus.id }) }
        reading.cancel()
        var statusCancelled = false
        do { _ = try await reading.value }
        catch is CancellationError { statusCancelled = true }
        try check(statusCancelled && client.isConnected, "cancelling a status read must preserve Mac playback")
        print("PASS: cancelling foreground observation preserves the playback session")

        // Music commands retain their original fail-closed timeout policy.
        do { _ = try await client.request(.init(action: .command,
            command: .init(sessionID: sessionID, action: .next)), timeout: 0.1) }
        catch { }
        try await waitUntil { !client.isConnected }
        print("PASS: default control timeout still invalidates an unconfirmed music connection")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock.now >= limit { throw CheckFailure.failed("Loopback check timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
