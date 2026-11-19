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
    @GestureState private var touchingVolume = false
    private var state: AudioState { remote ? (app.link.remoteState ?? lastRemoteState ?? app.player.state) : app.player.state }
    private var busy: Bool { operating || switching || app.link.remoteBusy || app.player.activating }
    private var canAdjustVolume: Bool { pageVisible && scenePhase == .active && !busy && playbackError == nil }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(state.track.image).resizable().scaledToFill().frame(width: 100, height: 90).clipped().clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
            Text(state.track.name).font(.headline).lineLimit(1).accessibilityIdentifier("watch-current-track")
            ZStack {
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
                if !showingVolume {
                    controls(state)
                        .padding(.vertical, 4)
                        .background(.black)
                }
            }
            .frame(height: 44)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .digitalCrownAccessory(.hidden)
        .accessibilityHint("旋转数码表冠调节音量")
        .accessibilityAction(named: "调节音量", revealVolume)
        .navigationTitle("")
        .alert("播放未完成", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
            Button("知道了", role: .cancel) { playbackError = nil }
        } message: {
            Text(playbackError ?? "请稍后重试。")
        }
            .task {
                try? await chooseLocation()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
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
            .onAppear { pageVisible = true }
            .onDisappear { pageVisible = false; showingVolume = false }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !busy { Task { try? await chooseLocation() } }
            }
            .onChange(of: app.link.remoteState) { _, value in
                if remote, let value { lastRemoteState = value }
            }
    }

    private func controls(_ state: AudioState) -> some View {
        HStack(spacing: 10) {
            playbackButton("上一首", symbol: "backward.end.fill", action: .previous)
            playbackButton(state.playing ? "暂停" : "播放", symbol: state.playing ? "pause.fill" : "play.fill", action: .playPause)
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
            guard !busy else { return }
            operating = true
            defer { operating = false }
            let operation: AudioCommand.Action = action == .playPause && state.playing ? .pause : action
            do {
                try await chooseLocation(waitForPhone: true)
                try Task.checkCancellation()
            } catch { return }
            // A newly confirmed phone may already be playing; a Play tap must not pause it.
            if operation == .playPause, state.playing { return }
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
        // Keep an active local session stable through brief connection changes.
        guard !app.player.state.playing && !app.player.activating else { remote = false; return }
        switching = true
        defer { switching = false }
        let confirmed: Bool
        if waitForPhone {
            confirmed = try await app.link.confirmPhoneForPlayback()
        } else if app.link.reachable {
            confirmed = await app.link.command(.status)
        } else {
            return
        }
        try Task.checkCancellation()
        if confirmed, let confirmedState = app.link.remoteState {
            remote = true
            lastRemoteState = confirmedState
            return
        }
        if remote, let lastRemoteState {
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
