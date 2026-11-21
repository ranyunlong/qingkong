import SwiftUI
import QingkongCore

struct WatchDumplingView: View {
    @Environment(AppServices.self) private var app
    private var mood: MoodSummary? { MoodSummary.latest(in: app.store.records) }

    var body: some View {
        GeometryReader { geometry in
            let characterSize = max(60, min(geometry.size.width * 0.95, geometry.size.height - 94))
            VStack(spacing: 0) {
                DumplingGreeting(mood: mood?.value ?? 3, label: mood?.label ?? "心情待记录")
                    .frame(width: characterSize, height: characterSize)
                    .offset(y: -8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Text(mood?.label ?? "心情待记录")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.top, 2).padding(.bottom, 8)
                HStack(spacing: 0) {
                    ForEach(HealthMetric.allCases) { metric in
                        NavigationLink(value: WatchRoute.trend(metric)) {
                            metricReading(metric)
                        }.buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                if app.health.isDemo {
                    Text("演示健康数据").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 22)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(edges: .bottom)
        .background(.black)
        .navigationTitle("")
        .accessibilityIdentifier("watch-dumpling-page")
    }

    private func metricReading(_ metric: HealthMetric) -> some View {
        let reading = app.health.latest(metric)
        return VStack(spacing: 2) {
            Label(metric.name, systemImage: metric.symbol).font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(reading.map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                .font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6)
            Text(metric.unit).font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.name)，\(reading.map { "\($0.value.formatted(.number.precision(.fractionLength(0)))) \(metric.unit)，采样于\($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? "暂无数据")，点按查看趋势")
    }
}
