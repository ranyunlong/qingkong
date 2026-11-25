import AppKit
import SwiftUI
import QingkongCore

struct MacMenuBarPlayer: View {
    @Bindable var player: MacAudioPlayer
    let library: MacLibrary
    let connection: MacDeviceConnection
    @Environment(\.openWindow) private var openWindow
    @State private var scrubPosition: Double?
    @State private var isScrubbing = false

    private var controlsDisabled: Bool { connection.isTransferring || player.isPreparing || !player.controlsAvailable }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                MacArtworkView(item: player.currentItem).frame(width: 62, height: 62)
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.hasSelection ? player.title : "小晴空").font(.headline).lineLimit(2)
                    Text(player.isPhonePlayback ? player.subtitle : (player.controlledSessionID == nil ? "音乐" : "iPhone 接力"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 3) {
                Slider(value: Binding(get: { scrubPosition ?? player.position }, set: { scrubPosition = $0 }),
                       in: 0...max(1, player.duration), onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing { scrubPosition = player.position }
                    else if let target = scrubPosition {
                        Task {
                            await player.seek(to: target)
                            if !isScrubbing { scrubPosition = nil }
                        }
                    }
                })
                .controlSize(.small).accessibilityLabel("播放进度")
                .disabled(!player.hasSelection || player.isBuffering || controlsDisabled)
                HStack {
                    ZStack {
                        if player.isBuffering || connection.isTransferring { ProgressView().controlSize(.mini) }
                    }.frame(width: 10, height: 10)
                    Text(macPlaybackClock(scrubPosition ?? player.position))
                    Spacer()
                    Text(macPlaybackClock(player.duration))
                }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 22) {
                Menu {
                    ForEach(AudioPlaybackMode.allCases, id: \.self) { mode in
                        Button { player.setMode(mode) } label: {
                            Label(mode.title, systemImage: mode == player.mode ? "checkmark" : mode.symbol)
                        }
                    }
                } label: { Image(systemName: player.mode.symbol) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("循环方式：\(player.mode.title)")
                Button { Task { await player.previous() } } label: { Image(systemName: "backward.end.fill") }
                    .accessibilityLabel("上一曲").disabled(!player.hasSelection)
                Button { library.togglePlayback(player: player) } label: {
                    Image(systemName: player.playbackIntent ? "pause.fill" : "play.fill")
                        .font(.system(size: 25, weight: .semibold)).frame(width: 30, height: 32)
                }
                .accessibilityLabel(player.playbackIntent ? "暂停" : "播放")
                .disabled(!player.hasSelection && library.playableAlbums.isEmpty && !library.showsPortableAlbum)
                Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill") }
                    .accessibilityLabel("下一曲").disabled(!player.hasSelection)
                Menu {
                    Button("关闭定时") { player.setTimer(minutes: 0) }
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button("\(minutes) 分钟") { player.setTimer(minutes: minutes) }
                    }
                } label: { Image(systemName: player.deadline == nil ? "timer" : "timer.circle.fill") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("定时关闭")
            }
            .buttonStyle(.plain).font(.system(size: 16)).disabled(controlsDisabled)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).controlSize(.small).accessibilityLabel("音量")
                    .disabled(player.isPhonePlayback)
                    .help(player.isPhonePlayback ? "在 iPhone 或 Apple Watch 调整 AirPlay 音量" : "音量")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }.font(.caption).disabled(controlsDisabled)
            if let deadline = player.deadline {
                Text("\(deadline.date.formatted(date: .omitted, time: .shortened)) 停止播放")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = player.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            HStack {
                Button("打开小晴空", systemImage: "arrow.up.forward.square") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.help("设置")
            }.font(.caption).buttonStyle(.borderless)
        }
        .padding(20).frame(width: 320)
        .onChange(of: player.currentItem?.id) { _, _ in scrubPosition = nil; isScrubbing = false }
    }
}
