import SwiftUI

/// The approved character breathes through its arms and expression, with a fixed body outline.
struct BreathingDumplingView: View {
    var breath: Double
    var exhale: Double = 0
    var exhaleProgress: Double = 0

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 224
            context.translateBy(x: size.width / 2 - 128 * scale, y: size.height / 2 - 128 * scale)
            context.scaleBy(x: scale, y: scale)
            for layer in DumplingArtwork.moods[2] {
                var drawing = context
                var path = layer.path
                drawing.opacity = layer.opacity
                switch layer.part {
                case .hands, .leftHand, .rightHand:
                    // This mood groups the sprig with its hands; draw only the arms below.
                    continue
                case .eyes, .brows, .cheek:
                    drawing.translateBy(x: 0, y: -4 * breath)
                case .mouth:
                    path = breathingMouth()
                    drawing.translateBy(x: 0, y: -4 * breath)
                default:
                    break
                }
                if let fill = layer.fill { drawing.fill(path, with: fill) }
                if let stroke = layer.stroke {
                    drawing.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }
            context.stroke(breathingArms(), with: .color(Color(.sRGB, red: 0.34902, green: 0.29804, blue: 0.28235, opacity: 1)),
                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            drawExhale(in: context)
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }

    private func breathingArms() -> Path {
        Path { result in
            result.move(to: CGPoint(x: 64, y: 157 - 3 * breath))
            result.addQuadCurve(to: CGPoint(x: 100, y: 177 - 16 * breath),
                                control: CGPoint(x: 81, y: 171 - 12 * breath))
            result.move(to: CGPoint(x: 192, y: 157 - 3 * breath))
            result.addQuadCurve(to: CGPoint(x: 156, y: 177 - 16 * breath),
                                control: CGPoint(x: 175, y: 171 - 12 * breath))
        }
    }

    private func breathingMouth() -> Path {
        let left = CGPoint(x: 117 + 6.6 * exhale, y: 152)
        let right = CGPoint(x: 139 - 6.6 * exhale, y: 152)
        return Path { result in
            result.move(to: left)
            result.addQuadCurve(to: right, control: CGPoint(x: 128, y: 163))
            result.addQuadCurve(to: left, control: CGPoint(x: 128, y: 163 - 25 * exhale))
        }
    }

    private func drawExhale(in context: GraphicsContext) {
        guard exhale > 0 else { return }
        let color = Color(.sRGB, red: 0.45, green: 0.59, blue: 0.48, opacity: 1)
        for index in 0..<3 {
            let progress = (exhaleProgress * 2.5 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let x = 141 + 48 * progress
            let y = 153 - 4 * breath + Double(index - 1) * 8
            let length = 14 + 16 * progress
            let air = Path { result in
                result.move(to: CGPoint(x: x, y: y))
                result.addCurve(to: CGPoint(x: x + length, y: y - 3),
                                control1: CGPoint(x: x + length * 0.4, y: y - 5),
                                control2: CGPoint(x: x + length * 0.6, y: y + 2))
            }
            var drawing = context
            drawing.opacity = exhale * sin(.pi * progress) * 0.75
            drawing.stroke(air, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

/// Gentle eye contact, an occasional blink, head tilt and small wave for quiet company.
struct QuietCompanionDumplingView: View {
    var elapsed: TimeInterval
    var isWaiting = false

    var body: some View {
        let time = elapsed.truncatingRemainder(dividingBy: 12)
        let blink = max(pulse(time, start: 2, duration: 0.3), pulse(time, start: 8, duration: 0.3))
        let tilt = isWaiting ? 0 : 3 * pulse(time, start: 4, duration: 3)
        let wave = isWaiting ? 0 : 8 * sin((time - 0.5) / 2 * .pi * 4) * pulse(time, start: 0.5, duration: 2)
        Canvas { context, size in
            let scale = min(size.width, size.height) / 224
            context.translateBy(x: size.width / 2 - 128 * scale, y: size.height / 2 - 128 * scale)
            context.scaleBy(x: scale, y: scale)
            for layer in DumplingArtwork.moods[3] {
                var drawing = context
                drawing.opacity = layer.opacity
                let grounded = layer.part == .shadow || layer.part == .accent || (layer.part == .body && layer.path.boundingRect.minY >= 190)
                if !grounded {
                    drawing.translateBy(x: 128, y: 207)
                    drawing.rotate(by: .degrees(tilt))
                    drawing.translateBy(x: -128, y: -207)
                }
                if layer.part == .eyes {
                    drawing.translateBy(x: 128, y: 129)
                    drawing.scaleBy(x: 1, y: 1 - 0.94 * blink)
                    drawing.translateBy(x: -128, y: -129)
                } else if layer.part == .leftHand || layer.part == .hands {
                    drawing.translateBy(x: 63, y: 158)
                    drawing.rotate(by: .degrees(wave))
                    drawing.translateBy(x: -63, y: -158)
                }
                if let fill = layer.fill { drawing.fill(layer.path, with: fill) }
                if let stroke = layer.stroke {
                    drawing.stroke(layer.path, with: .color(stroke), style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }

    private func pulse(_ time: TimeInterval, start: TimeInterval, duration: TimeInterval) -> Double {
        guard time > start, time < start + duration else { return 0 }
        return pow(sin((time - start) / duration * .pi), 2)
    }
}
