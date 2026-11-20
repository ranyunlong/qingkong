import SwiftUI
import QingkongCore

/// Native layered paths. Only the face and hands act; the body stays grounded.
struct DumplingArtworkView: View {
    let mood: Int
    var progress: Double = 0

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 224
            context.translateBy(x: size.width / 2 - 128 * scale, y: size.height / 2 - 128 * scale)
            context.scaleBy(x: scale, y: scale)
            let breath = sin(progress * .pi)
            for layer in DumplingArtwork.moods[min(5, max(1, mood)) - 1] {
                var drawing = context
                drawing.opacity = layer.opacity
                if layer.part != .accent && layer.part != .shadow {
                    transform(&drawing, origin: CGPoint(x: 128, y: 209), scaleY: 1 + breath * 0.015)
                    if mood == 3 { drawing.translateBy(x: 0, y: -4 * breath) }
                }
                animate(layer.part, in: &drawing)
                if let fill = layer.fill { drawing.fill(layer.path, with: fill) }
                if let stroke = layer.stroke {
                    drawing.stroke(layer.path, with: .color(stroke), style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }

    private func pulse(_ start: Double, _ end: Double) -> Double {
        guard progress > start, progress < end else { return 0 }
        return sin((progress - start) / (end - start) * .pi)
    }

    private func transform(_ context: inout GraphicsContext, origin: CGPoint, scaleX: Double = 1, scaleY: Double = 1, rotation: Double = 0) {
        context.translateBy(x: origin.x, y: origin.y)
        context.rotate(by: .degrees(rotation))
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -origin.x, y: -origin.y)
    }

    private func animate(_ part: DumplingArtwork.Part, in context: inout GraphicsContext) {
        switch part {
        case .eyes:
            let blink = pulse(0.18, 0.32)
            let squeeze = mood == 2 ? pulse(0.12, 0.8) * 0.7 : blink * 0.92
            transform(&context, origin: CGPoint(x: 128, y: 131), scaleY: 1 - squeeze)
            if mood == 1 { context.translateBy(x: pulse(0.3, 0.85) * 2, y: pulse(0.3, 0.85) * 2) }
        case .mouth:
            let expression = pulse(0.14, 0.85)
            let stretch: Double
            if mood == 2 { stretch = 1 + expression * 0.85 }
            else if mood == 5 { stretch = 1 + sin(progress * .pi * 6) * expression * 0.2 }
            else if mood == 1 { stretch = 1 - expression * 0.4 }
            else { stretch = 1 + expression * 0.18 }
            transform(&context, origin: CGPoint(x: 128, y: 158), scaleY: stretch)
        case .brows:
            transform(&context, origin: CGPoint(x: 128, y: 113), rotation: -3 * pulse(0.2, 0.8))
        case .leftHand, .rightHand:
            let wave = sin(progress * .pi * 6) * pulse(0.12, 0.9)
            let direction: Double = part == .leftHand ? 1 : -1
            transform(&context, origin: CGPoint(x: part == .leftHand ? 63 : 193, y: 156), rotation: direction * wave * (mood == 5 ? 15 : 12))
        case .hands:
            if mood == 2 { transform(&context, origin: CGPoint(x: 174, y: 171), rotation: 7 * pulse(0.14, 0.85)) }
            if mood == 3 { transform(&context, origin: CGPoint(x: 128, y: 151), rotation: 2 * sin(progress * .pi * 2)) }
        case .accent, .tear:
            context.opacity *= 0.7 + 0.3 * pulse(0, 1)
        default: break
        }
    }
}

struct DumplingGreeting: View {
    let mood: Int
    let label: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var lowLuminance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var playbackID = UUID()

    var body: some View {
        GeometryReader { geometry in
            Button(action: play) {
                TimelineView(.animation(minimumInterval: 1.0 / 24, paused: startedAt == nil)) { context in
                    DumplingArtworkView(mood: mood, progress: startedAt.map { DumplingMotion.progress(elapsed: context.date.timeIntervalSince($0)) } ?? 0)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .buttonStyle(.plain)
        }
        .accessibilityLabel("\(label)团子")
        .accessibilityHint(reduceMotion ? "已跟随系统减少动态效果" : "点按再播放一次表情动作")
        .accessibilityValue(startedAt == nil ? "静止" : "播放中")
        .accessibilityIdentifier("watch-dumpling-character")
        .onAppear(perform: play)
        .onChange(of: scenePhase) { _, phase in if phase == .active { play() } else { stop() } }
        .onChange(of: lowLuminance) { _, reduced in if reduced { stop() } else { play() } }
        .onChange(of: reduceMotion) { _, reduced in if reduced { stop() } }
        .onChange(of: mood) { _, _ in play() }
        .onDisappear(perform: stop)
        .task(id: playbackID) {
            guard startedAt != nil else { return }
            do { try await Task.sleep(for: .seconds(DumplingMotion.duration)) } catch { return }
            startedAt = nil
        }
    }

    private func play() {
        guard scenePhase == .active, !lowLuminance, !reduceMotion else { stop(); return }
        startedAt = .now
        playbackID = UUID()
    }
    private func stop() { startedAt = nil; playbackID = UUID() }
}
