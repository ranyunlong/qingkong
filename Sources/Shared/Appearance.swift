import SwiftUI
import Charts
import QingkongCore
#if os(iOS)
import UIKit
#endif

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
    let metric: HealthMetric
    var color: Color = .primary
    var compact = false
    var period: TrendPeriod = .week
    var selectionEnabled = true
    #if os(iOS)
    @State private var selectedDate: Date?

    private var selectedBucket: TrendBucket? {
        guard let selectedDate else { return nil }
        // Include empty buckets: dragging across a gap must never show a nearby day's value.
        return buckets.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    #endif
    var body: some View {
        let points = buckets.filter { $0.value != nil }
        if points.isEmpty {
            Text("暂无趋势记录").font(compact ? .caption2 : .footnote).foregroundStyle(Color.readableSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("暂无趋势记录")
        } else {
            #if os(iOS)
            if selectionEnabled {
            chart(points)
                .chartOverlay { proxy in
                    HorizontalChartSelection(proxy: proxy, selection: $selectedDate)
                }
                .onChange(of: buckets) { _, _ in selectedDate = nil }
                .onChange(of: metric) { _, _ in selectedDate = nil }
                .accessibilityHint("左右拖动查看时间和\(metric.name)数值，上下拖动滚动页面")
                .accessibilityIdentifier("health-trend-\(metric.rawValue)")
            } else {
                chart(points)
                    .accessibilityIdentifier("health-trend-\(metric.rawValue)")
            }
            #else
            chart(points)
            #endif
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
            #if os(iOS)
            if selectionEnabled, let selected = selectedBucket {
                RuleMark(x: .value("选中时间", selected.date))
                    .foregroundStyle(color.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ChartReadingLabel(
                            heading: period == .day ? selected.date.formatted(.dateTime.month().day().hour()) : selected.date.formatted(.dateTime.month().day()),
                            reading: selected.value.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)" } ?? "暂无记录",
                            color: color
                        )
                    }
                if let value = selected.value {
                    RuleMark(y: .value("选中数值", value))
                        .foregroundStyle(color.opacity(0.3))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("选中时间", selected.date), y: .value("选中数值", value))
                        .foregroundStyle(color)
                        .symbolSize(compact ? 45 : 85)
                }
            }
            #endif
        }
        .chartXScale(domain: (buckets.first?.date ?? .now)...max(buckets.last?.date ?? .now, (buckets.first?.date ?? .now).addingTimeInterval(3600)))
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(compact ? .hidden : .automatic)
        .chartYAxis(compact ? .hidden : .automatic)
        .chartLegend(.hidden)
        .accessibilityLabel("\(metric.name)趋势，\(points.count) 个有效时间段，单位\(metric.unit)")
    }
}

#if os(iOS)
struct HorizontalChartSelection<Value: Plottable>: View {
    let proxy: ChartProxy
    @Binding var selection: Value?

    var body: some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                let plot = geometry[plotFrame]
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(HorizontalChartDrag { location in
                        let x = min(max(location.x - plot.minX, 0), plot.width)
                        selection = proxy.value(atX: x, as: Value.self)
                    } onEnded: {
                        selection = nil
                    })
            }
        }
        .onDisappear { selection = nil }
        .accessibilityHidden(true)
    }
}

struct HorizontalChartDrag: UIGestureRecognizerRepresentable {
    var onChanged: (CGPoint) -> Void
    var onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(context.converter.localLocation)
        case .ended, .cancelled, .failed: onEnded()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            // Reject vertical pans before recognition so the page's scroll view can take them.
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

struct ChartReadingLabel: View {
    let heading: String
    let reading: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(heading).foregroundStyle(Color.readableSecondary)
            Text(reading).fontWeight(.semibold).foregroundStyle(color)
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chart-selected-reading")
    }
}
#endif

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
