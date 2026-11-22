import SwiftUI
import QingkongCore

struct WatchDumplingView: View {
    @Environment(AppServices.self) private var app
    private var mood: MoodSummary? { MoodSummary.latest(in: app.store.records) }
    @State private var selectedAction: CompanionAction = .greeting
    @State private var showActions = false
    @State private var replayRequest = 0
    private var actionLibrary = CompanionActionLibrary()
    private var availableActions: [CompanionAction] {
        actionLibrary.actions(moods: app.store.records, practices: app.companion.practices)
    }

    var body: some View {
        GeometryReader { geometry in
            let characterSize = max(60, min(geometry.size.width * 0.95, geometry.size.height - 94))
            VStack(spacing: 0) {
                DumplingGreeting(mood: mood?.value ?? 3, label: mood?.label ?? "心情待记录", action: selectedAction, replayRequest: replayRequest)
                    .frame(width: characterSize, height: characterSize)
                    .offset(y: -8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                HStack(spacing: 8) {
                    Text(mood?.label ?? "心情待记录").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Button { showActions = true } label: { Image(systemName: "hand.wave").font(.system(size: 12)) }
                        .buttonStyle(.plain).accessibilityLabel("团子动作")
                        .accessibilityIdentifier("watch-dumpling-actions")
                }.padding(.top, 2).padding(.bottom, 8)
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
        .sheet(isPresented: $showActions) {
            NavigationStack {
                List {
                    ForEach(availableActions) { action in
                        Button(action.name) {
                            selectedAction = action; replayRequest += 1; showActions = false
                        }
                    }
                    Text("招呼随时都在。主动记下心情或完成陪伴，会多一种轻柔动作。")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("表情与风景收藏") { CompanionCollectionView(actions: availableActions) }
                        .accessibilityIdentifier("open-watch-companion-collection")
                }.navigationTitle("团子动作")
            }
        }
        .onAppear { actionLibrary.remember(availableActions) }
        .onChange(of: availableActions) { _, actions in
            actionLibrary.remember(actions)
            if !actions.contains(selectedAction) { selectedAction = .greeting }
        }
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
