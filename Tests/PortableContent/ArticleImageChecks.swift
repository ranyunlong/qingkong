import Foundation
import ImageIO
import CoreGraphics
import QingkongCore

private enum CheckFailure: Error { case failed(String) }

private final class ImageFixtures: @unchecked Sendable {
    enum Outcome {
        case image(Data, mime: String = "image/png", length: Int? = nil)
        case failure
        case held(Data)
    }
    static let shared = ImageFixtures()
    private let lock = NSLock()
    private var snapshot = Data()
    private var fallback: Outcome = .failure
    private var outcomes: [Outcome] = []
    private var requests: [URLRequest] = []
    private var held: [(ImageFixtureProtocol, Data)] = []

    func configure(snapshot: Data? = nil, fallback: Outcome? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let snapshot { self.snapshot = snapshot }
        if let fallback { self.fallback = fallback }
    }
    func enqueue(_ outcome: Outcome) { lock.lock(); defer { lock.unlock() }; outcomes.append(outcome) }
    func response(for request: URLRequest) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        if request.url?.path == "/api/v1/snapshot" { return .image(snapshot, mime: "application/json") }
        return outcomes.isEmpty ? fallback : outcomes.removeFirst()
    }
    func hold(_ request: ImageFixtureProtocol, data: Data) { lock.lock(); defer { lock.unlock() }; held.append((request, data)) }
    func release() {
        lock.lock(); let pending = held; held = []; lock.unlock()
        for (request, data) in pending { request.deliver(data, mime: "image/png", length: nil) }
    }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    var capturedRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var imageRequests: Int { capturedRequests.filter { $0.url?.path != "/api/v1/snapshot" }.count }
}

private final class ImageFixtureProtocol: URLProtocol {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
    override func startLoading() {
        guard request.url?.host == "example.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        switch ImageFixtures.shared.response(for: request) {
        case .failure: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .held(let data): ImageFixtures.shared.hold(self, data: data)
        case .image(let data, let mime, let length): deliver(data, mime: mime, length: length)
        }
    }
    func deliver(_ data: Data, mime: String, length: Int?) {
        lock.lock(); let stopped = self.stopped; lock.unlock()
        guard !stopped, let url = request.url else { return }
        var headers = ["Content-Type": mime]
        if let length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct ArticleImageChecks {
    @MainActor static func main() async throws {
        let root = URL.temporaryDirectory.appending(path: "qingkong-image-check-" + UUID().uuidString)
        let suite = "qingkong.images.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("https://example.invalid", forKey: "QingkongContentURL")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        var article = (object["articles"] as! [[String: Any]])[0]
        let bodyURL = URL(string: "https://example.invalid/body.png")!
        let coverURL = URL(string: "https://example.invalid/cover.png")!
        article["bodyHTML"] = "<p>离线图文</p><img src=\"\(bodyURL.absoluteString)\" alt=\"本机测试图片\"/>"
        article["coverURL"] = coverURL.absoluteString
        object["articles"] = [article]
        let imageData = try png()
        let fixture = ImageFixtures.shared
        fixture.configure(snapshot: try JSONSerialization.data(withJSONObject: object), fallback: .image(imageData))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageFixtureProtocol.self]
        // The image cache must strip even inherited session headers.
        configuration.httpAdditionalHeaders = ["Authorization": "FixtureMustNotEscape", "Cookie": "FixtureMustNotEscape"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); fixture.release() }
        let library = ContentLibrary(defaults: defaults, directoryOverride: root, sessionOverride: session)
        await library.refresh()
        guard let loaded = library.articles.first else { throw CheckFailure.failed("fixture article did not load") }
        let initialRequests = fixture.imageRequests
        _ = try await library.articleImages.image(for: bodyURL, articleID: loaded.id)
        try check(files(in: root).isEmpty && fixture.imageRequests == initialRequests + 1,
                  "displaying an unread unsaved article must not retain image bytes")
        library.markRead(loaded.id)
        await library.articleImages.waitForPendingImages()
        try check(files(in: root).count == 2 && (try files(in: root).allSatisfy { try Data(contentsOf: $0) == imageData }),
                  "read article must store complete body and cover image bytes")
        print("PASS: unread images stay transient; read articles persist complete body and cover images")

        fixture.configure(fallback: .failure)
        let requestCount = fixture.imageRequests
        let restored = ContentLibrary(defaults: defaults, directoryOverride: root, sessionOverride: session)
        let offlineBody = try await restored.articleImages.image(for: bodyURL, articleID: loaded.id)
        let offlineCover = try await restored.articleImages.image(for: coverURL, articleID: loaded.id)
        await restored.articleImages.waitForPendingImages()
        try check(offlineBody.width == 2 && offlineCover.height == 2 && fixture.imageRequests == requestCount,
                  "relaunch must decode cached body and cover images without any image request")
        print("PASS: real disk images survive relaunch and display without network requests")

        let favoriteRoot = root.appending(path: "favorite")
        fixture.configure(fallback: .image(imageData))
        let favoriteLibrary = ContentLibrary(defaults: defaults, directoryOverride: favoriteRoot, sessionOverride: session)
        await favoriteLibrary.refresh()
        favoriteLibrary.toggleFavorite(loaded.id)
        await favoriteLibrary.articleImages.waitForPendingImages()
        try check(files(in: favoriteRoot).count == 2, "favorite-only article must cache its images")
        favoriteLibrary.toggleFavorite(loaded.id)
        try check(files(in: favoriteRoot).isEmpty, "removing the only retention reference must delete its images")
        print("PASS: favorite-only articles cache images and release them when no longer retained")

        let replacementURL = URL(string: "https://example.invalid/revised.png")!
        article["bodyHTML"] = "<img src=\"\(replacementURL.absoluteString)\" alt=\"新修订图片\"/>"
        article["coverURL"] = NSNull()
        article["revision"] = 2
        object["articles"] = [article]; object["revision"] = 2
        fixture.configure(snapshot: try JSONSerialization.data(withJSONObject: object), fallback: .failure)
        await restored.refresh()
        await restored.articleImages.waitForPendingImages()
        try check(files(in: root).isEmpty && restored.articleImages.identity(for: bodyURL, articleID: loaded.id) == nil,
                  "revision must immediately remove images no longer referenced by the retained article")
        fixture.configure(fallback: .image(imageData))
        _ = try await restored.articleImages.image(for: replacementURL, articleID: loaded.id)
        try check(files(in: root).count == 1, "new article revision must retain its own complete image")
        object["articles"] = []; object["revision"] = 3
        fixture.configure(snapshot: try JSONSerialization.data(withJSONObject: object), fallback: .failure)
        await restored.refresh()
        try check(files(in: root).isEmpty && restored.article(id: loaded.id) == nil, "withdrawal must delete the article's image files")
        print("PASS: article revision and withdrawal remove obsolete image files")

        let cacheRoot = root.appending(path: "isolated")
        let cache = ArticleImageCache(directory: cacheRoot.appending(path: "ArticleImages"), configuration: configuration)
        cache.reconcile(serviceAddress: "https://example.invalid", articles: [loaded], retainedIDs: [loaded.id])
        await cache.waitForPendingImages()
        fixture.enqueue(.held(imageData))
        let late = Task { try await cache.image(for: bodyURL, articleID: loaded.id) }
        try await wait { fixture.heldCount == 1 }
        cache.reconcile(serviceAddress: "https://example.invalid", articles: [], retainedIDs: [])
        fixture.release()
        try await mustFail(late, "withdrawn late response unexpectedly succeeded")
        try check(files(in: cacheRoot).isEmpty, "a late image response must not restore withdrawn bytes")
        print("PASS: late response cannot recreate withdrawn image cache")

        cache.reconcile(serviceAddress: "https://example.invalid", articles: [loaded], retainedIDs: [])
        fixture.enqueue(.held(imageData))
        let switched = Task { try await cache.image(for: bodyURL, articleID: loaded.id) }
        try await wait { fixture.heldCount == 1 }
        cache.reconcile(serviceAddress: "https://other.example.invalid", articles: [loaded], retainedIDs: [loaded.id])
        fixture.release()
        try await mustFail(switched, "previous service response unexpectedly succeeded")
        await cache.waitForPendingImages()
        try check(files(in: cacheRoot).isEmpty, "service switch must discard previous service responses")
        print("PASS: service isolation rejects responses started under the previous service")

        cache.reconcile(serviceAddress: "https://example.invalid", articles: [loaded], retainedIDs: [loaded.id])
        await cache.waitForPendingImages()
        fixture.enqueue(.held(imageData))
        let cancelled = Task { try await cache.image(for: bodyURL, articleID: loaded.id) }
        try await wait { fixture.heldCount == 1 }
        cancelled.cancel()
        try await mustFail(cancelled, "cancelled image unexpectedly succeeded")
        fixture.release()
        try check(files(in: cacheRoot).isEmpty, "cancelled request must not leave partial or complete cache files")
        print("PASS: cancellation leaves no image cache or partial file")

        // No retention pass runs here, so every fixture belongs to its explicit request.
        let boundsRoot = root.appending(path: "bounds")
        let bounds = ArticleImageCache(directory: boundsRoot.appending(path: "ArticleImages"), configuration: configuration)
        bounds.reconcile(serviceAddress: "https://example.invalid", articles: [loaded], retainedIDs: [])
        let invalid: [ImageFixtures.Outcome] = [.image(imageData, mime: "text/html"), .image(Data("not an image".utf8)),
            .image(imageData, length: 8 * 1_024 * 1_024 + 1), .image(Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)),
            .image(try png(width: 20_001, height: 1))]
        for outcome in invalid {
            fixture.enqueue(outcome)
            try await mustFail(Task { try await bounds.image(for: bodyURL, articleID: loaded.id) }, "invalid image unexpectedly succeeded")
            try check(files(in: boundsRoot).isEmpty, "rejected image must not leave a partial file")
        }
        fixture.enqueue(.image(try png(width: 2_000, height: 1)))
        let downsampled = try await bounds.image(for: bodyURL, articleID: loaded.id)
        try check(downsampled.width == 1_600, "display raster must stay within its existing 1600-pixel decode limit")
        print("PASS: MIME, corrupt data, declared and streamed 8 MiB limits, dimensions and thumbnail bounds hold")

        fixture.configure(fallback: .image(imageData))
        cache.reconcile(serviceAddress: "https://example.invalid", articles: [loaded], retainedIDs: [loaded.id])
        await cache.waitForPendingImages()
        try check(files(in: cacheRoot).count == 2, "corruption check requires two completed cache files")
        try Data("damaged cache".utf8).write(to: files(in: cacheRoot).first!)
        fixture.configure(fallback: .failure)
        for url in [bodyURL, coverURL] { _ = try? await cache.image(for: url, articleID: loaded.id) }
        try check(files(in: cacheRoot).count == 1, "corrupted stored image must be removed instead of reported available")
        cache.reconcile(serviceAddress: "https://other.example.invalid", articles: [], retainedIDs: [])
        try check(files(in: cacheRoot).isEmpty, "service switch must remove all previous service images")
        print("PASS: corrupted disk images are rejected and service switch removes the previous cache")

        let unwritableRoot = root.appending(path: "unwritable")
        let unwritable = ArticleImageCache(directory: unwritableRoot.appending(path: "ArticleImages"), configuration: configuration)
        unwritable.reconcile(serviceAddress: "https://example.invalid", articles: [loaded], retainedIDs: [loaded.id])
        await unwritable.waitForPendingImages()
        let unwritableDirectory = try FileManager.default.contentsOfDirectory(at: unwritableRoot.appending(path: "ArticleImages"), includingPropertiesForKeys: nil)[0]
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritableDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritableDirectory.path) }
        fixture.enqueue(.image(imageData))
        try await mustFail(Task { try await unwritable.image(for: bodyURL, articleID: loaded.id) }, "unwritable cache unexpectedly completed an offline image")
        try check(files(in: unwritableRoot).isEmpty, "failed atomic save must not leave completed or partial image files")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritableDirectory.path)
        print("PASS: disk write failure leaves no completed or partial offline image")

        let imageRequests = fixture.capturedRequests.filter { $0.url?.path != "/api/v1/snapshot" }
        try check(!imageRequests.isEmpty && imageRequests.allSatisfy {
            $0.httpMethod == "GET" && $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil
        }, "article image requests must remain anonymous bodyless GETs")
        print("PASS: intercepted image requests have no inherited credentials, cookies or personal payload")
        print("11 article image checks passed; real disk, intercepted responses, no network, simulator, or device used.")
    }

    private static func mustFail(_ task: Task<CGImage, Error>, _ message: String) async throws {
        let result = await task.result
        if case .success = result { throw CheckFailure.failed(message) }
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure.failed("article image check timed out")
    }

    private static func files(in root: URL) -> [URL] {
        let directory = root.appending(path: "ArticleImages")
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }

    private static func png(width: Int = 2, height: Int = 2) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw CheckFailure.failed("fixture PNG encoding failed") }
        return data as Data
    }
}
