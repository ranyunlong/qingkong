#if os(iOS)
import Foundation
import QingkongCore

struct WidgetAudioSnapshot: Codable, Equatable {
    var generatedAt: Date
    let track: Track
    let onlineTrackID: String?
    let title: String
    let playing: Bool
    let buffering: Bool

    init(state: AudioState, now: Date = .now) {
        generatedAt = now
        track = state.track
        onlineTrackID = state.onlineTrackID
        title = state.displayTitle
        playing = state.playing
        buffering = state.buffering == true
    }
}

enum WidgetAudioStorage {
    static let kind = "QingkongDumplingMusic"
    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SnapshotStorage.group)?
            .appendingPathComponent("widget-audio-v1.json")
    }

    static func load(from location: URL? = nil) -> WidgetAudioSnapshot? {
        guard let url = location ?? url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetAudioSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: WidgetAudioSnapshot, to location: URL? = nil) throws -> Bool {
        guard let url = location ?? url else { throw CocoaError(.fileNoSuchFile) }
        if var previous = load(from: url) {
            previous.generatedAt = snapshot.generatedAt
            if previous == snapshot { return false }
        }
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }
}
#endif
