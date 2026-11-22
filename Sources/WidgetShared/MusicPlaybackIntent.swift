#if os(iOS)
import AppIntents

enum WidgetAudioAction: String, AppEnum {
    case play, pause, previous, next
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "音乐操作"
    static var caseDisplayRepresentations: [WidgetAudioAction: DisplayRepresentation] = [
        .play: "播放", .pause: "暂停", .previous: "上一首", .next: "下一首"
    ]
}

// Both targets declare the same intent. AudioPlaybackIntent runs in the app's
// process, where it can operate the existing player while the app is backgrounded.
struct MusicPlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "控制小晴空音乐"
    static var description = IntentDescription("控制小晴空当前音乐的播放、暂停和切歌。")
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "音乐操作", default: .play) var action: WidgetAudioAction

    init() {}
    init(action: WidgetAudioAction) { self.action = action }
}
#endif
