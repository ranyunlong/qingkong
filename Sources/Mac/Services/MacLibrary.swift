import Foundation
import Observation
import QingkongCore

/// Music has its own revision and durable store. A phone music transfer never mutates articles.
@MainActor @Observable
final class MacLibrary {
    let content: ContentLibrary
    let downloads: AudioDownloads
    private(set) var musicCatalog: DesktopMusicCatalog?
    private(set) var statusMessage = "尚未联网检查内容。"
    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private weak var player: MacAudioPlayer?
    @ObservationIgnored private var versions: [String: Version] = [:]

    private struct Version: Codable {
        let revision: Int
    }
    private struct Cache: Codable {
        let catalog: DesktopMusicCatalog
        let versions: [String: Version]
    }

    var serviceAddress: String { musicCatalog?.serviceAddress ?? content.serviceAddress }
    var isRefreshing: Bool { content.isRefreshing || refreshingMusic }
    private var refreshingMusic = false
    var lastCheckedAt: Date? { musicCatalog?.checkedAt ?? content.lastCheckedAt }
    var albums: [PublicAlbum] {
        (musicCatalog?.albums ?? []).sorted { ($0.sortOrder, $0.title, $0.id) < ($1.sortOrder, $1.title, $1.id) }
    }
    var latestAlbums: [PublicAlbum] {
        albums.sorted {
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.sortOrder, $0.title, $0.id) < ($1.sortOrder, $1.title, $1.id)
        }
    }
    var tracks: [PublicAudioTrack] {
        (musicCatalog?.tracks ?? []).filter { $0.copyright.expiresAt.map { $0 > .now } ?? true }
            .sorted { ($0.sortOrder, $0.title, $0.id) < ($1.sortOrder, $1.title, $1.id) }
    }
    var playableAlbums: [PublicAlbum] { latestAlbums.filter { !tracks(in: $0).isEmpty } }
    var showsPortableAlbum: Bool {
        downloads.hasCheckedNetwork && !downloads.networkAvailable && downloads.hasFinishedRestoringDownloads &&
            !playableAlbums.contains { album in tracks(in: album).contains { downloads.localURL(for: $0) != nil } }
    }

    func albums(matching search: String, downloadedOnly: Bool) -> [PublicAlbum] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return playableAlbums.filter { album in
            let albumTracks = tracks(in: album)
            return (!downloadedOnly || albumTracks.contains { downloads.localURL(for: $0) != nil }) &&
                (query.isEmpty || album.title.localizedStandardContains(query) ||
                    albumTracks.contains { $0.title.localizedStandardContains(query) })
        }
    }

    func tracks(in album: PublicAlbum) -> [PublicAudioTrack] {
        let available = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return album.trackIDs.compactMap { available[$0] }.filter { $0.albumID == album.id }
    }

    init(testing: Bool = false, content: ContentLibrary? = nil, downloads: AudioDownloads? = nil,
         directoryOverride: URL? = nil, sessionOverride: URLSession? = nil) {
        self.content = content ?? ContentLibrary(testing: testing)
        self.downloads = downloads ?? AudioDownloads(testing: testing)
        session = sessionOverride ?? .shared
        let directory = directoryOverride ?? (testing ? URL.temporaryDirectory : URL.applicationSupportDirectory)
            .appending(path: testing ? "QingkongMacMusicUITesting" : "MacMusic", directoryHint: .isDirectory)
        cacheURL = directory.appending(path: "catalog.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
                musicCatalog = try cache.catalog.validated(at: cache.catalog.checkedAt)
                versions = cache.versions
                statusMessage = "正在显示已保存的音乐目录，尚未确认最新修订或撤回。"
            }
        } catch { statusMessage = "音乐目录缓存未能读取，请联网刷新。" }
        self.content.didRefresh = { [weak self] snapshot in
            guard let self,
                  (try? self.canonicalService(self.serviceAddress)) == (try? self.canonicalService(self.content.serviceAddress)) else { return }
            do {
                let next = try DesktopMusicCatalog(snapshot: snapshot, serviceAddress: self.content.serviceAddress,
                    checkedAt: self.content.lastCheckedAt ?? .now)
                _ = try self.acceptMusicCatalog(next)
            } catch { self.statusMessage = "音乐目录未能更新：\(error.localizedDescription)" }
        }
        // Existing article caches may carry a music projection, but phone sync never writes them.
        if musicCatalog == nil, let snapshot = self.content.snapshot, let checkedAt = self.content.lastCheckedAt {
            do { _ = try acceptMusicCatalog(DesktopMusicCatalog(snapshot: snapshot, serviceAddress: self.content.serviceAddress, checkedAt: checkedAt)) }
            catch { statusMessage = "音乐目录未能保存：\(error.localizedDescription)" }
        }
        if musicCatalog != nil { self.downloads.reconcile(with: tracks) }
    }

    func attach(player: MacAudioPlayer) {
        self.player = player
        player.onlineCatalogProvider = { [weak self] address in
            guard let self, self.musicCatalog != nil,
                  (try? self.canonicalService(address)) == (try? self.canonicalService(self.serviceAddress)) else { return nil }
            return self.tracks
        }
        player.localAudioURLProvider = { [weak self] track, address in
            guard let self,
                  (try? self.canonicalService(address)) == (try? self.canonicalService(self.serviceAddress)) else { return nil }
            return self.downloads.localURL(for: track)
        }
        player.didSelectOnline = { [weak self] track in self?.downloads.setPlayingTrack(track) }
        player.didStartOnline = { [weak self] track in self?.downloads.automaticallyCacheAfterPlaybackStarts(track) }
        if musicCatalog != nil { player.reconcileOnlineCatalog(tracks, serviceAddress: serviceAddress) }
    }

    /// Return only after atomic persistence. Duplicate sync never changes playback or its queue.
    @discardableResult
    func acceptMusicCatalog(_ incoming: DesktopMusicCatalog) throws -> Bool {
        let next = try incoming.validated(at: incoming.checkedAt)
        let service = try canonicalService(next.serviceAddress)
        let digest = try next.contentDigest()
        if let previous = versions[service] {
            guard next.revision >= previous.revision else { throw DesktopMusicCatalogError.revisionRollback }
        }
        if let previous = musicCatalog, try canonicalService(previous.serviceAddress) == service,
           next.revision == previous.revision {
            // Expiry can legitimately prune a same-revision phone projection during transfer.
            let currentContent = try previous.validated().contentDigest()
            let nextContent = try next.validated().contentDigest()
            guard currentContent == nextContent else { throw DesktopMusicCatalogError.revisionConflict }
        }
        let changed = try musicCatalog.map { try canonicalService($0.serviceAddress) != service || $0.contentDigest() != digest } ?? true
        var nextVersions = versions
        nextVersions[service] = Version(revision: next.revision)
        let data = try JSONEncoder().encode(Cache(catalog: next, versions: nextVersions))
        try data.write(to: cacheURL, options: .atomic)
        musicCatalog = next; versions = nextVersions
        statusMessage = albums.isEmpty ? "已更新音乐目录，当前没有已发布专辑。" : "音乐目录已保存，可在这台 Mac 选择专辑。"
        if changed {
            // Release a withdrawn decoder before its persistent file can be retired.
            player?.reconcileOnlineCatalog(tracks, serviceAddress: serviceAddress)
            downloads.reconcile(with: tracks)
        }
        return changed
    }

    func refresh() async {
        guard !isRefreshing else { return }
        let address = serviceAddress
        await content.refresh()
        if (try? canonicalService(address)) == (try? canonicalService(content.serviceAddress)) {
            if content.snapshot == nil || content.statusMessage.hasPrefix("刷新失败") { statusMessage = content.statusMessage }
            return
        }
        refreshingMusic = true
        defer { refreshingMusic = false }
        do {
            let url = try PublicContentURL.snapshotURL(from: address)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard (try? canonicalService(serviceAddress)) == (try? canonicalService(address)) else { return }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  http.url.map(PublicContentURL.isHTTPS) == true, data.count <= 10_000_000 else { throw PublicContentError.invalidSnapshot }
            let snapshot = try PublicContentSnapshot.decoder().decode(PublicContentSnapshot.self, from: data)
            _ = try acceptMusicCatalog(DesktopMusicCatalog(snapshot: snapshot, serviceAddress: address))
        } catch { statusMessage = "音乐目录刷新失败：\(error.localizedDescription) 正在显示缓存，尚未确认最新修订或撤回。" }
    }

    func togglePlayback(player: MacAudioPlayer, albumID: String? = nil, portableAlbum: Bool = false) {
        guard !player.isPreparing else { return }
        if player.hasSelection {
            player.toggle()
        } else if !player.queueItems.isEmpty {
            player.playQueueItem(at: player.currentIndex)
        } else if showsPortableAlbum || portableAlbum {
            player.play(Track.allCases[0])
        } else if let album = playableAlbums.first(where: { $0.id == albumID }) ?? playableAlbums.first,
                  let track = tracks(in: album).first {
            play(track: track, in: album, player: player)
        }
    }

    func play(track: PublicAudioTrack, in album: PublicAlbum, player: MacAudioPlayer, playing: Bool = true) {
        let queue = tracks(in: album)
        guard let index = queue.firstIndex(where: { $0.cacheIdentity == track.cacheIdentity }) else {
            statusMessage = "音轨已更新或下架，请刷新目录后重新选择。"; return
        }
        attach(player: player)
        player.playOnlineQueue(queue, index: index, serviceAddress: serviceAddress, playing: playing)
    }

    private func canonicalService(_ address: String) throws -> String {
        let url = try PublicContentURL.snapshotURL(from: address)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PublicContentError.invalidServiceURL }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        guard let canonical = parts.url else { throw PublicContentError.invalidServiceURL }
        return canonical.absoluteString
    }
}
