import SwiftUI

@main
struct ECGFixtureApp: App {
    private let points = (0...15360).map { i in
        let t = Double(i) / 512
        let phase = t.truncatingRemainder(dividingBy: 0.85)
        let voltage = 0.05 * sin(t * 12) + exp(-pow((phase - 0.3) / 0.018, 2)) - 0.2 * exp(-pow((phase - 0.34) / 0.025, 2))
        return VoltagePoint(seconds: t, millivolts: voltage)
    }
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("演示波形 · 仅用于交互验证").font(.headline)
                        Text("30 秒合成波形，不是健康记录").font(.subheadline)
                        ECGWaveformChart(points: points, color: .blue)
                        Text("左右浏览完整记录，上下滚动页面。")
                        ForEach(0..<12) { i in
                            LabeledContent("交互验收 \(i + 1)", value: "演示")
                                .frame(height: 60)
                        }
                    }.padding(22)
                }.navigationTitle("心电图交互验证")
            }
        }
    }
}
