import SwiftUI
import MediaPlayer
import QingkongCore

struct SleepView: View {
    @Environment(AppServices.self) private var app
    @State private var albumID: String?
    @State private var cellularTrack: PublicAudioTrack?

    private var preferredAlbumID: String? {
        app.player.onlineTrack?.albumID ?? (app.player.hasSelection ? BundledNatureAlbum.id : app.content.lastPlayedAlbumID)
    }
    private var displayAlbum: PublicAlbum? { app.content.albumForDisplay(selectedID: albumID, preferredID: preferredAlbumID) }
    private var showsOfflineAlbum: Bool {
        !app.downloads.networkAvailable || displayAlbum == nil || (albumID == nil && preferredAlbumID == BundledNatureAlbum.id)
    }
    private var previewTrack: PublicAudioTrack? {
        guard !app.player.hasSelection, !showsOfflineAlbum, let album = displayAlbum else { return nil }
        return app.content.tracks(in: album).first
    }
    private var displayedState: AudioState {
        var state = app.player.state
        if let track = previewTrack {
            state.onlineTrackID = track.id
            state.onlineTitle = track.title
            state.onlineArtworkURL = track.coverURL ?? displayAlbum?.coverURL
        }
        return state
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                AudioArtworkView(state: displayedState).frame(height: 225).clipShape(RoundedRectangle(cornerRadius: 28))
                VStack(spacing: 12) {
                    Text(displayedState.displayTitle).font(.title2.weight(.semibold)).accessibilityIdentifier("current-track-title")
                    if let track = app.player.onlineTrack ?? previewTrack {
                        Text(app.player.buffering ? "正在加载音轨…" : app.downloads.state(for: track).label).font(.subheadline).foregroundStyle(Color.readableSecondary)
                    } else {
                        Text("\(app.player.state.track.subtitle) · 离线可用").font(.subheadline).foregroundStyle(Color.readableSecondary)
                    }
                    PlaybackProgressView(player: app.player, previewDuration: previewTrack?.durationSeconds)
                        .id(displayedState.onlineTrackID ?? displayedState.track.id)
                    GlassButtonGroup {
                      HStack(spacing: 16) {
                        Button { skip(-1) } label: {
                            Image(systemName: "backward.end.fill").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        }.qingkongGlassButton(shape: .circle).accessibilityLabel("上一首").accessibilityIdentifier("player-previous")
                        Button { togglePlayback() } label: {
                            Image(systemName: app.player.state.playing || app.player.buffering ? "pause.fill" : "play.fill").font(.title2).frame(width: 64, height: 64)
                        }.qingkongGlassButton(prominent: true, shape: .circle)
                            .disabled(app.player.activating).accessibilityLabel(app.player.state.playing ? "暂停播放" : "开始播放").accessibilityIdentifier("player-toggle")
                        Button { skip(1) } label: {
                            Image(systemName: "forward.end.fill").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        }.qingkongGlassButton(shape: .circle).accessibilityLabel("下一首").accessibilityIdentifier("player-next")
                      }
                    }.padding(.vertical, 8)
                    if let error = app.player.error { Text(error).font(.footnote).foregroundStyle(Color.readableSecondary) }
                    HStack(spacing: 12) {
                        Menu {
                            Picker("播放模式", selection: Binding(get: { app.player.playbackMode }, set: { app.player.playbackMode = $0 })) {
                                ForEach(AudioPlaybackMode.allCases, id: \.self) { mode in
                                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                                }
                            }
                        } label: {
                            Image(systemName: app.player.playbackMode.symbol).font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
                        }.qingkongGlassButton(shape: .circle)
                            .accessibilityLabel("播放模式：\(app.player.playbackMode.title)")
                            .accessibilityHint("选择单曲循环、顺序循环或随机循环")
                            .accessibilityIdentifier("playback-mode")
                        Image(systemName: "speaker.fill")
                        SystemVolumeControl(tint: app.scene.accent).frame(maxWidth: .infinity).frame(height: 44)
                        Image(systemName: "speaker.wave.3.fill")
                    }.foregroundStyle(Color.readableSecondary)
                }.frame(maxWidth: .infinity)
                VStack(spacing: 12) {
                    NavigationLink { BedtimeView() } label: {
                        Label("睡前陪伴与个人方案", systemImage: "moon.zzz").frame(maxWidth: .infinity, minHeight: 44)
                    }.qingkongGlassButton()
                    NavigationLink {
                        OnlineLibraryView(content: app.content, downloads: app.downloads) { track, queue, allowCellular in
                            await app.playOnline(track, queue: queue, allowCellular: allowCellular)
                        }
                    } label: {
                        Label("专辑与线上音乐", systemImage: "square.stack").frame(maxWidth: .infinity, minHeight: 44)
                    }.qingkongGlassButton()
                }
                Surface {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("停止定时", systemImage: "timer").font(.headline)
                        Picker("停止定时", selection: Binding(get: { app.player.state.deadline.map { $0.durationMinutes ?? -1 } ?? 0 }, set: { app.player.setTimer(minutes: $0) })) {
                            if app.player.state.deadline?.durationMinutes == nil && app.player.state.deadline != nil { Text("已设定").tag(-1) }
                            Text("关闭").tag(0); Text("15 分").tag(15); Text("30 分").tag(30); Text("60 分").tag(60)
                        }.pickerStyle(.segmented).accessibilityIdentifier("sleep-timer")
                        if let deadline = app.player.state.deadline {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text("将在 \(countdown(deadline, at: context.date)) 停止播放")
                                    .monospacedDigit()
                            }.font(.caption).foregroundStyle(Color.readableSecondary).accessibilityIdentifier("sleep-countdown")
                        } else { Text("\(app.player.playbackMode.title)，可随时暂停。").font(.caption).foregroundStyle(Color.readableSecondary) }
                    }
                }
                AlbumRecommendationView(selectedAlbumID: $albumID, preferredAlbumID: preferredAlbumID, title: "当前专辑")
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }
        .task { await app.content.refresh() }
        .refreshable { await app.content.refresh() }
        .onChange(of: preferredAlbumID) { _, _ in albumID = nil }
        .confirmationDialog("使用蜂窝网络播放？", isPresented: Binding(get: { cellularTrack != nil }, set: { if !$0 { cellularTrack = nil } }), titleVisibility: .visible) {
            Button("使用流量在线播放") {
                if let track = cellularTrack { playOnline(track, allowCellular: true) }
                cellularTrack = nil
            }
            Button("取消", role: .cancel) { cellularTrack = nil }
        } message: { Text("在线播放会使用移动数据，自动补全缓存仍仅在 Wi-Fi 下进行。") }
    }

    private func togglePlayback() {
        if app.player.hasSelection { Task { await app.player.toggle() } }
        else if let track = previewTrack { requestPlay(track) }
        else { Task { await app.player.select(.rain, autoplay: true) } }
    }

    private func skip(_ step: Int) {
        if !app.player.hasSelection, let album = displayAlbum, !showsOfflineAlbum {
            let tracks = app.content.tracks(in: album)
            if !tracks.isEmpty { requestPlay(tracks[(step + tracks.count) % tracks.count]) }
        } else { Task { await app.player.skip(step) } }
    }

    private func requestPlay(_ track: PublicAudioTrack) {
        if app.downloads.localURL(for: track) == nil && app.downloads.networkAvailable && !app.downloads.isWiFi { cellularTrack = track }
        else { playOnline(track, allowCellular: false) }
    }

    private func playOnline(_ track: PublicAudioTrack, allowCellular: Bool) {
        do {
            _ = try app.downloads.playbackURL(for: track, allowCellular: allowCellular)
            let queue = app.content.albums.first { $0.id == track.albumID }.map { app.content.tracks(in: $0) } ?? [track]
            Task { await app.playOnline(track, queue: queue, allowCellular: allowCellular) }
        } catch { app.player.reportPlaybackError(error.localizedDescription) }
    }

    private func countdown(_ deadline: SleepDeadline, at date: Date) -> String {
        let seconds = Int(ceil(deadline.remaining(at: date)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

private struct PlaybackProgressView: View {
    let player: AudioPlayer
    let previewDuration: TimeInterval?
    @State private var draftPosition: TimeInterval?
    @State private var dragging = false
    @State private var seekRevision = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = player.playbackDuration > 0 ? player.playbackDuration : (previewDuration ?? 0)
            let validDuration = duration.isFinite && duration > 0 ? duration : 0
            let position = min(validDuration, max(0, draftPosition ?? player.playbackPosition))
            VStack(spacing: 0) {
                Slider(value: Binding(get: {
                    min(validDuration, max(0, draftPosition ?? player.playbackPosition))
                }, set: { value in
                    draftPosition = value
                    if !dragging { commitSeek(to: value) }
                }), in: 0...max(1, validDuration), onEditingChanged: { editing in
                    dragging = editing
                    if editing { seekRevision += 1 }
                    else { commitSeek(to: draftPosition ?? position) }
                })
                .disabled(!player.canSeek)
                .accessibilityLabel("播放进度")
                .accessibilityValue("\(timestamp(position))，共 \(timestamp(validDuration))")
                .accessibilityIdentifier("playback-progress")
                HStack {
                    Text(timestamp(position)).accessibilityLabel("已播放 \(timestamp(position))").accessibilityIdentifier("playback-elapsed")
                    Spacer()
                    Text(validDuration > 0 ? "−" + timestamp(ceil(max(0, validDuration - position))) : "--:--")
                        .accessibilityLabel("剩余 \(timestamp(ceil(max(0, validDuration - position))))")
                        .accessibilityIdentifier("playback-remaining")
                }.font(.caption).monospacedDigit().foregroundStyle(Color.readableSecondary)
            }
        }
    }

    private func commitSeek(to position: TimeInterval) {
        seekRevision += 1
        let revision = seekRevision
        Task {
            await player.seek(to: position)
            if seekRevision == revision { draftPosition = nil }
        }
    }

    private func timestamp(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "--:--" }
        let seconds = Int(min(359_999, value))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SystemVolumeControl: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = CenteredVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.accessibilityIdentifier = "system-volume"
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.tintColor = UIColor(tint)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = UIColor(tint)
    }
}

private final class CenteredVolumeView: MPVolumeView {
    override func volumeSliderRect(forBounds bounds: CGRect) -> CGRect {
        var rect = super.volumeSliderRect(forBounds: bounds)
        rect.origin.y = bounds.midY - rect.height / 2
        return rect
    }
}
