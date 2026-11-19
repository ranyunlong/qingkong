import Foundation
import QingkongCore

enum SnapshotStorage {
    static let group = "group.cn.geckoai.qingkong.shared"
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("complication-v1.json")
    }
    static func load() -> ComplicationSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ComplicationSnapshot.self, from: data)
    }
    static func save(_ snapshot: ComplicationSnapshot) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
