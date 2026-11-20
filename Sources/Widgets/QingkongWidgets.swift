import AppIntents
import SwiftUI
import WidgetKit
import QingkongCore

enum WidgetMetric: String, AppEnum {
    case followPhone, hrv, heartRate, oxygen
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "健康指标"
    static var caseDisplayRepresentations: [WidgetMetric: DisplayRepresentation] = [
        .followPhone: "跟随 iPhone 配置", .hrv: "HRV", .heartRate: "心率", .oxygen: "血氧"
    ]
    func resolve(_ preferences: Preferences) -> HealthMetric {
        switch self {
        case .followPhone: preferences.complicationMetric
        case .hrv: .hrv
        case .heartRate: .heartRate
        case .oxygen: .oxygen
        }
    }
}

struct MetricIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "晴空健康组件"
    static var description = IntentDescription("抬腕查看健康摘要，点按进入趋势。")
    @Parameter(title: "显示指标", default: .followPhone) var metric: WidgetMetric
    @Parameter(title: "显示迷你趋势", default: true) var showTrend: Bool
}

struct MetricEntry: TimelineEntry {
    let date: Date
    let snapshot: ComplicationSnapshot?
    let configuration: MetricIntent
}

struct MetricProvider: AppIntentTimelineProvider {
    func recommendations() -> [AppIntentRecommendation<MetricIntent>] {
        WidgetMetric.allCasesForRecommendations.map { metric in
            let intent = MetricIntent()
            intent.metric = metric
            return AppIntentRecommendation(intent: intent, description: metric == .followPhone ? "跟随 iPhone 配置" : metric.resolve(Preferences()).name)
        }
    }
    func placeholder(in context: Context) -> MetricEntry { MetricEntry(date: .now, snapshot: nil, configuration: MetricIntent()) }
    func snapshot(for configuration: MetricIntent, in context: Context) async -> MetricEntry {
        MetricEntry(date: .now, snapshot: SnapshotStorage.load(), configuration: configuration)
    }
    func timeline(for configuration: MetricIntent, in context: Context) async -> Timeline<MetricEntry> {
        let now = Date.now
        let entry = MetricEntry(date: now, snapshot: SnapshotStorage.load(), configuration: configuration)
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60)))
    }
}

private extension WidgetMetric {
    static var allCasesForRecommendations: [WidgetMetric] { [.followPhone, .hrv, .heartRate, .oxygen] }
}

struct MetricWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MetricEntry
    private var preferences: Preferences { entry.snapshot?.preferences ?? Preferences() }
    private var metric: HealthMetric { entry.configuration.metric.resolve(preferences) }
    private var reading: HealthReading? { entry.snapshot?.readings.first { $0.metric == metric } }
    var body: some View {
        Group {
            if family == .accessoryInline {
                Label("\(value) \(metric.unit)", systemImage: metric.symbol)
            } else if family == .accessoryCircular {
                VStack(spacing: 2) {
                    Image(systemName: metric.symbol).font(.caption2)
                    Text(value).font(.system(.title3, design: .rounded).weight(.medium)).minimumScaleFactor(0.6)
                    Text(reading.map { Calendar.current.isDate($0.date, inSameDayAs: entry.date) ? $0.date.formatted(.dateTime.hour().minute()) : $0.date.formatted(.dateTime.month().day()) } ?? "打开晴空").font(.system(size: 8))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Label(metric.name, systemImage: metric.symbol).font(.caption2)
                        Spacer(minLength: 0)
                        Text(value).font(.system(.headline, design: .rounded))
                        Text(metric.unit).font(.system(size: 9))
                    }
                    if entry.configuration.showTrend && preferences.showComplicationTrend {
                        HealthTrendChart(buckets: entry.snapshot?.trends[metric] ?? [], metric: metric, color: .primary, compact: true).frame(height: 20)
                    }
                    if let reading {
                        Text("采样 \(reading.date.formatted(.dateTime.month().day().hour().minute()))").font(.system(size: 9)).foregroundStyle(.secondary)
                    } else { Text("打开晴空，连接健康记录").font(.system(size: 9)) }
                }
            }
        }.privacySensitive()
            .containerBackground(.black, for: .widget)
            .widgetURL(URL(string: "qingkong://trend/\(metric.rawValue)"))
            .accessibilityLabel("\(metric.name)，\(reading == nil ? "暂无数据" : "\(value) \(metric.unit)")，\(reading.map { "采样于" + $0.date.formatted(date: .complete, time: .shortened) } ?? "打开晴空连接健康")，点按查看趋势")
    }
    private var value: String { reading.map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—" }
}

@main
struct QingkongWidgets: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QingkongMetric", intent: MetricIntent.self, provider: MetricProvider()) { entry in MetricWidgetView(entry: entry) }
            .configurationDisplayName("晴空健康")
            .description("查看最近健康记录与变化，点按打开趋势。")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
