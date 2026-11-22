import SwiftUI
import QingkongCore

@main
struct QingkongWatchApp: App {
    @State private var services: AppServices? = try? AppServices()
    var body: some Scene {
        WindowGroup {
            Group {
                if let services { WatchRootView().environment(services) }
                else { RecoveryView(retry: initialize) }
            }.tint(.white)
        }
    }
    private func initialize() { services = try? AppServices() }
}

enum WatchRoute: Hashable { case trend(HealthMetric), mood, music, setup, dumpling, relaxation, relaxationSettings, companionHistory }

struct WatchRootView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [WatchRoute] = []
    var body: some View {
        NavigationStack(path: $path) {
            List {
                HStack(spacing: 0) {
                    Button { path.append(.relaxation) } label: {
                        Label("陪我缓一缓", systemImage: "leaf")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }.accessibilityIdentifier("open-watch-relaxation")
                    Button { path.append(.relaxationSettings) } label: {
                        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("陪伴设置").accessibilityIdentifier("open-watch-relaxation-settings")
                }.buttonStyle(.plain)
                NavigationLink(value: WatchRoute.dumpling) {
                    HStack(spacing: 8) {
                        Image("mood-\(MoodSummary.latest(in: app.store.records)?.value ?? 3)")
                            .resizable().scaledToFit().frame(width: 40, height: 40)
                        Text("心情团子")
                    }
                }.accessibilityIdentifier("open-watch-dumpling")
                if app.health.isDemo { Text("演示健康数据").font(.caption2) }
                ForEach(HealthMetric.allCases) { metric in
                    NavigationLink(value: WatchRoute.trend(metric)) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(metric.name, systemImage: metric.symbol).font(.caption)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(app.health.latest(metric).map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—").font(.system(.title2, design: .rounded).weight(.medium))
                                Text(metric.unit).font(.caption2).foregroundStyle(.secondary)
                            }
                            if app.health.latest(metric) != nil {
                                HealthTrendChart(buckets: HealthMath.buckets(app.health.readings, metric: metric, period: .week), metric: metric, color: .white, compact: true)
                                    .frame(height: 28)
                                    .padding(.horizontal, 6).padding(.vertical, 6)
                            }
                        }.padding(.horizontal, 6).padding(.vertical, 8)
                    }
                }
                NavigationLink(value: WatchRoute.mood) { Label("记下此刻", systemImage: "face.smiling") }
                NavigationLink(value: WatchRoute.music) { Label("听听自然", systemImage: "moon") }
                NavigationLink { WatchAudioLibraryView() } label: { Label("手表曲库与下载", systemImage: "arrow.down.circle") }
                NavigationLink(value: WatchRoute.companionHistory) { Label("陪伴回顾", systemImage: "clock") }
                NavigationLink(value: WatchRoute.setup) { Label("连接与设置", systemImage: "gearshape") }
            }.navigationTitle("小晴空")
                .navigationDestination(for: WatchRoute.self) { route in
                    switch route {
                    case .dumpling: WatchDumplingView()
                    case .trend(let metric): WatchTrendView(metric: metric)
                    case .mood: WatchMoodView()
                    case .music: WatchMusicView()
                    case .setup: WatchSetupView()
                    case .relaxation: RelaxationView()
                    case .relaxationSettings: WatchRelaxationSettingsView()
                    case .companionHistory: CompanionHistoryView()
                    }
                }
        }.task { await app.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await app.activate() } }
                else { app.downloads.interruptForegroundDownloads() }
            }
            .onChange(of: app.watchReminders.destination, initial: true) { _, kind in
                guard let kind else { return }
                path = [.trend(kind.metric)]
                app.watchReminders.destination = nil
            }
            .onOpenURL { url in
                if url.scheme == "qingkong", url.host == "dumpling" { path = [.dumpling]; return }
                guard url.scheme == "qingkong", url.host == "trend",
                      let metric = HealthMetric(rawValue: url.lastPathComponent) else { return }
                path = [.trend(metric)]
            }
    }
}

private struct WatchRelaxationSettingsView: View {
    private var preferences = WatchRelaxationPreferences()
    var body: some View {
        List {
            NavigationLink {
                WatchRelaxationDurationView(selection: preferences.$duration)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("陪伴时长")
                    Text(preferences.duration.name).font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("watch-relaxation-duration")
            NavigationLink {
                WatchRelaxationModeView(selection: preferences.$mode)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("陪伴方式")
                    Text(preferences.mode.name).font(.caption).foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("watch-relaxation-mode")
            Toggle("引导声音", isOn: preferences.$sound).accessibilityIdentifier("watch-relaxation-sound")
            Toggle("手表触感", isOn: preferences.$haptics).accessibilityIdentifier("watch-relaxation-haptics")
            Text("按舒服的节奏自然呼吸，不需要憋气；若不舒服，请点结束。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("陪伴设置")
    }
}

private struct WatchRelaxationDurationView: View {
    @Binding var selection: RelaxationDuration
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(RelaxationDuration.allCases) { value in
            Button { selection = value; dismiss() } label: {
                HStack {
                    Text(value.name)
                    Spacer()
                    if selection == value { Image(systemName: "checkmark") }
                }.frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
        }.navigationTitle("陪伴时长")
    }
}

private struct WatchRelaxationModeView: View {
    @Binding var selection: RelaxationMode
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(RelaxationMode.allCases) { value in
            Button { selection = value; dismiss() } label: {
                HStack {
                    Text(value.name)
                    Spacer()
                    if selection == value { Image(systemName: "checkmark") }
                }.frame(minHeight: 32).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
        }.navigationTitle("陪伴方式")
    }
}

struct WatchTrendView: View {
    @Environment(AppServices.self) private var app
    let metric: HealthMetric
    @State private var period: TrendPeriod = .week
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let latest = app.health.latest(metric) {
                    Text("\(latest.value.formatted(.number.precision(.fractionLength(0)))) \(metric.unit)").font(.system(.title2, design: .rounded))
                    Text(latest.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    Text("来源：\(latest.source)").font(.caption2).foregroundStyle(.secondary)
                } else { Text("暂无可读取的记录").font(.headline) }
                trendPages
                if metric == .hrv {
                    Text(app.health.baseline.map { "个人基线 \($0.formatted(.number.precision(.fractionLength(0)))) ms" } ?? "基线积累中").font(.caption)
                    Text("SDNN · 此前 7 日至少 3 个有效日的日均值平均。 ").font(.caption2).foregroundStyle(.secondary)
                }
                Text("空缺表示没有记录，不代表零。 ").font(.caption2).foregroundStyle(.secondary)
                Button("刷新") { Task { await app.health.refresh() } }.disabled(app.health.loading)
                if let error = app.health.error { Text(error).font(.caption2) }
            }.padding(.horizontal, 12).padding(.bottom, 24)
        }.navigationTitle(metric.name)
    }

    private var trendPages: some View {
        TabView(selection: $period) {
            ForEach(TrendPeriod.allCases) { period in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(period.name)趋势").font(.headline)
                        .accessibilityIdentifier("watch-trend-period-\(period.rawValue)")
                    HealthTrendChart(buckets: HealthMath.buckets(app.health.readings, metric: metric, period: period), metric: metric, color: .white, compact: true, period: period)
                        .frame(height: 80)
                        .padding(.horizontal, 6).padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.bottom, 24)
                .tag(period)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 160)
        .accessibilityIdentifier("watch-trend-pages")
        .accessibilityHint("左右轻扫切换日、周、月图表")
    }
}

struct WatchMoodView: View {
    @Environment(AppServices.self) private var app
    @State private var mood = 3
    @State private var stress = 2
    @State private var message: String?
    private let stressLabels = ["很放松", "轻微压力", "中等压力", "压力较大", "压力很大"]
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("此刻，感觉如何？").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(1...5, id: \.self) { value in
                        Button { mood = value } label: {
                            VStack(spacing: 3) {
                                Image("mood-\(value)").resizable().scaledToFit().frame(height: 38)
                                Text(MoodRecord.labels[value - 1]).font(.caption2)
                            }.padding(4).frame(maxWidth: .infinity).background(mood == value ? .white.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityLabel("心情：\(MoodRecord.labels[value - 1])").accessibilityAddTraits(mood == value ? .isSelected : [])
                    }
                }
                Picker("此刻的压力", selection: $stress) {
                    ForEach(1...5, id: \.self) { value in
                        Text(stressLabels[value - 1]).tag(value)
                    }
                }
                .pickerStyle(.navigationLink)
                .frame(minHeight: 52)
                .accessibilityIdentifier("watch-stress-picker")
                Button("保存此刻") {
                    do { try app.store.add(mood: mood, stress: stress, note: ""); message = "已保存在手表，连接后同步" }
                    catch { message = "未能保存，请重试。" }
                }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                if let message { Text(message).font(.caption2).foregroundStyle(.secondary) }
            }.padding(.horizontal, 6)
        }.navigationTitle("心情")
    }
}

struct WatchSetupView: View {
    @Environment(AppServices.self) private var app
    @State private var complicationRefreshRequested = false
    var body: some View {
        List {
            Section("Apple 健康") {
                Text("只读取你允许的健康记录，无数据不代表你拒绝了访问。 ").font(.caption2)
                Button(app.health.requested ? "检查健康连接" : "连接健康") { Task { await app.health.authorize(); await app.watchReminders.activate(healthConnected: app.health.requested) } }
                if let error = app.health.error { Text(error).font(.caption2) }
            }
            Section("健康变化提醒") {
                Text(app.watchReminders.statusText).font(.caption2)
                Text("连接时由 iPhone 提交通知，系统按锁屏状态选择显示设备；联系不到 iPhone 时在手表通知。").font(.caption2)
                if let date = app.watchReminders.lastCheckedAt {
                    LabeledContent("最近检查") { Text(date, style: .time) }.font(.caption2)
                }
                if let error = app.watchReminders.error { Text(error).font(.caption2) }
                if let warning = app.health.backgroundDeliveryWarning { Text(warning).font(.caption2) }
                Button("检查提醒连接") { Task { await app.watchReminders.activate(healthConnected: app.health.requested); await app.health.refreshReminderReadings() } }
                Text("开关和阈值在 iPhone 个性化中设置。后台更新由系统安排，不保证实时提醒。").font(.caption2)
            }
            Section("配对同步") {
                Text(app.link.syncMessage).font(.caption2)
                Text(app.link.reachable ? "iPhone 当前可连接" : "iPhone 当前未连接，记录会先保存在手表").font(.caption2)
                Button("重试同步") { app.link.flush() }
                if let error = app.link.error { Text(error).font(.caption2) }
            }
            Section("表盘组件") {
                Text("添加「心情团子」圆形或矩形组件，点按进入团子页面。该页面亮屏活跃时播放一次表情动作，随后静止；系统仍会按设置返回表盘。").font(.caption2)
                Text("长按系统表盘 → 编辑 → 复杂功能，选择小晴空。可在 iPhone 小晴空中配置默认指标和迷你趋势。 ").font(.caption2)
                Button("刷新表盘组件") {
                    app.refreshComplications()
                    complicationRefreshRequested = true
                }
                if complicationRefreshRequested {
                    Text("已请求系统重新加载组件列表，请返回表盘编辑查看。组件是否出现仍取决于系统与所选位置。").font(.caption2)
                }
                if let error = app.snapshotError { Text(error).font(.caption2) }
            }
            Section("隐私") { Text("无注册、无广告，不上传日记或健康记录。心情与偏好只在配对设备间同步。详细说明见 iPhone 端个性化设置。 ").font(.caption2) }
        }.navigationTitle("连接与设置")
    }
}
