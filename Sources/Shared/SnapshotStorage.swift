import Foundation
import QingkongCore

enum SnapshotStorage {
    static let group = "group.cn.geckoai.qingkong.shared"
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("complication-v1.json")
    }
    static func load(from location: URL? = nil) -> ComplicationSnapshot? {
        guard let url = location ?? url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ComplicationSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: ComplicationSnapshot, to location: URL? = nil) throws -> Bool {
        guard let url = location ?? url else { throw CocoaError(.fileNoSuchFile) }
        if var previous = load(from: url) {
            previous.generatedAt = snapshot.generatedAt
            if previous == snapshot { return false }
        }
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }

    @discardableResult
    static func saveMood(_ mood: MoodSummary?, preferences: Preferences, to location: URL? = nil) throws -> Bool {
        let previous = load(from: location)
        // A Watch message may wake the phone before HealthKit has loaded in this process.
        let snapshot = ComplicationSnapshot(readings: previous?.readings ?? [], trends: previous?.trends ?? [:], preferences: preferences, mood: mood)
        return try save(snapshot, to: location)
    }
}
