import SwiftUI
import AVFoundation
import QingkongCore
#if os(watchOS)
import WatchKit
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
    @State private var saved = false
    @State private var autoSaved = false
    @State private var saveError: String?
    @State private var idleStartedAt = Date.now
    #if os(watchOS)
    private var watchPreferences = WatchRelaxationPreferences()
    @State private var lastHapticID: Int?
    @State private var resumeOnActive = false
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
        .onDisappear { session?.pause(at: .now); speaker.stopSpeaking(at: .immediate) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                #if os(watchOS)
                if session?.status == .running { resumeOnActive = true }
                #endif
                session?.pause(at: .now); speaker.stopSpeaking(at: .immediate)
            }
            #if os(watchOS)
            if phase == .active && resumeOnActive {
                session?.resume(at: .now); resumeOnActive = false; lastPhase = nil
            }
            #endif
        }
        .task {
            while !Task.isCancelled {
                now = .now
                session?.update(at: now)
                guide()
                #if os(watchOS)
                if session?.status == .completed && !autoSaved && saveError == nil { saveRecordWithoutDismissing() }
                #endif
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
                    if session.status == .completed { completion }
                    else { practice(session) }
                } else { preparation }
                if let saveError { Text(saveError).font(.footnote) }
            }.padding()
        }
        #endif
    }

    #if os(watchOS)
    private var watchContent: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active || session?.status == .paused)) { context in
                    if let session, session.status == .running || session.status == .paused {
                        character(for: session.mode, elapsed: session.elapsed(at: context.date))
                    } else {
                        QuietCompanionDumplingView(elapsed: reduceMotion ? 0 : max(0, context.date.timeIntervalSince(idleStartedAt)), isWaiting: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: max(50, geometry.size.height - 52))
                .accessibilityHidden(true)
                Button {
                    if let value = session {
                        if value.status == .completed {
                            saveRecordWithoutDismissing()
                            if !autoSaved { return }
                        } else { session?.exit(at: .now) }
                        speaker.stopSpeaking(at: .immediate)
                        dismiss()
                    } else {
                        var value = RelaxationSession(duration: watchPreferences.duration, mode: watchPreferences.mode,
                            guidanceSoundEnabled: watchPreferences.sound, hapticsEnabled: watchPreferences.haptics)
                        value.start(at: .now)
                        now = .now; session = value; lastPhase = nil; lastHapticID = nil
                        autoSaved = false; saveError = nil
                    }
                } label: {
                    Text(session == nil ? "开始陪伴" : "结束").font(.headline).frame(maxWidth: .infinity).frame(height: 24)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .frame(height: 44)
                .accessibilityIdentifier(session == nil ? "start-relaxation" : "end-relaxation")
            }
        }
        .alert("练习暂未保存", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("重试") { saveError = nil; saveRecordWithoutDismissing() }
            Button("稍后再试", role: .cancel) { saveError = nil }
        } message: { Text("请稍后点结束重试保存。") }
    }
    #endif

    private var preparation: some View {
        VStack(spacing: 18) {
            idleCharacter(waiting: true)
            Text("按你舒服的节奏就好。\n可以随时暂停或离开。").multilineTextAlignment(.center)
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
            companionButton(running ? "暂停" : "继续", prominent: true) {
                if running { session?.pause(at: .now); speaker.stopSpeaking(at: .immediate) }
                else { session?.resume(at: .now); lastPhase = nil }
            }.accessibilityIdentifier("pause-relaxation")
            companionButton("结束并离开", role: .cancel) {
                session?.exit(at: .now); speaker.stopSpeaking(at: .immediate); dismiss()
            }
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

    private var completion: some View {
        VStack(spacing: 18) {
            idleCharacter()
            Text("谢谢你给自己这段时间。").font(.headline)
            Text("现在的感觉，愿意的话可以记下。没有变化也没关系。").font(.subheadline)
            if saved {
                Text("已保存在这台设备上").font(.footnote)
                companionButton("完成", prominent: true) { dismiss() }
            } else {
                companionButton("好一些", prominent: true) { save(.better) }
                companionButton("差不多") { save(.same) }
                companionButton("暂时不想记录感受") { save(nil) }
            }
        }.onAppear { speaker.stopSpeaking(at: .immediate); saveRecordWithoutDismissing() }
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

    private func saveRecordWithoutDismissing() {
        guard !autoSaved else { return }
        guard let record = session?.completedRecord() else { return }
        do { try app.companion.savePractice(record); autoSaved = true }
        catch { saveError = "练习暂未保存，请点选反馈重试。" }
    }

    private func save(_ feedback: RelaxationFeedback?) {
        guard let record = session?.completedRecord(feedback: feedback) else { return }
        do { try app.companion.savePractice(record); saveError = nil; saved = true; autoSaved = true }
        catch { saveError = "练习暂未保存，请重试。" }
    }

    private func guide() {
        guard scenePhase == .active, let session, session.status == .running else { return }
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

#if os(watchOS)
struct WatchRelaxationPreferences: DynamicProperty {
    @AppStorage("qingkong.watch.relaxation.duration") var duration: RelaxationDuration = .oneMinute
    @AppStorage("qingkong.watch.relaxation.mode") var mode: RelaxationMode = .breathing
    @AppStorage("qingkong.watch.relaxation.sound") var sound = true
    @AppStorage("qingkong.watch.relaxation.haptics") var haptics = true
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
