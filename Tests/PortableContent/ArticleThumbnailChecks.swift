import Foundation
import CoreGraphics
import ImageIO
import QingkongCore

private enum CheckFailure: Error { case failed(String) }
private final class ThumbnailProtocol: URLProtocol {
    static let lock = NSLock()
    static var data = Data()
    static var requestCount = 0
    static var hold = false
    static var pending: [ThumbnailProtocol] = []
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { Self.lock.lock(); stopped = true; Self.lock.unlock() }
    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let held = Self.hold
        if held { Self.pending.append(self) }
        Self.lock.unlock()
        if !held { deliver() }
    }
    func deliver() {
        Self.lock.lock(); let cancelled = stopped; Self.lock.unlock()
        guard !cancelled else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func release() {
        lock.lock(); let requests = pending; pending = []; hold = false; lock.unlock()
        requests.forEach { $0.deliver() }
    }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requestCount }
}

@main
struct ArticleThumbnailChecks {
    @MainActor static func main() async throws {
        let directory = URL.temporaryDirectory.appending(path: "qingkong-thumbnail-" + UUID().uuidString)
        defer { ThumbnailProtocol.release(); try? FileManager.default.removeItem(at: directory) }
        let fixture = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/PublicContent/snapshot.json"))
        let snapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: fixture)
        guard let article = snapshot.articles.first else { throw CheckFailure.failed("missing article fixture") }
        var object = try JSONSerialization.jsonObject(with: PublicContentSnapshot.encoder().encode(snapshot)) as! [String: Any]
        var row = (object["articles"] as! [[String: Any]])[0]
        let url = URL(string: "https://example.invalid/large-cover.png")!
        row["coverURL"] = url.absoluteString
        row["bodyHTML"] = NSNull()
        object["articles"] = [row]
        let modified = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let display = modified.articles[0]
        ThumbnailProtocol.data = try png()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ThumbnailProtocol.self]
        let cache = ArticleImageCache(directory: directory, configuration: config)
        cache.reconcile(serviceAddress: "https://example.invalid", articles: [display], retainedIDs: [])

        var heartbeatGaps: [Double] = []
        let heartbeat = Task { @MainActor in
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                let now = ProcessInfo.processInfo.systemUptime
                heartbeatGaps.append(now - last)
                last = now
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<60 {
            #if THUMBNAIL_BASELINE
            _ = try await cache.image(for: url, articleID: article.id)
            #else
            let image = try await cache.image(for: url, articleID: article.id, maximumPixelSize: 192)
            try check(max(image.width, image.height) <= 192, "list cover must be downsampled for its display size")
            #endif
        }
        heartbeat.cancel()
        await heartbeat.value
        print(String(format: "BENCH: 60 repeated list-cover loads %.3f s, requests %d, main-actor max heartbeat gap %.1f ms",
                     ProcessInfo.processInfo.systemUptime - started, ThumbnailProtocol.count, (heartbeatGaps.max() ?? 0) * 1000))
        #if !THUMBNAIL_BASELINE
        try check(ThumbnailProtocol.count == 1, "reappearing unread rows reuse only memory, without repeated transfers")
        let disk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        try check((disk?.allObjects as? [URL] ?? []).allSatisfy { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true },
                  "thumbnail memory caching cannot retain unread article bytes on disk")
        print("PASS: 192px thumbnails reuse bounded memory without persisting unread images")

        let concurrentCache = ArticleImageCache(directory: directory.appending(path: "concurrent"), configuration: config)
        concurrentCache.reconcile(serviceAddress: "https://example.invalid", articles: [display], retainedIDs: [])
        ThumbnailProtocol.hold = true
        let before = ThumbnailProtocol.count
        let first = Task { try await concurrentCache.image(for: url, articleID: article.id, maximumPixelSize: 192) }
        let second = Task { try await concurrentCache.image(for: url, articleID: article.id, maximumPixelSize: 192) }
        try await wait { ThumbnailProtocol.count > before }
        first.cancel()
        ThumbnailProtocol.release()
        if case .success = await first.result { throw CheckFailure.failed("cancelled subscriber received a thumbnail") }
        let secondImage = try await second.value
        try check(secondImage.width == 192 && ThumbnailProtocol.count == before + 1, "shared thumbnail load survives one subscriber cancellation")
        print("PASS: concurrent rows share a request and cancellation cannot cancel another row")

        var revisionRow = row
        revisionRow["revision"] = display.revision + 1
        object["articles"] = [revisionRow]
        let updated = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object)).articles[0]
        concurrentCache.reconcile(serviceAddress: "https://example.invalid", articles: [updated], retainedIDs: [])
        let beforeRevision = ThumbnailProtocol.count
        _ = try await concurrentCache.image(for: url, articleID: updated.id, maximumPixelSize: 192)
        try check(ThumbnailProtocol.count == beforeRevision + 1, "article revision cannot reuse the previous thumbnail")
        concurrentCache.reconcile(serviceAddress: "https://example.invalid", articles: [], retainedIDs: [])
        do {
            _ = try await concurrentCache.image(for: url, articleID: updated.id, maximumPixelSize: 192)
            throw CheckFailure.failed("withdrawn thumbnail remained available")
        } catch is URLError { }
        print("PASS: revision and withdrawal invalidate thumbnail identities")

        let lateCache = ArticleImageCache(directory: directory.appending(path: "late"), configuration: config)
        lateCache.reconcile(serviceAddress: "https://example.invalid", articles: [display], retainedIDs: [])
        ThumbnailProtocol.hold = true
        let beforeLate = ThumbnailProtocol.count
        let late = Task { try await lateCache.image(for: url, articleID: display.id, maximumPixelSize: 192) }
        try await wait { ThumbnailProtocol.count > beforeLate }
        lateCache.reconcile(serviceAddress: "https://other.example.invalid", articles: [display], retainedIDs: [])
        ThumbnailProtocol.release()
        if case .success = await late.result { throw CheckFailure.failed("previous-service thumbnail was delivered") }
        try check(lateCache.thumbnailCacheBytes == 0, "late image cannot populate the next service's memory cache")
        print("PASS: service switch rejects in-flight thumbnail completion")

        let memoryCache = ArticleImageCache(directory: directory.appending(path: "memory"), configuration: config)
        var memoryArticles: [PublicArticle] = []
        for index in 0..<240 {
            var item = row
            item["id"] = "thumbnail-\(index)"
            item["coverURL"] = "https://example.invalid/cover-\(index).png"
            memoryArticles.append(try PublicContentSnapshot.decoder().decode(PublicArticle.self, from: JSONSerialization.data(withJSONObject: item)))
        }
        memoryCache.reconcile(serviceAddress: "https://example.invalid", articles: memoryArticles, retainedIDs: [])
        for article in memoryArticles { _ = try await memoryCache.image(for: article.coverURL!, articleID: article.id, maximumPixelSize: 192) }
        try check(memoryCache.thumbnailCacheBytes > 0 && memoryCache.thumbnailCacheBytes <= 16 * 1_024 * 1_024,
                  "decoded thumbnail memory must stay within 16 MiB")
        let beforeEviction = ThumbnailProtocol.count
        _ = try await memoryCache.image(for: memoryArticles.last!.coverURL!, articleID: memoryArticles.last!.id, maximumPixelSize: 192)
        try check(ThumbnailProtocol.count == beforeEviction, "recent thumbnail must survive memory trimming")
        _ = try await memoryCache.image(for: memoryArticles[0].coverURL!, articleID: memoryArticles[0].id, maximumPixelSize: 192)
        try check(ThumbnailProtocol.count == beforeEviction + 1, "oldest thumbnail must be evicted once the budget is exceeded")
        print("PASS: 16 MiB memory budget evicts old rasters and retains the most recent")

        let coverDirectory = directory.appending(path: "covers")
        let covers = PublicCoverCache(directory: coverDirectory, configuration: config)
        let beforeCover = ThumbnailProtocol.count
        let cover = try await covers.image(for: url, identity: "service/article/v1", maximumPixelSize: 288)
        try check(cover.width == 288, "public cover is downsampled")
        try check(covers.cachedImage(for: url, identity: "service/article/v1", maximumPixelSize: 288) != nil, "cover memory hit is available before the view's task")
        try check(ThumbnailProtocol.count == beforeCover + 1, "first cover loads once")
        let offlineCovers = PublicCoverCache(directory: coverDirectory, configuration: config, networkEnabled: false)
        _ = try await offlineCovers.image(for: url, identity: "service/article/v1", maximumPixelSize: 288)
        try check(ThumbnailProtocol.count == beforeCover + 1, "cover survives cache recreation without network")
        for identity in ["service/article/v2", "other-service/article/v1", "service/album/v1"] {
            do {
                _ = try await offlineCovers.image(for: url, identity: identity, maximumPixelSize: 288)
                throw CheckFailure.failed("cover crossed revision, service or content type")
            } catch is URLError { }
        }
        let concurrentCovers = PublicCoverCache(directory: directory.appending(path: "concurrent-covers"), configuration: config)
        let beforeConcurrentCovers = ThumbnailProtocol.count
        async let coverA = concurrentCovers.image(for: url, identity: "album/v1", maximumPixelSize: 960)
        async let coverB = concurrentCovers.image(for: url, identity: "album/v1", maximumPixelSize: 960)
        _ = try await (coverA, coverB)
        try check(ThumbnailProtocol.count == beforeConcurrentCovers + 1, "concurrent covers share one request")
        print("PASS: public covers persist offline, hit memory immediately, coalesce requests and isolate revisions/services")
        #endif
    }

    private static func check(_ value: Bool, _ message: String) throws { if !value { throw CheckFailure.failed(message) } }
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CheckFailure.failed("thumbnail request timed out")
    }
    private static func png() throws -> Data {
        let width = 2048, height = 1024
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure.failed("PNG fixture creation failed") }
        return data as Data
    }
}
