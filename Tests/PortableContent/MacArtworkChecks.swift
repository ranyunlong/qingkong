import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import QingkongCore

private final class FixtureState: @unchecked Sendable {
    static let shared = FixtureState()
    private let lock = NSLock()
    private var value = Data()
    private var captured: [URLRequest] = []
    func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
    func take(_ request: URLRequest) -> Data { lock.lock(); defer { lock.unlock() }; captured.append(request); return value }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
}
private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let data = FixtureState.shared.take(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
private enum Failure: Error { case check(String) }
private func check(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.check(message) } }
private func key(_ url: URL, _ identity: String) -> String {
    SHA256.hash(data: Data((url.absoluteString + "|" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
}
@main struct ArtworkChecks {
    @MainActor static func main() async throws {
        let root = URL.temporaryDirectory.appending(path: "qingkong-artwork-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try image()
        FixtureState.shared.set(png)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "must-not-escape", "Cookie": "must-not-escape"]
        let url = URL(string: "https://example.invalid/cover.png")!
        let online = MacAlbumArtworkCache(directory: root, configuration: configuration)
        let loaded = try await online.image(for: url, identity: "album|1|100")
        try check(loaded.width == 2 && loaded.height == 2, "validated image decoded")
        let destination = root.appending(path: key(url, "album|1|100"))
        try check(try Data(contentsOf: destination) == png, "complete bytes atomically persisted")
        try check(FixtureState.shared.requests.count == 1 && FixtureState.shared.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil }, "anonymous request")
        print("PASS: complete validated artwork persists with anonymous transport")
        let offline = MacAlbumArtworkCache(directory: root, networkEnabled: false)
        let restored = try await offline.image(for: url, identity: "album|1|100")
        try check(restored.width == 2 && FixtureState.shared.requests.count == 1, "disk reload must avoid network")
        do { _ = try await offline.image(for: url, identity: "album|2|100"); throw Failure.check("revision must not reuse stale artwork") }
        catch is URLError {}
        do { _ = try await offline.image(for: URL(string: "http://example.invalid/cover.png")!); throw Failure.check("HTTP must be rejected") }
        catch is URLError {}
        print("PASS: offline relaunch, revision isolation and HTTPS restriction")
        try Data("damaged image".utf8).write(to: destination, options: .atomic)
        do { _ = try await offline.image(for: url, identity: "album|1|100"); throw Failure.check("corrupt image accepted") }
        catch is URLError {}
        try check(!FileManager.default.fileExists(atPath: destination.path), "damaged disk bytes removed")
        _ = try await online.image(for: url, identity: "album|1|100")
        try check(try Data(contentsOf: destination) == png, "network retry repairs corrupted cache")
        print("PASS: corrupt disk artwork is rejected, removed and repaired")
        let cancelled = Task { @MainActor in try await offline.image(for: url, identity: "album|1|100") }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure.check("cancelled request returned an image") }
        catch is CancellationError {}
        print("PASS: cancellation prevents image delivery")
        let lru = root.appending(path: "lru")
        try FileManager.default.createDirectory(at: lru, withIntermediateDirectories: true)
        var padded = png
        padded.append(Data(repeating: 0, count: 7 * 1_024 * 1_024 - png.count))
        _ = try ArticleImageTransfer.decode(padded)
        var urls: [URL] = []
        for i in 0..<5 {
            let address = URL(string: "https://example.invalid/\(i).png")!
            urls.append(address)
            let file = lru.appending(path: key(address, "album"))
            try padded.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(i))], ofItemAtPath: file.path)
        }
        let bounded = MacAlbumArtworkCache(directory: lru, networkEnabled: false)
        try check(!FileManager.default.fileExists(atPath: lru.appending(path: key(urls[0], "album")).path), "oldest cover not evicted")
        _ = try await bounded.image(for: urls[1], identity: "album")
        let extra = URL(string: "https://example.invalid/extra.png")!
        let extraFile = lru.appending(path: key(extra, "album"))
        try padded.write(to: extraFile, options: .atomic)
        _ = MacAlbumArtworkCache(directory: lru, networkEnabled: false)
        let files = try FileManager.default.contentsOfDirectory(at: lru, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        try check(total <= 30 * 1_024 * 1_024 && FileManager.default.fileExists(atPath: lru.appending(path: key(urls[1], "album")).path) && !FileManager.default.fileExists(atPath: lru.appending(path: key(urls[2], "album")).path), "30MB trim must preserve recently accessed cover")
        print("PASS: 30 MB bound evicts least recently accessed artwork")
    }
    private static func image() throws -> Data {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.check("PNG fixture") }
        return output as Data
    }
}
