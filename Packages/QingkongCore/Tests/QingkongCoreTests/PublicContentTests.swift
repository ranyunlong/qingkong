import Foundation
import Testing
@testable import QingkongCore

struct PublicContentTests {
    @Test func articleRichTextIsOptionalAndPreservesPlainBodyAndOfflineCopies() throws {
        let legacy = try decode(fixture).validated()
        #expect(legacy.articles[0].bodyHTML == nil)
        #expect(PublicArticleRichText.parse(legacy.articles[0].bodyHTML) == nil)
        let html = "<h2>认识变化</h2><p>已核实的<strong>正文</strong>。</p>"
        var object = try #require(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        var articles = try #require(object["articles"] as? [[String: Any]])
        articles[0]["bodyHTML"] = html
        object["articles"] = articles
        let rich = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object)).validated()
        let cached = rich.retainingArticles(ids: ["article-a"])
        let restored = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: PublicContentSnapshot.encoder().encode(cached))
        #expect(restored == rich)
        #expect(restored.articles[0].bodyHTML == html)
        #expect(restored.articles[0].body == legacy.articles[0].body)
        #expect(restored.articles[0].body.localizedStandardContains("正文"))

        articles[0]["bodyHTML"] = NSNull()
        object["articles"] = articles
        let explicitNull = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(explicitNull.articles[0].bodyHTML == nil)
    }

    @Test func nativeRichTextPreservesHeadingsStylesListsQuotesAndEntities() throws {
        let parsed = try #require(PublicArticleRichText.parse("""
        <h2>标题 &amp; &#x1F324;</h2><p>普通<strong><em><u><s>重点</s></u></em></strong><br>下一行&nbsp;&lt;安全&gt;</p><h3>次标题</h3><ol><li>第一条<ul><li>嵌套</li></ul></li><li>第二条</li></ol><blockquote><p>引用</p></blockquote>
        """))
        #expect(parsed.blocks.map(\.headingLevel) == [2, nil, 3, nil, nil, nil, nil])
        #expect(parsed.blocks[0].runs.map(\.text).joined() == "标题 & 🌤")
        let emphasis = try #require(parsed.blocks[1].runs.first { $0.text == "重点" })
        #expect(emphasis.bold && emphasis.italic && emphasis.underlined && emphasis.struckThrough)
        #expect(parsed.blocks[1].runs.map(\.text).joined() == "普通重点\n下一行\u{00a0}<安全>")
        #expect(parsed.blocks[3].marker == "1.")
        #expect(parsed.blocks[4].marker == "•")
        #expect(parsed.blocks[4].listDepth == 2)
        #expect(parsed.blocks[5].marker == "2.")
        #expect(parsed.blocks[6].quoted)
    }

    @Test func nativeRichTextOnlyCreatesCredentialFreeHTTPSLinks() throws {
        let parsed = try #require(PublicArticleRichText.parse("""
        <p><a href="https://example.org/read?a=1&amp;b=2">来源</a><a href="javascript:alert(1)">脚本</a><a href="http://example.org">不安全</a><a href="https://user:secret@example.org">凭据</a><a href="file:///tmp/private">文件</a><a href="data:text/html,test">数据</a></p>
        """))
        let runs = parsed.blocks.flatMap(\.runs)
        #expect(runs.first?.link?.absoluteString == "https://example.org/read?a=1&b=2")
        #expect(runs.dropFirst().allSatisfy { $0.link == nil })
        #expect(runs.map(\.text).joined() == "来源脚本不安全凭据文件数据")
    }

    @Test func nativeRichTextPreservesImagesInProseOrder() throws {
        let parsed = try #require(PublicArticleRichText.parse("""
        <p>图片前<strong>重点<img src="https://example.org/body.jpg?a=1&amp;b=2" alt="呼吸示意图" width="1200" height="800"/>图片后</strong></p><img src="https://example.org/second.png" alt=""/><p>末段</p>
        """))
        #expect(parsed.blocks.count == 5)
        #expect(parsed.blocks.map { $0.runs.map(\.text).joined() } == ["图片前重点", "", "图片后", "", "末段"])
        #expect(parsed.blocks[2].runs.first?.bold == true)
        let image = try #require(parsed.blocks[1].image)
        #expect(image.url.absoluteString == "https://example.org/body.jpg?a=1&b=2")
        #expect(image.alt == "呼吸示意图")
        #expect(image.width == 1200 && image.height == 800)
        #expect(parsed.blocks[0].image == nil)
        #expect(parsed.blocks[3].image?.alt == "正文图片")
        #expect(parsed.blocks[3].image?.width == nil && parsed.blocks[3].image?.height == nil)
    }

    @Test func imageOnlyBodyIsReadableAndImageLimitIsEnforced() throws {
        let image = "<img src='https://example.org/body.png' alt='正文图片'/>"
        #expect(PublicArticleRichText.parse(image) != nil)
        #expect(PublicArticleRichText.parse(String(repeating: image, count: 30))?.blocks.count == 30)
        #expect(PublicArticleRichText.parse(String(repeating: image, count: 31)) == nil)
    }

    @Test func invalidImageMarkupFallsBackToEntirePlainBody() {
        for image in [
            "<img src='http://example.org/a.png' alt='图'/>",
            "<img src='https://user:secret@example.org/a.png' alt='图'/>",
            "<img src='data:image/png;base64,abc' alt='图'/>",
            "<img src='javascript:alert(1)' alt='图'/>",
            "<img src='//example.org/a.png' alt='图'/>",
            "<img src='https://example.org/a.png' alt='图' onerror='alert(1)'/>",
            "<img src='https://example.org/a.svg' alt='图' style='width:100%'/>",
            "<img src='https://example.org/a.png' alt='图' width='0'/>",
            "<img src='https://example.org/a.png' alt='图' width='01'/>",
            "<img src='https://example.org/a.png' alt='图' height='-10'/>",
            "<img src='https://example.org/a.png' alt='图' width='1.5'/>",
            "<img src='https://example.org/a.png' alt='图' width='999999999999999999999'/>",
            "<img src='https://example.org/a.png'/>",
            "<img alt='图'/>",
            "<img src='https://example.org/a.svg' alt='图'/>",
            "<img src='https://example.org/a.png' alt='图'>嵌套内容</img>",
            "<img src='https://example.org/a.png' alt='图'><strong>嵌套</strong></img>",
            "<svg><image href='https://example.org/a.png'/></svg>"
        ] {
            #expect(PublicArticleRichText.parse("<p>保留纯文本</p>" + image) == nil)
        }
    }

    @Test func proseResourcesRejectAmbiguousOrEncodedUnsafeURLs() {
        for address in [
            "https://example.org/a b.png", "https://example.org/a\\b.png", "https://example.org/%0aheader",
            "https://example.org/%0Dheader", "https://example.org/%7f.png", "https://example.org/%5c.png",
            "https://example.org/bad%url", "https://user@example.org/a.png", "https:///a.png", "https://"
        ] {
            #expect(PublicContentURL.articleResourceURL(from: address) == nil)
            #expect(PublicArticleRichText.parse("<p>之前</p><img src='\(address)' alt='图'/><p>之后</p>") == nil)
        }
        #expect(PublicContentURL.articleResourceURL(from: "https://example.org/a%20b.png") != nil)
    }

    @Test func imageDimensionsAndAltRespectPublicationBounds() throws {
        let boundary = try #require(PublicArticleRichText.parse("<img src='https://example.org/a.png' alt='\(String(repeating: "图", count: 300))' width='10000' height='1'/>"))
        #expect(boundary.blocks[0].image?.width == 10_000)
        #expect(boundary.blocks[0].image?.alt.count == 300)
        for attributes in [
            "alt='图' width='10001'", "alt='图' height='10001'",
            "alt='\(String(repeating: "图", count: 301))'", "alt='前&#10;后'", "alt='前&#9;后'", "alt='前&#127;后'"
        ] {
            #expect(PublicArticleRichText.parse("<img src='https://example.org/a.png' \(attributes)/>") == nil)
        }
    }

    @Test func unsupportedOrMalformedMarkupFallsBackToPlainBody() {
        for html in [
            "", "  ", "<p></p>", "<p>未闭合", "<p>错位</h2>", "<li>无列表</li>",
            "<script>alert(1)</script>", "<img src='https://example.org/tracker'>",
            "<iframe src='https://example.org'></iframe>", "<style>p{background:url(https://example.org)}</style>",
            "<p style='color:red'>样式</p>", "<p onclick='alert(1)'>事件</p>",
            "<a href='https://example.org' ping='https://example.org/tracker'>链接</a>",
            "<!DOCTYPE article-body SYSTEM 'https://example.org/data'><p>正文</p>",
            "<!DOCTYPE article-body [<!ENTITY secret SYSTEM 'file:///tmp/private'>]><p>&secret;</p>",
            "<?xml-stylesheet href='https://example.org/style'?><p>正文</p>",
            String(repeating: "a", count: 120_001),
            String(repeating: "<strong>", count: 49) + "正文" + String(repeating: "</strong>", count: 49)
        ] {
            #expect(PublicArticleRichText.parse(html) == nil)
        }
    }

    @Test func testArticlePublicationMarkerIsBackwardCompatibleAndPersists() throws {
        let ordinary = try decode(fixture)
        let ordinaryJSON = try JSONSerialization.jsonObject(with: PublicContentSnapshot.encoder().encode(ordinary)) as! [String: Any]
        #expect((ordinaryJSON["articles"] as! [[String: Any]])[0]["testOnly"] == nil)
        let test = try decode(fixture.replacingOccurrences(of: "\"category\":", with: "\"testOnly\":true,\"category\":"))
        let restored = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: PublicContentSnapshot.encoder().encode(test))
        let restoredJSON = try JSONSerialization.jsonObject(with: PublicContentSnapshot.encoder().encode(restored)) as! [String: Any]
        #expect((restoredJSON["articles"] as! [[String: Any]])[0]["testOnly"] as? Bool == true)
    }
    private var fixture: String {
        """
        {"schemaVersion":1,"revision":2,"generatedAt":"2026-11-21T01:00:00Z","articles":[{"id":"article-a","title":"认识变化","summary":"经过审核的说明","body":"已核实的正文。","category":"健康数据","coverURL":null,"references":[{"title":"参考资料","url":"https://example.org/reference"}],"review":{"reviewer":"审核人","credentials":"专业资质","reviewedAt":"2026-11-20T01:00:00Z"},"updatedAt":"2026-11-21T01:00:00Z","publishedAt":"2026-11-20T01:00:00Z","revision":2,"sortOrder":0}],"albums":[{"id":"album-a","title":"自然声音","summary":"专辑介绍","coverURL":null,"trackIDs":["track-a"],"updatedAt":"2026-11-21T01:00:00Z","publishedAt":"2026-11-20T01:00:00Z","revision":1,"sortOrder":0}],"tracks":[{"id":"track-a","albumID":"album-a","title":"雨声","audioURL":"https://example.org/rain.mp3","coverURL":null,"durationSeconds":120,"fileVersion":"v1","byteSize":1234,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","copyright":{"owner":"版权方","source":"自制","license":"已授权","expiresAt":null},"updatedAt":"2026-11-21T01:00:00Z","publishedAt":"2026-11-20T01:00:00Z","revision":1,"sortOrder":0}],"tombstones":[]}
        """
    }

    private func decode(_ text: String) throws -> PublicContentSnapshot {
        try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: Data(text.utf8))
    }

    @Test func validPublishedSnapshotDecodesAndRoundTrips() throws {
        let snapshot = try decode(fixture).validated()
        #expect(snapshot.articles.first?.review.reviewer == "审核人")
        #expect(snapshot.tracks.first?.byteSize == 1234)
        let roundTrip = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: PublicContentSnapshot.encoder().encode(snapshot))
        #expect(roundTrip == snapshot)
    }

    @Test func sourceAddressRequiresPermanentHTTPSWithoutCredentials() throws {
        #expect(try PublicContentURL.snapshotURL(from: " https://content.example.org/ ").absoluteString == "https://content.example.org/api/v1/snapshot")
        #expect(try PublicContentURL.snapshotURL(from: "https://content.example.org/api/v1/snapshot").path == "/api/v1/snapshot")
        for invalid in ["http://example.org", "https://user:secret@example.org", "https://example.org?token=abc", "file:///tmp/feed", "https://example.org#fragment", ""] {
            #expect(throws: PublicContentError.self) { try PublicContentURL.snapshotURL(from: invalid) }
        }
    }

    @Test func incompleteOrUnverifiableMediaIsRejected() throws {
        for invalid in [
            fixture.replacingOccurrences(of: "\"byteSize\":1234", with: "\"byteSize\":0"),
            fixture.replacingOccurrences(of: "\"durationSeconds\":120", with: "\"durationSeconds\":0"),
            fixture.replacingOccurrences(of: "https://example.org/rain.mp3", with: "http://example.org/rain.mp3"),
            fixture.replacingOccurrences(of: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", with: "bad-hash"),
            fixture.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"),
            fixture.replacingOccurrences(of: "\"albumID\":\"album-a\"", with: "\"albumID\":\"missing\"")
        ] {
            let snapshot = try decode(invalid)
            #expect(throws: PublicContentError.self) { try snapshot.validated() }
        }
    }

    @Test func fileVersionAndChecksumInvalidateOldCacheIdentity() throws {
        let original = try #require(decode(fixture).tracks.first)
        let updated = try #require(decode(fixture.replacingOccurrences(of: "\"fileVersion\":\"v1\"", with: "\"fileVersion\":\"v2\"")).tracks.first)
        #expect(original.id == updated.id)
        #expect(original.cacheIdentity != updated.cacheIdentity)
        let differentURL = try #require(decode(fixture.replacingOccurrences(of: "rain.mp3", with: "new-location.mp3")).tracks.first)
        #expect(original.cacheIdentity == differentURL.cacheIdentity)
    }

    @Test func expiredRightsAndConflictingTombstonesAreRejected() throws {
        let expired = try decode(fixture.replacingOccurrences(of: "\"expiresAt\":null", with: "\"expiresAt\":\"2026-01-01T00:00:00Z\""))
        let active = try expired.validated()
        #expect(active.tracks.isEmpty)
        #expect(active.albums.first?.trackIDs.isEmpty == true)
        #expect(active.articles.count == 1)
        let conflict = try decode(fixture.replacingOccurrences(of: "\"tombstones\":[]", with: "\"tombstones\":[{\"id\":\"article-a\",\"kind\":\"article\",\"revision\":2,\"withdrawnAt\":\"2026-11-21T01:00:00Z\"}]"))
        #expect(throws: PublicContentError.self) { try conflict.validated() }
    }

    @Test func readAndFavoriteArticleCacheKeepsOnlyExplicitLocalReading() throws {
        let snapshot = try decode(fixture)
        #expect(snapshot.retainingArticles(ids: []).articles.isEmpty)
        #expect(snapshot.retainingArticles(ids: ["article-a"]).articles.count == 1)
        #expect(snapshot.retainingArticles(ids: []).tracks == snapshot.tracks)
    }

    @Test(arguments: [("articles", "article-a"), ("albums", "album-a"), ("tracks", "track-a")])
    func backendTombstoneKindsRejectConflictingVisibleContent(kind: String, identity: String) throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        // These plural kinds are emitted by ContentService and documented in API.md.
        object["tombstones"] = [["id": identity, "kind": kind, "revision": 2, "withdrawnAt": "2026-11-21T01:00:00Z"]]
        let conflict = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(throws: PublicContentError.self) { try conflict.validated() }

        object["articles"] = []; object["albums"] = []; object["tracks"] = []
        let withdrawn = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: object)).validated()
        #expect(withdrawn.tombstones.first?.id == identity)
    }

    @Test func onlyCompleteUnmodifiedFilePassesOfflineValidation() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        try Data("abc".utf8).write(to: file)
        #expect(try AudioFileIntegrity.matches(fileURL: file, byteSize: 3, sha256: hash))
        #expect(try !AudioFileIntegrity.matches(fileURL: file, byteSize: 4, sha256: hash))
        #expect(try !AudioFileIntegrity.matches(fileURL: file, byteSize: 2, sha256: hash))
        try Data("abx".utf8).write(to: file)
        #expect(try !AudioFileIntegrity.matches(fileURL: file, byteSize: 3, sha256: hash))
        try Data("ab".utf8).write(to: file)
        #expect(try !AudioFileIntegrity.matches(fileURL: file, byteSize: 3, sha256: hash))
    }

    @Test func fullSnapshotReplacementRemovesWithdrawnArticle() throws {
        let existing = try decode(fixture)
        let object = try #require(JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [String: Any])
        var replacement = object
        replacement["articles"] = []
        let fresh = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: JSONSerialization.data(withJSONObject: replacement)).validated()
        #expect(existing.articles.count == 1)
        #expect(fresh.articles.isEmpty)
    }
}
