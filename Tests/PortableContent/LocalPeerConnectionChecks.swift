import Foundation
import Network
import Security

private enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let message): message } }
}

@MainActor
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

@MainActor
private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw CheckFailure.failed("Timed out waiting for a loopback condition") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private final class LoopbackPair {
    static let code = "0011-2233-4455-6677-8899-AABB"
    private var listener: NWListener?
    private var listenerReady = false
    var client: LocalPeerConnection?
    var server: LocalPeerConnection?
    var clientReady = false
    var serverReady = false
    var clientMessages: [Data] = []
    var serverMessages: [Data] = []
    var clientCloses: [String] = []
    var serverCloses: [String] = []

    func start(clientCode: String = LoopbackPair.code, plainServer: Bool = false, secret: Data? = nil, clientSecret: Data? = nil) async throws {
        let secure = try secret.map { try DesktopPairing.parameters(secret: $0) } ?? DesktopPairing.parameters(code: Self.code)
        let parameters = plainServer ? NWParameters.tcp : secure
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.listenerReady = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let server = LocalPeerConnection(connection)
                self.server = server
                server.onReady = { [weak self] in self?.serverReady = true }
                server.onMessage = { [weak self] in self?.serverMessages.append($0) }
                server.onClose = { [weak self] in self?.serverCloses.append($0) }
                server.start()
            }
        }
        listener.start(queue: .main)
        try await waitUntil { self.listenerReady }
        let port = listener.port!
        try require(port.rawValue != 0, "Listener did not receive an ephemeral port")
        let clientParameters = try (clientSecret ?? secret).map { try DesktopPairing.parameters(secret: $0) } ?? DesktopPairing.parameters(code: clientCode)
        clientParameters.requiredInterfaceType = .loopback
        let client = LocalPeerConnection(NWConnection(host: "127.0.0.1", port: port, using: clientParameters))
        self.client = client
        client.onReady = { [weak self] in self?.clientReady = true }
        client.onMessage = { [weak self] in self?.clientMessages.append($0) }
        client.onClose = { [weak self] in self?.clientCloses.append($0) }
        client.start()
    }

    func ready() async throws {
        do { try await waitUntil { self.clientReady && self.serverReady } }
        catch { throw CheckFailure.failed("TLS readiness failed; client: \(String(describing: client?.connection.state)), server: \(String(describing: server?.connection.state)); client close: \(clientCloses), server close: \(serverCloses)") }
    }

    func stop() {
        client?.close(); server?.close(); listener?.cancel(); listener?.newConnectionHandler = nil
    }

    func sendRaw(_ data: Data) async throws {
        guard let connection = client?.connection else { throw CheckFailure.failed("Missing client connection") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

@MainActor
private enum LocalPeerConnectionChecks {
    static func frame(_ data: Data) -> Data {
        header(data.count) + data
    }

    static func header(_ size: Int) -> Data {
        var bigEndian = UInt32(size).bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func run() async throws {
        try await accountSecretAuthenticatesOnlySameAccount()
        try await correctCodeUsesTLSAndTransmitsBothDirections()
        try await wrongCodeNeverReadiesOrReceivesMessages()
        try await fragmentedAndCoalescedFramesRetainMessageBoundaries()
        try await invalidHeadersCloseWithoutMessages()
        try await disconnectClosesOnlyOnce()
        try await handshakeTimeoutClosesWithoutReadiness()
        print("PASS: encrypted loopback, wrong-code rejection, fragmented/coalesced frames, invalid sizes, disconnect, timeout")
    }

    static func accountSecretAuthenticatesOnlySameAccount() async throws {
        for secret in [Data(), Data(repeating: 1, count: 31), Data(repeating: 1, count: 33)] {
            do { _ = try DesktopPairing.parameters(secret: secret); throw CheckFailure.failed("Invalid account secret accepted") }
            catch DesktopConnectionError.invalidMessage {}
        }
        let pair = LoopbackPair()
        defer { pair.stop() }
        try await pair.start(secret: Data(repeating: 0x4a, count: 32))
        try await pair.ready()
        try pair.client!.send(Data("account-authenticated".utf8))
        try await waitUntil { pair.serverMessages.count == 1 }
        try require(pair.serverMessages.first == Data("account-authenticated".utf8), "Account secret did not authenticate transport")
        let stranger = LoopbackPair()
        defer { stranger.stop() }
        try await stranger.start(secret: Data(repeating: 0x4a, count: 32), clientSecret: Data(repeating: 0x5b, count: 32))
        try await waitUntil(seconds: 15) { !stranger.clientCloses.isEmpty }
        try require(!stranger.clientReady && stranger.serverMessages.isEmpty, "Different account accessed application data")
        print("PASS: same-account 256-bit credential works, different account and malformed credentials rejected")
    }

    static func correctCodeUsesTLSAndTransmitsBothDirections() async throws {
        let pair = LoopbackPair()
        defer { pair.stop() }
        try await pair.start()
        try await pair.ready()
        let metadata = pair.client!.connection.metadata(definition: NWProtocolTLS.definition) as! NWProtocolTLS.Metadata
        try require(sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv12, "Connection did not negotiate TLS 1.2")
        try require(sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue == UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256), "Connection did not negotiate the authenticated PSK cipher")
        for invalid in [Data(), Data(repeating: 0, count: DesktopPairing.maximumMessageSize + 1)] {
            do {
                try pair.client!.send(invalid)
                throw CheckFailure.failed("Invalid outbound size was accepted")
            } catch DesktopConnectionError.invalidMessage {}
        }
        try pair.client!.send(Data("from Mac".utf8))
        try pair.server!.send(Data("from phone".utf8))
        try await waitUntil { pair.clientMessages.count == 1 && pair.serverMessages.count == 1 }
        try require(pair.serverMessages == [Data("from Mac".utf8)], "Client message changed")
        try require(pair.clientMessages == [Data("from phone".utf8)], "Server message changed")
        print("PASS: matching codes negotiated TLS 1.2 PSK AES-128-GCM and exchanged messages")
    }

    static func wrongCodeNeverReadiesOrReceivesMessages() async throws {
        let pair = LoopbackPair()
        defer { pair.stop() }
        try await pair.start(clientCode: "FFFF-FFFF-FFFF-FFFF-FFFF-FFFF")
        try await waitUntil(seconds: 15) { !pair.clientCloses.isEmpty && !pair.serverCloses.isEmpty }
        try require(!pair.clientReady && !pair.serverReady, "Wrong pairing code reached ready")
        try require(pair.clientMessages.isEmpty && pair.serverMessages.isEmpty, "Wrong pairing code received application data")
        do {
            try pair.client!.send(Data("secret".utf8))
            throw CheckFailure.failed("Closed unauthenticated peer accepted a message")
        } catch DesktopConnectionError.disconnected {}
        print("PASS: wrong code failed before readiness or application data")
    }

    static func fragmentedAndCoalescedFramesRetainMessageBoundaries() async throws {
        let pair = LoopbackPair()
        defer { pair.stop() }
        try await pair.start()
        try await pair.ready()
        let first = frame(Data("fragmented".utf8))
        try await pair.sendRaw(Data(first.prefix(2)))
        try await Task.sleep(for: .milliseconds(30))
        try require(pair.serverMessages.isEmpty, "Incomplete header produced a message")
        try await pair.sendRaw(Data(first.dropFirst(2).prefix(4)))
        try await Task.sleep(for: .milliseconds(30))
        try require(pair.serverMessages.isEmpty, "Incomplete body produced a message")
        try await pair.sendRaw(Data(first.dropFirst(6)) + frame(Data("second".utf8)) + frame(Data("third".utf8)))
        try await waitUntil { pair.serverMessages.count == 3 }
        try require(pair.serverMessages == [Data("fragmented".utf8), Data("second".utf8), Data("third".utf8)], "Fragmentation or coalescing changed message boundaries")
        let maximumMessage = Data(repeating: 0xA5, count: DesktopPairing.maximumMessageSize)
        try pair.client!.send(maximumMessage)
        try await waitUntil { pair.serverMessages.count == 4 }
        try require(pair.serverMessages.last == maximumMessage, "Maximum legal frame was truncated or rejected")
        print("PASS: fragmented headers/bodies and coalesced messages preserved boundaries")
    }

    static func invalidHeadersCloseWithoutMessages() async throws {
        for size in [0, DesktopPairing.maximumMessageSize + 1] {
            let pair = LoopbackPair()
            defer { pair.stop() }
            try await pair.start()
            try await pair.ready()
            try await pair.sendRaw(header(size))
            try await waitUntil { !pair.serverCloses.isEmpty }
            try require(pair.serverMessages.isEmpty, "Invalid frame produced application data")
            try require(pair.serverCloses == [DesktopConnectionError.invalidMessage.localizedDescription], "Invalid frame did not close with the expected error")
        }
        print("PASS: empty and oversized inbound frames closed before payload allocation")
    }

    static func disconnectClosesOnlyOnce() async throws {
        let pair = LoopbackPair()
        defer { pair.stop() }
        try await pair.start()
        try await pair.ready()
        try await pair.sendRaw(header(8) + Data("cut".utf8))
        pair.client!.close()
        pair.client!.close()
        try await waitUntil { !pair.serverCloses.isEmpty }
        try require(pair.clientCloses.count == 1 && pair.serverCloses.count == 1, "Disconnect callback ran more than once")
        try require(pair.serverMessages.isEmpty, "Truncated frame was delivered on disconnect")
        try require(pair.client!.onReady == nil && pair.client!.onMessage == nil && pair.client!.onClose == nil, "Closed peer retained callbacks")
        do {
            try pair.client!.send(Data("late".utf8))
            throw CheckFailure.failed("Disconnected peer accepted a message")
        } catch DesktopConnectionError.disconnected {}
        print("PASS: disconnect cancelled both peers and notified closure once")
    }

    static func handshakeTimeoutClosesWithoutReadiness() async throws {
        let pair = LoopbackPair()
        defer { pair.stop() }
        try await pair.start(plainServer: true)
        try await waitUntil(seconds: 15) { !pair.clientCloses.isEmpty }
        try require(!pair.clientReady, "Plain TCP server completed the TLS handshake")
        try require(pair.clientMessages.isEmpty, "Unencrypted peer delivered application data")
        try require(pair.clientCloses == [DesktopConnectionError.timedOut.localizedDescription], "Handshake stall did not close with timeout")
        try require(pair.client!.onReady == nil && pair.client!.onMessage == nil && pair.client!.onClose == nil, "Timed-out peer retained callbacks")
        print("PASS: stalled TLS handshake closed after its timeout")
    }
}

@main
private enum ChecksMain {
    static func main() {
        Task { @MainActor in
            do {
                try await LocalPeerConnectionChecks.run()
                exit(EXIT_SUCCESS)
            } catch {
                print("FAIL: \(error)")
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}
