#if os(iOS)
import Foundation
import QingkongCore

enum WatchBatteryStorage {
    static let kind = "QingkongWatchBattery"
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SnapshotStorage.group)?
            .appendingPathComponent("watch-battery-v1.json")
    }

    static func load(from location: URL? = nil) -> WatchBatterySnapshot? {
        guard let url = location ?? url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WatchBatterySnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ value: WatchBatterySnapshot, now: Date = .now, to location: URL? = nil) throws -> Bool {
        guard value.percentage(at: now) != nil else { return false }
        guard let url = location ?? url else { throw CocoaError(.fileNoSuchFile) }
        if let previous = load(from: url), previous.sampledAt >= value.sampledAt { return false }
        try JSONEncoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }

    static func clear() throws {
        guard let url else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
#endif
