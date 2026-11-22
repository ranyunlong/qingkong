import Foundation
import CryptoKit
import ImageIO
import Observation
import QingkongCore

/// Only the current service's read or saved article revisions may retain image bytes.
@MainActor @Observable
final class ArticleImageCache {
    private struct Resource {
        let articleID: String
        let url: URL
        let key: String
    }

    private let directory: URL
    private let configuration: URLSessionConfiguration
    private let networkEnabled: Bool
    private var serviceAddress: String?
    private var serviceDirectory: URL?
    private var generation = UUID()
    private var resources: [String: [URL: Resource]] = [:]
    private var retainedKeys: Set<String> = []
    @ObservationIgnored private var prefetch: Task<Void, Never>?

    init(directory: URL, configuration: URLSessionConfiguration? = nil, networkEnabled: Bool = true) {
        self.directory = directory
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
    }

    func reconcile(serviceAddress: String, articles: [PublicArticle], retainedIDs: Set<String>) {
        if self.serviceAddress != serviceAddress {
            generation = UUID()
            self.serviceAddress = serviceAddress
            serviceDirectory = directory.appending(path: Self.digest(serviceAddress), directoryHint: .isDirectory)
        }
        var next: [String: [URL: Resource]] = [:]
        var nextRetained: Set<String> = []
        for article in articles {
            var urls = Set(PublicArticleRichText.parse(article.bodyHTML)?.blocks.compactMap { $0.image?.url } ?? [])
            if let cover = article.coverURL, PublicContentURL.articleResourceURL(from: cover.absoluteString) != nil { urls.insert(cover) }
            for url in urls {
                let key = Self.digest("\(article.id)|\(article.revision)|\(article.updatedAt.timeIntervalSince1970)|\(url.absoluteString)")
                next[article.id, default: [:]][url] = Resource(articleID: article.id, url: url, key: key)
                if retainedIDs.contains(article.id) { nextRetained.insert(key) }
            }
        }
        resources = next
        retainedKeys = nextRetained
        prefetch?.cancel()
        cleanUnreferencedFiles()
        let pending = resources.values.flatMap(\.values).filter { retainedKeys.contains($0.key) }.sorted { $0.key < $1.key }
        prefetch = Task { [weak self] in
            for resource in pending {
                guard !Task.isCancelled, let self else { return }
                _ = try? await self.image(for: resource.url, articleID: resource.articleID)
            }
        }
    }

    /// Includes service and article revision so SwiftUI replaces images after either changes.
    func identity(for url: URL, articleID: String) -> String? {
        guard let key = resources[articleID]?[url]?.key, let serviceAddress else { return nil }
        return Self.digest(serviceAddress) + key
    }

    func waitForPendingImages() async { await prefetch?.value }

    func image(for url: URL, articleID: String) async throws -> CGImage {
        guard let resource = resources[articleID]?[url], let serviceDirectory,
              PublicContentURL.articleResourceURL(from: url.absoluteString) != nil else { throw URLError(.resourceUnavailable) }
        let requestGeneration = generation
        let destination = serviceDirectory.appending(path: resource.key)
        if retainedKeys.contains(resource.key), FileManager.default.fileExists(atPath: destination.path) {
            do {
                let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= ArticleImageTransfer.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                let data = try Data(contentsOf: destination, options: .mappedIfSafe)
                let image = try ArticleImageTransfer.decode(data)
                try Task.checkCancellation()
                return image
            } catch is CancellationError { throw CancellationError() }
            catch { try? FileManager.default.removeItem(at: destination) }
        }
        guard networkEnabled else { throw URLError(.notConnectedToInternet) }
        let data = try await ArticleImageTransfer.load(url, configuration: configuration)
        let image = try ArticleImageTransfer.decode(data)
        try Task.checkCancellation()
        guard generation == requestGeneration, resources[articleID]?[url]?.key == resource.key else { throw URLError(.cancelled) }
        if retainedKeys.contains(resource.key) {
            try FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: true)
            // No index entry or final file exists until complete bytes have passed decoding.
            try data.write(to: destination, options: .atomic)
        }
        return image
    }

    private func cleanUnreferencedFiles() {
        guard let serviceDirectory else { return }
        try? FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != serviceDirectory.lastPathComponent {
            try? FileManager.default.removeItem(at: old)
        }
        for file in (try? FileManager.default.contentsOfDirectory(at: serviceDirectory, includingPropertiesForKeys: nil)) ?? [] where !retainedKeys.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Anonymous public image transport; both streaming bytes and decoded pixels are bounded.
private enum ArticleImageTransfer {
    static let maximumBytes = 8 * 1_024 * 1_024

    static func load(_ url: URL, configuration: URLSessionConfiguration) async throws -> Data {
        let session = URLSession(configuration: configuration, delegate: ArticleImageRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("image/jpeg,image/png,image/gif,image/webp,image/heic,image/heif", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              let finalURL = response.url, PublicContentURL.articleResourceURL(from: finalURL.absoluteString) != nil,
              ["image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif"].contains(response.mimeType?.lowercased() ?? ""),
              response.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.cannotDecodeContentData) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png", "com.compuserve.gif", "org.webmproject.webp", "public.heic", "public.heif"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              Int64(width) * Int64(height) <= 40_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1_600,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        return thumbnail
    }
}

private final class ArticleImageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, PublicContentURL.articleResourceURL(from: url.absoluteString) != nil else {
            completionHandler(nil); return
        }
        completionHandler(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }
}
