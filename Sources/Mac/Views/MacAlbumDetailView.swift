import SwiftUI
import QingkongCore

struct MacAlbumDetailView: View {
    let library: MacLibrary
    let player: MacAudioPlayer
    let album: PublicAlbum
    let isTransferring: Bool
    let back: () -> Void
    private var tracks: [PublicAudioTrack] { library.tracks(in: album) }
    private var offlineCount: Int { tracks.filter { library.downloads.localURL(for: $0) != nil }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Button("专辑", systemImage: "chevron.left", action: back).buttonStyle(.plain)
                HStack(alignment: .bottom, spacing: 24) {
                    MacAlbumArtworkView(url: album.coverURL, identity: macAlbumArtworkIdentity(album)).frame(width: 190, height: 190)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(album.title).font(.largeTitle.bold()).textSelection(.enabled)
                        if !album.summary.isEmpty { Text(album.summary).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                        Text("\(tracks.count) 首 · \(offlineCount) 首已下载").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("播放", systemImage: "play.fill") {
                                if let first = tracks.first { library.play(track: first, in: album, player: player) }
                            }
                            .buttonStyle(.borderedProminent).disabled(tracks.isEmpty || isTransferring)
                            Button("下载专辑", systemImage: "arrow.down.circle") {
                                tracks.forEach { library.downloads.download($0) }
                            }.disabled(tracks.isEmpty || offlineCount == tracks.count)
                            Menu {
                                Button("取消正在下载的音轨", systemImage: "xmark.circle") {
                                    tracks.filter { macDownloadIsBusy(library.downloads.state(for: $0)) }.forEach { library.downloads.delete($0) }
                                }.disabled(!tracks.contains { macDownloadIsBusy(library.downloads.state(for: $0)) })
                                Button("删除专辑下载", systemImage: "trash", role: .destructive) {
                                    tracks.filter { library.downloads.storedRecord(for: $0) != nil }.forEach { library.downloads.delete($0) }
                                }.disabled(offlineCount == 0)
                            } label: { Image(systemName: "ellipsis") }
                            .menuIndicator(.hidden).help("专辑下载操作")
                        }
                    }
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        MacOnlineTrackRow(library: library, player: player, album: album, track: track, number: index + 1, isTransferring: isTransferring)
                    }
                }
                .font(.callout)
                if let error = library.downloads.storageError {
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

private struct MacOnlineTrackRow: View {
    let library: MacLibrary
    let player: MacAudioPlayer
    let album: PublicAlbum
    let track: PublicAudioTrack
    let number: Int
    let isTransferring: Bool
    private var state: AudioDownloadState { library.downloads.state(for: track) }
    private var isCurrent: Bool { player.currentItem?.onlineTrack?.cacheIdentity == track.cacheIdentity }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if isCurrent { Image(systemName: player.playbackIntent ? "speaker.wave.2.fill" : "pause.fill").foregroundStyle(.tint) }
                else { Text("\(number)").monospacedDigit().foregroundStyle(.secondary) }
            }.frame(width: 22)
            Text(track.title).fontWeight(isCurrent ? .semibold : .medium).lineLimit(1)
            Spacer(minLength: 8)
            Text(macPlaybackClock(track.durationSeconds)).monospacedDigit().foregroundStyle(.secondary)
            MacTrackDownloadButton(downloads: library.downloads, track: track).frame(width: 28, height: 28)
            Button { library.play(track: track, in: album, player: player) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless).help("播放\(track.title)").accessibilityLabel("播放\(track.title)").disabled(isTransferring)
        }
        .padding(.vertical, 13).padding(.horizontal, 10).contentShape(Rectangle())
        .onTapGesture(count: 2) { if !isTransferring { library.play(track: track, in: album, player: player) } }
        .contextMenu {
            Button("播放", systemImage: "play.fill") { library.play(track: track, in: album, player: player) }.disabled(isTransferring)
            if library.downloads.localURL(for: track) != nil {
                Button("删除下载", systemImage: "trash", role: .destructive) { library.downloads.delete(track) }
            } else if macDownloadIsBusy(state) {
                Button("取消下载", systemImage: "xmark.circle") { library.downloads.delete(track) }
            } else {
                Button("下载", systemImage: "arrow.down.circle") { library.downloads.download(track) }
            }
        }
    }
}

private struct MacTrackDownloadButton: View {
    let downloads: AudioDownloads
    let track: PublicAudioTrack
    @State private var showsFailure = false

    var body: some View {
        Group {
            switch downloads.state(for: track) {
            case .offline:
                Menu {
                    Button("删除下载", systemImage: "trash", role: .destructive) { downloads.delete(track) }
                } label: { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary) }
                .menuIndicator(.hidden).menuStyle(.borderlessButton).help("已下载，点按管理")
            case .downloading(let progress):
                Button { downloads.delete(track) } label: {
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 1.5)
                        Circle().trim(from: 0, to: min(1, max(0, progress)))
                            .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill").font(.system(size: 5, weight: .regular))
                    }
                    .frame(width: 16, height: 16).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .help("取消下载，已完成 \(Int(progress * 100))%")
                .accessibilityLabel("取消下载\(track.title)")
                .accessibilityValue("已完成 \(Int(progress * 100))%")
            case .verifying, .waitingForWiFi, .waitingForConnection:
                Button { downloads.delete(track) } label: { Image(systemName: "xmark.circle") }
                    .help(downloads.state(for: track).label + "；点按取消")
            case .failed(let message):
                Button { showsFailure = true } label: { Image(systemName: "exclamationmark.circle") }
                    .help(message).accessibilityLabel("\(track.title)下载失败，查看详情")
                    .popover(isPresented: $showsFailure) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(message).textSelection(.enabled)
                            Button("重新下载", systemImage: "arrow.clockwise") {
                                showsFailure = false
                                downloads.download(track)
                            }
                        }.padding().frame(width: 280, alignment: .leading)
                    }
            case .unavailable:
                Button { downloads.download(track) } label: { Image(systemName: "arrow.down.circle") }
                    .help("下载\(track.title)").accessibilityLabel("下载\(track.title)")
            }
        }
        .font(.system(size: 16, weight: .regular))
        .buttonStyle(.borderless)
    }
}

func macDownloadIsBusy(_ state: AudioDownloadState) -> Bool {
    switch state {
    case .downloading, .verifying, .waitingForConnection, .waitingForWiFi: true
    default: false
    }
}
