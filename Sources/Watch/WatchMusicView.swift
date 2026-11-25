import SwiftUI
import WatchKit
import AVFoundation
import QingkongCore

struct WatchMusicView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var remote = false
    @State private var switching = false
    @State private var operating = false
    @State private var lastRemoteState: AudioState?
    @State private var playbackError: String?
    @State private var showingVolume = false
    @State private var volumeActivity = UUID()
    @State private var pageVisible = false
    @State private var operationContext = UUID()
    @State private var macVolumeTask: Task<Void, Never>?
    @State private var pendingMacVolume: Double?
    @GestureState private var touchingVolume = false
    private var state: AudioState { remote ? (app.link.remoteState ?? lastRemoteState ?? app.player.state) : app.player.state }
    private var macRemote: Bool { remote && state.playbackSessionID != nil }
    private var airPlayRemote: Bool { remote && state.airPlayRouteName != nil }
    private var routedRemote: Bool { macRemote || airPlayRemote }
    private var busy: Bool { operating || switching || app.link.remoteBusy || app.player.activating }
    private var canAdjustVolume: Bool {
        pageVisible && scenePhase == .active && !operating && !switching && !app.player.activating &&
            (routedRemote || !app.link.remoteBusy) && playbackError == nil
    }

    var body: some View {
        GeometryReader { geometry in
          VStack(spacing: 6) {
            AudioArtworkView(state: state)
                .frame(width: 100, height: max(50, min(90, geometry.size.height - (routedRemote ? 120 : 88))))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 2) {
                Text(state.displayTitle).font(.headline).lineLimit(1).accessibilityIdentifier("watch-current-track")
                Text(airPlayRemote ? "AirPlay · \(state.airPlayRouteName ?? "Mac")" : (macRemote ? (state.remoteConnected == false ? "Mac 连接中断" : "\(state.playbackDevice ?? "Mac") 播放") : (remote ? "iPhone 正在加载…" : "正在加载…")))
                    .font(.caption2).lineLimit(1)
                    .opacity(routedRemote || state.buffering == true ? 1 : 0)
                    .accessibilityHidden(!routedRemote && state.buffering != true)
            }.frame(height: 32)
            if routedRemote { macProgress }
            ZStack {
                if macRemote {
                    MacWatchVolumeControl(volume: state.volume, enabled: canAdjustVolume,
                        valueChanged: scheduleMacVolume, activity: volumeChanged)
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        .accessibilityHidden(!showingVolume)
                } else {
                // Keep the native control mounted and focused, including while covered.
                // Handing focus over after the first crown event loses that volume step.
                WatchSystemVolumeControl(remote: remote, focused: canAdjustVolume, volumeChanged: volumeChanged)
                    .id(remote)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                    .allowsHitTesting(canAdjustVolume)
                    .accessibilityHidden(!showingVolume)
                    .accessibilityLabel(remote ? "iPhone 音量" : "手表音量")
                    .accessibilityHint("旋转数码表冠调节音量")
                    .accessibilityIdentifier("watch-system-volume")
                    .simultaneousGesture(DragGesture(minimumDistance: 0)
                        .updating($touchingVolume) { _, touching, _ in touching = true }
                        .onChanged { _ in volumeChanged() }
                        .onEnded { _ in volumeChanged() })
                }
                if !showingVolume {
                    controls(state)
                        .padding(.vertical, 4)
                        .background(.black)
                }
            }
            .frame(height: 44)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 6)
        .digitalCrownAccessory(.hidden)
        .accessibilityHint("旋转数码表冠调节音量")
        .accessibilityAction(named: "调节音量", revealVolume)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    List {
                        NavigationLink("手表曲库与下载") { WatchAudioLibraryView() }
                        Button("自动选择播放设备") {
                            Task {
                                operationContext = UUID()
                                await app.player.useAutomaticPlaybackSelection()
                                remote = false
                            }
                        }
                        if remote {
                            Picker("循环方式", selection: Binding(get: { state.playbackMode ?? .sequence }, set: { mode in
                                Task {
                                    if !(await app.link.command(.mode, playbackMode: mode)) { playbackError = app.link.error }
                                }
                            })) {
                                ForEach(AudioPlaybackMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                            }
                            if routedRemote {
                                Picker("停止定时", selection: Binding(get: { state.deadline?.durationMinutes ?? 0 }, set: { minutes in
                                    Task { if !(await app.link.command(.timer, amount: Double(minutes))) { playbackError = app.link.error } }
                                })) {
                                    Text("关闭").tag(0); Text("15 分钟").tag(15); Text("30 分钟").tag(30); Text("60 分钟").tag(60)
                                }
                            }
                        }
                        Text(app.player.localPlaybackSelected ? "当前保持手表本机播放。" : "返回音乐页后自动检查可用播放设备。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.navigationTitle("播放设置")
                } label: { Image(systemName: "ellipsis").foregroundStyle(.black) }
                    .tint(.white)
                    .accessibilityLabel("播放设备与手表下载")
                    .accessibilityIdentifier("watch-music-settings")
            }
        }
        .alert("播放未完成", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("知道了", role: .cancel) { playbackError = nil }
        } message: {
            Text(playbackError ?? "请稍后重试。")
        }
            .task {
                try? await chooseLocation()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(routedRemote ? 2 : 10)) } catch { return }
                    if scenePhase == .active, !busy, !showingVolume { try? await chooseLocation() }
                }
            }
            .task(id: volumeActivity) {
                guard showingVolume else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard !touchingVolume else { return }
                showingVolume = false
            }
            .onChange(of: canAdjustVolume) { _, available in
                if !available { showingVolume = false }
            }
            .onChange(of: app.link.remoteVolumeRevision) { _, _ in
                if remote { volumeChanged() }
            }
            .onAppear {
                pageVisible = true
                if !app.player.localPlaybackSelected, !app.player.state.playing, let phone = app.link.remoteState {
                    lastRemoteState = phone
                    remote = true
                }
            }
            .onDisappear { pageVisible = false; showingVolume = false; operationContext = UUID(); pendingMacVolume = nil; macVolumeTask?.cancel(); macVolumeTask = nil }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !busy { Task { try? await chooseLocation() } }
            }
            .onChange(of: app.link.remoteState) { _, value in
                guard let value else {
                    if lastRemoteState?.playbackSessionID != nil { lastRemoteState?.remoteConnected = false }
                    return
                }
                lastRemoteState = value
                // A phone status update changes the display, never starts Watch playback.
                if !app.player.localPlaybackSelected && !app.player.state.playing && !app.player.activating && !switching { remote = true }
            }
            .onChange(of: app.player.localPlaybackSelected) { _, value in
                operationContext = UUID()
                if value { remote = false }
            }
            .onChange(of: app.link.reachable) { _, connected in
                if connected, scenePhase == .active, !busy { Task { try? await chooseLocation() } }
            }
    }

    private var macProgress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = max(0, state.playbackDuration ?? 0)
            let position = state.playbackPosition ?? 0
            let elapsed = max(0, context.date.timeIntervalSince(app.link.remoteStateReceivedAt ?? context.date))
            let projected = min(duration, position + (state.playing && state.buffering != true && state.remoteConnected != false ? min(3, elapsed) : 0))
            VStack(spacing: 2) {
                ProgressView(value: projected, total: max(1, duration)).tint(.white)
                HStack {
                    Text(clock(projected))
                    Spacer()
                    if let deadline = state.deadline { Text("\(Int(ceil(deadline.remaining(at: context.date) / 60))) 分后停止") }
                    else { Text(clock(duration)) }
                }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.frame(height: 26)
    }

    private func clock(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "--:--" }
        let seconds = Int(min(value, 359999))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func scheduleMacVolume(_ value: Double) {
        pendingMacVolume = value
        guard macVolumeTask == nil else { return }
        macVolumeTask = Task {
            defer { macVolumeTask = nil }
            while pendingMacVolume != nil, pageVisible, !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard !busy else { continue }
                guard let value = pendingMacVolume else { return }
                pendingMacVolume = nil
                if !(await app.link.command(.volume, amount: value)) {
                    playbackError = app.link.error ?? "Mac 未确认音量。"
                    return
                }
            }
        }
    }

    private func controls(_ state: AudioState) -> some View {
        HStack(spacing: 10) {
            playbackButton("上一首", symbol: "backward.end.fill", action: .previous)
            playbackButton(state.playing || state.buffering == true ? "暂停" : "播放", symbol: state.playing || state.buffering == true ? "pause.fill" : "play.fill", action: .playPause)
            playbackButton("下一首", symbol: "forward.end.fill", action: .next)
        }.buttonStyle(.plain).disabled(busy)
    }

    private func playbackButton(_ title: String, symbol: String, action: AudioCommand.Action) -> some View {
        Button { perform(action) } label: {
            Image(systemName: symbol)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }.accessibilityLabel(title)
    }

    private func revealVolume() {
        guard canAdjustVolume else { return }
        showingVolume = true
        volumeActivity = UUID()
    }

    private func volumeChanged() {
        revealVolume()
    }

    private func perform(_ action: AudioCommand.Action) {
        Task {
            guard pageVisible, !busy else { return }
            let context = operationContext
            operating = true
            defer { operating = false }
            let operation: AudioCommand.Action = action == .playPause && (state.playing || state.buffering == true) ? .pause : action
            // A remote pause/skip must receive a phone receipt. Changing the local
            // player cannot stand in for an operation that failed on the phone.
            if remote && operation != .playPause {
                if !(await app.link.command(operation)) { playbackError = app.link.error ?? "iPhone 未确认操作，请稍后重试。" }
                return
            }
            do {
                try await chooseLocation(waitForPhone: true)
                try Task.checkCancellation()
            } catch { return }
            guard pageVisible, context == operationContext else { return }
            // A newly confirmed phone may already be playing; a Play tap must not pause it.
            if operation == .playPause, state.playing || state.buffering == true { return }
            if remote {
                if !(await app.link.command(operation)) { playbackError = app.link.error ?? "iPhone 未确认操作，请稍后重试。" }
            }
            else {
                let reply = await app.player.handle(AudioCommand(action: operation))
                playbackError = reply.error
            }
        }
    }

    private func chooseLocation(waitForPhone: Bool = false) async throws {
        guard !switching && !app.link.remoteBusy else { return }
        // A user explicitly selected a verified Watch download. Keep its local
        // pause/resume and queue controls until another source is selected.
        if app.player.localPlaybackSelected { remote = false; return }
        // Keep an active local session stable through brief connection changes.
        guard !app.player.state.playing && !app.player.activating else { remote = false; return }
        switching = true
        defer { switching = false }
        let confirmed: Bool
        if waitForPhone {
            confirmed = try await app.link.confirmPhoneForPlayback()
        } else if app.link.reachable || lastRemoteState?.playbackSessionID != nil {
            confirmed = await app.link.command(.status)
        } else {
            return
        }
        try Task.checkCancellation()
        // The user may have selected local audio while the phone receipt was pending.
        guard !app.player.localPlaybackSelected, !app.player.state.playing, !app.player.activating else {
            remote = false
            return
        }
        if confirmed, let confirmedState = app.link.remoteState {
            remote = true
            lastRemoteState = confirmedState
            return
        }
        // A failed background status probe must not turn subsequent remote
        // pause/skip commands into local operations. Only an explicit Play tap
        // may select the Watch after the phone confirmation times out.
        guard waitForPhone else { return }
        if remote, let lastRemoteState {
            if lastRemoteState.onlineTrackID != nil || lastRemoteState.playbackSessionID != nil {
                playbackError = lastRemoteState.playbackSessionID != nil ? "未能连接 Mac，未改为手表播放。请检查配对手机和 Wi-Fi。" : "iPhone 未确认播放。可在手表曲库选择已下载音轨或内置声音。"
                throw CancellationError()
            }
            await app.player.prepareForPlayback(lastRemoteState)
        }
        remote = false
    }
}

private struct WatchSystemVolumeControl: WKInterfaceObjectRepresentable {
    let remote: Bool
    let focused: Bool
    var volumeChanged: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(volumeChanged: volumeChanged) }

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: remote ? .companion : .local)
        control.setTintColor(.white)
        context.coordinator.observeLocalVolume()
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        context.coordinator.volumeChanged = volumeChanged
        context.coordinator.updateFocus(focused, control: control)
    }

    static func dismantleWKInterfaceObject(_ control: WKInterfaceVolumeControl, coordinator: Coordinator) {
        coordinator.wantsFocus = false
        control.resignFocus()
        coordinator.observation?.invalidate()
    }

    final class Coordinator {
        var volumeChanged: () -> Void
        var observation: NSKeyValueObservation?
        var wantsFocus = false

        init(volumeChanged: @escaping () -> Void) { self.volumeChanged = volumeChanged }

        func updateFocus(_ focused: Bool, control: WKInterfaceVolumeControl) {
            wantsFocus = focused
            guard focused else { control.resignFocus(); return }
            // SwiftUI may update before attaching the WatchKit object to the page.
            DispatchQueue.main.async { [weak self, weak control] in
                guard self?.wantsFocus == true else { return }
                control?.focus()
            }
        }

        func observeLocalVolume() {
            observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.volumeChanged() }
            }
        }
    }
}

private struct MacWatchVolumeControl: View {
    let volume: Float
    let enabled: Bool
    let valueChanged: (Double) -> Void
    let activity: () -> Void
    @State private var draft = 0.0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
            Slider(value: $draft, in: 0...1).labelsHidden()
            Image(systemName: "speaker.wave.3.fill")
        }
        .focusable(enabled).focused($focused)
        .digitalCrownRotation($draft, from: 0, through: 1, by: 0.025, sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear { draft = Double(volume); focused = enabled }
        .onChange(of: enabled) { _, value in focused = value }
        .onChange(of: volume) { _, value in
            if abs(draft - Double(value)) > 0.005 { draft = Double(value) }
        }
        .onChange(of: draft) { _, value in
            guard enabled, abs(value - Double(volume)) > 0.005 else { return }
            activity(); valueChanged(value)
        }
        .disabled(!enabled)
        .accessibilityLabel("播放音量")
        .accessibilityValue("\(Int(draft * 100))%")
        .accessibilityIdentifier("watch-mac-volume")
    }
}
