import SwiftUI
import QingkongCore

enum AppTab: Hashable { case today, trends, mood, sleep }

struct RootView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .today
    @State private var sleepRootVisible = true
    @State private var mood = 3
    @State private var settings = false
    @State private var reminderSheet: ReminderDestination?
    @State private var healthIntroduction = false
    @State private var trendMetric: HealthMetric = .hrv
    var body: some View {
        tabShell
            .tint(app.scene.accent)
            .sheet(isPresented: $healthIntroduction, onDismiss: {
                app.health.completeConnectionIntroduction()
                app.healthIntroductionActive = false
                Task { await app.reminders.requestPermissionIfNeeded(); presentReminderDestination() }
            }) { HealthConnectionIntroductionView().environment(app) }
            .sheet(isPresented: $settings, onDismiss: presentReminderDestination) { NavigationStack { PersonalizationView() }.environment(app) }
            .sheet(item: $reminderSheet) { _ in
                NavigationStack {
                    RelaxationAdviceView(inSheet: true, openSounds: { reminderSheet = nil; tab = .sleep })
                }.environment(app)
            }
            .onChange(of: app.reminders.destination) { _, _ in presentReminderDestination() }
            .task {
                healthIntroduction = app.needsHealthIntroduction
                app.healthIntroductionActive = healthIntroduction
                presentReminderDestination()
                await app.start()
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    app.updateClock()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await app.activate() } }
            }
            .onOpenURL { url in
                guard url.scheme == "qingkong" else { return }
                if url.host == "dumpling" { tab = .mood }
                else if url.host == "music" { tab = .sleep }
                else if url.host == "trend", let metric = HealthMetric(rawValue: url.lastPathComponent) {
                    trendMetric = metric; tab = .trends
                }
            }
    }

    private func presentReminderDestination() {
        guard !healthIntroduction else { return }
        guard let destination = app.reminders.destination else { return }
        if settings { settings = false; return }
        app.reminders.destination = nil
        switch destination {
        case .advice: reminderSheet = .advice
        case .sounds: reminderSheet = nil; tab = .sleep
        case .heartRate: reminderSheet = nil; trendMetric = .heartRate; tab = .trends
        case .oxygen: reminderSheet = nil; trendMetric = .oxygen; tab = .trends
        }
    }

    private var tabShell: some View { tabs }

    private var tabs: some View {
        TabView(selection: $tab) {
            navigation("今日") { TodayView(selectedMood: $mood, openMood: { tab = .mood }) }
                .tabItem { tabLabel("今日", systemImage: "sun.max") }.tag(AppTab.today)
            navigation("趋势") { TrendsView(metric: $trendMetric) }
                .tabItem { tabLabel("趋势", systemImage: "chart.bar") }.tag(AppTab.trends)
            navigation("心情") { MoodView(selectedMood: $mood) }
                .tabItem { tabLabel("心情", systemImage: "face.smiling") }.tag(AppTab.mood)
            navigation("助眠") {
                SleepView()
                    .onAppear { sleepRootVisible = true }
                    .onDisappear { sleepRootVisible = false }
            }
                .tabItem { tabLabel("助眠", systemImage: "moon.stars") }.tag(AppTab.sleep)
        }
    }

    private func tabLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .symbolRenderingMode(.monochrome)
            .environment(\.symbolVariants, .none)
    }

    private func navigation<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("个性化", systemImage: "slider.horizontal.3") { settings = true }
                            // The toolbar provides its own glass background.
                            .buttonStyle(.automatic)
                            .accessibilityIdentifier("open-settings")
                    }
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if (app.player.state.playing || app.player.buffering) && (tab != .sleep || !sleepRootVisible) {
                MiniPlayer { tab = .sleep }.padding(.horizontal, 22).padding(.bottom, 8)
            }
        }
    }
}

private struct HealthConnectionIntroductionView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "heart.text.clipboard").font(.system(size: 48)).foregroundStyle(app.scene.accent).accessibilityHidden(true)
                    Text("连接健康，\n了解自己的日常。").font(.largeTitle.bold())
                    Text("允许小晴空读取 Apple 健康中的心率、血氧、HRV 和已有的心电图记录，查看趋势并接收你开启的健康提醒。")
                    Label("只申请读取，不写入或修改记录", systemImage: "checkmark.shield")
                    Label("健康与日记保留在设备上", systemImage: "iphone")
                    Text("你可以逐项选择允许读取的数据，也可以稍后在个性化设置中连接。没有可读取数据时，仍能记录心情和听自然声音。")
                        .font(.subheadline).foregroundStyle(Color.readableSecondary)
                    if let error = app.health.error { Text(error).font(.footnote) }
                    Button(connecting ? "正在连接…" : "连接 Apple 健康") {
                        Task {
                            connecting = true
                            await app.health.authorize()
                            connecting = false
                            if app.health.requested { dismiss() }
                        }
                    }.qingkongGlassButton(prominent: true).disabled(connecting).accessibilityIdentifier("initial-connect-health")
                    Button("稍后再说") { dismiss() }.qingkongGlassButton().disabled(connecting).accessibilityIdentifier("skip-initial-health")
                }.padding(24)
            }.navigationTitle("欢迎来到小晴空").navigationBarTitleDisplayMode(.inline)
        }.tint(app.scene.accent).interactiveDismissDisabled(connecting)
    }
}

struct MiniPlayer: View {
    @Environment(AppServices.self) private var app
    let open: () -> Void
    @ViewBuilder var body: some View {
        if #available(iOS 26, *) { controls.glassEffect(.regular, in: .capsule) }
        else { controls.background(.bar, in: .capsule) }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 10) {
                    AudioArtworkView(state: app.player.state).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.player.state.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(app.player.buffering ? "正在加载 · 点按展开" : (app.player.state.playing ? "正在播放 · 点按展开" : "已暂停 · 点按展开"))
                            .font(.caption2).foregroundStyle(Color.readableSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.accessibilityLabel("展开播放器").accessibilityIdentifier("mini-player-open")
            Button {
                Task { await app.player.toggle() }
            } label: {
                Image(systemName: app.player.state.playing || app.player.buffering ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold)).frame(width: 48, height: 48).contentShape(Rectangle())
            }
            .accessibilityLabel(app.player.state.playing || app.player.buffering ? "暂停播放" : "继续播放")
            .accessibilityIdentifier("mini-player-toggle")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(minHeight: 76)
        .background {
            Capsule().fill(.clear).contentShape(Capsule()).onTapGesture(perform: open).accessibilityHidden(true)
        }
    }
}

struct PageIntro: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.caption).foregroundStyle(Color.readableSecondary)
            Text(title).font(.system(.largeTitle, design: .rounded).weight(.semibold)).tracking(-0.8)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.readableSecondary).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12).padding(.bottom, 8)
    }
}

struct Surface<Content: View>: View {
    @Environment(AppServices.self) private var app
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(app.scene.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
    }
}

struct HealthAccessNote: View {
    @Environment(AppServices.self) private var app
    var body: some View {
        if app.health.isDemo {
            Label("演示健康数据，仅用于界面预览", systemImage: "info.circle").font(.footnote).foregroundStyle(Color.readableSecondary)
        } else if !app.health.available {
            Label("当前设备暂无可用健康服务，你仍可以记录心情、听自然声音。", systemImage: "info.circle").font(.footnote).foregroundStyle(Color.readableSecondary)
        } else if app.health.readings.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(app.health.requested ? "暂时没有可读取的健康记录" : "连接健康，了解自己的日常", systemImage: "heart.text.clipboard")
                    .font(.subheadline.weight(.medium))
                Text("仅在你同意后读取所选数据。若没有记录，可在「健康」App 检查数据来源和访问设置。")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
                Button(app.health.requested ? "检查健康连接" : "连接 Apple 健康") { Task { await app.health.authorize() } }
                    .qingkongGlassButton().disabled(app.health.loading)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
        }
        if let error = app.health.error { Text(error).font(.footnote).foregroundStyle(Color.readableSecondary) }
    }
}

extension View {
    func qingkongGlassButton(prominent: Bool = false, shape: ButtonBorderShape = .capsule) -> some View {
        modifier(QingkongGlassButton(prominent: prominent, shape: shape))
    }
}

private struct QingkongGlassButton: ViewModifier {
    let prominent: Bool
    let shape: ButtonBorderShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent).buttonBorderShape(shape) }
            else { content.buttonStyle(.glass).buttonBorderShape(shape) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent).buttonBorderShape(shape) }
            else { content.buttonStyle(.bordered).buttonBorderShape(shape) }
        }
    }
}

struct GlassButtonGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else { content }
    }
}
