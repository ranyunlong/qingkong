import SwiftUI
import AVFoundation
import QingkongCore
#if os(watchOS)
import WatchKit
import HealthKit
import Observation
#endif

struct RelaxationView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var duration: RelaxationDuration = .oneMinute
    @State private var mode: RelaxationMode = .breathing
    @State private var sound = true
    @State private var haptics = true
    @State private var session: RelaxationSession?
    @State private var now = Date.now
    @State private var lastPhase: RelaxationPhase?
    @State private var speaker = AVSpeechSynthesizer()
    @State private var resultPresented = false
    @State private var finishing = false
    @State private var resultReadings: [HealthReading] = []
    @State private var returningToPreparation = false
    @State private var idleStartedAt = Date.now
    #if os(watchOS)
    private var watchPreferences = WatchRelaxationPreferences()
    @State private var lastHapticID: Int?
    @State private var watchRuntime = WatchRelaxationRuntime()
    @State private var starting = false
    #endif

    private var characterHeight: CGFloat {
        #if os(watchOS)
        110
        #else
        150
        #endif
    }

    var body: some View {
        content
        .navigationTitle("陪我缓一缓")
        .navigationDestination(isPresented: $resultPresented) {
            if let session, let startedAt = session.startedAt, let endedAt = session.endedAt,
               let record = session.completedRecord(finalHeartRate: RelaxationHeartRate.latest(in: resultReadings, startedAt: startedAt, endedAt: endedAt)) {
                RelaxationResultView(record: record, readings: resultReadings) {
                    returningToPreparation = true
                    resultPresented = false
                }
                .id(record.id)
            }
        }
        .onChange(of: resultPresented) { wasPresented, isPresented in
            if wasPresented && !isPresented {
                if returningToPreparation {
                    returningToPreparation = false; session = nil; finishing = false
                    resultReadings = []; idleStartedAt = .now
                } else { dismiss() }
            }
        }
        .onDisappear {
            session?.pause(at: .now); speaker.stopSpeaking(at: .immediate)
            #if os(watchOS)
            watchRuntime.cancel()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(watchOS)
            // Lowering the wrist changes scenePhase, but must not pause an
            // active workout or mindfulness runtime session.
            if phase == .active { lastPhase = nil }
            #else
            if phase != .active {
                session?.pause(at: .now); speaker.stopSpeaking(at: .immediate)
            } else if session?.status == .paused {
                session?.resume(at: .now); lastPhase = nil
            }
            #endif
        }
        .task {
            while !Task.isCancelled {
                now = .now
                session?.update(at: now)
                guide()
                if let session, session.status == .completed && !finishing {
                    finishing = true
                    speaker.stopSpeaking(at: .immediate)
                    #if os(watchOS)
                    await watchRuntime.finish(at: session.endedAt ?? now)
                    resultReadings = watchRuntime.readings
                    #else
                    await app.health.refresh()
                    resultReadings = app.health.readings
                    #endif
                    guard !Task.isCancelled else { return }
                    resultPresented = true
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    @ViewBuilder private var content: some View {
        #if os(watchOS)
        watchContent
        #else
        ScrollView {
            VStack(spacing: 20) {
                if let session {
                    practice(session)
                } else { preparation }
            }.padding()
        }
        #endif
    }

    #if os(watchOS)
    private var watchContent: some View {
        VStack(spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
                if let session, session.status == .running {
                    character(for: session.mode, elapsed: session.elapsed(at: context.date))
                } else {
                    QuietCompanionDumplingView(elapsed: reduceMotion ? 0 : max(0, context.date.timeIntervalSince(idleStartedAt)), isWaiting: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
            if session == nil {
                Button {
                    guard !starting else { return }
                    starting = true
                    Task { @MainActor in
                        let startedAt = await watchRuntime.start()
                        starting = false
                        guard !Task.isCancelled, let startedAt else { return }
                        var value = RelaxationSession(duration: watchPreferences.duration, mode: watchPreferences.mode,
                            guidanceSoundEnabled: watchPreferences.sound, hapticsEnabled: watchPreferences.haptics)
                        value.start(at: startedAt)
                        now = .now; session = value; lastPhase = nil; lastHapticID = nil
                    }
                } label: {
                    Text(starting ? "正在准备…" : "开始陪伴").font(.headline).frame(maxWidth: .infinity).frame(height: 24)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .frame(height: 44).disabled(starting)
                .accessibilityIdentifier("start-relaxation")
            }
        }
    }
    #endif

    private var preparation: some View {
        VStack(spacing: 18) {
            idleCharacter(waiting: true)
            Text("按你舒服的节奏就好。\n可以随时通过左上角返回。").multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                Text("陪伴时长").font(.subheadline)
                Picker("陪伴时长", selection: $duration) { ForEach(RelaxationDuration.allCases) { Text($0.name).tag($0) } }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif
                .accessibilityIdentifier("relaxation-duration")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("陪伴方式").font(.subheadline)
                Picker("陪伴方式", selection: $mode) { ForEach(RelaxationMode.allCases) { Text($0.name).tag($0) } }
                #if os(iOS)
                .pickerStyle(.segmented)
                #endif
                .accessibilityIdentifier("relaxation-mode")
            }
            Toggle("引导声音", isOn: $sound).accessibilityIdentifier("relaxation-sound")
            #if os(watchOS)
            Toggle("手表触感", isOn: $haptics)
            #endif
            companionButton("开始陪伴", prominent: true) {
                var value = RelaxationSession(duration: duration, mode: mode, guidanceSoundEnabled: sound, hapticsEnabled: haptics)
                value.start(at: .now)
                session = value; lastPhase = nil
            }
            .accessibilityIdentifier("start-relaxation")
            Text("无需连接健康或先填记录。不需要憋气；若不舒服，请停止并自然呼吸。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func practice(_ value: RelaxationSession) -> some View {
        let phase = value.phase(at: now)
        let running = value.status == .running
        return VStack(spacing: 22) {
            practiceCharacter(value)
            Text(running ? instruction(phase) : "暂停一下，按自己的节奏来。")
                .font(.headline).multilineTextAlignment(.center)
            Text(clock(value.remaining(at: now))).font(.title2.monospacedDigit())
                .accessibilityLabel("剩余 \(Int(ceil(value.remaining(at: now)))) 秒")

        }
    }

    private func practiceCharacter(_ value: RelaxationSession) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: value.status != .running || reduceMotion || scenePhase != .active)) { context in
            character(for: value.mode, elapsed: value.elapsed(at: context.date))
                .frame(height: characterHeight + 50)
        }
        .frame(height: (characterHeight + 30) * 1.15)
        .accessibilityHidden(true)
    }

    private func idleCharacter(waiting: Bool = false) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
            QuietCompanionDumplingView(elapsed: reduceMotion ? 0 : max(0, context.date.timeIntervalSince(idleStartedAt)), isWaiting: waiting)
        }
        .frame(height: characterHeight + 30)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func character(for mode: RelaxationMode, elapsed: TimeInterval) -> some View {
        if mode == .breathing {
            let cycle = elapsed.truncatingRemainder(dividingBy: 10)
            let progress = cycle < 4 ? cycle / 4 : 1 - (cycle - 4) / 6
            let breath = reduceMotion ? 0 : (1 - cos(.pi * progress)) / 2
            let exhale = reduceMotion || cycle < 4 ? 0 : sin((cycle - 4) / 6 * .pi)
            let exhaleProgress = reduceMotion || cycle < 4 ? 0 : (cycle - 4) / 6
            BreathingDumplingView(breath: breath, exhale: exhale, exhaleProgress: exhaleProgress)
        } else {
            QuietCompanionDumplingView(elapsed: reduceMotion ? 0 : elapsed)
        }
    }

    private func companionButton(_ title: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }
        #if os(iOS)
        .qingkongGlassButton(prominent: prominent)
        .controlSize(.large)
        #else
        .buttonStyle(.bordered)
        #endif
    }

    private func guide() {
        guard let session, session.status == .running else { return }
        #if os(watchOS)
        guard scenePhase == .active || watchRuntime.running else { return }
        #else
        guard scenePhase == .active else { return }
        #endif
        #if os(watchOS)
        if let cue = session.hapticCue(at: now), cue.id != lastHapticID {
            lastHapticID = cue.id
            switch cue.kind {
            case .inhale: WKInterfaceDevice.current().play(.directionUp)
            case .pulse: WKInterfaceDevice.current().play(.click)
            case .exhale: WKInterfaceDevice.current().play(.directionDown)
            }
        }
        #endif
        let phase = session.phase(at: now)
        guard lastPhase != phase else { return }
        lastPhase = phase
        if session.guidanceSoundEnabled {
            let utterance = AVSpeechUtterance(string: instruction(phase))
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = 0.4
            speaker.speak(utterance)
        }
    }

    private func instruction(_ phase: RelaxationPhase) -> String {
        switch phase { case .inhale: "轻轻吸气"; case .exhale: "慢慢呼气"; case .quiet: "我在这里，安静陪你。" }
    }
    private func clock(_ seconds: TimeInterval) -> String { let total = Int(ceil(seconds)); return String(format: "%02d:%02d", total / 60, total % 60) }
}

private struct RelaxationResultView: View {
    @Environment(AppServices.self) private var app
    let record: RelaxationRecord
    let readings: [HealthReading]
    let onFeedbackSaved: () -> Void
    @State private var saved = false
    @State private var selectedFeedback: RelaxationFeedback?
    @State private var choosingFeedback = false
    @State private var saveError: String?
    @State private var page = 0

    private var encouragement: String {
        guard let decrease = RelaxationHeartRate.decreaseFraction(in: readings, startedAt: record.startedAt, endedAt: record.completedAt), decrease > 0 else {
            return "做得很好。谢谢你留出这段时间，认真照顾自己的感受。"
        }
        if decrease >= 0.1 {
            return "这段时间，心率慢慢放缓了。做得很好，你给自己留出了一片安静的空间。"
        }
        return "心率比开始时低了一些。你正按自己的节奏慢慢调整，做得很好。"
    }

    var body: some View {
        resultContent
            .navigationTitle(page == 1 ? "现在感觉怎么样？" : "陪伴完成")
            .onAppear { if !saved { persist(nil, choosingFeedback: false) } }
            .alert("暂未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("重试") { persist(selectedFeedback, choosingFeedback: choosingFeedback) }
                Button("稍后再试", role: .cancel) { saveError = nil }
            } message: { Text("请重试保存这次陪伴。") }
    }

    @ViewBuilder private var resultContent: some View {
        #if os(watchOS)
        TabView(selection: $page) {
            VStack(spacing: 6) {
                Image("mood-4").resizable().scaledToFit().frame(maxHeight: 40).accessibilityHidden(true)
                heartRateSummary
                Text(encouragement).font(.footnote).multilineTextAlignment(.center).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("relaxation-encouragement")
                Text("向左滑动，记录此刻感受").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 4).padding(.bottom, 22).tag(0)
            VStack(spacing: 10) {
                feedbackButtons
            }.padding(.top, 32).padding(.bottom, 22).tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .accessibilityIdentifier("relaxation-result-pages")
        #else
        ScrollView {
            VStack(spacing: 18) {
                Image("mood-4").resizable().scaledToFit().frame(height: 120).accessibilityHidden(true)
                heartRateSummary
                Text(encouragement).font(.headline).multilineTextAlignment(.center)
                    .accessibilityIdentifier("relaxation-encouragement")
                Text("现在感觉怎么样？没有变化也没关系。")
                    .font(.subheadline).multilineTextAlignment(.center)
                feedbackButtons
            }.padding()
        }
        #endif
    }

    @ViewBuilder private var heartRateSummary: some View {
        if let reading = record.finalHeartRate {
            VStack(spacing: 3) {
                Text("\(reading.value.formatted(.number.precision(.fractionLength(0)))) 次/分")
                    .font(.title3.monospacedDigit()).accessibilityIdentifier("relaxation-final-heart-rate")
                Text("本次最后心率 · \(reading.date.formatted(.dateTime.hour().minute().second()))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("本次暂无可读取的心率").font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("relaxation-no-heart-rate")
        }
    }

    @ViewBuilder private var feedbackButtons: some View {
        feedbackButton("好一些", feedback: .better)
        feedbackButton("差不多", feedback: .same)
        feedbackButton("暂时不想记录感受", feedback: nil)
    }

    private func feedbackButton(_ title: String, feedback: RelaxationFeedback?) -> some View {
        Button { persist(feedback, choosingFeedback: true) } label: {
            Text(title)
                #if os(watchOS)
                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 24)
                #else
                .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                #endif
        }
        #if os(iOS)
        .qingkongGlassButton(prominent: feedback == .better).controlSize(.large)
        #else
        .buttonStyle(.bordered).frame(minHeight: 44)
        #endif
    }

    private func persist(_ feedback: RelaxationFeedback?, choosingFeedback: Bool) {
        var updated = record
        updated.feedback = feedback
        self.choosingFeedback = choosingFeedback; selectedFeedback = feedback
        do {
            try app.companion.savePractice(updated)
            saved = true; saveError = nil
            if choosingFeedback { onFeedbackSaved() }
        } catch { saveError = "暂未保存，请重试。" }
    }
}

#if os(watchOS)
struct WatchRelaxationPreferences: DynamicProperty {
    @AppStorage("qingkong.watch.relaxation.duration") var duration: RelaxationDuration = .oneMinute
    @AppStorage("qingkong.watch.relaxation.mode") var mode: RelaxationMode = .breathing
    @AppStorage("qingkong.watch.relaxation.sound") var sound = true
    @AppStorage("qingkong.watch.relaxation.haptics") var haptics = true
}

/// Owns only the current local practice. No workout is saved and no health
/// samples are passed to connectivity or public content services.
@MainActor @Observable
private final class WatchRelaxationRuntime: NSObject, HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate, WKExtendedRuntimeSessionDelegate {
    private(set) var running = false
    private(set) var readings: [HealthReading] = []
    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var workout: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var preparingCollector: HKLiveWorkoutBuilder?
    @ObservationIgnored private var mindfulness: WKExtendedRuntimeSession?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var startedAt: Date?

    func start() async -> Date? {
        let attempt = UUID()
        generation = attempt
        readings = []; startedAt = nil
        let heartRate = HKQuantityType(.heartRate)
        do {
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [heartRate])
            guard generation == attempt, !Task.isCancelled else { return nil }
            guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                return startMindfulness()
            }
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .mindAndBody
            configuration.locationType = .indoor
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let collector = session.associatedWorkoutBuilder()
            let source = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            // This experience needs heart rate, not energy or distance totals.
            for type in source.typesToCollect where type != heartRate { source.disableCollection(for: type) }
            source.enableCollection(for: heartRate, predicate: nil)
            collector.dataSource = source
            session.delegate = self; collector.delegate = self
            workout = session; builder = collector
            let date = Date.now
            startedAt = date
            session.startActivity(with: date)
            preparingCollector = collector
            do {
                try await collector.beginCollection(at: date)
            } catch {
                preparingCollector = nil
                session.end(); collector.discardWorkout()
                if self.builder === collector { self.workout = nil; self.builder = nil }
                guard generation == attempt, !Task.isCancelled else { return nil }
                return startMindfulness()
            }
            preparingCollector = nil
            guard generation == attempt, !Task.isCancelled else {
                session.end()
                try? await collector.endCollection(at: .now)
                collector.discardWorkout()
                return nil
            }
            running = true
            return date
        } catch {
            guard generation == attempt, !Task.isCancelled else { return nil }
            workout?.end(); builder?.discardWorkout()
            workout = nil; builder = nil
            return startMindfulness()
        }
    }

    private func startMindfulness() -> Date {
        let date = Date.now
        startedAt = date
        if WKApplication.shared().applicationState == .active {
            let session = WKExtendedRuntimeSession()
            session.delegate = self; mindfulness = session
            session.start()
        }
        return date
    }

    func finish(at date: Date) async {
        generation = UUID(); running = false
        mindfulness?.invalidate(); mindfulness = nil
        let session = workout, collector = builder
        workout = nil; builder = nil
        session?.end()
        guard let collector, preparingCollector !== collector else { return }
        collectHeartRate(from: collector, through: date)
        do { try await collector.endCollection(at: date) } catch { /* Keep any valid samples already received. */ }
        collectHeartRate(from: collector, through: date)
        collector.discardWorkout()
    }

    func cancel() {
        generation = UUID(); running = false
        mindfulness?.invalidate(); mindfulness = nil
        let session = workout, collector = builder
        workout = nil; builder = nil
        session?.end()
        // If authorization/start is still returning, start() owns cleanup.
        guard let collector, preparingCollector !== collector else { return }
        let date = Date.now
        Task {
            try? await collector.endCollection(at: date)
            collector.discardWorkout()
        }
    }

    private func collectHeartRate(from collector: HKLiveWorkoutBuilder, through date: Date = .now) {
        guard let startedAt,
              let statistics = collector.statistics(for: HKQuantityType(.heartRate)),
              let quantity = statistics.mostRecentQuantity(),
              let interval = statistics.mostRecentQuantityDateInterval() else { return }
        let reading = HealthReading(metric: .heartRate, date: interval.end,
            value: quantity.doubleValue(for: .count().unitDivided(by: .minute())), source: "Apple Watch")
        guard RelaxationHeartRate.latest(in: [reading], startedAt: startedAt, endedAt: date) != nil,
              !readings.contains(where: { $0.date == reading.date }) else { return }
        readings.append(reading)
    }

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            guard self.builder === workoutBuilder else { return }
            self.collectHeartRate(from: workoutBuilder)
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard self.workout === workoutSession else { return }
            if toState == .ended { await self.finish(at: date) }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.workout === workoutSession else { return }
            await self.finish(at: .now)
        }
    }
    nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        Task { @MainActor in if self.mindfulness === extendedRuntimeSession { self.running = true } }
    }
    nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}
    nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        Task { @MainActor in if self.mindfulness === extendedRuntimeSession { self.running = false; self.mindfulness = nil } }
    }
}
#endif


/// Shared by local companion screens; a tap plays one response and then returns to rest.
struct CompanionActionCharacter: View {
    let mood: Int
    var action: CompanionAction = .greeting
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: Date?
    @State private var playbackID = UUID()

    var body: some View {
        Button(action: play) {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: startedAt == nil || reduceMotion || scenePhase != .active)) { context in
                let transform = action.transform(elapsed: startedAt.map { context.date.timeIntervalSince($0) } ?? 0, reduceMotion: reduceMotion)
                Image("mood-\(min(5, max(1, mood)))").resizable().scaledToFit()
                    .scaleEffect(x: 1, y: transform.scaleY, anchor: .bottom)
                    .rotationEffect(.degrees(transform.rotationDegrees))
                    .offset(x: transform.offsetX, y: transform.offsetY)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("团子，\(action.name)")
        .accessibilityHint(reduceMotion ? "已跟随系统减少动态效果，保持静态" : "点按播放一次动作")
        .accessibilityValue(startedAt == nil ? "静止" : "播放中")
        .onChange(of: action) { _, _ in play() }
        .onChange(of: reduceMotion) { _, reduced in if reduced { stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear(perform: stop)
        .task(id: playbackID) {
            guard startedAt != nil else { return }
            do { try await Task.sleep(for: .seconds(action.duration)) } catch { return }
            startedAt = nil
        }
    }

    private func play() {
        guard !reduceMotion, scenePhase == .active else { stop(); return }
        startedAt = .now; playbackID = UUID()
    }
    private func stop() { startedAt = nil; playbackID = UUID() }
}


/// Only two local milestones are retained; no journal, score or health sample is stored here.
struct CompanionActionLibrary: DynamicProperty {
    @AppStorage(CompanionActionMemory.nodKey) private var nodUnlocked = false
    @AppStorage(CompanionActionMemory.swayKey) private var swayUnlocked = false

    func actions(moods: [MoodRecord], practices: [RelaxationRecord]) -> [CompanionAction] {
        let remembered: [CompanionAction] = (nodUnlocked ? [.nod] : []) + (swayUnlocked ? [.sway] : [])
        return CompanionActionAvailability(moods: moods, practices: practices, rememberedActions: remembered).actions
    }

    func remember(_ actions: [CompanionAction]) {
        if !nodUnlocked && actions.contains(.nod) { nodUnlocked = true }
        if !swayUnlocked && actions.contains(.sway) { swayUnlocked = true }
    }
}
