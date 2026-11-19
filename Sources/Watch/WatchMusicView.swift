import SwiftUI
import WatchKit
import QingkongCore

struct WatchMusicView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var remote = false
    @State private var switching = false
    @State private var operating = false
    @State private var lastRemoteState: AudioState?
    @State private var playbackError: String?
    private var state: AudioState { remote ? (app.link.remoteState ?? lastRemoteState ?? app.player.state) : app.player.state }
    private var busy: Bool { operating || switching || app.link.remoteBusy || app.player.activating }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(state.track.image).resizable().scaledToFill().frame(maxWidth: 100).frame(height: 90).clipped().clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
                WatchSystemVolumeControl(remote: remote, focused: scenePhase == .active && !busy && playbackError == nil)
                    .id(remote)
                    .frame(width: 44, height: 44)
                    .allowsHitTesting(!busy)
                    .accessibilityLabel(remote ? "iPhone 音量" : "手表音量")
                    .accessibilityHint("旋转数码表冠调节音量")
                    .accessibilityIdentifier("watch-system-volume")
            }
            Text(state.track.name).font(.headline).lineLimit(1).accessibilityIdentifier("watch-current-track")
            controls(state)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
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
                    if scenePhase == .active, !busy { try? await chooseLocation() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !busy { Task { try? await chooseLocation() } }
            }
            .onChange(of: app.link.remoteState) { _, value in
                if remote, let value { lastRemoteState = value }
            }
    }

    private func controls(_ state: AudioState) -> some View {
        HStack(spacing: 10) {
            Button("上一首", systemImage: "backward.end.fill") { perform(.previous) }.labelStyle(.iconOnly)
            Button(state.playing ? "暂停" : "播放", systemImage: state.playing ? "pause.fill" : "play.fill") { perform(.playPause) }.labelStyle(.iconOnly)
            Button("下一首", systemImage: "forward.end.fill") { perform(.next) }.labelStyle(.iconOnly)
        }.buttonStyle(.bordered).disabled(busy)
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

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: remote ? .companion : .local)
        control.setTintColor(.white)
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        if focused { control.focus() }
        else { control.resignFocus() }
    }

    static func dismantleWKInterfaceObject(_ control: WKInterfaceVolumeControl, coordinator: ()) {
        control.resignFocus()
    }
}
