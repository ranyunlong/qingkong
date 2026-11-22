import Foundation
import QingkongCore

private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

private final class FixtureTransport: @unchecked Sendable {
    enum Outcome { case snapshot(Data), fail(URLError.Code) }
    static let shared = FixtureTransport()
    private let lock = NSLock()
    private var outcomes: [Outcome] = []
    private var requests: [URLRequest] = []

    func enqueue(_ outcome: Outcome) {
        lock.lock(); defer { lock.unlock() }
        outcomes.append(outcome)
    }

    func next(_ request: URLRequest) -> Outcome {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return outcomes.isEmpty ? .fail(.resourceUnavailable) : outcomes.removeFirst()
    }

    var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, url.host == "example.invalid", url.path == "/api/v1/snapshot" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch FixtureTransport.shared.next(request) {
        case .fail(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .snapshot(let data):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@main
struct ContentLibraryChecks {
    @MainActor static func main() async throws {
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let originalData = try Data(contentsOf: fixtureURL)
        var object = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
        let fixture = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: originalData).validated()
        try check(object["testOnly"] as? Bool == true, "fixture must clearly identify test-only data")
        try check(fixture.articles.count == 6 && Set(fixture.articles.map(\.category)).count == 3,
                  "fixture must provide six articles across three categories")
        try check(fixture.articles.allSatisfy { $0.title.hasPrefix("[测试]") && $0.review.reviewer.contains("未专业审核") },
                  "test articles and synthetic review fields must never imply a professional review")
        print("PASS: six clearly marked test articles decode using the real client schema")

        let root = FileManager.default.temporaryDirectory.appending(path: "qingkong-content-check-" + UUID().uuidString)
        let suite = "qingkong.content.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let defaultLibrary = ContentLibrary(defaults: defaults, directoryOverride: root.appending(path: "default-service"), sessionOverride: session)
        try check(defaultLibrary.serviceAddress == "https://xqk.geckoai.cn" && defaultLibrary.isConfigured,
                  "a fresh install must have the public service configured without user input")
        print("PASS: a fresh install defaults to the public content service without configuration")
        defaults.set("https://example.invalid", forKey: "QingkongContentURL")
        func makeLibrary() -> ContentLibrary {
            ContentLibrary(defaults: defaults, directoryOverride: root, sessionOverride: session)
        }
        let transport = FixtureTransport.shared
        transport.enqueue(.snapshot(originalData))
        let library = makeLibrary()
        await library.refresh()
        try check(library.articles.count == 6 && library.lastCheckedAt != nil, "successful response must populate real client state")
        try check(library.articles.filter { $0.category == "阅读与收藏" }.count == 3, "category fixture must support related reading")
        try check(library.articles.filter { ($0.title + $0.summary + $0.body).localizedStandardContains("书签") }.count == 1,
                  "body-only search term must identify its article")
        print("PASS: actual client refresh loads articles with useful category and search samples")

        var albumObject = object
        var albumRows = object["albums"] as! [[String: Any]]
        for index in albumRows.indices { albumRows[index]["publishedAt"] = "2026-11-\(20 + index)T02:00:00Z" }
        albumRows[0]["updatedAt"] = "2026-11-22T04:00:00Z"
        let orderedTrackIDs = Array(fixture.albums[2].trackIDs.reversed())
        albumRows[2]["trackIDs"] = orderedTrackIDs
        albumObject["albums"] = Array(albumRows.reversed())
        albumObject["tracks"] = Array((object["tracks"] as! [[String: Any]]).reversed())
        transport.enqueue(.snapshot(try JSONSerialization.data(withJSONObject: albumObject)))
        let albumLibrary = ContentLibrary(defaults: defaults, directoryOverride: root.appending(path: "album-order"), sessionOverride: session)
        await albumLibrary.refresh()
        try check(albumLibrary.latestAlbums.map(\.id) == fixture.albums.reversed().map(\.id),
                  "latest albums must follow publication date even when an older album was edited more recently")
        try check(albumLibrary.albums.map(\.id) == fixture.albums.map(\.id), "latest recommendation must preserve the existing catalog sort order")
        try check(albumLibrary.tracks(in: albumLibrary.latestAlbums[0]).map(\.id) == orderedTrackIDs,
                  "album playback must follow its explicit track order regardless of global track sorting")
        print("PASS: latest recommendation uses publication dates and album queues preserve explicit track order")
        try check(albumLibrary.albumForDisplay()?.id == fixture.albums[2].id, "first use must display the latest playable album")
        try check(albumLibrary.albumForDisplay(preferredID: fixture.albums[0].id)?.id == fixture.albums[0].id,
                  "the current album must take priority over the newest release")
        try check(albumLibrary.albumForDisplay(selectedID: fixture.albums[1].id, preferredID: fixture.albums[0].id)?.id == fixture.albums[1].id,
                  "refresh must be able to browse another album without changing playback")
        try check(albumLibrary.albumForDisplay(preferredID: "withdrawn-album")?.id == fixture.albums[2].id,
                  "a withdrawn previous album must fall back to the latest playable album")
        albumLibrary.recordPlayback(of: fixture.tracks[0])
        let albumRestored = ContentLibrary(defaults: defaults, directoryOverride: root.appending(path: "album-order"), sessionOverride: session)
        try check(albumRestored.lastPlayedAlbumID == fixture.tracks[0].albumID,
                  "the last played album must survive relaunch using local preferences")
        print("PASS: current album, refresh, withdrawn fallback and local playback preference select the right album")

        let readID = fixture.articles[0].id
        let favoriteID = fixture.articles[1].id
        let withdrawnID = fixture.articles[3].id
        library.markRead(readID)
        library.markRead(withdrawnID)
        library.toggleFavorite(favoriteID)
        library.toggleFavorite(withdrawnID)
        let restored = makeLibrary()
        try check(Set(restored.articles.map(\.id)) == Set([readID, favoriteID, withdrawnID]),
                  "relaunch must retain only read and explicitly saved article bodies")
        try check(restored.isRead(readID) && restored.isFavorite(favoriteID), "read and favorite states must survive disk restoration")
        try check(restored.statusMessage.contains("尚未检查"), "restoring a cache must not claim a live check")
        print("PASS: real disk cache restores read and favorite articles without caching unread bodies")

        let checkedAt = restored.lastCheckedAt
        transport.enqueue(.fail(.notConnectedToInternet))
        await restored.refresh()
        try check(restored.articles.count == 3 && restored.lastCheckedAt == checkedAt,
                  "offline failure must preserve readable articles and the historical check time")
        try check(restored.statusMessage.contains("缓存") && restored.statusMessage.contains("尚未确认"),
                  "offline failure must explain that revisions and withdrawals are unconfirmed")
        print("PASS: offline failure preserves real cache and does not invent a successful check")

        var articles = object["articles"] as! [[String: Any]]
        let revisedBody = fixture.articles[0].body + "\n\n【测试修订二】这是联网刷新后替换的新正文。"
        articles[0]["body"] = revisedBody
        articles[0]["revision"] = 2
        articles[0]["updatedAt"] = "2026-11-22T03:05:00Z"
        object["articles"] = articles
        object["revision"] = 2
        object["generatedAt"] = "2026-11-22T03:05:00Z"
        transport.enqueue(.snapshot(try JSONSerialization.data(withJSONObject: object)))
        await restored.refresh()
        try check(restored.article(id: readID)?.body == revisedBody && restored.isRead(readID) && restored.isFavorite(favoriteID),
                  "revision must replace the body while preserving stable reading and favorite IDs")
        try check(makeLibrary().article(id: readID)?.body == revisedBody, "revised body must replace the on-disk offline copy")
        print("PASS: revision replaces actual client and offline bodies without losing reading preferences")

        var conflict = object
        conflict["revision"] = 3
        conflict["tombstones"] = [["id": withdrawnID, "kind": "articles", "revision": 3, "withdrawnAt": "2026-11-22T03:10:00Z"]]
        transport.enqueue(.snapshot(try JSONSerialization.data(withJSONObject: conflict)))
        await restored.refresh()
        try check(restored.snapshot?.revision == 2 && restored.article(id: withdrawnID) != nil && restored.isFavorite(withdrawnID),
                  "conflicting backend withdrawal must fail atomically and preserve the last valid cache")
        try check(makeLibrary().snapshot?.revision == 2, "conflicting withdrawal must not overwrite the valid disk cache")
        print("PASS: conflicting backend tombstones cannot replace the last valid live or disk cache")

        articles.removeAll { $0["id"] as? String == withdrawnID }
        object["articles"] = articles
        object["revision"] = 3
        object["generatedAt"] = "2026-11-22T03:10:00Z"
        object["tombstones"] = [["id": withdrawnID, "kind": "articles", "revision": 3, "withdrawnAt": "2026-11-22T03:10:00Z"]]
        transport.enqueue(.snapshot(try JSONSerialization.data(withJSONObject: object)))
        await restored.refresh()
        try check(restored.article(id: withdrawnID) == nil && !restored.isFavorite(withdrawnID) && !restored.isRead(withdrawnID),
                  "successful withdrawal must remove article and reading/favorite references")
        try check(makeLibrary().article(id: withdrawnID) == nil, "withdrawn body must not return after reopening the disk cache")
        print("PASS: withdrawal removes a read favorite from live and restored client caches")

        transport.enqueue(.snapshot(originalData))
        await restored.refresh()
        try check(restored.snapshot?.revision == 3 && restored.article(id: withdrawnID) == nil,
                  "an older response must not revive withdrawn content")
        print("PASS: stale server revision cannot revive a withdrawn article")

        transport.enqueue(.snapshot(Data("{invalid".utf8)))
        await restored.refresh()
        try check(restored.snapshot?.revision == 3 && restored.article(id: readID)?.body == revisedBody,
                  "invalid response must preserve the last usable client state")
        print("PASS: malformed response preserves the last usable article revision")

        try restored.setServiceAddress("https://other.example.invalid")
        try check(restored.articles.isEmpty && restored.lastCheckedAt == nil && restored.favoriteIDs.isEmpty && restored.readIDs.isEmpty,
                  "switching services must clear content and local reading identities")
        try check(makeLibrary().articles.isEmpty && !FileManager.default.fileExists(atPath: root.appending(path: "library.json").path),
                  "service switch must remove the previous service's on-disk article cache")
        print("PASS: switching service clears the previous content and persistent reading cache")

        var richObject = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]
        var richArticles = richObject["articles"] as! [[String: Any]]
        let richHTML = "<h2>测试标题</h2><p>离线也能保留<strong>文字格式</strong>。</p><img src=\"https://example.org/sky.png\" alt=\"晴空插图\" width=\"800\" height=\"600\"/><ul><li>测试列表</li></ul>"
        richArticles[0]["bodyHTML"] = richHTML
        richObject["articles"] = richArticles
        defaults.set("https://example.invalid", forKey: "QingkongContentURL")
        let richRoot = root.appending(path: "rich-text")
        let richLibrary = ContentLibrary(defaults: defaults, directoryOverride: richRoot, sessionOverride: session)
        transport.enqueue(.snapshot(try JSONSerialization.data(withJSONObject: richObject)))
        await richLibrary.refresh()
        richLibrary.markRead(readID)
        let richRestored = ContentLibrary(defaults: defaults, directoryOverride: richRoot, sessionOverride: session)
        try check(richRestored.article(id: readID)?.bodyHTML == richHTML &&
                  richRestored.article(id: readID)?.body == fixture.articles[0].body &&
                  PublicArticleRichText.parse(richRestored.article(id: readID)?.bodyHTML)?.blocks.contains(where: { $0.image?.alt == "晴空插图" }) == true,
                  "read article cache must retain rich formatting, image metadata and the original plain fallback")
        print("PASS: real offline article cache preserves rich formatting, image metadata and plain-text fallback")

        try check(!transport.capturedRequests.isEmpty && transport.capturedRequests.allSatisfy {
            $0.httpMethod == "GET" && $0.httpBody == nil && $0.url?.query == nil && $0.value(forHTTPHeaderField: "Authorization") == nil
        }, "fixture requests must carry no account, health, diary or other personal payload")
        print("PASS: all captured public-content requests are bodyless anonymous GETs")
        print("15 native content checks passed; intercepted responses only, no network, simulator, or device used.")
    }
}
