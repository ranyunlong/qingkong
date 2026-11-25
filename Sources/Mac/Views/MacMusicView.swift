import SwiftUI
import QingkongCore

struct MacMusicView: View {
    let connection: MacDeviceConnection
    let player: MacAudioPlayer
    let library: MacLibrary
    @Binding var selectedAlbumID: String?
    @Binding var showsPortableAlbum: Bool
    @State private var downloadedOnly = false
    @State private var showsDownloads = false
    @State private var search = ""

    private var visibleAlbums: [PublicAlbum] {
        library.albums(matching: search, downloadedOnly: downloadedOnly)
    }

    private var showsFallbackTile: Bool {
        library.showsPortableAlbum && (search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            "随身自然".localizedStandardContains(search) || Track.allCases.contains { $0.name.localizedStandardContains(search) })
    }

    var body: some View {
        Group {
            if showsPortableAlbum {
                MacPortableAlbumView(player: player, isTransferring: connection.isTransferring) {
                    showsPortableAlbum = false
                }
            } else if let album = library.albums.first(where: { $0.id == selectedAlbumID }) {
                MacAlbumDetailView(library: library, player: player, album: album, isTransferring: connection.isTransferring) {
                    selectedAlbumID = nil
                }
            } else {
                albumGrid
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await library.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新曲库").accessibilityLabel("刷新曲库")
                .disabled(library.isRefreshing)
                Button { showsDownloads = true } label: { Image(systemName: "internaldrive") }
                    .help("管理下载空间").accessibilityLabel("管理下载空间")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索专辑或歌曲")
        .sheet(isPresented: $showsDownloads) { MacDownloadsView(downloads: library.downloads) }
    }

    private var albumGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    Text("专辑").font(.largeTitle.bold())
                    Spacer()
                    MacAlbumFilter(downloadedOnly: $downloadedOnly)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 156, maximum: 230), spacing: 24)], alignment: .leading, spacing: 26) {
                    if showsFallbackTile {
                        Button { showsPortableAlbum = true } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                MacArtworkView(item: DesktopQueueItem(track: Track.allCases[0]), cornerRadius: 10)
                                    .aspectRatio(1, contentMode: .fit)
                                Text("随身自然").font(.headline).foregroundStyle(.primary)
                                Label("3 首 · 内置", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("打开随身自然专辑")
                    }
                    ForEach(visibleAlbums) { album in
                        Button { selectedAlbumID = album.id } label: {
                            MacAlbumTile(library: library, album: album)
                        }
                        .buttonStyle(.plain).help("打开\(album.title)")
                    }
                }
                if library.isRefreshing && library.albums.isEmpty {
                    ProgressView("正在加载在线专辑…").controlSize(.small)
                } else if visibleAlbums.isEmpty && !showsFallbackTile {
                    Label(!search.isEmpty ? "没有找到专辑或歌曲" : downloadedOnly ? "还没有下载的在线专辑" : "暂时没有在线专辑", systemImage: !search.isEmpty ? "magnifyingglass" : downloadedOnly ? "arrow.down.circle" : "music.note.list")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(library.statusMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(28).frame(maxWidth: 1200, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

private struct MacAlbumFilter: View {
    @Binding var downloadedOnly: Bool

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    glassButton("全部", downloaded: false)
                    glassButton("已下载", downloaded: true)
                }
            }
            .buttonBorderShape(.capsule).controlSize(.large)
        } else {
            Picker("音乐范围", selection: $downloadedOnly) {
                Text("全部").tag(false)
                Text("已下载").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(width: 160)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder private func glassButton(_ title: String, downloaded: Bool) -> some View {
        if downloadedOnly == downloaded {
            Button(title) { downloadedOnly = downloaded }
                .buttonStyle(.glassProminent).accessibilityAddTraits(.isSelected)
        } else {
            Button(title) { downloadedOnly = downloaded }
                .buttonStyle(.glass)
        }
    }
}

private struct MacAlbumTile: View {
    let library: MacLibrary
    let album: PublicAlbum
    private var offlineCount: Int { library.tracks(in: album).filter { library.downloads.localURL(for: $0) != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            MacAlbumArtworkView(url: album.coverURL, identity: macAlbumArtworkIdentity(album)).aspectRatio(1, contentMode: .fit)
            Text(album.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
            HStack(spacing: 5) {
                if offlineCount > 0 { Image(systemName: "arrow.down.circle.fill") }
                Text(offlineCount > 0 ? "\(offlineCount)/\(library.tracks(in: album).count) 首已下载" : "\(library.tracks(in: album).count) 首")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct MacAlbumArtworkView: View {
    let url: URL?
    var identity: String? = nil
    var cornerRadius: CGFloat = 10
    @State private var image: CGImage?
    @State private var imageIdentity: String?
    @State private var requestID = UUID()

    private var resourceIdentity: String { (url?.absoluteString ?? "") + "|" + (identity ?? "") }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image, imageIdentity == resourceIdentity {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else { placeholder }
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius)).accessibilityHidden(true)
        .task(id: resourceIdentity) {
            let request = UUID()
            requestID = request
            image = nil
            imageIdentity = nil
            guard let url else { return }
            do {
                let loaded = try await MacAlbumArtworkCache.shared.image(for: url, identity: identity)
                guard !Task.isCancelled, requestID == request else { return }
                image = loaded
                imageIdentity = resourceIdentity
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                image = nil
            }
        }
        .onDisappear { requestID = UUID(); image = nil; imageIdentity = nil }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
        }
    }
}

func macAlbumArtworkIdentity(_ album: PublicAlbum) -> String {
    "\(album.id)|\(album.revision)|\(album.updatedAt.timeIntervalSince1970)"
}

private struct MacPortableAlbumView: View {
    let player: MacAudioPlayer
    let isTransferring: Bool
    let back: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Button("专辑", systemImage: "chevron.left", action: back).buttonStyle(.plain)
                HStack(alignment: .bottom, spacing: 24) {
                    MacArtworkView(item: DesktopQueueItem(track: Track.allCases[0]), cornerRadius: 10)
                        .frame(width: 190, height: 190)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("随身自然").font(.largeTitle.bold())
                        Text("3 首 · 内置专辑").foregroundStyle(.secondary)
                        Button("播放", systemImage: "play.fill") { player.play(Track.allCases[0]) }
                            .buttonStyle(.borderedProminent).disabled(isTransferring)
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    ForEach(Array(Track.allCases.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 14) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                            Text(track.name).fontWeight(.medium)
                            Spacer()
                            Text(track.subtitle).foregroundStyle(.secondary)
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).help("内置，无需下载")
                            Button { player.play(track) } label: { Image(systemName: "play.fill") }
                                .buttonStyle(.borderless).help("播放\(track.name)").disabled(isTransferring)
                        }
                        .padding(.vertical, 14).padding(.horizontal, 10)
                    }
                }
                .font(.callout)
            }
            .padding(28).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}
