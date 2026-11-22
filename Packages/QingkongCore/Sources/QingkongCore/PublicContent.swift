import Foundation
import CryptoKit

public struct PublicContentSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: Int
    public let generatedAt: Date
    public let articles: [PublicArticle]
    public let albums: [PublicAlbum]
    public let tracks: [PublicAudioTrack]
    public let tombstones: [PublicContentTombstone]

    public func validated(at date: Date = .now) throws -> PublicContentSnapshot {
        guard schemaVersion == 1, revision >= 0,
              Set(articles.map(\.id)).count == articles.count,
              Set(albums.map(\.id)).count == albums.count,
              Set(tracks.map(\.id)).count == tracks.count else { throw PublicContentError.invalidSnapshot }
        let albumIDs = Set(albums.map(\.id))
        for article in articles {
            guard !article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !article.body.isEmpty, !article.review.reviewer.isEmpty,
                  !article.references.isEmpty,
                  article.references.allSatisfy({ PublicContentURL.isHTTPS($0.url) }) else { throw PublicContentError.invalidSnapshot }
        }
        let validTracks = tracks.filter { $0.copyright.expiresAt.map({ $0 > date }) ?? true }
        for track in validTracks {
            guard albumIDs.contains(track.albumID), PublicContentURL.isHTTPS(track.audioURL),
                  !track.fileVersion.isEmpty, track.byteSize > 0, track.durationSeconds.isFinite,
                  track.durationSeconds > 0, track.sha256.count == 64,
                  track.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw PublicContentError.invalidSnapshot }
        }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        guard albums.allSatisfy({ album in
            Set(album.trackIDs).count == album.trackIDs.count && album.trackIDs.allSatisfy { byID[$0]?.albumID == album.id }
        }) else { throw PublicContentError.invalidSnapshot }
        // The service uses plural kinds; retain compatibility with earlier singular caches.
        let legacyKinds = ["article": "articles", "album": "albums", "track": "tracks"]
        let withdrawn = Set(tombstones.map { "\(legacyKinds[$0.kind] ?? $0.kind):\($0.id)" })
        guard !articles.contains(where: { withdrawn.contains("articles:\($0.id)") }),
              !albums.contains(where: { withdrawn.contains("albums:\($0.id)") }),
              !tracks.contains(where: { withdrawn.contains("tracks:\($0.id)") }) else { throw PublicContentError.invalidSnapshot }
        let activeIDs = Set(validTracks.map(\.id))
        let validAlbums = albums.map { album in
            PublicAlbum(id: album.id, title: album.title, summary: album.summary, coverURL: album.coverURL,
                        trackIDs: album.trackIDs.filter { activeIDs.contains($0) }, updatedAt: album.updatedAt,
                        publishedAt: album.publishedAt, revision: album.revision, sortOrder: album.sortOrder)
        }
        return PublicContentSnapshot(schemaVersion: schemaVersion, revision: revision, generatedAt: generatedAt,
                                     articles: articles, albums: validAlbums, tracks: validTracks, tombstones: tombstones)
    }

    public func retainingArticles(ids: Set<String>) -> PublicContentSnapshot {
        PublicContentSnapshot(schemaVersion: schemaVersion, revision: revision, generatedAt: generatedAt,
                              articles: articles.filter { ids.contains($0.id) }, albums: albums, tracks: tracks, tombstones: tombstones)
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public struct PublicArticle: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let testOnly: Bool?
    public let title: String
    public let summary: String
    public let body: String
    public let bodyHTML: String?
    public let category: String
    public let coverURL: URL?
    public let references: [PublicContentReference]
    public let review: PublicContentReview
    public let updatedAt: Date
    public let publishedAt: Date
    public let revision: Int
    public let sortOrder: Int
}

public struct PublicContentReference: Codable, Equatable, Sendable {
    public let title: String
    public let url: URL
}

public struct PublicContentReview: Codable, Equatable, Sendable {
    public let reviewer: String
    public let credentials: String
    public let reviewedAt: Date
}

public struct PublicAlbum: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let coverURL: URL?
    public let trackIDs: [String]
    public let updatedAt: Date
    public let publishedAt: Date
    public let revision: Int
    public let sortOrder: Int
}

public struct PublicAudioTrack: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let albumID: String
    public let title: String
    public let audioURL: URL
    public let coverURL: URL?
    public let durationSeconds: Double
    public let fileVersion: String
    public let byteSize: Int64
    public let sha256: String
    public let copyright: PublicAudioCopyright
    public let updatedAt: Date
    public let publishedAt: Date
    public let revision: Int
    public let sortOrder: Int

    /// URL alone never identifies a complete offline file.
    public var cacheIdentity: String { "\(id)|\(fileVersion)|\(sha256)|\(byteSize)" }
}

public struct PublicAudioCopyright: Codable, Equatable, Sendable {
    public let owner: String
    public let source: String
    public let license: String
    public let expiresAt: Date?
}

public struct PublicContentTombstone: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let revision: Int
    public let withdrawnAt: Date
}

public enum PublicContentError: Error, LocalizedError {
    case invalidSnapshot
    case invalidServiceURL
    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "内容服务返回的数据不完整或版本不受支持，保留原有离线内容。"
        case .invalidServiceURL: "请输入不含账号、密码或临时签名的长期 HTTPS 服务地址。"
        }
    }
}

public enum PublicContentURL {
    public static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    /// Published prose and images share this strict, credential-free URL grammar.
    public static func articleResourceURL(from address: String) -> URL? {
        guard !address.isEmpty,
              address.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 && $0.value != 92 }),
              address.range(of: #"%(?![0-9a-fA-F]{2})"#, options: .regularExpression) == nil,
              let decoded = address.removingPercentEncoding,
              decoded.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && $0.value != 92 }),
              let url = URL(string: address), isHTTPS(url) else { return nil }
        return url
    }

    public static func snapshotURL(from address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isHTTPS(url), url.query == nil, url.fragment == nil else {
            throw PublicContentError.invalidServiceURL
        }
        if url.path.hasSuffix("/api/v1/snapshot") || url.path.hasSuffix("/api/public/snapshot") { return url }
        return url.appending(path: "api/v1/snapshot")
    }
}

/// Streaming validation prevents a partial file or error body from becoming offline audio.
public enum AudioFileIntegrity {
    public static func matches(fileURL: URL, byteSize: Int64, sha256: String) throws -> Bool {
        guard byteSize > 0 else { return false }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            total += Int64(chunk.count)
            guard total <= byteSize else { return false }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return total == byteSize && digest == sha256
    }
}

/// A deliberately small, local-only rich-text grammar. No HTML importer, web view,
/// document type, attachment or resource-loading API receives published markup.
public struct PublicArticleRichText: Equatable, Sendable {
    public struct Image: Equatable, Sendable {
        public let url: URL
        public let alt: String
        public let width: Int?
        public let height: Int?
    }

    public struct Run: Equatable, Sendable {
        public let text: String
        public let bold: Bool
        public let italic: Bool
        public let underlined: Bool
        public let struckThrough: Bool
        public let link: URL?
    }

    public struct Block: Equatable, Sendable {
        public let headingLevel: Int?
        public let listDepth: Int
        public let marker: String?
        public let quoted: Bool
        public let runs: [Run]
        public let image: Image?
    }

    public let blocks: [Block]

    /// Unsupported, malformed, empty or oversized markup uses the article's plain body.
    public static func parse(_ html: String?) -> PublicArticleRichText? {
        guard let html, !html.isEmpty, html.count <= 120_000,
              !html.contains("<!"), !html.contains("<?") else { return nil }
        // The editor emits HTML void breaks and nonbreaking spaces; normalize only
        // these known HTML forms to XML before applying the strict allowlist.
        let normalized = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "<br/>", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "&nbsp;", with: "&#160;")
        let delegate = ArticleMarkupParser()
        let parser = XMLParser(data: Data(("<article-body>" + normalized + "</article-body>").utf8))
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.rejected else { return nil }
        delegate.finishBlock()
        guard delegate.blocks.contains(where: { block in
            block.image != nil || block.runs.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }) else { return nil }
        return PublicArticleRichText(blocks: delegate.blocks)
    }
}

private final class ArticleMarkupParser: NSObject, XMLParserDelegate {
    private struct Element {
        let name: String
        var link: URL? = nil
        var marker: String? = nil
        var itemCount = 0
    }

    private let allowed: Set<String> = ["p", "br", "h2", "h3", "strong", "b", "em", "i", "u", "s", "ul", "ol", "li", "blockquote", "a", "img"]
    private let boundaries: Set<String> = ["p", "h2", "h3", "li", "blockquote", "ul", "ol"]
    private var elements: [Element] = []
    private var runs: [PublicArticleRichText.Run] = []
    private var headingLevel: Int?
    private var listDepth = 0
    private var marker: String?
    private var quoted = false
    private var imageCount = 0
    fileprivate var blocks: [PublicArticleRichText.Block] = []
    fileprivate var rejected = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elements.isEmpty, elementName == "article-body", attributeDict.isEmpty {
            elements.append(Element(name: elementName))
            return
        }
        let name = elementName.lowercased()
        guard elements.count < 48, allowed.contains(name),
              elements.last?.name != "img",
              attributeDict.isEmpty || (name == "a" && Set(attributeDict.keys) == ["href"]) ||
                (name == "img" && Set(attributeDict.keys).isSubset(of: ["src", "alt", "width", "height"])) else {
            reject(parser)
            return
        }
        if boundaries.contains(name) { finishBlock() }
        var element = Element(name: name)
        if name == "img" {
            guard imageCount < 30, let source = attributeDict["src"],
                  let url = PublicContentURL.articleResourceURL(from: source),
                  !["svg", "svgz"].contains(url.pathExtension.lowercased()),
                  let alt = attributeDict["alt"], alt.unicodeScalars.count <= 300,
                  !alt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  ["width", "height"].allSatisfy({ attributeDict[$0].map { positiveDimension($0) != nil } ?? true }) else {
                reject(parser)
                return
            }
            finishBlock()
            imageCount += 1
            let image = PublicArticleRichText.Image(url: url, alt: alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "正文图片" : alt,
                width: attributeDict["width"].flatMap(positiveDimension), height: attributeDict["height"].flatMap(positiveDimension))
            blocks.append(PublicArticleRichText.Block(headingLevel: nil, listDepth: 0, marker: nil, quoted: false, runs: [], image: image))
        }
        if name == "a", let address = attributeDict["href"] {
            // Unsafe addresses lose their link behavior but retain readable text.
            element.link = PublicContentURL.articleResourceURL(from: address)
        }
        if name == "li" {
            guard let index = elements.lastIndex(where: { $0.name == "ul" || $0.name == "ol" }) else {
                reject(parser)
                return
            }
            elements[index].itemCount += 1
            element.marker = elements[index].name == "ol" ? "\(elements[index].itemCount)." : "•"
        }
        elements.append(element)
        if name == "br" { append("\n") }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !rejected else { return }
        if boundaries.contains(elementName.lowercased()) || elementName == "article-body" { finishBlock() }
        if !elements.isEmpty { elements.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard elements.last?.name != "img" else {
            reject(parser)
            return
        }
        // Ignore indentation between blocks, while preserving spaces inside prose.
        if runs.isEmpty, string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !elements.contains(where: { ["p", "li", "h2", "h3", "blockquote"].contains($0.name) }) { return }
        append(string)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        reject(parser)
        return nil
    }

    private func reject(_ parser: XMLParser) {
        rejected = true
        parser.abortParsing()
    }

    private func positiveDimension(_ value: String) -> Int? {
        guard value.first != "0", !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(value), (1...10_000).contains(number) else { return nil }
        return number
    }

    private func append(_ text: String) {
        guard !rejected, !text.isEmpty else { return }
        if runs.isEmpty {
            headingLevel = elements.contains(where: { $0.name == "h2" }) ? 2 : (elements.contains(where: { $0.name == "h3" }) ? 3 : nil)
            listDepth = elements.filter { $0.name == "ul" || $0.name == "ol" }.count
            quoted = elements.contains { $0.name == "blockquote" }
            marker = nil
            if let item = elements.lastIndex(where: { $0.name == "li" }) {
                marker = elements[item].marker
                elements[item].marker = nil
            }
        }
        let names = Set(elements.map(\.name))
        runs.append(PublicArticleRichText.Run(text: text,
            bold: !names.isDisjoint(with: ["strong", "b"]), italic: !names.isDisjoint(with: ["em", "i"]),
            underlined: names.contains("u"), struckThrough: names.contains("s"),
            link: elements.last(where: { $0.name == "a" })?.link))
    }

    fileprivate func finishBlock() {
        guard !runs.isEmpty else { return }
        blocks.append(PublicArticleRichText.Block(headingLevel: headingLevel, listDepth: listDepth, marker: marker, quoted: quoted, runs: runs, image: nil))
        runs = []
    }
}
