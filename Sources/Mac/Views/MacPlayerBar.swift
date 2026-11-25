import SwiftUI
import QingkongCore

struct MacPlayerBar: View {
    let connection: MacDeviceConnection
    @Bindable var player: MacAudioPlayer
    let library: MacLibrary
    let selectedAlbumID: String?
    let showsPortableAlbum: Bool
    @Binding var showsQueue: Bool
    @State private var scrubPosition: Double?
    @State private var isScrubbing = false
    @State private var showsVolume = false
    @State private var showsError = false
    @FocusState private var volumeFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                wideLayout
                compactLayout
            }
            if let error = player.error {
                Button { showsError = true } label: {
                    Label("播放遇到问题", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsError) {
                    Text(error).textSelection(.enabled).padding().frame(maxWidth: 320)
                }
            }
        }
        .padding(12)
        .modifier(MacPlayerSurface())
        .onChange(of: player.currentItem?.id) { _, _ in scrubPosition = nil; isScrubbing = false }
    }

    private var wideLayout: some View {
        HStack(spacing: 15) {
            transport
            MacArtworkView(item: player.currentItem).frame(width: 44, height: 44)
            nowPlaying.frame(minWidth: 145, maxWidth: .infinity)
            utilities
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                MacArtworkView(item: player.currentItem).frame(width: 36, height: 36)
                title
                Spacer(minLength: 0)
                utilities
            }
            HStack(spacing: 15) {
                transport
                progress
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 13) {
            repeatControl
            Button { Task { await player.previous() } } label: { Image(systemName: "backward.end.fill") }
                .help("上一曲").accessibilityLabel("上一曲")
                .disabled(!player.hasSelection || connection.isTransferring)
            Button { library.togglePlayback(player: player, albumID: selectedAlbumID, portableAlbum: showsPortableAlbum) } label: {
                Image(systemName: player.playbackIntent ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold)).frame(width: 25, height: 28)
            }
            .help(player.playbackIntent ? "暂停" : "播放")
            .accessibilityLabel(player.playbackIntent ? "暂停" : "播放")
            .disabled(connection.isTransferring || player.isPreparing ||
                      (!player.hasSelection && library.playableAlbums.isEmpty && !library.showsPortableAlbum && !showsPortableAlbum))
            Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill") }
                .help("下一曲").accessibilityLabel("下一曲")
                .disabled(!player.hasSelection || connection.isTransferring)
            timerControl
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .font(.system(size: 15, weight: .semibold))
        .fixedSize()
        .disabled(!player.controlsAvailable)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(player.title).font(.callout.weight(.semibold)).lineLimit(1)
            if !player.subtitle.isEmpty {
                Text(player.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var nowPlaying: some View {
        VStack(spacing: 3) {
            title.frame(maxWidth: .infinity, alignment: .leading)
            progress
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            HStack(spacing: 3) {
                ZStack {
                    if player.isBuffering || connection.isTransferring {
                        ProgressView().controlSize(.mini)
                            .scaleEffect(0.8)
                            .accessibilityLabel(connection.isTransferring ? "正在接续" : "正在缓冲")
                    }
                }
                .frame(width: 10, height: 10)
                Text(macPlaybackClock(scrubPosition ?? player.position))
                    .frame(minWidth: 30, alignment: .trailing)
            }
            Slider(value: Binding(get: { scrubPosition ?? player.position }, set: { scrubPosition = $0 }),
                   in: 0...max(1, player.duration), onEditingChanged: { editing in
                isScrubbing = editing
                if editing {
                    scrubPosition = player.position
                } else if let target = scrubPosition {
                    Task {
                        await player.seek(to: target)
                        if !isScrubbing { scrubPosition = nil }
                    }
                }
            })
            .controlSize(.mini)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(macPlaybackClock(scrubPosition ?? player.position))，共 \(macPlaybackClock(player.duration))")
            .disabled(!player.hasSelection || player.isBuffering || connection.isTransferring || !player.controlsAvailable)
            Text(macPlaybackClock(player.duration)).frame(width: 36, alignment: .leading)
        }
        .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
    }

    private var volumeControl: some View {
        volumeButton
        .disabled(!player.controlsAvailable)
        .opacity(showsVolume ? 0 : 1)
        .accessibilityHidden(showsVolume)
        .overlay(alignment: .trailing) {
            if showsVolume {
                HStack(spacing: 8) {
                    Slider(value: $player.volume, in: 0...1)
                        .controlSize(.mini).tint(.accentColor).accessibilityLabel("音量")
                        .disabled(player.isPhonePlayback)
                        .help(player.isPhonePlayback ? "在 iPhone 或 Apple Watch 调整 AirPlay 音量" : "音量")
                        .focused($volumeFocused)
                        .frame(width: 90)
                        .onAppear { volumeFocused = true }
                    volumeButton
                }
                .padding(.leading, 12).frame(height: 32)
                .background {
                    Capsule().fill(Color.primary.opacity(0.10))
                        .background(.regularMaterial, in: Capsule())
                }
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .contentShape(Capsule())
                .onHover { inside in
                    if !inside { showsVolume = false; volumeFocused = false }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: volumeFocused) { _, focused in
            if !focused { showsVolume = false }
        }
        .onExitCommand { showsVolume = false; volumeFocused = false }
        .onDisappear { showsVolume = false; volumeFocused = false }
        .animation(.easeInOut(duration: 0.16), value: showsVolume)
    }

    private var volumeButton: some View {
        Button { showsVolume.toggle() } label: {
            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(width: 28, height: 28)
        }
        .help("音量").accessibilityLabel("音量控制")
        .accessibilityValue(showsVolume ? "已展开" : "已收起")
    }

    private var utilities: some View {
        HStack(spacing: 10) {
            volumeControl
            Button { showsQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .foregroundStyle(showsQueue ? Color.accentColor : Color.primary)
                .help("播放队列").accessibilityLabel("播放队列").accessibilityValue(showsQueue ? "已展开" : "已收起")
            Menu {
                Button("停止播放", systemImage: "stop.fill") { player.stop() }
                    .disabled(!player.hasSelection && !player.isPreparing)
            } label: { Image(systemName: "ellipsis") }
            .help("更多播放操作").accessibilityLabel("更多播放操作")
        }
        .buttonStyle(.plain).menuStyle(.borderlessButton).menuIndicator(.hidden)
        .font(.system(size: 14)).fixedSize()
    }

    private var repeatControl: some View {
        Menu {
            ForEach(AudioPlaybackMode.allCases, id: \.self) { mode in
                Button { player.setMode(mode) } label: {
                    Label(mode.title, systemImage: mode == player.mode ? "checkmark" : mode.symbol)
                }
            }
        } label: { Image(systemName: player.mode.symbol).font(.system(size: 14)) }
        .help(player.mode.title).accessibilityLabel("循环方式：\(player.mode.title)")
    }

    private var timerControl: some View {
        Menu {
            Button("关闭定时") { player.setTimer(minutes: 0) }
            ForEach([15, 30, 60], id: \.self) { minutes in
                Button("\(minutes) 分钟") { player.setTimer(minutes: minutes) }
            }
            if let deadline = player.deadline {
                Divider()
                Text("\(deadline.date.formatted(date: .omitted, time: .shortened)) 停止播放")
            }
        } label: {
            Image(systemName: player.deadline == nil ? "timer" : "timer.circle.fill").font(.system(size: 14))
        }
        .help(player.deadline == nil ? "定时关闭" : "已设置定时关闭")
        .accessibilityLabel(player.deadline == nil ? "定时关闭" : "已设置定时关闭")
    }
}
