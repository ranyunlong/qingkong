import SwiftUI
import WidgetKit
import QingkongCore

struct DumplingEntry: TimelineEntry {
    let date: Date
    let snapshot: ComplicationSnapshot?
}

struct DumplingProvider: TimelineProvider {
    func placeholder(in context: Context) -> DumplingEntry { DumplingEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (DumplingEntry) -> Void) {
        completion(DumplingEntry(date: .now, snapshot: SnapshotStorage.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DumplingEntry>) -> Void) {
        let now = Date.now
        completion(Timeline(entries: [DumplingEntry(date: now, snapshot: SnapshotStorage.load())], policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct DumplingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QingkongDumpling", provider: DumplingProvider()) { entry in
            DumplingWidgetView(entry: entry)
        }
        .configurationDisplayName("心情团子")
        .description("最近记录的心情与健康摘要。点按团子，打开小晴空。")
        #if os(watchOS)
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
        #endif
    }
}

struct DumplingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DumplingEntry
    private var mood: MoodSummary? { entry.snapshot?.mood }
    private var title: String { mood.map { "最近心情 · \($0.label)" } ?? "记下此刻心情" }
    private var accent: Color {
        let hex = entry.snapshot?.preferences.manualScene.hex ?? SceneTheme.clear.hex
        return Color(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    private var sampledAt: Date? { entry.snapshot?.readings.filter { $0.isValid && $0.date <= entry.date }.map(\.date).max() }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                VStack(spacing: 0) {
                    mascot.frame(maxHeight: .infinity)
                    Text("HRV \(value(.hrv))").font(.system(size: 10, weight: .medium, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                }
            case .accessoryInline:
                Label("\(mood?.label ?? "待记录") · HRV \(value(.hrv)) ms", systemImage: "face.smiling")
            case .accessoryRectangular:
                HStack(spacing: 4) {
                    mascot.frame(width: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mood?.label ?? "心情待记录").font(.caption2)
                        HStack(spacing: 5) {
                            compactMetric(.hrv)
                            compactMetric(.heartRate)
                            compactMetric(.oxygen)
                        }
                        sampleTime.font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            case .systemMedium:
                HStack(spacing: 16) {
                    VStack(spacing: 0) {
                        mascot.frame(maxHeight: .infinity)
                        Text(mood?.label ?? "小晴空").font(.caption.weight(.medium)).foregroundStyle(accent)
                    }.frame(width: 90)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(accent)
                        readings
                        sampleTime.font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                VStack(spacing: 5) {
                    HStack {
                        Text("小晴空").font(.caption2).foregroundStyle(accent)
                        Spacer(minLength: 0)
                        Text(mood?.label ?? "待记录").font(.caption2).foregroundStyle(.secondary)
                    }
                    mascot.frame(maxHeight: .infinity)
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(HealthMetric.allCases) { metric in
                            VStack(spacing: 2) {
                                Text(metric.name).font(.system(size: 9)).foregroundStyle(.secondary)
                                Text(value(metric))
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                                Text(metric.unit).font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                            .lineLimit(1).multilineTextAlignment(.center)
                            .frame(minWidth: 0, maxWidth: .infinity)
                        }
                    }
                    sampleTime.font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
        }
        .privacySensitive()
        .containerBackground(for: .widget) {
            #if os(iOS)
            Color(.systemBackground).overlay(accent.opacity(0.07))
            #else
            Color.black
            #endif
        }
        .widgetURL(URL(string: "qingkong://dumpling"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var mascot: some View {
        Image("mood-\(mood?.value ?? 3)").resizable().scaledToFit()
            .widgetAccentable(false)
            .accessibilityHidden(true)
    }
    private var readings: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(HealthMetric.allCases) { metric in
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.name).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(value(metric)).font(.system(size: 18, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.65)
                    Text(metric.unit).font(.system(size: 8)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private var sampleTime: Text {
        if let date = sampledAt { Text("采样 \(date.formatted(.dateTime.month().day().hour().minute()))") }
        else { Text("打开小晴空连接健康") }
    }
    private func compactMetric(_ metric: HealthMetric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.name).font(.system(size: 8)).foregroundStyle(.secondary)
            Text(value(metric)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
    }
    private func reading(_ metric: HealthMetric) -> HealthReading? {
        entry.snapshot?.readings.filter { $0.metric == metric && $0.isValid && $0.date <= entry.date }.max { $0.date < $1.date }
    }
    private func value(_ metric: HealthMetric) -> String {
        reading(metric).map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—"
    }
    private var accessibilitySummary: String {
        let feeling = mood.map { "最近心情\($0.label)，记录于\($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未记录心情"
        return feeling + "。" + HealthMetric.allCases.map { metric in
            reading(metric).map { "\(metric.name) \(value(metric)) \(metric.unit)，采样于\($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? "\(metric.name)暂无数据"
        }.joined(separator: "。") + "。点按打开小晴空"
    }
}
