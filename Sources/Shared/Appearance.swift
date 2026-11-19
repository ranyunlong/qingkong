import SwiftUI
import Charts
import QingkongCore

extension Color {
    static var readableSecondary: Color { Color.primary.opacity(0.72) }
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

extension SceneTheme {
    var accent: Color {
        #if os(iOS)
        Color("Accent-\(rawValue)")
        #else
        Color(hex: hex)
        #endif
    }
}

struct HealthTrendChart: View {
    let buckets: [TrendBucket]
    var color: Color = .primary
    var compact = false
    var body: some View {
        let points = buckets.filter { $0.value != nil }
        if points.isEmpty {
            Text("暂无趋势记录").font(compact ? .caption2 : .footnote).foregroundStyle(Color.readableSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("暂无趋势记录")
        } else {
            chart(points)
        }
    }
    private func chart(_ points: [TrendBucket]) -> some View {
        Chart {
            ForEach(points) { point in
                if let value = point.value {
                    LineMark(x: .value("时间", point.date), y: .value("数值", value), series: .value("连续记录", point.segment))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: compact ? 1.7 : 2.5, lineCap: .round))
                        .interpolationMethod(.linear)
                    PointMark(x: .value("时间", point.date), y: .value("数值", value))
                        .foregroundStyle(color)
                        .symbolSize(compact ? 9 : 24)
                }
            }
        }
        .chartXScale(domain: (buckets.first?.date ?? .now)...max(buckets.last?.date ?? .now, (buckets.first?.date ?? .now).addingTimeInterval(3600)))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartLegend(.hidden)
        .accessibilityLabel("健康趋势，\(points.count) 个有效时间段")
    }
}

struct RecoveryView: View {
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
            Text("暂时无法打开本地记录").font(.headline)
            Text("你的记录不会被自动清除，请稍后重试。").font(.footnote).foregroundStyle(Color.readableSecondary).multilineTextAlignment(.center)
            Button("重试", action: retry).buttonStyle(.borderedProminent)
        }.padding()
    }
}
