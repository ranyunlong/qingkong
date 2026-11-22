import Foundation
import Darwin
import QingkongCore

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
struct LiveAudioDownloadChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: source)
        let snapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: data).validated()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check(object["testOnly"] as? Bool == true, "only the explicitly marked test catalog may be used")
        guard let track = snapshot.tracks.min(by: { $0.byteSize < $1.byteSize }) else {
            throw CheckFailure.failed("test catalog has no tracks")
        }
        try check(track.byteSize <= 20_000_000, "live check is limited to one source file no larger than 20 MB")

        let root = FileManager.default.temporaryDirectory.appending(path: "qingkong-live-download-" + UUID().uuidString)
        let directory = root.appending(path: "cache")
        // This process-local override permits the Mac's current route without changing App preferences.
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previousArguments
        arguments["audio-wifi-only"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
            try? FileManager.default.removeItem(at: root)
        }
        let cache = AudioDownloads(directoryOverride: directory)
        defer { cache.interruptForegroundDownloads() }
        cache.reconcile(with: [track])

        let networkDeadline = Date.now.addingTimeInterval(15)
        while !cache.networkAvailable && Date.now < networkDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(cache.networkAvailable, "no live network route became available; no network behavior is verified")
        try check(!cache.wifiOnlyDownloads, "network preference override must remain process-local")
        print("SOURCE: \(track.title) (\(track.byteSize) bytes); actual URLSession requests, no audio playback")

        cache.download(track, intent: .manual)
        let partialDeadline = Date.now.addingTimeInterval(30)
        var observedPartial = false
        while Date.now < partialDeadline {
            switch cache.state(for: track) {
            case .downloading(let progress) where progress > 0 && progress < 1:
                observedPartial = true
            case .failed(let reason): throw CheckFailure.failed("first live request failed: " + reason)
            case .offline: throw CheckFailure.failed("file finished before a partial-transfer cancellation could be verified")
            default: break
            }
            if observedPartial { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(observedPartial && cache.localURL(for: track) == nil, "partially received bytes must not be offline audio")
        cache.delete(track)
        try await Task.sleep(for: .milliseconds(200))
        try check(cache.localURL(for: track) == nil && cache.manualBytes == 0, "cancelled transfer must not produce an offline record")
        print("PASS: real partial HTTPS transfer stays unavailable offline and can be cancelled")

        @MainActor func awaitOffline(_ item: PublicAudioTrack) async throws -> URL {
            let deadline = Date.now.addingTimeInterval(120)
            while Date.now < deadline {
                if let url = cache.localURL(for: item) { return url }
                if case .failed(let reason) = cache.state(for: item) { throw CheckFailure.failed(reason) }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CheckFailure.failed("live download did not complete within 120 seconds")
        }

        cache.download(track, intent: .manual)
        let firstURL = try await awaitOffline(track)
        let matches = try AudioFileIntegrity.matches(fileURL: firstURL, byteSize: track.byteSize, sha256: track.sha256)
        try check(matches,
                  "real URLSession completion must retain the exact source bytes")
        try check(cache.manualBytes == track.byteSize, "only one completed file may be indexed after retry")
        print("PASS: retry completes through the production delegate, integrity and media checks")

        var revisedObject = object
        var revisedTracks = object["tracks"] as! [[String: Any]]
        let index = revisedTracks.firstIndex { $0["id"] as? String == track.id }!
        revisedTracks[index]["fileVersion"] = track.fileVersion + "-network-v2"
        revisedObject["tracks"] = revisedTracks
        let revisedSnapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: revisedObject)).validated()
        let revised = revisedSnapshot.tracks.first { $0.id == track.id }!
        cache.reconcile(with: [revised])
        try check(cache.localURL(for: track) == nil && cache.localURL(for: revised) == nil,
                  "new version must not reuse the retired offline identity")
        try check(!FileManager.default.fileExists(atPath: firstURL.path), "retired unprotected file must be removed")
        cache.download(revised, intent: .manual)
        let revisedURL = try await awaitOffline(revised)
        try check(revisedURL != firstURL && cache.manualBytes == revised.byteSize,
                  "new version must have its own complete file and exact space count")
        print("PASS: version replacement retires the old file and downloads a separately verified identity")

        let reopened = AudioDownloads(directoryOverride: directory)
        reopened.reconcile(with: [revised])
        let restoreDeadline = Date.now.addingTimeInterval(15)
        while reopened.localURL(for: revised) == nil && Date.now < restoreDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try check(reopened.localURL(for: revised) != nil, "reopening must reverify the actual downloaded file without another request")
        reopened.delete(revised)
        try check(reopened.manualBytes == 0 && reopened.storedRecords.isEmpty,
                  "completed live download must be deletable without an orphaned index")
        print("PASS: reopening reverifies downloaded bytes; deletion clears the file and space count")
        print("4 live-download checks passed for one supplied HTTPS source; two complete downloads plus one cancelled partial transfer.")
    }
}
