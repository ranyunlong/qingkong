import Foundation
import CryptoKit
import QingkongCore

private enum CheckFailure: Error { case failed(String) }

private actor IntegrityGate {
    private var firstCall = true
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false

    func verify(_ url: URL, size: Int64, hash: String) async throws -> Bool {
        if firstCall {
            firstCall = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                waiting = true
            }
        }
        return try AudioFileIntegrity.matches(fileURL: url, byteSize: size, sha256: hash)
    }

    func release() {
        continuation?.resume()
        continuation = nil
        waiting = false
    }
}

@main
struct AudioDownloadsChecks {
    @MainActor static func main() async throws {
        let root = URL.temporaryDirectory.appending(path: "qingkong-download-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let bytes = try Data(contentsOf: fixture)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let track = try makeTrack(size: bytes.count, hash: hash)
        let phoneDirectory = root.appending(path: "phone")
        let watchDirectory = root.appending(path: "watch")
        try seed(track: track, bytes: bytes, directory: phoneDirectory)
        let phone = AudioDownloads(testing: true, directoryOverride: phoneDirectory)
        let watch = AudioDownloads(testing: true, directoryOverride: watchDirectory)
        try await wait { phone.localURL(for: track) != nil }
        try check(watch.localURL(for: track) == nil && watch.manualBytes == 0, "phone cache must not become a Watch download")
        print("PASS: separate device stores do not share offline availability")

        let restarted = AudioDownloads(testing: true, directoryOverride: phoneDirectory)
        try check(restarted.localURL(for: track) == nil, "manifest alone must not prove availability")
        try await wait { restarted.localURL(for: track) != nil }
        try check(restarted.manualBytes == Int64(bytes.count), "manual download survives verified relaunch")
        print("PASS: relaunch requires real file verification before availability")

        restarted.setPlayingTrack(track)
        restarted.deleteStored(identity: track.cacheIdentity)
        try check(restarted.localURL(for: track) != nil && restarted.storageError != nil, "playing file must be protected")
        restarted.setPlayingTrack(nil)
        restarted.delete(track)
        try check(restarted.localURL(for: track) == nil && restarted.manualBytes == 0, "stopped file can be deleted")
        print("PASS: playing file is protected and deletion works after release")

        let corruptedDirectory = root.appending(path: "corrupt")
        try seed(track: track, bytes: bytes, directory: corruptedDirectory)
        try Data(bytes.prefix(bytes.count / 2)).write(to: corruptedDirectory.appending(path: "fixture.wav"))
        let corrupted = AudioDownloads(testing: true, directoryOverride: corruptedDirectory)
        try await wait { corrupted.records.isEmpty }
        try check(corrupted.localURL(for: track) == nil, "truncated file must never be offline")
        print("PASS: corrupted restored file is rejected and removed")

        let replacedDirectory = root.appending(path: "replace")
        try seed(track: track, bytes: bytes, directory: replacedDirectory)
        let replaced = AudioDownloads(testing: true, directoryOverride: replacedDirectory)
        try await wait { replaced.localURL(for: track) != nil }
        let newer = try makeTrack(size: bytes.count, hash: hash, version: "2")
        try check(replaced.localURL(for: newer) == nil, "new version must not reuse old identity")
        replaced.reconcile(with: [newer])
        try check(replaced.records.isEmpty && replaced.localURL(for: track) == nil, "catalog revision removes superseded file")
        print("PASS: new catalog version cannot reuse the previous offline file")

        try seed(track: track, bytes: bytes, directory: root.appending(path: "rights"))
        let licensed = AudioDownloads(testing: true, directoryOverride: root.appending(path: "rights"))
        try await wait { licensed.localURL(for: track) != nil }
        let expired = try makeTrack(size: bytes.count, hash: hash, expired: true)
        try check(licensed.localURL(for: expired) == nil, "expired rights forbid offline use even with a complete file")
        licensed.reconcile(with: [])
        try check(licensed.records.isEmpty, "withdrawal removes the cached file")
        print("PASS: rights expiry and withdrawal invalidate offline use")
        let cancelGate = IntegrityGate()
        let cancelled = AudioDownloads(testing: true, directoryOverride: root.appending(path: "cancel"), verifyFile: {
            try await cancelGate.verify($0, size: $1, hash: $2)
        })
        let cancelledFile = root.appending(path: "cancelled-stage.wav")
        try bytes.write(to: cancelledFile)
        let oldCancel = Task { await cancelled.verifyCompletedDownload(at: cancelledFile, track: track, intent: .manual) }
        try await waitForGate(cancelGate)
        cancelled.interruptForegroundDownloads()
        let interrupted = cancelled.state(for: track)
        await cancelGate.release()
        await oldCancel.value
        try check(cancelled.records.isEmpty && cancelled.localURL(for: track) == nil && cancelled.state(for: track) == interrupted,
                  "cancelled verification must not restore offline availability or overwrite interruption")
        try check(!FileManager.default.fileExists(atPath: cancelledFile.path), "cancelled staging file must be removed")
        print("PASS: foreground interruption invalidates an in-flight verification")

        let retryGate = IntegrityGate()
        let retried = AudioDownloads(testing: true, directoryOverride: root.appending(path: "retry"), verifyFile: {
            try await retryGate.verify($0, size: $1, hash: $2)
        })
        let oldFile = root.appending(path: "old-stage.wav")
        let newFile = root.appending(path: "new-stage.wav")
        try bytes.write(to: oldFile)
        try bytes.write(to: newFile)
        let oldRetry = Task { await retried.verifyCompletedDownload(at: oldFile, track: track, intent: .manual) }
        try await waitForGate(retryGate)
        retried.interruptForegroundDownloads()
        await retried.verifyCompletedDownload(at: newFile, track: track, intent: .manual)
        try check(retried.localURL(for: track) != nil, "new retry must finish while the old validation waits")
        await retryGate.release()
        await oldRetry.value
        try check(retried.state(for: track) == .offline && retried.manualBytes == track.byteSize,
                  "old validation must not overwrite or delete a successful retry")
        guard let retryURL = retried.localURL(for: track) else { throw CheckFailure.failed("retry lost offline file") }
        try check(try Data(contentsOf: retryURL) == bytes, "successful retry must retain its complete bytes")
        print("PASS: late verification cannot overwrite or remove a successful retry")

        let withdrawnGate = IntegrityGate()
        let withdrawn = AudioDownloads(testing: true, directoryOverride: root.appending(path: "withdrawn"), verifyFile: {
            try await withdrawnGate.verify($0, size: $1, hash: $2)
        })
        let withdrawnFile = root.appending(path: "withdrawn-stage.wav")
        try bytes.write(to: withdrawnFile)
        let withdrawal = Task { await withdrawn.verifyCompletedDownload(at: withdrawnFile, track: track, intent: .manual) }
        try await waitForGate(withdrawnGate)
        withdrawn.reconcile(with: [])
        await withdrawnGate.release()
        await withdrawal.value
        try check(withdrawn.records.isEmpty && withdrawn.localURL(for: track) == nil && withdrawn.state(for: track) == .unavailable,
                  "withdrawn track must not return after a late verification")
        print("PASS: catalog withdrawal invalidates an in-flight verification")
        let retiredDirectory = root.appending(path: "retired-playing")
        try seed(track: track, bytes: bytes, directory: retiredDirectory)
        let retired = AudioDownloads(testing: true, directoryOverride: retiredDirectory)
        try await wait { retired.localURL(for: track) != nil }
        retired.setPlayingTrack(track)
        retired.reconcile(with: [newer])
        try check(FileManager.default.fileExists(atPath: retiredDirectory.appending(path: "fixture.wav").path),
                  "superseded playing file must stay on disk until playback releases it")
        try check(retired.records[track.cacheIdentity] != nil,
                  "superseded playing file must remain in the management index while its bytes still exist")
        try check(retired.localURL(for: track) == nil, "superseded retained file must not remain playable")
        retired.deleteStored(identity: track.cacheIdentity)
        try check(retired.storedRecord(for: track) != nil && retired.storageError != nil,
                  "management deletion must protect a retired file still in playback")
        retired.setPlayingTrack(nil)
        try check(retired.records.isEmpty && !FileManager.default.fileExists(atPath: retiredDirectory.appending(path: "fixture.wav").path),
                  "releasing the retired playing file removes its bytes and management record")
        print("PASS: superseded playing file stays manageable until release")

        let expiredDirectory = root.appending(path: "expired-management")
        try seed(track: track, bytes: bytes, directory: expiredDirectory)
        let expiredCache = AudioDownloads(testing: true, directoryOverride: expiredDirectory)
        try await wait { expiredCache.localURL(for: track) != nil }
        try check(expiredCache.localURL(for: expired) == nil && expiredCache.storedRecord(for: expired) != nil,
                  "expired audio must remain manageable without a playable URL")
        expiredCache.deleteStored(identity: expired.cacheIdentity)
        try check(expiredCache.storedRecords.isEmpty && !FileManager.default.fileExists(atPath: expiredDirectory.appending(path: "fixture.wav").path),
                  "expired file deletion must remove its bytes and management record")
        print("PASS: expired files can be deleted without a playable URL")

        let retainedDirectory = root.appending(path: "failed-removal")
        try seed(track: track, bytes: bytes, directory: retainedDirectory)
        let retained = AudioDownloads(testing: true, directoryOverride: retainedDirectory)
        try await wait { retained.localURL(for: track) != nil }
        retained.reconcile(with: [track])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: retainedDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retainedDirectory.path) }
        retained.reconcile(with: [])
        try check(retained.localURL(for: track) == nil && retained.storedRecords.count == 1 && retained.storageError != nil,
                  "failed removal of withdrawn bytes must preserve a management record")
        try check(retained.storedRecords.first?.title == track.title, "withdrawn file must retain its last known title")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retainedDirectory.path)
        retained.deleteStored(identity: track.cacheIdentity)
        try check(retained.storedRecords.isEmpty && !FileManager.default.fileExists(atPath: retainedDirectory.appending(path: "fixture.wav").path),
                  "withdrawn file must be removable by identity after storage becomes writable")
        print("PASS: failed cleanup keeps withdrawn files indexed for later deletion")

        let restoreWithdrawalDirectory = root.appending(path: "restore-withdrawal")
        try seed(track: track, bytes: bytes, directory: restoreWithdrawalDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: restoreWithdrawalDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restoreWithdrawalDirectory.path) }
        let restoreWithdrawal = AudioDownloads(testing: true, directoryOverride: restoreWithdrawalDirectory)
        restoreWithdrawal.reconcile(with: [])
        // Reconciliation clears the old state before the restore task can run on the main actor.
        try await wait { restoreWithdrawal.states[track.cacheIdentity] != nil }
        try check(restoreWithdrawal.state(for: track) == .unavailable && restoreWithdrawal.localURL(for: track) == nil,
                  "late restore state must not change a withdrawn track's public availability")
        try check(restoreWithdrawal.storedRecord(for: track) != nil,
                  "withdrawn bytes retained after failed cleanup must remain manageable")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restoreWithdrawalDirectory.path)
        restoreWithdrawal.deleteStored(identity: track.cacheIdentity)
        try check(restoreWithdrawal.storedRecords.isEmpty && !FileManager.default.fileExists(atPath: restoreWithdrawalDirectory.appending(path: "fixture.wav").path),
                  "late restore must not prevent identity-based deletion of withdrawn bytes")
        print("PASS: late restore keeps withdrawn track unavailable while retaining file management")

        let automaticDirectory = root.appending(path: "automatic-upgrade")
        try seed(track: track, bytes: bytes, directory: automaticDirectory, intent: .automatic)
        let automatic = AudioDownloads(testing: true, directoryOverride: automaticDirectory)
        try await wait { automatic.localURL(for: track) != nil }
        try check(automatic.storedRecord(for: track)?.title == nil, "legacy manifests without titles must still load")
        let automaticURL = automatic.localURL(for: track)
        automatic.download(track, intent: .manual)
        try check(automatic.manualBytes == track.byteSize && automatic.automaticBytes == 0 && automatic.localURL(for: track) == automaticURL,
                  "retaining automatic cache must upgrade existing bytes without a second transfer")
        automatic.clearAutomaticCache()
        try check(automatic.localURL(for: track) == automaticURL && automatic.state(for: track) == .offline,
                  "automatic cache cleanup must preserve the upgraded download")
        let retainedRestart = AudioDownloads(testing: true, directoryOverride: automaticDirectory)
        try await wait { retainedRestart.localURL(for: track) != nil }
        try check(retainedRestart.manualBytes == track.byteSize && retainedRestart.automaticBytes == 0,
                  "manual retention must persist across relaunch")
        guard let retainedURL = retainedRestart.localURL(for: track) else { throw CheckFailure.failed("retained download lost its file") }
        try check(try Data(contentsOf: retainedURL) == bytes, "retaining automatic cache must preserve complete file contents")
        print("PASS: automatic cache retention reuses bytes and survives cleanup and relaunch")
        print("14 portable download checks passed; no network, audio playback, simulator, or device used.")
    }

    private static func waitForGate(_ gate: IntegrityGate) async throws {
        for _ in 0..<300 {
            if await gate.waiting { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.failed("verification did not reach the gate")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.failed("verification did not finish")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }

    private static func seed(track: PublicAudioTrack, bytes: Data, directory: URL, intent: AudioDownloadIntent = .manual) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appending(path: "fixture.wav"))
        let record = AudioDownloads.Record(trackID: track.id, identity: track.cacheIdentity, fileName: "fixture.wav",
                                          intent: intent, byteSize: track.byteSize, sha256: track.sha256, lastUsedAt: .now)
        try JSONEncoder().encode([track.cacheIdentity: record]).write(to: directory.appending(path: "manifest.json"))
    }

    private static func makeTrack(size: Int, hash: String, version: String = "1", expired: Bool = false) throws -> PublicAudioTrack {
        let object: [String: Any] = ["id": "fixture", "albumID": "album", "title": "Local test fixture",
            "audioURL": "https://example.invalid/fixture.wav", "durationSeconds": 1,
            "fileVersion": version, "byteSize": size, "sha256": hash,
            "copyright": ["owner": "Local test", "source": "fixture", "license": "Test only",
                          "expiresAt": expired ? "2020-01-01T00:00:00Z" as Any : NSNull()],
            "updatedAt": "2026-11-21T00:00:00Z", "publishedAt": "2026-11-21T00:00:00Z", "revision": 1, "sortOrder": 0]
        return try PublicContentSnapshot.decoder().decode(PublicAudioTrack.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
