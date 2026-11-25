import Foundation
import Network
import QingkongCore

private enum CatalogCheckError: Error { case failed(String) }

/// Real phone transport, authenticated loopback, no cloud and no audio output.
@main @MainActor
struct CatalogConnectionChecks {
    static func main() async throws {
        let parameters = try DesktopPairing.parameters(secret: Data(repeating: 0x56, count: 32))
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        var ready = false
        var supportsCatalog = false
        var holdStatus = false
        var finishHello = false
        var catalogMessages = 0
        var chunks = 0
        var receiver = DesktopMusicCatalogReceiver()
        var saved: DesktopMusicCatalog?
        var transferInfo: DesktopMusicCatalogTransferInfo?
        var commitAt: Date?
        var servers: [LocalPeerConnection] = []
        listener.stateUpdateHandler = { state in Task { @MainActor in if case .ready = state { ready = true } } }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let server = LocalPeerConnection(connection); servers.append(server)
                server.onMessage = { data in
                    guard let request = try? JSONDecoder().decode(DesktopMusicRequest.self, from: data) else { return }
                    do {
                        var status: DesktopMusicCatalogStatus?
                        var receipt: DesktopMusicCatalogTransferInfo?
                        switch request.action {
                        case .hello:
                            try check(request.capabilities?.contains(DesktopMusicCatalog.capability) == true, "phone hello advertises catalog support")
                            let response = DesktopMusicResponse(id: request.id, hostID: UUID(),
                                capabilities: supportsCatalog ? [DesktopMusicCatalog.capability] : [])
                            if finishHello {
                                let payload = try JSONEncoder().encode(response)
                                var size = UInt32(payload.count).bigEndian
                                var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(payload)
                                connection.send(content: frame, contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in Task { @MainActor in server.close() } })
                            } else { try server.send(JSONEncoder().encode(response)) }
                            return
                        case .catalogStatus:
                            catalogMessages += 1
                            if holdStatus { return }
                        case .catalogBegin:
                            catalogMessages += 1
                            try receiver.begin(request.catalogTransfer!, current: saved)
                            transferInfo = request.catalogTransfer
                        case .catalogChunk:
                            catalogMessages += 1; chunks += 1
                            try check(data.count < 1_048_576, "chunk frame stays below transport cap")
                            try receiver.append(request.catalogChunk!)
                        case .catalogCommit:
                            catalogMessages += 1
                            saved = try receiver.commit(transferID: request.catalogTransferID!, current: saved, at: commitAt ?? .now)
                            receipt = transferInfo
                        default: break
                        }
                        if let saved { status = .init(catalog: saved, digest: try saved.contentDigest()) }
                        try server.send(JSONEncoder().encode(DesktopMusicResponse(id: request.id, catalogStatus: status, catalogReceipt: receipt)))
                    } catch {
                        try? server.send(JSONEncoder().encode(DesktopMusicResponse(id: request.id, success: false, error: error.localizedDescription)))
                    }
                }
                server.start()
            }
        }
        listener.start(queue: .main)
        defer { servers.forEach { $0.close() }; listener.cancel() }
        try await waitUntil { ready }
        func makeClient() -> PhoneMacPeer {
            PhoneMacPeer(id: UUID().uuidString, name: "Mac", endpoint: .hostPort(host: .ipv4(.loopback), port: listener.port!),
                secret: Data(repeating: 0x56, count: 32), deviceID: UUID().uuidString, deviceName: "iPhone")
        }
        let catalog = try fixture()
        let old = makeClient(); old.connect()
        try await waitUntil { old.isConnected }
        let skipped = try await old.syncMusicCatalog(catalog)
        try check(skipped == nil && catalogMessages == 0, "legacy host receives no unknown catalog messages")
        old.close()
        print("PASS: capability gate preserves older playback peers")

        supportsCatalog = true
        let client = makeClient(); client.connect()
        defer { client.close() }
        try await waitUntil { client.isConnected }
        let status = try await client.syncMusicCatalog(catalog)
        try check(status?.digest == catalog.contentDigest() && chunks >= 3 && saved == catalog, "complete multipart transfer gets verified acknowledgement")
        let sentChunks = chunks
        _ = try await client.syncMusicCatalog(catalog)
        try check(chunks == sentChunks, "unchanged content does not resend chunks")
        print("PASS: multipart catalog, real TLS framing, acknowledgement, and deduplication")

        let expiring = try fixture(expiresAt: Date.now.addingTimeInterval(60), revision: 2)
        commitAt = Date.now.addingTimeInterval(120)
        let prunedStatus = try await client.syncMusicCatalog(expiring)
        try check(prunedStatus?.trackCount == 0 && saved?.tracks.isEmpty == true,
                  "verified receipt acknowledges actual stored catalog when copyright expires during transfer")
        commitAt = nil
        print("PASS: verified transfer receipt permits actual expiry-pruned persisted state")

        finishHello = true
        let closingClient = makeClient()
        var changes = 0
        closingClient.onChange = { changes += 1 }
        closingClient.connect()
        try await waitUntil { changes > 0 }
        try await waitUntil { !closingClient.isConnected }
        try check(!closingClient.isConnected, "a hello reply followed by EOF cannot leave a ghost connected peer")
        finishHello = false
        closingClient.connect()
        try await waitUntil { closingClient.isConnected }
        closingClient.close()
        print("PASS: hello followed by EOF stays disconnected and can reconnect")

        holdStatus = true
        var timedOut = false
        do { _ = try await client.request(.init(action: .catalogStatus), timeout: 0.1, closeOnCancel: false, closeOnTimeout: false) }
        catch { timedOut = true }
        try check(timedOut && client.isConnected, "catalog timeout preserves music connection")
        let control = try await client.request(.init(action: .observe, observing: true))
        try check(control.success, "controls remain responsive after catalog timeout")
        let pending = Task { try await client.syncMusicCatalog(catalog) }
        try await Task.sleep(for: .milliseconds(50)); pending.cancel()
        do { _ = try await pending.value; throw CatalogCheckError.failed("cancel expected") }
        catch is CancellationError { }
        try check(client.isConnected, "background cancellation preserves music connection")
        print("PASS: timeout and cancellation preserve subsequent music controls")
    }

    private static func fixture(expiresAt: Date? = nil, revision: Int = 1) throws -> DesktopMusicCatalog {
        let stamp = "2026-11-24T00:00:00Z"
        let album: [String: Any] = ["id": "album", "title": "自然", "summary": String(repeating: "a", count: 600_000),
            "trackIDs": [], "updatedAt": stamp, "publishedAt": stamp, "revision": 1, "sortOrder": 0]
        var albumValue = album
        var tracks: [[String: Any]] = []
        if let expiresAt {
            albumValue["trackIDs"] = ["rain"]
            tracks = [["id": "rain", "albumID": "album", "title": "Rain", "audioURL": "https://example.org/rain.wav",
                "durationSeconds": 120, "fileVersion": "1", "byteSize": 100, "sha256": String(repeating: "a", count: 64),
                "copyright": ["owner": "Owner", "source": "Self", "license": "CC0", "expiresAt": ISO8601DateFormatter().string(from: expiresAt)],
                "updatedAt": stamp, "publishedAt": stamp, "revision": revision, "sortOrder": 0]]
        }
        let object: [String: Any] = ["schemaVersion": 1, "revision": revision, "generatedAt": stamp,
            "articles": [], "albums": [albumValue], "tracks": tracks, "tombstones": []]
        let snapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        return try DesktopMusicCatalog(snapshot: snapshot, serviceAddress: "https://example.org", checkedAt: Date.now)
    }
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CatalogCheckError.failed(message) }
    }
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < limit else { throw CatalogCheckError.failed("loopback timeout") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
