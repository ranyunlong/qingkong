import Foundation
import QingkongCore

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
struct TestPlaylistChecks {
    @MainActor static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let media = URL(fileURLWithPath: CommandLine.arguments[2])
        let snapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: Data(contentsOf: source)).validated()
        try check(snapshot.albums.count == 3 && snapshot.tracks.count == 30 && snapshot.albums.allSatisfy { $0.trackIDs.count == 10 },
                  "test catalog must retain all three ordered playlists with ten tracks each")
        try check(snapshot.albums.map(\.title) == ["晴天随行", "星光慢行", "微风来信"], "album titles and supplied playlist order must be retained")
        for album in snapshot.albums {
            let ordered = snapshot.tracks.filter { $0.albumID == album.id }.sorted { $0.sortOrder < $1.sortOrder }.map(\.id)
            try check(ordered == album.trackIDs, "album sequence must match the supplied track order")
        }
        print("PASS: three albums preserve all thirty supplied tracks and their order")

        let root = FileManager.default.temporaryDirectory.appending(path: "qingkong-playlist-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectory = root.appending(path: "phone")
        let cache = AudioDownloads(testing: true, reset: true, directoryOverride: cacheDirectory)
        cache.reconcile(with: snapshot.tracks)
        for track in snapshot.tracks {
            let original = media.appending(path: track.id + ".mp3")
            try check(FileManager.default.fileExists(atPath: original.path), "source audio missing: \(track.title)")
            let staged = root.appending(path: "staged-" + track.id + ".mp3")
            try FileManager.default.copyItem(at: original, to: staged)
            await cache.verifyCompletedDownload(at: staged, track: track, intent: .manual)
            try check(cache.state(for: track) == .offline && cache.localURL(for: track) != nil,
                      "real complete MP3 must pass production offline verification: \(track.title)")
        }
        let expectedBytes = snapshot.tracks.reduce(Int64(0)) { $0 + $1.byteSize }
        try check(cache.manualBytes == expectedBytes && cache.storedRecords.count == 30, "manual cache index must account for all verified bytes")
        print("PASS: all thirty real MP3s pass actual download-store integrity and playability checks")

        let separate = AudioDownloads(testing: true, reset: true, directoryOverride: root.appending(path: "separate-device"))
        separate.reconcile(with: snapshot.tracks)
        try check(snapshot.tracks.allSatisfy { separate.localURL(for: $0) == nil } && separate.manualBytes == 0,
                  "another device store must not inherit the phone's files")
        print("PASS: a separate device store has none of the phone's downloaded playlist files")

        let reopened = AudioDownloads(testing: true, directoryOverride: cacheDirectory)
        reopened.reconcile(with: snapshot.tracks)
        let deadline = Date.now.addingTimeInterval(30)
        while snapshot.tracks.contains(where: { reopened.localURL(for: $0) == nil }) && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(snapshot.tracks.allSatisfy { reopened.localURL(for: $0) != nil } && reopened.manualBytes == expectedBytes,
                  "reopening the actual index must reverify all thirty MP3s")
        print("PASS: reopening the real file index reverifies all thirty offline tracks")

        let first = snapshot.tracks[0]
        let playingURL = reopened.localURL(for: first)!
        reopened.setPlayingTrack(first)
        reopened.reconcile(with: Array(snapshot.tracks.dropFirst()))
        try check(reopened.localURL(for: first) == nil && FileManager.default.fileExists(atPath: playingURL.path),
                  "withdrawn track must become unavailable while its active file stays protected")
        reopened.deleteStored(identity: first.cacheIdentity)
        try check(reopened.storedRecord(for: first) != nil, "protected file must remain indexed until playback releases it")
        reopened.setPlayingTrack(nil)
        try check(reopened.storedRecord(for: first) == nil && !FileManager.default.fileExists(atPath: playingURL.path),
                  "releasing playback must remove the retired file and index")
        print("PASS: withdrawal protects the active file until release without allowing new offline use")

        for record in reopened.storedRecords { reopened.deleteStored(identity: record.identity) }
        try check(reopened.manualBytes == 0 && reopened.storedRecords.isEmpty, "all remaining playlist downloads must be removable")
        print("PASS: all remaining playlist downloads can be removed and their space accounted for")
        print("6 real-playlist checks passed for 30 MP3s; no network, audio playback, simulator, or device used.")
    }
}
