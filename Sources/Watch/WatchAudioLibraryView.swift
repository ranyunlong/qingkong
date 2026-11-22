import SwiftUI
import QingkongCore

struct WatchAudioLibraryView: View {
    @Environment(AppServices.self) private var app
    @State private var error: String?

    var body: some View {
        List {
            Section("手表上的声音") {
                Text("完整下载并校验后可在手表离线播放。手机上的缓存与这里分开保存。").font(.caption2)
                Text("下载时请保持此页面打开；离开页面或应用退到后台会中断，返回后可重试。").font(.caption2).foregroundStyle(.secondary)
                Text(app.content.statusMessage).font(.caption2)
                if let checked = app.content.lastCheckedAt {
                    Text("上次检查：\(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                }
                Button("刷新手表曲库") { Task { await app.content.refresh() } }.disabled(app.content.isRefreshing)
                if app.content.isRefreshing { ProgressView() }
                if !app.content.isConfigured { Text("公共内容服务暂不可用，请稍后刷新重试。").font(.caption2) }
            }
            ForEach(app.content.albums) { album in
                Section(album.title) {
                    Text(album.summary).font(.caption2).foregroundStyle(.secondary)
                    let tracks = album.trackIDs.compactMap { id in app.content.tracks.first { $0.id == id && $0.albumID == album.id } }
                    ForEach(tracks) { track in row(track) }
                }
            }
            Section("网络与空间") {
                Toggle("下载避开蜂窝与昂贵网络", isOn: Binding(get: { app.downloads.wifiOnlyDownloads }, set: { app.downloads.wifiOnlyDownloads = $0 }))
                Text("默认开启。系统选择可用连接；关闭后，主动下载可能使用移动数据。").font(.caption2).foregroundStyle(.secondary)
                LabeledContent("手表已下载", value: ByteCountFormatter.string(fromByteCount: app.downloads.manualBytes, countStyle: .file)).font(.caption2)
                if let message = app.downloads.storageError { Text(message).font(.caption2) }
            }
            Section("已存文件") {
                ForEach(app.downloads.storedRecords) { record in
                    let track = app.content.tracks.first { $0.cacheIdentity == record.identity }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track?.title ?? record.title ?? "已存音轨")
                        Text(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file)).font(.caption2)
                        if track == nil { Text("已不在当前目录，可清理").font(.caption2).foregroundStyle(.secondary) }
                        Button("删除手表下载", role: .destructive) { app.downloads.deleteStored(identity: record.identity) }
                    }
                }
            }
            Section("内置声音") {
                ForEach(Track.allCases) { track in
                    Button(track.name) {
                        Task {
                            await app.player.selectLocally(track)
                            error = app.player.error
                        }
                    }
                }
                Text("这里选择的声音在手表播放，不会遥控手机。").font(.caption2).foregroundStyle(.secondary)
            }
        }.navigationTitle("手表曲库")
            .task { await app.content.refresh() }
            .onDisappear { app.downloads.interruptForegroundDownloads() }
            .alert("暂时无法播放", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }

    private func row(_ track: PublicAudioTrack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(track.title).font(.headline)
            Text(app.downloads.localURL(for: track) == nil ? app.downloads.state(for: track).label : "手表完整离线可用").font(.caption2).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: track.byteSize, countStyle: .file)).font(.caption2)
            if case .downloading(let value) = app.downloads.state(for: track) { ProgressView(value: value) }
            if app.downloads.localURL(for: track) != nil {
                Button("在手表播放") { Task { await app.playDownloaded(track); error = app.player.error } }
                    .disabled(app.player.activating)
            }
            if downloading(track) {
                Button("取消下载") { app.downloads.delete(track) }
            } else if let record = app.downloads.storedRecord(for: track) {
                Button("删除手表下载", role: .destructive) { app.downloads.deleteStored(identity: record.identity) }
            } else {
                Button("下载到手表 / 重试") { app.downloads.download(track, intent: .manual) }
            }
        }.padding(.vertical, 4)
    }

    private func downloading(_ track: PublicAudioTrack) -> Bool {
        switch app.downloads.state(for: track) {
        case .downloading, .verifying, .waitingForConnection: true
        default: false
        }
    }
}
