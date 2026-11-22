import SwiftUI
import QingkongCore

struct OnlineLibraryView: View {
    let content: ContentLibrary
    let downloads: AudioDownloads
    let onPlay: (PublicAudioTrack, [PublicAudioTrack], Bool) async -> Void

    var body: some View {
        List {
            ForEach(content.latestAlbums) { album in
                Section {
                    AlbumPlaylistView(album: album, content: content, downloads: downloads, onPlay: onPlay)
                        .padding(.vertical, 8)
                }
            }
            Section { BundledNatureAlbumView().padding(.vertical, 8) }
            Section {
                NavigationLink { AudioDownloadSettings(content: content, downloads: downloads) } label: { Label("下载与空间管理", systemImage: "arrow.down.circle") }
            }
        }
        .navigationTitle("专辑与声音")
        .refreshable { await content.refresh() }
        .task { await content.refresh() }
    }
}

struct AlbumRecommendationView: View {
    @Environment(AppServices.self) private var app
    @Binding var selectedAlbumID: String?
    var preferredAlbumID: String? = nil
    var title = "听一张专辑"

    private var album: PublicAlbum? { app.content.albumForDisplay(selectedID: selectedAlbumID, preferredID: preferredAlbumID) }
    private var showsOfflineAlbum: Bool {
        !app.downloads.networkAvailable || album == nil || (selectedAlbumID == nil && preferredAlbumID == BundledNatureAlbum.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(title).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                Button {
                    let albums = app.content.playableAlbums
                    if showsOfflineAlbum, app.downloads.networkAvailable, let first = albums.first { selectedAlbumID = first.id }
                    else if let current = album, let index = albums.firstIndex(where: { $0.id == current.id }), albums.count > 1 {
                        selectedAlbumID = albums[(index + 1) % albums.count].id
                    } else { Task { await app.content.refresh() } }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                }
                    .qingkongGlassButton(shape: .circle)
                    .controlSize(.regular).frame(width: 44, height: 44)
                    .disabled(!app.downloads.networkAvailable || (app.content.isRefreshing && app.content.playableAlbums.count < 2))
                    .accessibilityLabel("刷新，换一张专辑").accessibilityIdentifier("refresh-home-album")
                NavigationLink {
                    OnlineLibraryView(content: app.content, downloads: app.downloads) { track, queue, allowCellular in
                        await app.playOnline(track, queue: queue, allowCellular: allowCellular)
                    }
                } label: { Text("更多").font(.subheadline).frame(height: 20) }
                    .controlSize(.regular).frame(height: 44)
                    .accessibilityLabel("更多专辑").accessibilityIdentifier("open-album-library")
            }
            if showsOfflineAlbum { BundledNatureAlbumView() }
            else if let album {
                AlbumPlaylistView(album: album, content: app.content, downloads: app.downloads) { track, queue, allowCellular in
                    await app.playOnline(track, queue: queue, allowCellular: allowCellular)
                }.id(album.id)
            }
        }
    }
}

enum BundledNatureAlbum {
    static let id = "qingkong-bundled-nature"
    static let title = "随身自然"
    static let summary = "把雨声、海浪和安静的夜晚装进口袋。三段内置自然声音，无需网络，随时听一会儿。"
}

struct BundledNatureAlbumView: View {
    @Environment(AppServices.self) private var app
    private var isCurrentAlbum: Bool { app.player.hasSelection && app.player.onlineTrack == nil }
    private var isPlaying: Bool { isCurrentAlbum && app.player.state.playing }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Image("forest").resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.accessibilityHidden(true)
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    Text(BundledNatureAlbum.title).font(.title2.weight(.semibold))
                    Text("3 段自然声音 · 内置离线").font(.subheadline)
                }.foregroundStyle(.white).padding(20)
            }.frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 24)).allowsHitTesting(false)
            Text(BundledNatureAlbum.summary).font(.subheadline).foregroundStyle(Color.readableSecondary)
            Button {
                if isCurrentAlbum { Task { await app.player.toggle() } }
                else { Task { await app.player.select(.rain, autoplay: true) } }
            } label: {
                Label(isPlaying ? "暂停播放" : "播放专辑", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }.qingkongGlassButton(prominent: true).disabled(app.player.activating).accessibilityIdentifier("play-bundled-album")
            VStack(spacing: 0) {
                ForEach(Track.allCases) { track in
                    if track != Track.allCases.first { Divider() }
                    Button {
                        Task {
                            if isCurrentAlbum && app.player.state.track == track { await app.player.toggle() }
                            else { await app.player.select(track, autoplay: true) }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(track.image).resizable().scaledToFill().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(track.name).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                                Text(track.subtitle + " · 离线可用").font(.caption).foregroundStyle(Color.readableSecondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: isPlaying && app.player.state.track == track ? "waveform" : "play.circle").foregroundStyle(app.scene.accent)
                        }.frame(minHeight: 64).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(app.player.activating).accessibilityIdentifier("track-\(track.id)")
                }
            }
        }
    }
}

struct AlbumPlaylistView: View {
    @Environment(AppServices.self) private var app
    let album: PublicAlbum
    let content: ContentLibrary
    let downloads: AudioDownloads
    let onPlay: (PublicAudioTrack, [PublicAudioTrack], Bool) async -> Void
    @State private var cellularTrack: PublicAudioTrack?
    @State private var error: String?

    private var tracks: [PublicAudioTrack] { content.tracks(in: album) }
    private var isFullyDownloaded: Bool { !tracks.isEmpty && tracks.allSatisfy { downloads.state(for: $0) == .offline } }
    private var isCurrentAlbum: Bool { app.player.onlineTrack?.albumID == album.id }
    private var isPlaying: Bool { isCurrentAlbum && (app.player.state.playing || app.player.buffering) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            cover
            if !album.summary.isEmpty {
                Text(album.summary).font(.subheadline).foregroundStyle(Color.readableSecondary)
            }
            HStack(spacing: 12) {
                Button {
                    if isCurrentAlbum && app.player.error == nil {
                        Task { await app.player.toggle() }
                    } else if let first = tracks.first { requestPlay(first) }
                } label: {
                    Label(isPlaying ? "暂停播放" : "播放专辑", systemImage: isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }.qingkongGlassButton(prominent: true)
                    .disabled(tracks.isEmpty || app.player.activating)
                    .accessibilityIdentifier("play-album-\(album.id)")
                if !isFullyDownloaded {
                    Menu {
                        Button("下载整张专辑", systemImage: "arrow.down.circle") {
                            for track in tracks { downloads.download(track, intent: .manual) }
                        }.disabled(tracks.isEmpty)
                    } label: {
                        Image(systemName: "arrow.down.circle").font(.title3).frame(minWidth: 44, minHeight: 44)
                    }.qingkongGlassButton(shape: .circle).accessibilityLabel("专辑下载")
                        .accessibilityIdentifier("download-album-\(album.id)")
                }
            }
            if tracks.isEmpty {
                Text("这张专辑暂时没有可播放的歌曲。").font(.subheadline).foregroundStyle(Color.readableSecondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    if index > 0 { Divider() }
                    trackRow(track, number: index + 1)
                }
            }
            if isCurrentAlbum, let message = app.player.error {
                Text(message).font(.footnote).foregroundStyle(Color.readableSecondary)
            }
        }
        .confirmationDialog("使用蜂窝网络播放？", isPresented: Binding(get: { cellularTrack != nil }, set: { if !$0 { cellularTrack = nil } }), titleVisibility: .visible) {
            Button("使用流量在线播放") {
                if let track = cellularTrack { play(track, allowCellular: true) }
                cellularTrack = nil
            }
            Button("取消", role: .cancel) { cellularTrack = nil }
        } message: { Text("在线播放会使用移动数据，自动补全缓存仍仅在 Wi-Fi 下进行。") }
        .alert("暂时无法播放", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                Group {
                    if let url = album.coverURL, PublicContentURL.isHTTPS(url) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image { image.resizable().scaledToFill() }
                            else { artworkPlaceholder }
                        }.id(url)
                    } else { artworkPlaceholder }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.accessibilityHidden(true)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(album.title).font(.title2.weight(.semibold)).accessibilityIdentifier("album-title-\(album.id)")
                Text("\(tracks.count) 首歌曲").font(.subheadline)
            }.foregroundStyle(.white).padding(20)
        }.frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 24)).allowsHitTesting(false)
    }

    private var artworkPlaceholder: some View {
        ZStack {
            app.scene.accent.opacity(0.2)
            Image(systemName: "music.note.list").font(.system(size: 48)).foregroundStyle(app.scene.accent)
        }
    }

    private func trackRow(_ track: PublicAudioTrack, number: Int) -> some View {
        let selected = app.player.onlineTrack?.id == track.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button { requestPlay(track) } label: {
                    HStack(spacing: 12) {
                        Group {
                            if selected && (app.player.state.playing || app.player.buffering) {
                                Image(systemName: app.player.buffering ? "hourglass" : "waveform").foregroundStyle(app.scene.accent)
                            } else { Text(number.formatted()).foregroundStyle(Color.readableSecondary) }
                        }.font(.subheadline).frame(width: 24)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(track.title).font(.subheadline.weight(.medium)).foregroundStyle(selected ? app.scene.accent : Color.primary)
                            Text("\(Int(track.durationSeconds) / 60):\(String(format: "%02d", Int(track.durationSeconds) % 60)) · \(downloads.state(for: track).label)")
                                .font(.caption).foregroundStyle(Color.readableSecondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 54).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(app.player.activating)
                    .accessibilityLabel("\(selected && isPlaying ? "暂停" : "播放")：\(track.title)")
                    .accessibilityIdentifier("album-track-\(track.id)")
                Menu {
                    if isBusy(track) {
                        Button("取消下载", systemImage: "xmark.circle") { downloads.delete(track) }
                    } else if let record = downloads.storedRecord(for: track) {
                        if record.intent == .automatic && downloads.localURL(for: track) != nil {
                            Button("保留下载", systemImage: "arrow.down.circle.fill") { downloads.download(track, intent: .manual) }
                        }
                        Button("删除下载", systemImage: "trash", role: .destructive) { downloads.deleteStored(identity: record.identity) }
                    } else {
                        Button("下载 / 重试", systemImage: "arrow.down.circle") { downloads.download(track, intent: .manual) }
                    }
                    Text(ByteCountFormatter.string(fromByteCount: track.byteSize, countStyle: .file))
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.borderless).accessibilityLabel("\(track.title)的下载选项")
            }
            if case .downloading(let progress) = downloads.state(for: track) { ProgressView(value: progress) }
        }.padding(.vertical, 6)
    }

    private func isBusy(_ track: PublicAudioTrack) -> Bool {
        switch downloads.state(for: track) { case .downloading, .verifying, .waitingForConnection: true; default: false }
    }

    private func requestPlay(_ track: PublicAudioTrack) {
        if app.player.onlineTrack?.id == track.id && app.player.error == nil {
            Task { await app.player.toggle() }
        } else if downloads.localURL(for: track) == nil && downloads.networkAvailable && !downloads.isWiFi {
            cellularTrack = track
        } else { play(track, allowCellular: false) }
    }

    private func play(_ track: PublicAudioTrack, allowCellular: Bool) {
        do {
            _ = try downloads.playbackURL(for: track, allowCellular: allowCellular)
            let queue = tracks
            Task { await onPlay(track, queue, allowCellular) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct AudioDownloadSettings: View {
    let content: ContentLibrary
    @Bindable var downloads: AudioDownloads
    var body: some View {
        Form {
            Section("网络偏好") {
                Toggle("主动下载仅使用 Wi-Fi", isOn: $downloads.wifiOnlyDownloads)
                Text("自动补全缓存始终仅在 Wi-Fi 下进行。关闭后，主动下载可使用蜂窝流量。当前传输中更改为仅 Wi-Fi 会停止蜂窝下载，可在连接 Wi-Fi 后重试。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("空间管理") {
                LabeledContent("主动下载", value: ByteCountFormatter.string(fromByteCount: downloads.manualBytes, countStyle: .file))
                LabeledContent("自动缓存", value: ByteCountFormatter.string(fromByteCount: downloads.automaticBytes, countStyle: .file))
                Button("清理自动缓存", role: .destructive) { downloads.clearAutomaticCache() }
                Text("自动缓存最多保留约 300 MB，按最近使用清理。主动下载保留至手动删除；播放中的文件不会被清理。").font(.footnote).foregroundStyle(.secondary)
                if let error = downloads.storageError { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("已存文件") {
                ForEach(downloads.storedRecords) { record in
                    let track = content.tracks.first { $0.cacheIdentity == record.identity }
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track?.title ?? record.title ?? "已存音轨")
                            Text("\(record.intent == .manual ? "主动下载" : "自动缓存") · \(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                            if track == nil { Text("已不在当前目录，可清理").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("删除", role: .destructive) { downloads.deleteStored(identity: record.identity) }
                    }
                }
            }
        }.navigationTitle("下载与空间")
    }
}
