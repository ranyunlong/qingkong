import Foundation
import Network
import Security
import CryptoKit

enum DesktopConnectionError: LocalizedError {
    case disconnected, invalidMessage, timedOut
    var errorDescription: String? {
        switch self {
        case .disconnected: "连接已断开，请确认设备连接同一 Wi-Fi，且 Mac 上的小晴空正在运行。"
        case .invalidMessage: "设备返回的数据无法识别，请更新两端的小晴空。"
        case .timedOut: "等待设备确认超时，请检查 Wi-Fi 和 Mac 上的小晴空。"
        }
    }
}

enum DesktopPairing {
    static let serviceType = "_qingkong._tcp"
    static let maximumMessageSize = 1_048_576

    static func makeCode() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw DesktopConnectionError.disconnected
        }
        let value = bytes.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: value.count, by: 4).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return String(value[start..<value.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    static func normalizedCode(_ code: String) -> String? {
        let value = code.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count == 24, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return value
    }

    static func parameters(code: String) throws -> NWParameters {
        guard let value = normalizedCode(code) else { throw DesktopConnectionError.invalidMessage }
        let key = Data(SHA256.hash(data: Data(("qingkong-local-v1:" + value).utf8)))
        return secureParameters(key: key, identity: "qingkong-local-v1")
    }

    static func parameters(secret: Data) throws -> NWParameters {
        guard secret.count == 32 else { throw DesktopConnectionError.invalidMessage }
        let key = Data(SHA256.hash(data: Data("qingkong-account-v2:".utf8) + secret))
        return secureParameters(key: key, identity: "qingkong-account-v2")
    }

    private static func secureParameters(key: Data, identity: String) -> NWParameters {
        let identity = Data(identity.utf8)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, keyData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // PSK suites are declared in CipherSuite.h rather than the Swift enum.
        let cipher = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, cipher)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

@MainActor
final class LocalPeerConnection {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClose: ((String) -> Void)?
    private var buffer = Data()
    private var closed = false
    private var ready = false
    private var timeout: Task<Void, Never>?

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    self.ready = true; self.timeout?.cancel(); self.onReady?(); self.receive()
                case .failed, .cancelled:
                    self.close(message: "设备连接已断开，请检查同一 Apple ID、Wi-Fi 与本地网络权限。")
                default: break
                }
            }
        }
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !self.ready else { return }
            self.close(message: DesktopConnectionError.timedOut.localizedDescription)
        }
    }

    func send(_ data: Data) throws {
        guard !closed, ready else { throw DesktopConnectionError.disconnected }
        guard !data.isEmpty, data.count <= DesktopPairing.maximumMessageSize else { throw DesktopConnectionError.invalidMessage }
        var size = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &size) { Data($0) }
        framed.append(data)
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            if error != nil { Task { @MainActor in self?.close(message: DesktopConnectionError.disconnected.localizedDescription) } }
        })
    }

    func close(message: String = DesktopConnectionError.disconnected.localizedDescription) {
        guard !closed else { return }
        closed = true; timeout?.cancel(); connection.cancel(); buffer.removeAll()
        onClose?(message)
        onReady = nil; onMessage = nil; onClose = nil
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                while self.buffer.count >= 4 {
                    let size = self.buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                    guard size > 0, size <= DesktopPairing.maximumMessageSize else {
                        self.close(message: DesktopConnectionError.invalidMessage.localizedDescription); return
                    }
                    guard self.buffer.count >= size + 4 else { break }
                    let message = Data(self.buffer.dropFirst(4).prefix(size))
                    self.buffer = Data(self.buffer.dropFirst(size + 4))
                    self.onMessage?(message)
                    if self.closed { return }
                }
                if complete || error != nil { self.close(); return }
                self.receive()
            }
        }
    }
}
