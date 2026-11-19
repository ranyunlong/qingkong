import Foundation
import Observation
import SwiftData
import QingkongCore

@Model
final class StoredMood {
    @Attribute(.unique) var id: UUID
    var payload: Data
    var updatedAt: Date
    var pendingSync: Bool
    init(record: MoodRecord, pendingSync: Bool) throws {
        id = record.id; payload = try JSONEncoder().encode(record)
        updatedAt = record.updatedAt; self.pendingSync = pendingSync
    }
}

@MainActor @Observable
final class LocalStore {
    let container: ModelContainer
    private(set) var records: [MoodRecord] = []
    private(set) var preferences: Preferences
    var error: String?
    @ObservationIgnored var didChange: (() -> Void)?
    @ObservationIgnored var didChangePreferences: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let context: ModelContext
    private let preferencesKey = "qingkong.preferences.v1"

    var entries: [MoodRecord] { records.filter { !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt } }
    var scene: SceneTheme { preferences.scene(entries: records) }

    init(testing: Bool = false, reset: Bool = false) throws {
        defaults = testing ? UserDefaults(suiteName: "cn.geckoai.qingkong.uitests")! : .standard
        if testing && reset { defaults.removePersistentDomain(forName: "cn.geckoai.qingkong.uitests") }
        preferences = defaults.data(forKey: "qingkong.preferences.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        let folder = URL.applicationSupportDirectory.appending(path: "Qingkong", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = ModelConfiguration(url: folder.appending(path: testing ? "uitests.store" : "journal.store"), cloudKitDatabase: .none)
        container = try ModelContainer(for: StoredMood.self, configurations: config)
        context = ModelContext(container)
        context.autosaveEnabled = false
        if testing && reset {
            try context.delete(model: StoredMood.self)
            try context.save()
        }
        try reload()
    }

    func add(mood: Int, stress: Int, note: String) throws {
        try save(MoodRecord(mood: mood, stress: stress, note: note))
    }

    func delete(_ record: MoodRecord) throws {
        var tombstone = record
        tombstone.isDeleted = true
        tombstone.note = ""
        tombstone.updatedAt = max(.now, record.updatedAt.addingTimeInterval(0.001))
        try save(tombstone)
    }

    func save(_ incoming: MoodRecord, fromPeer: Bool = false) throws {
        let rows = try context.fetch(FetchDescriptor<StoredMood>())
        if let row = rows.first(where: { $0.id == incoming.id }) {
            let local = try JSONDecoder().decode(MoodRecord.self, from: row.payload)
            let resolved = RecordMerge.resolve(local: local, incoming: incoming)
            guard resolved != local else { return }
            row.payload = try JSONEncoder().encode(resolved)
            row.updatedAt = resolved.updatedAt
            row.pendingSync = !fromPeer
        } else {
            context.insert(try StoredMood(record: incoming, pendingSync: !fromPeer))
        }
        do { try context.save() } catch { context.rollback(); throw error }
        try reload()
        if !fromPeer { didChange?() }
    }

    func pendingRecords() throws -> [MoodRecord] {
        try context.fetch(FetchDescriptor<StoredMood>()).filter(\.pendingSync).map { try JSONDecoder().decode(MoodRecord.self, from: $0.payload) }
    }

    func acknowledge(_ receipt: SyncReceipt) throws {
        guard let row = try context.fetch(FetchDescriptor<StoredMood>()).first(where: { $0.id == receipt.id }) else { return }
        guard receipt.matches(try JSONDecoder().decode(MoodRecord.self, from: row.payload)) else { return }
        row.pendingSync = false
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func updatePreferences(_ edit: (inout Preferences) -> Void) {
        var value = preferences
        edit(&value)
        value.updatedAt = .now
        preferences = value
        persistPreferences()
        didChangePreferences?()
    }

    func receivePreferences(_ incoming: Preferences) {
        guard incoming.updatedAt > preferences.updatedAt else { return }
        preferences = incoming
        persistPreferences()
        // Store the received version without assigning a new timestamp or echoing it.
    }

    private func persistPreferences() {
        do { defaults.set(try JSONEncoder().encode(preferences), forKey: preferencesKey) }
        catch { self.error = "偏好暂未保存，请重试。" }
    }

    private func reload() throws {
        records = try context.fetch(FetchDescriptor<StoredMood>()).map { try JSONDecoder().decode(MoodRecord.self, from: $0.payload) }
    }
}
