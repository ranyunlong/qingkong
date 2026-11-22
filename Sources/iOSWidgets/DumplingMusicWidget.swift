import SwiftUI
import WidgetKit
import QingkongCore

struct DumplingMusicEntry: TimelineEntry {
    let date: Date
    let audio: WidgetAudioSnapshot?
    let mood: Int
}

struct DumplingMusicProvider: TimelineProvider {
    func placeholder(in context: Context) -> DumplingMusicEntry {
        DumplingMusicEntry(date: .now, audio: nil, mood: 3)
    }
    func getSnapshot(in context: Context, completion: @escaping (DumplingMusicEntry) -> Void) {
        completion(entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DumplingMusicEntry>) -> Void) {
        let current = entry()
        completion(Timeline(entries: [current], policy: .after(current.date.addingTimeInterval(30 * 60))))
    }
    private func entry() -> DumplingMusicEntry {
        DumplingMusicEntry(date: .now, audio: WidgetAudioStorage.load(), mood: SnapshotStorage.load()?.mood?.value ?? 3)
    }
}

struct DumplingMusicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetAudioStorage.kind, provider: DumplingMusicProvider()) { entry in
            DumplingMusicWidgetView(entry: entry)
        }
        .configurationDisplayName("团子音乐")
        .description("让团子陪你听歌，直接播放、暂停或切换歌曲。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DumplingMusicWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DumplingMusicEntry
    private var active: Bool { entry.audio?.playing == true || entry.audio?.buffering == true }
    private var title: String { entry.audio?.title ?? Track.rain.name }

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 16) {
                    mascot.frame(width: 92)
                    VStack(alignment: .leading, spacing: 10) {
                        song
                        controls
                    }
                }
            } else {
                VStack(spacing: 3) {
                    mascot.frame(maxHeight: .infinity)
                    song
                    controls
                }
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemBackground).overlay(Color(red: 0.30, green: 0.57, blue: 0.75).opacity(0.08))
        }
        .widgetURL(URL(string: "qingkong://music"))
    }

    private var mascot: some View {
        Link(destination: URL(string: "qingkong://music")!) {
            Image("mood-\(entry.mood)").resizable().scaledToFit()
                .widgetAccentable(false)
        }.privacySensitive().accessibilityLabel("打开小晴空播放器")
    }

    private var song: some View {
        Link(destination: URL(string: "qingkong://music")!) {
            VStack(alignment: family == .systemMedium ? .leading : .center, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(entry.audio?.buffering == true ? "正在加载…" : active ? "正在播放" : "点按播放")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: family == .systemMedium ? .leading : .center)
        }.buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 0) {
            control(.previous, title: "上一首", symbol: "backward.end.fill")
            control(active ? .pause : .play, title: active ? "暂停" : "播放", symbol: active ? "pause.fill" : "play.fill")
            control(.next, title: "下一首", symbol: "forward.end.fill")
        }.buttonStyle(.plain)
    }

    private func control(_ action: WidgetAudioAction, title: String, symbol: String) -> some View {
        Button(intent: MusicPlaybackIntent(action: action)) {
            Image(systemName: symbol)
                .font(.system(size: action == .play || action == .pause ? 19 : 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}
