import SwiftUI
import QingkongCore

struct MacQueueView: View {
    let player: MacAudioPlayer
    let isTransferring: Bool
    @State private var selection: Int?
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("播放队列").font(.headline)
                Spacer()
                Text("\(player.queueItems.count) 首").font(.caption).foregroundStyle(.secondary)
            }.padding()
            if player.queueItems.isEmpty {
                ContentUnavailableView("队列为空", systemImage: "music.note.list", description: Text("选择专辑播放，或从 iPhone 接续。"))
            } else {
                List(selection: $selection) {
                    ForEach(Array(player.queueItems.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 10) {
                            MacArtworkView(item: item, cornerRadius: 5).frame(width: 38, height: 38)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.callout.weight(index == player.currentIndex ? .semibold : .regular)).lineLimit(2)
                                Text(item.track?.subtitle ?? "在线音轨").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            if index == player.currentIndex {
                                Image(systemName: player.playbackIntent ? "speaker.wave.2.fill" : "pause.fill")
                                    .font(.caption)
                                    .foregroundStyle(appearsActive && selection == index ? Color.white : Color.accentColor)
                                    .accessibilityLabel(player.playbackIntent ? "正在播放" : "当前曲目")
                            }
                        }
                        .padding(.vertical, 5)
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .tag(index)
                        .onTapGesture { selection = index; play(index) }
                        .contextMenu { Button("播放", systemImage: "play.fill") { play(index) }.disabled(isTransferring || !player.controlsAvailable) }
                        .accessibilityAction(named: "播放") { play(index) }
                    }
                }
                .listStyle(.inset)
                .onChange(of: player.currentIndex, initial: true) { _, index in selection = index }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func play(_ index: Int) {
        guard !isTransferring, player.controlsAvailable else { return }
        player.playQueueItem(at: index, playing: true)
    }
}
