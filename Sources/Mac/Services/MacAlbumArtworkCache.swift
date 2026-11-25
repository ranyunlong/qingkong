import Foundation
import CryptoKit
import CoreGraphics
import QingkongCore

/// A bounded, anonymous artwork cache independent of article reading history.
@MainActor
final class MacAlbumArtworkCache {
    static let shared = MacAlbumArtworkCache()
    private let directory: URL
    private let configuration: URLSessionConfiguration
    private let networkEnabled: Bool
    private let maximumBytes = 30 * 1_024 * 1_024

    init(directory: URL? = nil, configuration: URLSessionConfiguration? = nil, networkEnabled: Bool = true) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "MacAlbumArtwork", directoryHint: .isDirectory)
        self.networkEnabled = networkEnabled
        let configuration = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        self.configuration = configuration
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        trim()
    }

    func image(for url: URL, identity: String? = nil) async throws -> CGImage {
        guard PublicContentURL.articleResourceURL(from: url.absoluteString) != nil else { throw URLError(.unsupportedURL) }
        try Task.checkCancellation()
        let key = SHA256.hash(data: Data((url.absoluteString + "|" + (identity ?? "")).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let destination = directory.appending(path: key)
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                let size = values.fileSize ?? 0
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      size > 0, size <= ArticleImageTransfer.maximumBytes else { throw URLError(.cannotDecodeContentData) }
                let data = try Data(contentsOf: destination, options: .mappedIfSafe)
                let image = try ArticleImageTransfer.decode(data)
                try Task.checkCancellation()
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                trim()
                return image
            } catch is CancellationError { throw CancellationError() }
            catch { try? FileManager.default.removeItem(at: destination) }
        }
        guard networkEnabled else { throw URLError(.notConnectedToInternet) }
        let data = try await ArticleImageTransfer.load(url, configuration: configuration)
        let image = try ArticleImageTransfer.decode(data)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        trim()
        return image
    }

    /// Last successful access updates modification time; evict the oldest bytes first.
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        var entries: [(url: URL, size: Int, accessedAt: Date)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            let size = values.fileSize ?? 0
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  size > 0, size <= ArticleImageTransfer.maximumBytes else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.accessedAt < $1.accessedAt }) where total > maximumBytes {
            do {
                try FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            } catch { continue }
        }
    }
}
