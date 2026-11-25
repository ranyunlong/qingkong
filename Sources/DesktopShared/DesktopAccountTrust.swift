#if os(iOS) || os(macOS)
import CloudKit
import CryptoKit
import Foundation
import Observation
import Security

/// CloudKit stores only a random local-connection key, never application content.
@MainActor @Observable
final class DesktopAccountTrust {
    private(set) var credential: Data?
    private(set) var status = "正在检查 iCloud 自动连接…"
    private(set) var accountScope: String?
    private(set) var accountChangeID = UUID()
    @ObservationIgnored var didChange: (() -> Void)?

    @ObservationIgnored private let container = CKContainer(identifier: "iCloud.cn.geckoai.qingkong")
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var accountObserver: DesktopAccountChangeObserver?

    private static let recordID = CKRecord.ID(recordName: "local-connection-v1")
    private static let recordType = "DesktopLocalTrust"
    private static let credentialField = "credential"

    init() {
        accountObserver = DesktopAccountChangeObserver { [weak self] in
            // The observer is explicitly delivered on the main queue. Invalidate
            // synchronously so an existing LAN connection is closed immediately.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshID = UUID()
                self.update(credential: nil, scope: nil, accountChanged: true)
                self.status = "iCloud 账号已变化，正在重新验证…"
                Task { [weak self] in await self?.refresh() }
            }
        }
    }

    func refresh() async {
        let requestID = UUID()
        refreshID = requestID
        status = "正在检查 iCloud 自动连接…"
        do {
            let scope = try await validatedAccountScope()
            guard refreshID == requestID else { return }
            if accountScope != scope { update(credential: nil, scope: scope) }

            do {
                let value = try await fetchOrCreateCredential()
                try await verifyAccountScope(scope)
                guard refreshID == requestID else { return }
                // Publish only after verifying the account again: the user may
                // have changed accounts while a CloudKit request was in flight.
                let cached = DesktopTrustKeychain.save(value, scope: scope)
                update(credential: value, scope: scope)
                status = cached ? "同一 iCloud 账号的自动连接已就绪。" : "自动连接已就绪，本机凭据缓存暂不可用。"
            } catch {
                guard refreshID == requestID else { return }
                if let cloudError = error as? CKError,
                   DesktopAccountTrustPolicy.allowsCachedFallback(cloudError.code) {
                    // A previously known identity is insufficient after an
                    // account change or an identity lookup failure.
                    try await verifyAccountScope(scope)
                    guard refreshID == requestID else { return }
                    if let cached = DesktopTrustKeychain.load(scope: scope) {
                        update(credential: cached, scope: scope)
                        status = "iCloud 暂时不可用，正使用已验证账号的本机连接凭据。"
                        return
                    }
                }
                throw error
            }
        } catch {
            guard refreshID == requestID else { return }
            let accountChanged: Bool
            switch error {
            case TrustError.accountUnavailable(.noAccount), TrustError.accountChanged: accountChanged = true
            default: accountChanged = false
            }
            update(credential: nil, scope: nil, accountChanged: accountChanged)
            status = unavailableMessage(for: error)
        }
    }

    private func update(credential: Data?, scope: String?, accountChanged: Bool = false) {
        guard accountChanged || self.credential != credential || accountScope != scope else { return }
        if accountChanged { accountChangeID = UUID() }
        self.credential = credential
        accountScope = scope
        didChange?()
    }

    private func validatedAccountScope() async throws -> String {
        let availability = try await container.accountStatus()
        guard availability == .available else { throw TrustError.accountUnavailable(availability) }
        let userID = try await container.userRecordID()
        // Avoid putting a raw CloudKit user identifier into the Keychain label.
        let identity = "iCloud.cn.geckoai.qingkong:" + userID.recordName
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func verifyAccountScope(_ expected: String) async throws {
        guard try await validatedAccountScope() == expected else { throw TrustError.accountChanged }
    }

    private func fetchOrCreateCredential() async throws -> Data {
        let database = container.privateCloudDatabase
        do {
            return try credential(from: await database.record(for: Self.recordID))
        } catch {
            guard let cloudError = error as? CKError,
                  DesktopAccountTrustPolicy.allowsCreation(cloudError.code) else { throw error }
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw TrustError.randomUnavailable
        }
        let record = CKRecord(recordType: Self.recordType, recordID: Self.recordID)
        record.encryptedValues[Self.credentialField] = Data(bytes) as NSData
        do {
            // A new record has no change tag. This policy prevents simultaneous
            // first launches from overwriting the winning device's key.
            let results = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false
            )
            guard let result = results.saveResults[Self.recordID] else { throw TrustError.invalidRecord }
            return try credential(from: result.get())
        } catch let error as CKError where error.code == .serverRecordChanged {
            if let winner = error.serverRecord { return try credential(from: winner) }
            return try credential(from: await database.record(for: Self.recordID))
        }
    }

    private func credential(from record: CKRecord) throws -> Data {
        guard record.recordID == Self.recordID, record.recordType == Self.recordType,
              let value = record.encryptedValues[Self.credentialField] as? Data,
              DesktopAccountTrustPolicy.isValidCredential(value) else { throw TrustError.invalidRecord }
        return value
    }

    private func unavailableMessage(for error: Error) -> String {
        if case TrustError.accountUnavailable(let availability) = error {
            switch availability {
            case .noAccount: return "请在系统设置中登录 iCloud，以使用同账号自动连接。"
            case .restricted: return "当前 iCloud 账号不允许使用自动连接。"
            default: return "暂时无法验证 iCloud 账号，请稍后重试。"
            }
        }
        if case TrustError.invalidRecord = error {
            return "iCloud 连接凭据无法验证，请检查两端版本后重试。"
        }
        return "iCloud 自动连接暂不可用，请稍后重试。"
    }

    private enum TrustError: Error {
        case accountUnavailable(CKAccountStatus), accountChanged, invalidRecord, randomUnavailable
    }
}

enum DesktopAccountTrustPolicy {
    static func isValidCredential(_ value: Data) -> Bool { value.count == 32 }

    static func allowsCreation(_ code: CKError.Code) -> Bool { code == .unknownItem }

    static func allowsCachedFallback(_ code: CKError.Code) -> Bool {
        switch code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy, .serverResponseLost: true
        default: false
        }
    }
}

/// The notification registration has no mutable state after initialization.
private final class DesktopAccountChangeObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(onChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { _ in
            onChange()
        }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

private enum DesktopTrustKeychain {
    private static let service = "cn.geckoai.qingkong.desktop-account-trust.v1"

    private static func query(scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: scope,
         kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }

    static func load(scope: String) -> Data? {
        var request = query(scope: scope)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let value = item as? Data,
              DesktopAccountTrustPolicy.isValidCredential(value) else { return nil }
        return value
    }

    static func save(_ value: Data, scope: String) -> Bool {
        guard DesktopAccountTrustPolicy.isValidCredential(value) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let request = query(scope: scope)
        let result = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if result == errSecSuccess { return true }
        guard result == errSecItemNotFound else { return false }
        return SecItemAdd(request.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
}
#endif
