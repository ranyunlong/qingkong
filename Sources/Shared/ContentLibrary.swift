import Foundation
import Observation
import QingkongCore

@MainActor @Observable
final class ContentLibrary {
    static let defaultServiceAddress = "https://xqk.geckoai.cn"
    private(set) var snapshot: PublicContentSnapshot?
    private(set) var isRefreshing = false
    private(set) var lastCheckedAt: Date?
    private(set) var statusMessage = "尚未联网检查内容。"
    private(set) var serviceAddress: String
    private(set) var favoriteIDs: Set<String> = []
    private(set) var readIDs: Set<String> = []
    private(set) var lastPlayedAlbumID: String?
    var didRefresh: ((PublicContentSnapshot) -> Void)?
    var didChangeService: (() -> Void)?
    let coverImages: PublicCoverCache
    let articleImages: ArticleImageCache
    @ObservationIgnored private let testing: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var requestGeneration = UUID()

    private struct Cache: Codable {
        var address: String
        var snapshot: PublicContentSnapshot
        var checkedAt: Date
        var favoriteIDs: Set<String>
        var readIDs: Set<String>
    }

    var articles: [PublicArticle] { (snapshot?.articles ?? []).sorted { ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title) } }
    var albums: [PublicAlbum] { (snapshot?.albums ?? []).sorted { ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title) } }
    var latestAlbums: [PublicAlbum] {
        albums.sorted {
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.sortOrder, $0.title, $0.id) < ($1.sortOrder, $1.title, $1.id)
        }
    }
    var tracks: [PublicAudioTrack] { (snapshot?.tracks ?? []).sorted { ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title) } }
    var playableAlbums: [PublicAlbum] { latestAlbums.filter { !tracks(in: $0).isEmpty } }
    var isConfigured: Bool { !serviceAddress.isEmpty }

    func tracks(in album: PublicAlbum) -> [PublicAudioTrack] {
        album.trackIDs.compactMap { id in tracks.first { $0.id == id && $0.albumID == album.id } }
    }

    func albumForDisplay(selectedID: String? = nil, preferredID: String? = nil) -> PublicAlbum? {
        let albums = playableAlbums
        return albums.first { $0.id == selectedID } ?? albums.first { $0.id == preferredID } ?? albums.first
    }

    func recordPlayback(of track: PublicAudioTrack) {
        guard tracks.contains(where: { $0.cacheIdentity == track.cacheIdentity && $0.albumID == track.albumID }),
              track.copyright.expiresAt.map({ $0 > .now }) ?? true,
              lastPlayedAlbumID != track.albumID else { return }
        lastPlayedAlbumID = track.albumID
        defaults.set(track.albumID, forKey: "QingkongLastPlayedAlbum")
    }

    init(testing: Bool = false, reset: Bool = false, defaults defaultsOverride: UserDefaults? = nil,
         directoryOverride: URL? = nil, sessionOverride: URLSession? = nil) {
        self.testing = testing
        session = sessionOverride ?? .shared
        let defaults = defaultsOverride ?? (testing ? UserDefaults(suiteName: "QingkongPublicContentUITesting")! : .standard)
        self.defaults = defaults
        let directory = directoryOverride ?? (testing ? URL.temporaryDirectory : URL.applicationSupportDirectory).appending(path: testing ? "QingkongPublicContentUITesting" : "PublicContent", directoryHint: .isDirectory)
        coverImages = PublicCoverCache(directory: directory.appending(path: "Covers", directoryHint: .isDirectory),
                                       configuration: sessionOverride?.configuration, networkEnabled: !testing)
        articleImages = ArticleImageCache(directory: directory.appending(path: "ArticleImages", directoryHint: .isDirectory),
                                          configuration: sessionOverride?.configuration, networkEnabled: !testing)
        if testing && reset {
            defaults.removePersistentDomain(forName: "QingkongPublicContentUITesting")
            if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
        }
        lastPlayedAlbumID = defaults.string(forKey: "QingkongLastPlayedAlbum")
        cacheURL = directory.appending(path: "library.json")
        // Production always uses the app's public service; isolated checks may supply their own address.
        serviceAddress = defaultsOverride?.string(forKey: "QingkongContentURL") ?? Self.defaultServiceAddress
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cache = try PublicContentSnapshot.decoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
                if cache.address == serviceAddress {
                    // Last successful fetch is historical evidence, never a claim of a current connection.
                    snapshot = try cache.snapshot.validated(at: cache.checkedAt)
                    lastCheckedAt = cache.checkedAt
                    favoriteIDs = cache.favoriteIDs; readIDs = cache.readIDs
                    statusMessage = "正在显示已读或收藏的离线文章，尚未检查最新修订。"
                }
            }
        } catch { statusMessage = "本地内容缓存未能读取，可联网刷新。" }
        if !isConfigured { statusMessage = "尚未配置公共内容服务。内置声音与本地记录仍可使用。" }
        reconcileArticleImages()
    }

    func setServiceAddress(_ address: String) throws {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { _ = try PublicContentURL.snapshotURL(from: value) }
        guard value != serviceAddress else { return }
        requestGeneration = UUID()
        serviceAddress = value; defaults.set(value, forKey: "QingkongContentURL")
        snapshot = nil; lastCheckedAt = nil; favoriteIDs = []; readIDs = []
        reconcileArticleImages()
        lastPlayedAlbumID = nil; defaults.removeObject(forKey: "QingkongLastPlayedAlbum")
        didChangeService?()
        if FileManager.default.fileExists(atPath: cacheURL.path) { try FileManager.default.removeItem(at: cacheURL) }
        statusMessage = value.isEmpty ? "尚未配置公共内容服务。" : "服务地址已保存，尚未联网检查。"
    }

    func refresh() async {
        guard !testing else { statusMessage = "界面测试不访问公共内容服务。"; return }
        guard !isRefreshing else { return }
        guard isConfigured else { statusMessage = "公共内容服务暂不可用，请稍后重试。"; return }
        isRefreshing = true
        let generation = requestGeneration
        defer { isRefreshing = false }
        do {
            let url = try PublicContentURL.snapshotURL(from: serviceAddress)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard generation == requestGeneration else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.url.map(PublicContentURL.isHTTPS) == true else { throw URLError(.badServerResponse) }
            guard data.count <= 10_000_000 else { throw PublicContentError.invalidSnapshot }
            let next = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: data).validated()
            guard next.revision >= (snapshot?.revision ?? 0) else { throw PublicContentError.invalidSnapshot }
            snapshot = next; lastCheckedAt = .now
            favoriteIDs.formIntersection(next.articles.map(\.id)); readIDs.formIntersection(next.articles.map(\.id))
            statusMessage = next.articles.isEmpty && next.albums.isEmpty ? "已连接服务，当前没有已发布内容。" : "已获取最新发布内容。"
            didRefresh?(next)
            save()
        } catch {
            guard generation == requestGeneration else { return }
            statusMessage = "刷新失败：\(error.localizedDescription)\(snapshot == nil ? "" : " 正在显示缓存，尚未确认最新修订或撤回。")"
        }
    }

    func article(id: String) -> PublicArticle? { articles.first { $0.id == id } }
    func isFavorite(_ id: String) -> Bool { favoriteIDs.contains(id) }
    func isRead(_ id: String) -> Bool { readIDs.contains(id) }
    func toggleFavorite(_ id: String) {
        if !favoriteIDs.insert(id).inserted { favoriteIDs.remove(id) }
        save()
    }
    func markRead(_ id: String) {
        guard readIDs.insert(id).inserted else { return }
        save()
    }

    private func save() {
        guard let snapshot, let lastCheckedAt else { return }
        reconcileArticleImages()
        do {
            // Only read and explicitly saved article bodies are retained across launches.
            let cachedSnapshot = snapshot.retainingArticles(ids: readIDs.union(favoriteIDs))
            let cache = Cache(address: serviceAddress, snapshot: cachedSnapshot, checkedAt: lastCheckedAt, favoriteIDs: favoriteIDs, readIDs: readIDs)
            try PublicContentSnapshot.encoder().encode(cache).write(to: cacheURL, options: .atomic)
        } catch { statusMessage += " 本地缓存保存失败，退出后可能无法离线阅读。" }
    }

    private func reconcileArticleImages() {
        articleImages.reconcile(serviceAddress: serviceAddress, articles: articles, retainedIDs: readIDs.union(favoriteIDs))
    }
}
