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
    @ObservationIgnored private var thumbnails: [String: Thumbnail] = [:]
    @ObservationIgnored private var thumbnailRequests: [String: ThumbnailRequest] = [:]
    @ObservationIgnored private var thumbnailAccess: UInt64 = 0
    private let thumbnailByteLimit = 16 * 1_024 * 1_024

    private struct Thumbnail {
        let image: CGImage
        let resourceKey: String
        var accessed: UInt64
        var cost: Int { image.bytesPerRow * image.height }
    }
    private struct ThumbnailRequest {
        let id: UUID
        let resourceKey: String
        let task: Task<CGImage, Error>
    }

    var thumbnailCacheBytes: Int { thumbnails.values.reduce(0) { $0 + $1.cost } }

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
            thumbnails.removeAll()
            thumbnailRequests.values.forEach { $0.task.cancel() }
            thumbnailRequests.removeAll()
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
        let validKeys = Set(next.values.flatMap { $0.values.map(\.key) })
        thumbnails = thumbnails.filter { validKeys.contains($0.value.resourceKey) }
        for (key, request) in thumbnailRequests where !validKeys.contains(request.resourceKey) {
            request.task.cancel()
            thumbnailRequests.removeValue(forKey: key)
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

    func image(for url: URL, articleID: String, maximumPixelSize: Int = 1600) async throws -> CGImage {
        try Task.checkCancellation()
        guard let resource = resources[articleID]?[url], let serviceDirectory,
              PublicContentURL.articleResourceURL(from: url.absoluteString) != nil else { throw URLError(.resourceUnavailable) }
        let requestGeneration = generation
        let pixelSize = min(1600, max(1, maximumPixelSize))
        // Body images retain the existing disk policy. Only small, transient rasters use memory.
        guard pixelSize < 1600 else {
            return try await loadImage(resource, directory: serviceDirectory, generation: requestGeneration, pixelSize: pixelSize)
        }
        let key = serviceDirectory.lastPathComponent + resource.key + "|\(pixelSize)"
        thumbnailAccess &+= 1
        if var cached = thumbnails[key] {
            cached.accessed = thumbnailAccess
            thumbnails[key] = cached
            return cached.image
        }
        let request: ThumbnailRequest
        if let pending = thumbnailRequests[key] {
            request = pending
        } else {
            let task = Task { try await self.loadImage(resource, directory: serviceDirectory, generation: requestGeneration, pixelSize: pixelSize) }
            request = ThumbnailRequest(id: UUID(), resourceKey: resource.key, task: task)
            thumbnailRequests[key] = request
        }
        defer { if thumbnailRequests[key]?.id == request.id { thumbnailRequests.removeValue(forKey: key) } }
        let image = try await request.task.value
        try Task.checkCancellation()
        guard isCurrent(resource, generation: requestGeneration) else { throw URLError(.cancelled) }
        thumbnailAccess &+= 1
        thumbnails[key] = Thumbnail(image: image, resourceKey: resource.key, accessed: thumbnailAccess)
        while thumbnailCacheBytes > thumbnailByteLimit,
              let oldest = thumbnails.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            thumbnails.removeValue(forKey: oldest)
        }
        return image
    }

    private func isCurrent(_ resource: Resource, generation: UUID) -> Bool {
        self.generation == generation && resources[resource.articleID]?[resource.url]?.key == resource.key
    }

    private func loadImage(_ resource: Resource, directory: URL, generation: UUID, pixelSize: Int) async throws -> CGImage {
        try Task.checkCancellation()
        let destination = directory.appending(path: resource.key)
        if retainedKeys.contains(resource.key) {
            // File inspection and raster decoding must not run on the UI actor.
            let read = Task.detached(priority: .utility) { () throws -> CGImage? in
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
                do {
                    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= ArticleImageTransfer.maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    let data = try Data(contentsOf: destination, options: .mappedIfSafe)
                    return try ArticleImageTransfer.decode(data, maximumPixelSize: pixelSize)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    return nil
                }
            }
            let stored = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
            try Task.checkCancellation()
            guard isCurrent(resource, generation: generation) else { throw URLError(.cancelled) }
            if let stored { return stored }
        }
        guard networkEnabled else { throw URLError(.notConnectedToInternet) }
        let data = try await ArticleImageTransfer.load(resource.url, configuration: configuration)
        let decode = Task.detached(priority: .utility) { try ArticleImageTransfer.decode(data, maximumPixelSize: pixelSize) }
        let image = try await withTaskCancellationHandler(operation: { try await decode.value }, onCancel: { decode.cancel() })
        try Task.checkCancellation()
        guard isCurrent(resource, generation: generation) else { throw URLError(.cancelled) }
        if retainedKeys.contains(resource.key) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Only retained, fully validated images may be committed to the persistent cache.
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
enum ArticleImageTransfer {
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

    static func decode(_ data: Data, maximumPixelSize: Int = 1600) throws -> CGImage {
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
                  kCGImageSourceThumbnailMaxPixelSize: min(1600, max(1, maximumPixelSize)),
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

/// Public list covers are disposable cache data, separate from saved article bodies.
/// Identity includes service, content kind and revision; startup never needs a full catalog.
@MainActor
final class PublicCoverCache {
    private let directory: URL
    private let configuration: URLSessionConfiguration
    private let networkEnabled: Bool
    private let memory = NSCache<NSString, CGImage>()
    private var requests: [String: Task<CGImage, Error>] = [:]
    private let diskLimit = 30 * 1_024 * 1_024

    init(directory: URL, configuration: URLSessionConfiguration? = nil, networkEnabled: Bool = true) {
        self.directory = directory
        self.networkEnabled = networkEnabled
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        self.configuration = config
        memory.totalCostLimit = 16 * 1_024 * 1_024
    }

    func cachedImage(for url: URL, identity: String, maximumPixelSize: Int) -> CGImage? {
        memory.object(forKey: memoryKey(url, identity, maximumPixelSize) as NSString)
    }

    func image(for url: URL, identity: String, maximumPixelSize: Int) async throws -> CGImage {
        guard PublicContentURL.articleResourceURL(from: url.absoluteString) != nil else { throw URLError(.unsupportedURL) }
        try Task.checkCancellation()
        let key = memoryKey(url, identity, maximumPixelSize)
        if let image = memory.object(forKey: key as NSString) { return image }
        if let request = requests[key] {
            let image = try await request.value
            try Task.checkCancellation()
            return image
        }
        let destination = directory.appending(path: diskKey(url, identity))
        let pixelSize = min(1600, max(1, maximumPixelSize))
        let config = configuration
        let enabled = networkEnabled
        let limit = diskLimit
        let cacheDirectory = directory
        let request = Task<CGImage, Error> {
            // Reading, decoding and disk eviction never run on the UI actor.
            let cached = await Task.detached(priority: .utility) { () -> CGImage? in
                guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
                do {
                    let values = try destination.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size > 0, size <= ArticleImageTransfer.maximumBytes else { throw URLError(.cannotDecodeContentData) }
                    let image = try ArticleImageTransfer.decode(Data(contentsOf: destination), maximumPixelSize: pixelSize)
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
                    return image
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    return nil
                }
            }.value
            if let cached { return cached }
            guard enabled else { throw URLError(.notConnectedToInternet) }
            let data = try await ArticleImageTransfer.load(url, configuration: config)
            return try await Task.detached(priority: .utility) {
                let image = try ArticleImageTransfer.decode(data, maximumPixelSize: pixelSize)
                // A full disk or a cache write failure must not prevent display.
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? data.write(to: destination, options: .atomic)
                Self.trim(cacheDirectory, limit: limit)
                return image
            }.value
        }
        requests[key] = request
        defer { requests[key] = nil }
        let image = try await request.value
        memory.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
        try Task.checkCancellation()
        return image
    }

    private func diskKey(_ url: URL, _ identity: String) -> String {
        SHA256.hash(data: Data((identity + "|" + url.absoluteString).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func memoryKey(_ url: URL, _ identity: String, _ pixelSize: Int) -> String {
        diskKey(url, identity) + "|\(min(1600, max(1, pixelSize)))"
    }

    nonisolated private static func trim(_ directory: URL, limit: Int) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true, let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries.sorted(by: { $0.2 < $1.2 }) where total > limit {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
