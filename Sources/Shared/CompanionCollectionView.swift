import SwiftUI
import QingkongCore

/// Uses the approved body and hands, with two additional, explicitly chosen expressions.
struct CompanionExpressionView: View {
    let expression: CompanionExpression

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 224
            context.translateBy(x: size.width / 2 - 128 * scale, y: size.height / 2 - 128 * scale)
            context.scaleBy(x: scale, y: scale)
            for layer in DumplingArtwork.moods[3] {
                switch layer.part {
                case .eyes, .brows, .mouth, .accent: continue
                default: break
                }
                var drawing = context
                drawing.opacity = layer.opacity
                if let fill = layer.fill { drawing.fill(layer.path, with: fill) }
                if let stroke = layer.stroke {
                    drawing.stroke(layer.path, with: .color(stroke), style: StrokeStyle(lineWidth: layer.width, lineCap: .round, lineJoin: .round))
                }
            }
            let ink = Color(red: 0.349, green: 0.298, blue: 0.282)
            if expression == .gentleSmile {
                let eyes = Path { path in
                    for x in [CGFloat(87), CGFloat(151)] {
                        path.move(to: CGPoint(x: x, y: 132))
                        path.addQuadCurve(to: CGPoint(x: x + 20, y: 132), control: CGPoint(x: x + 10, y: 119))
                    }
                }
                context.stroke(eyes, with: .color(ink), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            } else {
                for x in [CGFloat(89), CGFloat(153)] {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: 121, width: 16, height: 23)), with: .color(ink))
                    context.fill(Path(ellipseIn: CGRect(x: x + 3, y: 124, width: 6, height: 7)), with: .color(.white))
                    context.fill(Path(ellipseIn: CGRect(x: x + 9, y: 135, width: 3, height: 3)), with: .color(.white.opacity(0.85)))
                }
            }
            let smile = Path { path in
                path.move(to: CGPoint(x: 116, y: 154))
                path.addQuadCurve(to: CGPoint(x: 140, y: 154), control: CGPoint(x: 128, y: expression == .gentleSmile ? 168 : 174))
            }
            context.stroke(smile, with: .color(ink), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        }.aspectRatio(1, contentMode: .fit).accessibilityLabel(expression.name + "团子")
    }
}

/// Static, offline artwork. It does not start a rendering timer or alter the app theme.
struct CompanionSceneryView: View {
    let scenery: CompanionScenery

    var body: some View {
        Canvas { context, size in
            let day = scenery == .morningMeadow
            let sky = day ? [Color(red: 0.77, green: 0.90, blue: 0.96), Color(red: 0.99, green: 0.95, blue: 0.83)]
                : [Color(red: 0.12, green: 0.17, blue: 0.32), Color(red: 0.44, green: 0.48, blue: 0.67)]
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let radius = size.width * 0.09
            let light = CGRect(x: size.width * 0.67, y: size.height * 0.13, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: light), with: .color(day ? Color(red: 1, green: 0.88, blue: 0.55) : Color(red: 1, green: 0.96, blue: 0.78)))
            if !day {
                for point in [CGPoint(x: 0.14, y: 0.17), CGPoint(x: 0.36, y: 0.09), CGPoint(x: 0.48, y: 0.27), CGPoint(x: 0.86, y: 0.39)] {
                    context.fill(Path(ellipseIn: CGRect(x: point.x * size.width, y: point.y * size.height, width: 2, height: 2)), with: .color(.white.opacity(0.8)))
                }
            }
            for index in 0..<3 {
                let baseline = size.height * (0.54 + Double(index) * 0.14)
                let hill = Path { path in
                    path.move(to: CGPoint(x: 0, y: baseline))
                    path.addCurve(to: CGPoint(x: size.width, y: baseline + size.height * 0.06),
                                  control1: CGPoint(x: size.width * 0.32, y: baseline - size.height * (index == 1 ? 0.10 : 0.24)),
                                  control2: CGPoint(x: size.width * 0.72, y: baseline + size.height * 0.12))
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.addLine(to: CGPoint(x: 0, y: size.height))
                    path.closeSubpath()
                }
                let colors = day ? [Color(red: 0.65, green: 0.78, blue: 0.64), Color(red: 0.48, green: 0.68, blue: 0.52), Color(red: 0.33, green: 0.55, blue: 0.42)]
                    : [Color(red: 0.27, green: 0.36, blue: 0.49), Color(red: 0.23, green: 0.33, blue: 0.45), Color(red: 0.18, green: 0.29, blue: 0.39)]
                context.fill(hill, with: .color(colors[index]))
            }
            if !day {
                let lake = CGRect(x: -size.width * 0.1, y: size.height * 0.73, width: size.width * 1.2, height: size.height * 0.5)
                context.fill(Path(ellipseIn: lake), with: .color(Color(red: 0.36, green: 0.49, blue: 0.62)))
                for index in 0..<4 {
                    let y = size.height * (0.80 + Double(index) * 0.04)
                    let width = size.width * (0.05 + Double(index) * 0.025)
                    let line = Path { path in
                        path.move(to: CGPoint(x: size.width * 0.76 - width, y: y))
                        path.addLine(to: CGPoint(x: size.width * 0.76 + width, y: y))
                    }
                    context.stroke(line, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }.accessibilityLabel(scenery.name)
    }
}

struct CompanionCollectionView: View {
    let actions: [CompanionAction]

    var body: some View {
        let collection = CompanionCollectionAvailability(actions: actions)
        List {
            Section {
                Text("新的表情和风景会记住你照顾自己的时刻。没有连续打卡，也不会因为删除记录而收回。")
                    .font(.footnote)
            }
            ForEach(CompanionScenery.allCases) { scenery in
                CompanionCollectionSection(scenery: scenery, unlocked: collection.scenery.contains(scenery))
            }
        }.navigationTitle("表情与风景")
    }
}

private struct CompanionCollectionSection: View {
    let scenery: CompanionScenery
    let unlocked: Bool
    private var expression: CompanionExpression { scenery == .morningMeadow ? .gentleSmile : .brightEyes }
    private var explanation: String {
        if unlocked { return "已解锁，可随时欣赏。" }
        return scenery.requiredAction == .nod ? "记下过一次心情后可用，任何心情都可以。" : "完成过一次放松陪伴后可用，不要求记录感受。"
    }
    private var imageDescription: String {
        scenery.name + "，" + expression.name + "，" + (unlocked ? "已解锁" : "等待解锁")
    }

    var body: some View {
        Section(scenery.name + " · " + expression.name) {
            ZStack {
                CompanionSceneryView(scenery: scenery)
                CompanionExpressionView(expression: expression).padding(20)
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .saturation(unlocked ? 1 : 0)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(imageDescription)
            Text(explanation).font(.footnote)
            #if os(iOS)
            if unlocked { Text("可以在心情明信片中选择这组画面。").font(.footnote).foregroundStyle(.secondary) }
            #endif
        }
    }
}
