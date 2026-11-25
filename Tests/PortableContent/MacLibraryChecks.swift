import AppKit
import CryptoKit
import Foundation
import QingkongCore

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}

private final class SnapshotProtocol: URLProtocol {
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct MacLibraryChecks {
    @MainActor static func main() async throws {
        let root = URL.temporaryDirectory.appending(path: "qingkong-mac-library-" + UUID().uuidString)
        let suite = "qingkong.mac.library." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://example.invalid", forKey: "QingkongContentURL")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/PublicContent/snapshot.json"))
        var object = try JSONSerialization.jsonObject(with: fixture) as! [String: Any]
        object["revision"] = 10
        SnapshotProtocol.payload = try JSONSerialization.data(withJSONObject: object)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SnapshotProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let content = ContentLibrary(defaults: defaults, directoryOverride: root.appending(path: "articles"), sessionOverride: session)
        let downloads = AudioDownloads(testing: true, directoryOverride: root.appending(path: "downloads"))
        let musicDirectory = root.appending(path: "music")
        let library = MacLibrary(content: content, downloads: downloads, directoryOverride: musicDirectory, sessionOverride: session)
        try check(!library.showsPortableAlbum, "unknown initial network state cannot flash the built-in fallback")
        downloads.updateNetworkAvailability(available: false, wifi: false, wired: false, expensive: false, constrained: false)
        try await wait { downloads.hasFinishedRestoringDownloads }
        try check(library.showsPortableAlbum, "offline without a valid downloaded album exposes the built-in fallback")
        downloads.updateNetworkAvailability(available: true, wifi: true, wired: false, expensive: false, constrained: false)
        try check(!library.showsPortableAlbum, "online never exposes the fallback album")
        func restoredLibrary() -> MacLibrary {
            let restoredContent = ContentLibrary(defaults: defaults, directoryOverride: root.appending(path: "articles"), sessionOverride: session)
            let restoredDownloads = AudioDownloads(testing: true, directoryOverride: root.appending(path: "restored-downloads-" + UUID().uuidString))
            return MacLibrary(content: restoredContent, downloads: restoredDownloads, directoryOverride: musicDirectory)
        }
        await library.refresh()
        try check(content.snapshot?.revision == 10 && library.musicCatalog?.revision == 10, "a direct refresh populates independent article and music stores")
        let originalArticles = content.articles
        guard let searchTrack = library.tracks.first,
              let searchAlbum = library.albums.first(where: { $0.id == searchTrack.albumID }) else { throw CheckFailure.failed("search fixture has no music") }
        try check(library.albums(matching: searchTrack.title, downloadedOnly: false).contains(where: { $0.id == searchAlbum.id }),
                  "track title search returns its album")
        try check(library.albums(matching: searchAlbum.title, downloadedOnly: false).contains(where: { $0.id == searchAlbum.id }),
                  "album title search returns its album")
        try check(library.albums(matching: searchAlbum.title, downloadedOnly: true).isEmpty,
                  "download filter intersects search rather than ignoring it")
        try check(library.albums(matching: "   ", downloadedOnly: false) == library.playableAlbums,
                  "whitespace-only search returns the ordinary album order")
        print("PASS: network-unknown, offline fallback and album/track search filtering")

        let defaultPlayer = MacAudioPlayer()
        defaultPlayer.volume = 0
        guard let firstAlbum = library.playableAlbums.first,
              let firstTrack = library.tracks(in: firstAlbum).first,
              let anotherAlbum = library.playableAlbums.last else { throw CheckFailure.failed("default playback fixture has no albums") }
        library.togglePlayback(player: defaultPlayer)
        try check(defaultPlayer.currentItem?.onlineTrack?.id == firstTrack.id && defaultPlayer.currentIndex == 0 &&
                  defaultPlayer.queueItems.compactMap(\.onlineTrack) == library.tracks(in: firstAlbum) && defaultPlayer.playbackIntent,
                  "play with no selection must start the first displayed album at its first track with the full album queue")
        library.togglePlayback(player: defaultPlayer, albumID: anotherAlbum.id)
        try check(!defaultPlayer.playbackIntent && defaultPlayer.currentItem?.onlineTrack?.id == firstTrack.id,
                  "play/pause must pause the existing queue instead of replacing it with a browsed album")
        defaultPlayer.stop()
        library.togglePlayback(player: defaultPlayer, albumID: anotherAlbum.id)
        try check(defaultPlayer.currentItem?.onlineTrack?.id == library.tracks(in: anotherAlbum).first?.id && defaultPlayer.playbackIntent,
                  "an explicitly opened album takes priority only when the player has no queue")
        defaultPlayer.stop()
        library.togglePlayback(player: defaultPlayer, albumID: "removed-album")
        try check(defaultPlayer.currentItem?.onlineTrack?.id == firstTrack.id,
                  "a stale album selection falls back to the first available album")
        defaultPlayer.stop()
        print("PASS: empty-player default album, full queue, chosen album and existing-queue preservation")
        object["revision"] = 20
        let musicSnapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let catalog = try DesktopMusicCatalog(snapshot: musicSnapshot, serviceAddress: "https://example.invalid")
        try check(try library.acceptMusicCatalog(catalog), "new phone music catalog must persist")
        try check(content.snapshot?.revision == 10 && content.articles == originalArticles, "phone music sync cannot replace the article store")
        let restored = restoredLibrary()
        try check(restored.musicCatalog == catalog, "acknowledged catalog survives relaunch")
        try check(!(try library.acceptMusicCatalog(catalog)), "duplicate catalog is accepted idempotently")
        print("PASS: independent stores, durable receipt, relaunch and idempotent catalog")

        let old = try DesktopMusicCatalog(snapshot: PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: SnapshotProtocol.payload), serviceAddress: "https://EXAMPLE.invalid:443/api/v1/snapshot")
        var rejected = false
        do { _ = try library.acceptMusicCatalog(old) } catch { rejected = true }
        try check(rejected && library.musicCatalog?.revision == 20, "canonical service aliases cannot roll back a directory")
        object["revision"] = 11
        SnapshotProtocol.payload = try JSONSerialization.data(withJSONObject: object)
        await library.refresh()
        try check(content.snapshot?.revision == 11 && library.musicCatalog?.revision == 20,
                  "article refresh still advances independently when music already has a newer phone revision")
        print("PASS: canonical service rollback protection and independent article refresh")

        object["revision"] = 21
        let next = try DesktopMusicCatalog(snapshot: PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object)), serviceAddress: "https://example.invalid")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: musicDirectory.path)
        rejected = false
        do { _ = try library.acceptMusicCatalog(next) } catch { rejected = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: musicDirectory.path)
        try check(rejected && library.musicCatalog?.revision == 20, "failed persistence cannot publish an unacknowledgeable catalog")
        try check(restoredLibrary().musicCatalog?.revision == 20,
                  "failed atomic replacement retains the preceding durable directory")
        print("PASS: failed atomic persistence preserves memory and durable catalog")

        // Use the real audio cache and decoder; no network or audible output is allowed.
        let audioBytes = try Data(contentsOf: URL(fileURLWithPath: "Resources/Audio/rain.wav"))
        let hash = SHA256.hash(data: audioBytes).map { String(format: "%02x", $0) }.joined()
        var audioObject = object
        var rows = audioObject["tracks"] as! [[String: Any]]
        for i in rows.indices { rows[i]["byteSize"] = audioBytes.count; rows[i]["sha256"] = hash; rows[i]["audioURL"] = "https://example.invalid/track.wav" }
        audioObject["tracks"] = rows; audioObject["revision"] = 22
        let audioSnapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: audioObject))
        _ = try library.acceptMusicCatalog(DesktopMusicCatalog(snapshot: audioSnapshot, serviceAddress: "https://example.invalid"))
        let track = library.tracks[0]
        let staged = root.appending(path: "staged.wav")
        try audioBytes.write(to: staged)
        await downloads.verifyCompletedDownload(at: staged, track: track, intent: .manual)
        guard let persistent = downloads.localURL(for: track), let album = library.albums.first(where: { $0.id == track.albumID }) else { throw CheckFailure.failed("real cache verification failed") }
        downloads.updateNetworkAvailability(available: false, wifi: false, wired: false, expensive: false, constrained: false)
        try check(!library.showsPortableAlbum && library.albums(matching: track.title, downloadedOnly: true).contains(where: { $0.id == album.id }),
                  "one valid local track provides an offline album and suppresses built-in fallback")
        try check(library.albums(matching: "does-not-exist-987", downloadedOnly: true).isEmpty && !library.showsPortableAlbum,
                  "empty search results cannot enable built-in fallback")
        let player = MacAudioPlayer()
        library.attach(player: player)
        library.play(track: track, in: album, player: player, playing: false)
        try await wait { !player.isBuffering }
        try check(player.error == nil && player.hasSelection && !player.isPlaying, "verified offline download must decode without fetching its unreachable service")
        await player.seek(to: 1)
        let priorPosition = player.playbackPosition
        let priorDuration = player.duration
        _ = try library.acceptMusicCatalog(DesktopMusicCatalog(snapshot: audioSnapshot, serviceAddress: "https://example.invalid"))
        try check(abs(player.playbackPosition - priorPosition) < 0.05 && player.duration == priorDuration && !player.isBuffering,
                  "duplicate sync cannot restart or reload a selected decoder")
        player.play(Track.allCases[0], playing: false)
        try check(FileManager.default.fileExists(atPath: persistent.path) && downloads.localURL(for: track) == persistent,
                  "changing tracks must not delete a persistent download")
        library.play(track: track, in: album, player: player, playing: false)
        try await wait { !player.isBuffering }
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try check(FileManager.default.fileExists(atPath: persistent.path), "application cleanup must not delete a persistent offline download")
        print("PASS: verified offline decoding, track switch and app exit retain downloaded files")

        // Catalog withdrawal stops the decoder before download reconciliation deletes its bytes.
        library.play(track: track, in: album, player: player, playing: false)
        try await wait { !player.isBuffering }
        audioObject["revision"] = 23; audioObject["tracks"] = []; audioObject["albums"] = []
        let withdrawn = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: audioObject))
        _ = try library.acceptMusicCatalog(DesktopMusicCatalog(snapshot: withdrawn, serviceAddress: "https://example.invalid"))
        try check(!player.hasSelection && !player.isBuffering && player.error != nil, "catalog withdrawal must stop and clear the active online selection")
        try check(downloads.storedRecords.isEmpty && !FileManager.default.fileExists(atPath: persistent.path), "released withdrawn bytes must be removed from download management")
        try check(library.showsPortableAlbum, "withdrawn downloads cannot suppress the offline fallback")
        print("PASS: withdrawal releases decoder before retiring downloaded audio")

        audioObject["revision"] = 24
        let activeSnapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object.merging(["revision": 24]) { _, next in next }))
        let active = try DesktopMusicCatalog(snapshot: activeSnapshot, serviceAddress: "https://example.invalid")
        _ = try library.acceptMusicCatalog(active)
        var conflictObject = object
        conflictObject["revision"] = 24
        var conflictRows = conflictObject["tracks"] as! [[String: Any]]
        conflictRows[0]["title"] = "Different metadata without a new revision"
        conflictObject["tracks"] = conflictRows
        let conflict = try DesktopMusicCatalog(snapshot: PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: conflictObject)), serviceAddress: "https://example.invalid")
        rejected = false
        do { _ = try library.acceptMusicCatalog(conflict) } catch { rejected = true }
        try check(rejected && library.musicCatalog == active, "same-revision metadata conflicts cannot replace a catalog")

        var expiryObject = object
        expiryObject["revision"] = 25
        var expiryRows = expiryObject["tracks"] as! [[String: Any]]
        let checkedAt = Date.now.addingTimeInterval(-10)
        let expiry = Date.now.addingTimeInterval(-5).ISO8601Format()
        for i in expiryRows.indices {
            var rights = expiryRows[i]["copyright"] as! [String: Any]
            rights["expiresAt"] = expiry; expiryRows[i]["copyright"] = rights
        }
        expiryObject["tracks"] = expiryRows
        let expiringSnapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: expiryObject))
        let historical = try DesktopMusicCatalog(snapshot: expiringSnapshot, serviceAddress: "https://example.invalid", checkedAt: checkedAt)
        _ = try library.acceptMusicCatalog(historical)
        try check(!historical.tracks.isEmpty && library.tracks.isEmpty, "historical evidence cannot make expired music playable today")
        let pruned = try historical.validated()
        _ = try library.acceptMusicCatalog(pruned)
        try check(library.musicCatalog?.revision == 25 && library.tracks.isEmpty,
                  "same-revision expiry pruning must not be rejected as a metadata conflict")
        print("PASS: same-revision expiry pruning is accepted while actual metadata conflicts are rejected")

        let otherService = try DesktopMusicCatalog(snapshot: activeSnapshot, serviceAddress: "https://other.example.invalid")
        _ = try library.acceptMusicCatalog(otherService)
        rejected = false
        do { _ = try library.acceptMusicCatalog(active) } catch { rejected = true }
        try check(rejected && library.serviceAddress == otherService.serviceAddress,
                  "switching services cannot erase an earlier service revision floor")
        print("PASS: service switches retain each service's rollback floor")

        let raceDownloads = AudioDownloads(testing: true, directoryOverride: root.appending(path: "race-downloads"))
        let raceContent = ContentLibrary(testing: true, directoryOverride: root.appending(path: "race-articles"))
        let raceLibrary = MacLibrary(content: raceContent, downloads: raceDownloads, directoryOverride: root.appending(path: "race-music"))
        _ = try raceLibrary.acceptMusicCatalog(DesktopMusicCatalog(snapshot: audioSnapshot, serviceAddress: "https://example.invalid"))
        let raceStage = root.appending(path: "race-stage.wav")
        try audioBytes.write(to: raceStage)
        await raceDownloads.verifyCompletedDownload(at: raceStage, track: track, intent: .manual)
        let racePlayer = MacAudioPlayer()
        raceLibrary.attach(player: racePlayer)
        let oldDeadline = SleepDeadline(minutes: 9)
        let originalStart = DesktopPlaybackStart(queue: [DesktopQueueItem(track: Track.allCases[0])], index: 0,
            position: 0, playing: false, mode: .sequence, deadline: oldDeadline, serviceAddress: "")
        _ = try await racePlayer.prepare(originalStart)
        _ = try await racePlayer.commit(sessionID: originalStart.sessionID)
        racePlayer.volume = 0.37
        var enteredLocalLoad = false
        let originalProvider = racePlayer.localAudioURLProvider
        racePlayer.localAudioURLProvider = { track, address in
            enteredLocalLoad = true
            return originalProvider?(track, address)
        }
        let pending = DesktopPlaybackStart(queue: [DesktopQueueItem(onlineTrack: track)], index: 0,
            position: 0, playing: false, mode: .single, deadline: nil, serviceAddress: "https://example.invalid")
        let preparationTask = Task { try await racePlayer.prepare(pending) }
        try await wait { enteredLocalLoad }
        try check(racePlayer.isPreparing, "withdrawal must occur during the actual asynchronous decoder preparation")
        // Retain the file so rejection proves catalog invalidation rather than a missing audio file.
        raceDownloads.setPlayingTrack(track)
        _ = try raceLibrary.acceptMusicCatalog(DesktopMusicCatalog(snapshot: withdrawn, serviceAddress: "https://example.invalid"))
        try check(raceDownloads.storedRecord(for: track) != nil, "race fixture must retain complete audio through preparation")
        rejected = false
        do { _ = try await preparationTask.value } catch { rejected = true }
        try check(rejected, "a withdrawal during load must invalidate the in-flight preparation generation")
        rejected = false
        do { _ = try await racePlayer.commit(sessionID: pending.sessionID) } catch { rejected = true }
        try check(rejected && racePlayer.controlledSessionID == originalStart.sessionID && racePlayer.deadline == oldDeadline && racePlayer.volume == 0.37,
                  "withdrawn preparation cannot commit or disturb the preceding controlled session")
        raceDownloads.setPlayingTrack(nil)
        print("PASS: withdrawal during real asynchronous preparation invalidates commit and preserves preceding session")

        // Shortening rights keeps the cache identity unchanged and must be checked after async seek.
        var restoredAudioObject = try JSONSerialization.jsonObject(with: PublicContentSnapshot.encoder().encode(audioSnapshot)) as! [String: Any]
        restoredAudioObject["revision"] = 24
        let restoredAudioSnapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: restoredAudioObject))
        _ = try raceLibrary.acceptMusicCatalog(DesktopMusicCatalog(snapshot: restoredAudioSnapshot, serviceAddress: "https://example.invalid"))
        let finalStage = root.appending(path: "final-stage.wav")
        try audioBytes.write(to: finalStage)
        await raceDownloads.verifyCompletedDownload(at: finalStage, track: track, intent: .manual)
        _ = try await racePlayer.prepare(pending)
        var expiredTrackObject = try JSONSerialization.jsonObject(with: PublicContentSnapshot.encoder().encode(track)) as! [String: Any]
        var expiredRights = expiredTrackObject["copyright"] as! [String: Any]
        expiredRights["expiresAt"] = "2020-01-01T00:00:00Z"
        expiredTrackObject["copyright"] = expiredRights
        let shortenedRights = try PublicContentSnapshot.decoder().decode(PublicAudioTrack.self, from: JSONSerialization.data(withJSONObject: expiredTrackObject))
        try check(shortenedRights.cacheIdentity == track.cacheIdentity, "rights changes must preserve the test's cache identity")
        var rightsChangedDuringSeek = false
        var scheduledRightsChange = false
        racePlayer.onlineCatalogProvider = { _ in
            if !scheduledRightsChange {
                scheduledRightsChange = true
                Task { @MainActor in rightsChangedDuringSeek = true }
            }
            return [rightsChangedDuringSeek ? shortenedRights : track]
        }
        rejected = false
        do { _ = try await racePlayer.commit(sessionID: pending.sessionID, latest: pending) } catch { rejected = true }
        try check(rightsChangedDuringSeek, "shortened rights must take effect during the real asynchronous commit seek")
        try check(rejected && racePlayer.controlledSessionID == originalStart.sessionID && racePlayer.deadline == oldDeadline && racePlayer.volume == 0.37,
                  "commit must recheck current rights after seek before replacing the preceding player")
        rejected = false
        do { _ = try await racePlayer.commit(sessionID: pending.sessionID) } catch { rejected = true }
        try check(rejected && !racePlayer.isPreparing, "rights-invalid preparation must be discarded and cannot be committed again")
        print("PASS: rights shortened during real commit seek reject installation and preserve the original player")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw CheckFailure.failed("player did not finish loading")
    }
}
