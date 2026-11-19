import SwiftUI
import MediaPlayer
import QingkongCore

struct SleepView: View {
    @Environment(AppServices.self) private var app
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageIntro(eyebrow: "属于你的安静时刻", title: "把今天，\n轻轻放下来。", subtitle: "一段自然声音，陪你慢慢休息。")
                Image(app.player.state.track.image).resizable().scaledToFill().frame(height: 225).clipped().clipShape(RoundedRectangle(cornerRadius: 28)).accessibilityHidden(true)
                VStack(spacing: 12) {
                    Text(app.player.state.track.name).font(.title2.weight(.semibold)).accessibilityIdentifier("current-track-title")
                    Text("\(app.player.state.track.subtitle) · 离线可用").font(.subheadline).foregroundStyle(Color.readableSecondary)
                    GlassButtonGroup {
                      HStack(spacing: 16) {
                        Button { Task { await app.player.skip(-1) } } label: {
                            Image(systemName: "backward.end.fill").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        }.qingkongGlassButton(shape: .circle).accessibilityLabel("上一首").accessibilityIdentifier("player-previous")
                        Button { Task { await app.player.toggle() } } label: {
                            Image(systemName: app.player.state.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 64, height: 64)
                        }.qingkongGlassButton(prominent: true, shape: .circle)
                            .disabled(app.player.activating).accessibilityLabel(app.player.state.playing ? "暂停播放" : "开始播放").accessibilityIdentifier("player-toggle")
                        Button { Task { await app.player.skip(1) } } label: {
                            Image(systemName: "forward.end.fill").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        }.qingkongGlassButton(shape: .circle).accessibilityLabel("下一首").accessibilityIdentifier("player-next")
                      }
                    }.padding(.vertical, 8)
                    if let error = app.player.error { Text(error).font(.footnote).foregroundStyle(Color.readableSecondary) }
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                        SystemVolumeControl(tint: app.scene.accent).frame(maxWidth: .infinity).frame(height: 44)
                        Image(systemName: "speaker.wave.3.fill")
                    }.foregroundStyle(Color.readableSecondary)
                }.frame(maxWidth: .infinity)
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
                        } else { Text("循环播放，可随时暂停。 ").font(.caption).foregroundStyle(Color.readableSecondary) }
                    }
                }
                GlassButtonGroup {
                  VStack(alignment: .leading, spacing: 12) {
                    Text("为你准备的自然声音").font(.headline).padding(.bottom, 12)
                    ForEach(Track.allCases) { track in
                        Button { Task { await app.player.select(track, autoplay: true) } } label: {
                            HStack(spacing: 14) {
                                Image(track.image).resizable().scaledToFill().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 5) { Text(track.name).font(.subheadline.weight(.medium)); Text(track.subtitle).font(.caption).foregroundStyle(Color.readableSecondary) }
                                Spacer()
                                Image(systemName: app.player.state.track == track && app.player.state.playing ? "waveform" : "play.circle").foregroundStyle(app.scene.accent)
                            }.padding(.vertical, 12).contentShape(Rectangle())
                        }.qingkongGlassButton(shape: .roundedRectangle(radius: 20)).accessibilityIdentifier("track-\(track.id)")
                    }
                  }
                }
                #if DEBUG
                Text("开发预览音频 · 正式发布前将替换为完整音源。 ").font(.caption).foregroundStyle(Color.readableSecondary)
                #endif
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }
    }

    private func countdown(_ deadline: SleepDeadline, at date: Date) -> String {
        let seconds = Int(ceil(deadline.remaining(at: date)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
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
