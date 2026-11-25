import Foundation
import CryptoKit

/// The desktop receives only the public music projection, never articles or personal records.
public struct DesktopMusicCatalog: Codable, Equatable, Sendable {
    public static let capability = "music-catalog-sync-v1"

    public let serviceAddress: String
    public let revision: Int
    public let generatedAt: Date
    public let checkedAt: Date
    public let albums: [PublicAlbum]
    public let tracks: [PublicAudioTrack]
    public let tombstones: [PublicContentTombstone]

    public init(snapshot: PublicContentSnapshot, serviceAddress: String, checkedAt: Date = .now) throws {
        let music = PublicContentSnapshot(schemaVersion: snapshot.schemaVersion, revision: snapshot.revision,
            generatedAt: snapshot.generatedAt, articles: [], albums: snapshot.albums, tracks: snapshot.tracks,
            tombstones: snapshot.tombstones.filter { Self.musicKinds.contains($0.kind) })
        let validated = try music.validated(at: checkedAt)
        self.serviceAddress = serviceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        revision = validated.revision; generatedAt = validated.generatedAt; self.checkedAt = checkedAt
        albums = validated.albums; tracks = validated.tracks; tombstones = validated.tombstones
        _ = try self.validated(at: checkedAt)
    }

    private init(serviceAddress: String, revision: Int, generatedAt: Date, checkedAt: Date,
                 albums: [PublicAlbum], tracks: [PublicAudioTrack], tombstones: [PublicContentTombstone]) {
        self.serviceAddress = serviceAddress; self.revision = revision; self.generatedAt = generatedAt
        self.checkedAt = checkedAt; self.albums = albums; self.tracks = tracks; self.tombstones = tombstones
    }

    /// Reuse the public snapshot validator, including withdrawals and copyright expiry.
    public func validated(at date: Date = .now) throws -> DesktopMusicCatalog {
        _ = try canonicalCatalogService(serviceAddress)
        guard generatedAt.timeIntervalSince1970.isFinite, checkedAt.timeIntervalSince1970.isFinite,
              date.timeIntervalSince1970.isFinite,
              tombstones.allSatisfy({ Self.musicKinds.contains($0.kind) && !$0.id.isEmpty && $0.revision >= 0 && $0.withdrawnAt.timeIntervalSince1970.isFinite }),
              albums.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              tracks.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw DesktopMusicCatalogError.invalidCatalog
        }
        let music = try PublicContentSnapshot(schemaVersion: 1, revision: revision, generatedAt: generatedAt,
            articles: [], albums: albums, tracks: tracks, tombstones: tombstones).validated(at: date)
        return DesktopMusicCatalog(serviceAddress: serviceAddress, revision: revision, generatedAt: generatedAt,
            checkedAt: checkedAt, albums: music.albums, tracks: music.tracks, tombstones: tombstones)
    }

    /// Stable content identity. A successful refresh with only a newer checkedAt needs no transfer.
    /// This differs from TransferInfo.sha256, which authenticates the exact wire bytes.
    public func contentDigest() throws -> String {
        struct Content: Encodable {
            let serviceAddress: String
            let revision: Int
            let generatedAt: Date
            let albums: [PublicAlbum]
            let tracks: [PublicAudioTrack]
            let tombstones: [PublicContentTombstone]
        }
        let content = Content(serviceAddress: try canonicalCatalogService(serviceAddress), revision: revision,
            generatedAt: generatedAt, albums: albums, tracks: tracks, tombstones: tombstones)
        return catalogSHA256(try catalogEncoder().encode(content))
    }

    private static let musicKinds: Set<String> = ["album", "albums", "track", "tracks"]
}

public struct DesktopMusicCatalogTransferInfo: Codable, Equatable, Sendable {
    public let id: UUID
    public let serviceAddress: String
    public let revision: Int
    public let totalBytes: Int
    public let chunkCount: Int
    /// SHA256 of the complete encoded payload, including checkedAt.
    public let sha256: String

    public init(id: UUID = UUID(), serviceAddress: String, revision: Int, totalBytes: Int, chunkCount: Int, sha256: String) {
        self.id = id; self.serviceAddress = serviceAddress; self.revision = revision
        self.totalBytes = totalBytes; self.chunkCount = chunkCount; self.sha256 = sha256
    }

    public var isValid: Bool {
        guard (try? canonicalCatalogService(serviceAddress)) != nil, revision >= 0,
              (1...DesktopMusicCatalogTransfer.maxTotalBytes).contains(totalBytes),
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
        return chunkCount == (totalBytes - 1) / DesktopMusicCatalogTransfer.maxChunkBytes + 1
    }
}

public struct DesktopMusicCatalogChunk: Codable, Equatable, Sendable {
    public let transferID: UUID
    public let index: Int
    public let data: Data

    public init(transferID: UUID, index: Int, data: Data) {
        self.transferID = transferID; self.index = index; self.data = data
    }
}

public struct DesktopMusicCatalogTransfer: Sendable {
    /// Base64 and the request envelope remain well below the existing 1 MiB frame limit.
    public static let maxChunkBytes = 262_144
    public static let maxTotalBytes = 10_000_000
    public let info: DesktopMusicCatalogTransferInfo
    public let chunks: [DesktopMusicCatalogChunk]

    public init(catalog: DesktopMusicCatalog) throws {
        let value = try catalog.validated(at: catalog.checkedAt)
        let data = try catalogEncoder().encode(value)
        guard (1...Self.maxTotalBytes).contains(data.count) else { throw DesktopMusicCatalogError.invalidTransfer }
        let id = UUID()
        info = DesktopMusicCatalogTransferInfo(id: id, serviceAddress: value.serviceAddress, revision: value.revision,
            totalBytes: data.count, chunkCount: (data.count - 1) / Self.maxChunkBytes + 1, sha256: catalogSHA256(data))
        chunks = stride(from: 0, to: data.count, by: Self.maxChunkBytes).enumerated().map { index, offset in
            DesktopMusicCatalogChunk(transferID: id, index: index, data: data.subdata(in: offset..<min(offset + Self.maxChunkBytes, data.count)))
        }
    }
}

/// One bounded transfer per authenticated connection. No partial catalog escapes this receiver.
public struct DesktopMusicCatalogReceiver: Sendable {
    private var info: DesktopMusicCatalogTransferInfo?
    private var chunks: [Data] = []
    private var totalBytes = 0
    private var baseline: DesktopMusicCatalog?

    public init() {}

    public mutating func begin(_ info: DesktopMusicCatalogTransferInfo, current: DesktopMusicCatalog? = nil) throws {
        guard info.isValid else { throw DesktopMusicCatalogError.invalidTransfer }
        try rejectCatalogRollback(serviceAddress: info.serviceAddress, revision: info.revision, current: current)
        self.info = info; chunks = []; totalBytes = 0; baseline = current
    }

    public mutating func append(_ chunk: DesktopMusicCatalogChunk) throws {
        guard let info, chunk.transferID == info.id,
              chunk.index >= 0, chunk.index < info.chunkCount,
              !chunk.data.isEmpty, chunk.data.count <= DesktopMusicCatalogTransfer.maxChunkBytes else {
            throw DesktopMusicCatalogError.unexpectedChunk
        }
        if chunk.index < chunks.count {
            guard chunks[chunk.index] == chunk.data else { throw DesktopMusicCatalogError.unexpectedChunk }
            return
        }
        guard chunk.index == chunks.count else { throw DesktopMusicCatalogError.unexpectedChunk }
        // Bounds above guarantee that index arithmetic cannot overflow.
        let expectedBytes = min(DesktopMusicCatalogTransfer.maxChunkBytes,
            info.totalBytes - chunk.index * DesktopMusicCatalogTransfer.maxChunkBytes)
        guard chunk.data.count == expectedBytes, totalBytes <= info.totalBytes - chunk.data.count else {
            throw DesktopMusicCatalogError.invalidTransfer
        }
        chunks.append(chunk.data); totalBytes += chunk.data.count
    }

    public mutating func commit(transferID: UUID, current: DesktopMusicCatalog? = nil, at date: Date = .now) throws -> DesktopMusicCatalog {
        guard let info, transferID == info.id else { throw DesktopMusicCatalogError.invalidTransfer }
        defer { reset() }
        guard chunks.count == info.chunkCount, totalBytes == info.totalBytes else { throw DesktopMusicCatalogError.incompleteTransfer }
        var data = Data(capacity: totalBytes)
        for chunk in chunks { data.append(chunk) }
        guard catalogSHA256(data) == info.sha256 else { throw DesktopMusicCatalogError.digestMismatch }
        let decoded = try JSONDecoder().decode(DesktopMusicCatalog.self, from: data)
        guard decoded.revision == info.revision,
              try canonicalCatalogService(decoded.serviceAddress) == canonicalCatalogService(info.serviceAddress) else {
            throw DesktopMusicCatalogError.invalidTransfer
        }
        // Compare both catalogs at the same local instant: expiry may remove music without
        // a server revision bump, and must not be mistaken for conflicting metadata.
        let value = try decoded.validated(at: date)
        for previous in [baseline, current].compactMap({ $0 }) {
            try rejectCatalogRollback(serviceAddress: value.serviceAddress, revision: value.revision, current: previous)
            if try canonicalCatalogService(value.serviceAddress) == canonicalCatalogService(previous.serviceAddress),
               value.revision == previous.revision,
               try value.contentDigest() != previous.validated(at: date).contentDigest() {
                throw DesktopMusicCatalogError.revisionConflict
            }
        }
        return value
    }

    public mutating func reset() {
        info = nil; chunks = []; totalBytes = 0; baseline = nil
    }
}

public struct DesktopMusicCatalogStatus: Codable, Equatable, Sendable {
    public let serviceAddress: String
    public let revision: Int
    public let albumCount: Int
    public let trackCount: Int
    /// contentDigest(), not the complete transfer payload's sha256.
    public let digest: String
    public let syncedAt: Date

    public init(catalog: DesktopMusicCatalog, digest: String, syncedAt: Date = .now) {
        serviceAddress = catalog.serviceAddress; revision = catalog.revision
        albumCount = catalog.albums.count; trackCount = catalog.tracks.count
        self.digest = digest; self.syncedAt = syncedAt
    }
}

public enum DesktopMusicCatalogError: Error, LocalizedError {
    case invalidCatalog, invalidTransfer, unexpectedChunk, incompleteTransfer, digestMismatch, revisionRollback, revisionConflict

    public var errorDescription: String? {
        switch self {
        case .invalidCatalog: "音乐目录不完整，保留现有目录。"
        case .invalidTransfer: "音乐目录传输信息无效或超出大小限制。"
        case .unexpectedChunk: "音乐目录分片顺序或内容无效。"
        case .incompleteTransfer: "音乐目录尚未传输完整，保留现有目录。"
        case .digestMismatch: "音乐目录完整性校验失败，保留现有目录。"
        case .revisionRollback: "收到较旧的音乐目录，保留现有版本。"
        case .revisionConflict: "相同版本的音乐目录内容不一致，保留现有目录。"
        }
    }
}

private func catalogEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

private func catalogSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func canonicalCatalogService(_ address: String) throws -> String {
    let url = try PublicContentURL.snapshotURL(from: address)
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PublicContentError.invalidServiceURL }
    components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
    if components.port == 443 { components.port = nil }
    guard let canonical = components.url else { throw PublicContentError.invalidServiceURL }
    return canonical.absoluteString
}

private func rejectCatalogRollback(serviceAddress: String, revision: Int, current: DesktopMusicCatalog?) throws {
    if let current, try canonicalCatalogService(serviceAddress) == canonicalCatalogService(current.serviceAddress), revision < current.revision {
        throw DesktopMusicCatalogError.revisionRollback
    }
}
