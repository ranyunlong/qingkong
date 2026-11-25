import Foundation

/// This status describes an opted-in foreground transfer, not access to raw health data.
public enum DesktopReportSyncState: String, Codable, Equatable, Sendable {
    case disabled, enabled, syncing, failed
    public static let capability = "report-auto-sync-v1"
}

/// Device-local consent. An account change revokes every previously enabled Mac.
public struct DesktopReportAuthorization: Codable, Equatable, Sendable {
    public private(set) var accountScope: String?
    private var enabledMacs: Set<UUID> = []

    public init() {}

    public mutating func confirmAccount(_ scope: String?) {
        guard accountScope != scope else { return }
        enabledMacs = []
        accountScope = scope
    }

    public mutating func setEnabled(_ enabled: Bool, for mac: UUID) {
        guard accountScope != nil else { return }
        if enabled { enabledMacs.insert(mac) } else { enabledMacs.remove(mac) }
    }

    public func isEnabled(for mac: UUID) -> Bool { accountScope != nil && enabledMacs.contains(mac) }

    public func maySend(to mac: UUID, foreground: Bool, connected: Bool, isDemo: Bool) -> Bool {
        foreground && connected && !isDemo && isEnabled(for: mac)
    }
}

extension DesktopReport {
    /// Stable content for coalescing refreshes. generatedAt changes even without new data.
    public func contentIdentity() throws -> Data {
        struct Content: Encodable {
            let timeZoneIdentifier: String
            let days: [DesktopReportDay]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Content(timeZoneIdentifier: timeZoneIdentifier, days: days))
    }
}
