import Foundation
import CryptoKit
import Testing
@testable import QingkongCore

struct DesktopMusicCatalogTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(revision: Int = 3, padding: Int = 0, expiresAt: Date? = nil) -> PublicContentSnapshot {
        let track = PublicAudioTrack(id: "rain", albumID: "nature", title: "雨声", audioURL: URL(string: "https://content.example.org/rain.m4a")!, coverURL: nil,
            durationSeconds: 120, fileVersion: "1", byteSize: 1024, sha256: String(repeating: "a", count: 64),
            copyright: PublicAudioCopyright(owner: "Owner", source: "Original", license: "CC0", expiresAt: expiresAt),
            updatedAt: now, publishedAt: now, revision: revision, sortOrder: 0)
        let album = PublicAlbum(id: "nature", title: "自然", summary: String(repeating: "x", count: padding), coverURL: nil, trackIDs: ["rain"], updatedAt: now, publishedAt: now, revision: revision, sortOrder: 0)
        let article = PublicArticle(id: "article", testOnly: nil, title: "不传输文章", summary: "文章摘要", body: "文章正文", bodyHTML: nil, category: "睡眠", coverURL: nil,
            references: [PublicContentReference(title: "参考", url: URL(string: "https://example.org")!)], review: PublicContentReview(reviewer: "审阅人", credentials: "资质", reviewedAt: now), updatedAt: now, publishedAt: now, revision: 1, sortOrder: 0)
        return PublicContentSnapshot(schemaVersion: 1, revision: revision, generatedAt: now, articles: [article], albums: [album], tracks: [track], tombstones: [
            PublicContentTombstone(id: "old-article", kind: "articles", revision: 1, withdrawnAt: now),
            PublicContentTombstone(id: "old-album", kind: "album", revision: 1, withdrawnAt: now),
            PublicContentTombstone(id: "old-track", kind: "tracks", revision: 1, withdrawnAt: now)
        ])
    }

    private func catalog(revision: Int = 3, padding: Int = 0, address: String = "https://content.example.org") throws -> DesktopMusicCatalog {
        try DesktopMusicCatalog(snapshot: snapshot(revision: revision, padding: padding), serviceAddress: address, checkedAt: now)
    }

    @Test func helloCapabilitiesAndVerifiedCommitReceiptRemainOptionalForLegacyPeers() throws {
        let legacy = try JSONDecoder().decode(DesktopMusicRequest.self,
            from: Data("{\"version\":2,\"id\":\"00000000-0000-0000-0000-000000000001\",\"action\":\"hello\"}".utf8))
        #expect(legacy.capabilities == nil)
        let hello = DesktopMusicRequest(action: .hello, capabilities: [DesktopMusicCatalog.capability])
        #expect(try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(hello)).capabilities == hello.capabilities)
        let transfer = try DesktopMusicCatalogTransfer(catalog: catalog())
        let reply = DesktopMusicResponse(id: UUID(), catalogReceipt: transfer.info)
        #expect(try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(reply)).catalogReceipt == transfer.info)
        let oldReply = DesktopMusicResponse(id: UUID())
        #expect(try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(oldReply)).catalogReceipt == nil)
    }

    @Test func projectionContainsMusicOnlyAndRetainsRevisionAndCheckTime() throws {
        let value = try catalog()
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(object["articles"] == nil)
        #expect(!String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("文章正文"))
        #expect(value.tombstones.map(\.id) == ["old-album", "old-track"])
        #expect(value.revision == 3 && value.checkedAt == now && value.generatedAt == now)
        #expect(value.albums.count == 1 && value.tracks.count == 1)
        #expect(throws: (any Error).self) { try catalog(address: "https://user:secret@content.example.org") }
        let expired = try DesktopMusicCatalog(snapshot: snapshot(expiresAt: now.addingTimeInterval(-1)), serviceAddress: "https://content.example.org", checkedAt: now)
        #expect(expired.tracks.isEmpty && expired.albums[0].trackIDs.isEmpty)
    }

    @Test func catalogValidationRejectsInconsistentMusicAndNonMusicTombstones() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog())) as? [String: Any])
        object["tracks"] = []
        let broken = try JSONDecoder().decode(DesktopMusicCatalog.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) { try broken.validated(at: now) }
        object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog())) as? [String: Any])
        object["tombstones"] = [["id": "secret", "kind": "articles", "revision": 3, "withdrawnAt": 100]]
        let notMusic = try JSONDecoder().decode(DesktopMusicCatalog.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: (any Error).self) { try notMusic.validated(at: now) }
    }

    @Test func transferFitsFramesChecksDigestAndDeliversOnlyOnCommit() throws {
        let value = try catalog(padding: 600_000)
        let transfer = try DesktopMusicCatalogTransfer(catalog: value)
        #expect(transfer.chunks.count == 3)
        #expect(transfer.chunks[0].data.count == 262_144)
        #expect(transfer.chunks[1].data.count == 262_144)
        let data = transfer.chunks.reduce(into: Data()) { $0.append($1.data) }
        #expect(data.count == transfer.info.totalBytes)
        #expect(transfer.info.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        var receiver = DesktopMusicCatalogReceiver()
        try receiver.begin(transfer.info)
        for chunk in transfer.chunks {
            let request = DesktopMusicRequest(action: .catalogChunk, catalogChunk: chunk)
            #expect(try JSONEncoder().encode(request).count < 1_048_576)
            try receiver.append(chunk)
            try receiver.append(chunk)
        }
        #expect(try receiver.commit(transferID: transfer.info.id, at: now) == value)
        #expect(throws: (any Error).self) { try receiver.commit(transferID: transfer.info.id, at: now) }
    }

    @Test func receiverRejectsUnsafeIndicesWrongOrderConflictingDuplicatesAndMissingChunks() throws {
        let transfer = try DesktopMusicCatalogTransfer(catalog: catalog(padding: 300_000))
        var receiver = DesktopMusicCatalogReceiver()
        try receiver.begin(transfer.info)
        for index in [-1, Int.min, Int.max, transfer.info.chunkCount] {
            #expect(throws: (any Error).self) { try receiver.append(DesktopMusicCatalogChunk(transferID: transfer.info.id, index: index, data: Data([1]))) }
        }
        #expect(throws: (any Error).self) { try receiver.append(transfer.chunks[1]) }
        #expect(throws: (any Error).self) { try receiver.append(DesktopMusicCatalogChunk(transferID: UUID(), index: 0, data: transfer.chunks[0].data)) }
        try receiver.append(transfer.chunks[0])
        #expect(throws: (any Error).self) { try receiver.append(DesktopMusicCatalogChunk(transferID: transfer.info.id, index: 0, data: Data(repeating: 1, count: 262_144))) }
        #expect(throws: (any Error).self) { try receiver.commit(transferID: transfer.info.id, at: now) }
    }

    @Test func receiverRejectsBadDigestAndMetadataPayloadMismatch() throws {
        let transfer = try DesktopMusicCatalogTransfer(catalog: catalog())
        var receiver = DesktopMusicCatalogReceiver()
        let corrupt = DesktopMusicCatalogTransferInfo(id: transfer.info.id, serviceAddress: transfer.info.serviceAddress, revision: 3, totalBytes: transfer.info.totalBytes, chunkCount: 1, sha256: String(repeating: "0", count: 64))
        try receiver.begin(corrupt)
        try receiver.append(transfer.chunks[0])
        #expect(throws: (any Error).self) { try receiver.commit(transferID: corrupt.id, at: now) }
        let mismatch = DesktopMusicCatalogTransferInfo(id: transfer.info.id, serviceAddress: transfer.info.serviceAddress, revision: 4, totalBytes: transfer.info.totalBytes, chunkCount: 1, sha256: transfer.info.sha256)
        try receiver.begin(mismatch)
        try receiver.append(transfer.chunks[0])
        #expect(throws: (any Error).self) { try receiver.commit(transferID: mismatch.id, at: now) }
    }

    @Test func receiverEnforcesTotalAndPerChunkLimitsBeforeBuffering() throws {
        let transfer = try DesktopMusicCatalogTransfer(catalog: catalog())
        var receiver = DesktopMusicCatalogReceiver()
        for (bytes, count) in [(0, 0), (-1, 1), (10_000_001, 39), (Int.max, Int.max), (1, 2)] {
            let info = DesktopMusicCatalogTransferInfo(serviceAddress: "https://content.example.org", revision: 3, totalBytes: bytes, chunkCount: count, sha256: transfer.info.sha256)
            #expect(throws: (any Error).self) { try receiver.begin(info) }
        }
        try receiver.begin(transfer.info)
        #expect(throws: (any Error).self) { try receiver.append(DesktopMusicCatalogChunk(transferID: transfer.info.id, index: 0, data: Data())) }
        #expect(throws: (any Error).self) { try receiver.append(DesktopMusicCatalogChunk(transferID: transfer.info.id, index: 0, data: Data([1]))) }
        #expect(throws: (any Error).self) { try receiver.append(DesktopMusicCatalogChunk(transferID: transfer.info.id, index: 0, data: Data(repeating: 1, count: 262_145))) }
        #expect(throws: (any Error).self) { try DesktopMusicCatalogTransfer(catalog: catalog(padding: 10_000_000)) }
    }

    @Test func exactlyTenMillionBytesCanCommitButValidHashCannotBypassCatalogValidation() throws {
        let small = try DesktopMusicCatalogTransfer(catalog: catalog())
        let exact = try DesktopMusicCatalogTransfer(catalog: catalog(padding: 10_000_000 - small.info.totalBytes))
        #expect(exact.info.totalBytes == 10_000_000)
        var receiver = DesktopMusicCatalogReceiver()
        try receiver.begin(exact.info)
        for chunk in exact.chunks { try receiver.append(chunk) }
        #expect(try receiver.commit(transferID: exact.info.id, at: now).tracks.count == 1)

        var object = try #require(JSONSerialization.jsonObject(with: small.chunks[0].data) as? [String: Any])
        object["tracks"] = []
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let info = DesktopMusicCatalogTransferInfo(serviceAddress: "https://content.example.org", revision: 3,
            totalBytes: bytes.count, chunkCount: 1, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        try receiver.begin(info)
        try receiver.append(DesktopMusicCatalogChunk(transferID: info.id, index: 0, data: bytes))
        #expect(throws: (any Error).self) { try receiver.commit(transferID: info.id, at: now) }
    }

    @Test func sameServiceCannotRollBackAtBeginOrCommitButNewServiceCanStartLower() throws {
        let transfer = try DesktopMusicCatalogTransfer(catalog: catalog(revision: 3))
        let newer = try catalog(revision: 4, address: "https://content.example.org/")
        var receiver = DesktopMusicCatalogReceiver()
        #expect(throws: (any Error).self) { try receiver.begin(transfer.info, current: newer) }
        try receiver.begin(transfer.info)
        try receiver.append(transfer.chunks[0])
        #expect(throws: (any Error).self) { try receiver.commit(transferID: transfer.info.id, current: newer, at: now) }
        let different = try catalog(revision: 100, address: "https://other.example.org")
        try receiver.begin(transfer.info, current: different)
        try receiver.append(transfer.chunks[0])
        #expect(try receiver.commit(transferID: transfer.info.id, current: different, at: now).revision == 3)
    }

    @Test func contentDigestIgnoresCheckTimeAndSameRevisionCannotReplaceDifferentMusic() throws {
        let value = try catalog()
        let checkedAgain = try DesktopMusicCatalog(snapshot: snapshot(), serviceAddress: "https://content.example.org", checkedAt: now.addingTimeInterval(60))
        #expect(try value.contentDigest() == checkedAgain.contentDigest())
        let transfer = try DesktopMusicCatalogTransfer(catalog: checkedAgain)
        #expect(try transfer.info.sha256 != DesktopMusicCatalogTransfer(catalog: value).info.sha256)
        #expect(try value.contentDigest() == catalog(address: "https://CONTENT.example.org:443/").contentDigest())
        var receiver = DesktopMusicCatalogReceiver()
        try receiver.begin(transfer.info, current: value)
        try receiver.append(transfer.chunks[0])
        #expect(try receiver.commit(transferID: transfer.info.id, current: value, at: now).checkedAt == now.addingTimeInterval(60))
        let changed = try catalog(padding: 2)
        #expect(try value.contentDigest() != changed.contentDigest())
        let changedTransfer = try DesktopMusicCatalogTransfer(catalog: changed)
        try receiver.begin(changedTransfer.info, current: value)
        try receiver.append(changedTransfer.chunks[0])
        #expect(throws: (any Error).self) { try receiver.commit(transferID: changedTransfer.info.id, current: value, at: now) }
    }

    @Test func sameRevisionCanRefreshWhenCopyrightExpiryRemovesTracks() throws {
        let source = snapshot(expiresAt: now.addingTimeInterval(30))
        let original = try DesktopMusicCatalog(snapshot: source, serviceAddress: "https://content.example.org", checkedAt: now)
        let later = now.addingTimeInterval(60)
        let refreshed = try DesktopMusicCatalog(snapshot: source, serviceAddress: "https://content.example.org", checkedAt: later)
        #expect(original.tracks.count == 1 && refreshed.tracks.isEmpty)
        let transfer = try DesktopMusicCatalogTransfer(catalog: refreshed)
        var receiver = DesktopMusicCatalogReceiver()
        try receiver.begin(transfer.info, current: original)
        try receiver.append(transfer.chunks[0])
        let received = try receiver.commit(transferID: transfer.info.id, current: original, at: later)
        #expect(received.tracks.isEmpty && received.albums[0].trackIDs.isEmpty)
        #expect(received.checkedAt == later)

        // A transfer already in flight at expiry must produce the same safe local directory.
        let inFlight = try DesktopMusicCatalogTransfer(catalog: original)
        try receiver.begin(inFlight.info, current: refreshed)
        try receiver.append(inFlight.chunks[0])
        #expect(try receiver.commit(transferID: inFlight.info.id, current: refreshed, at: later).tracks.isEmpty)
    }

    @Test func protocolRoundTripsCatalogActionsAndOptionalStatusWhileOldMessagesDecode() throws {
        let value = try catalog()
        let transfer = try DesktopMusicCatalogTransfer(catalog: value)
        for action in [DesktopMusicRequest.Action.catalogBegin, .catalogChunk, .catalogCommit, .catalogStatus] {
            let request = DesktopMusicRequest(action: action, catalogTransfer: transfer.info, catalogChunk: transfer.chunks[0], catalogTransferID: transfer.info.id)
            let decoded = try JSONDecoder().decode(DesktopMusicRequest.self, from: JSONEncoder().encode(request))
            #expect(decoded.version == 2 && decoded.action == action)
            #expect(decoded.catalogTransfer == transfer.info && decoded.catalogChunk == transfer.chunks[0] && decoded.catalogTransferID == transfer.info.id)
        }
        let digest = try value.contentDigest()
        let status = DesktopMusicCatalogStatus(catalog: value, digest: digest, syncedAt: now)
        let response = DesktopMusicResponse(id: UUID(), capabilities: [DesktopMusicCatalog.capability], catalogStatus: status)
        let decoded = try JSONDecoder().decode(DesktopMusicResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded.catalogStatus?.albumCount == 1 && decoded.catalogStatus?.trackCount == 1)
        #expect(decoded.catalogStatus?.revision == 3 && decoded.catalogStatus?.syncedAt == now)
        #expect(decoded.catalogStatus?.digest == digest)
        let old = try JSONDecoder().decode(DesktopMusicResponse.self, from: Data("{\"version\":2,\"id\":\"00000000-0000-0000-0000-000000000001\",\"success\":true}".utf8))
        #expect(old.catalogStatus == nil)
        let oldRequest = try JSONDecoder().decode(DesktopMusicRequest.self, from: Data("{\"version\":2,\"id\":\"00000000-0000-0000-0000-000000000001\",\"action\":\"hello\"}".utf8))
        #expect(oldRequest.catalogTransfer == nil && oldRequest.catalogChunk == nil && oldRequest.catalogTransferID == nil)
    }
}
