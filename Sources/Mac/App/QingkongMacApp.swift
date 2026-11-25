import AppKit
import SwiftUI

@main
struct QingkongMacApp: App {
    @NSApplicationDelegateAdaptor(QingkongMacAppDelegate.self) private var appDelegate
    @State private var connection = MacDeviceConnection()
    @State private var player = MacAudioPlayer()
    @State private var trust = DesktopAccountTrust()
    @State private var library = MacLibrary()
    @State private var showsMenuBarPlayer = true

    var body: some Scene {
        WindowGroup("小晴空", id: "main") {
            MacContentView(connection: connection, player: player, library: library)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    player.enableSystemPlayback { [weak connection] in connection?.isTransferring == false }
                    library.attach(player: player)
                    await library.refresh()
                }
                .task { await connection.startHosting(player: player, trust: trust, library: library) }
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandMenu("设备") {
                Button("刷新 Apple ID 设备信任") { Task { await connection.refreshTrust() } }
                Button("断开 iPhone") { connection.disconnect() }.disabled(!connection.isConnected)
            }
            CommandMenu("播放") {
                Button(player.playbackIntent ? "暂停" : "播放") { library.togglePlayback(player: player) }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(connection.isTransferring || player.isPreparing || !player.controlsAvailable ||
                              (!player.hasSelection && library.playableAlbums.isEmpty && !library.showsPortableAlbum))
                Button("上一首") { Task { await player.previous() } }.disabled(!player.hasSelection || !player.controlsAvailable)
                Button("下一首") { Task { await player.next() } }.disabled(!player.hasSelection || !player.controlsAvailable)
                Button("停止") { player.stop() }.disabled((!player.hasSelection && !player.isPreparing) || !player.controlsAvailable)
            }
        }
        MenuBarExtra("小晴空", systemImage: "cloud.sun", isInserted: $showsMenuBarPlayer) {
            MacMenuBarPlayer(player: player, library: library, connection: connection)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: player.isPhonePlayback, initial: true) { _, followingPhone in
            showsMenuBarPlayer = !followingPhone
        }
        Settings {
            MacSettingsView(connection: connection, library: library)
        }
    }
}

private final class QingkongMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}

private struct MacSettingsView: View {
    let connection: MacDeviceConnection
    let library: MacLibrary
    @State private var confirmsClear = false
    @State private var showsDownloads = false

    var body: some View {
        Form {
            Section("设备连接") {
                Text(connection.serviceStatus).foregroundStyle(.secondary)
                Button("刷新设备信任") { Task { await connection.refreshTrust() } }
            }
            Section("本机数据") {
                Button("管理音乐下载", systemImage: "internaldrive") { showsDownloads = true }
                Button("清除本机报表") { confirmsClear = true }
                    .disabled(connection.report == nil || connection.isSyncing)
                Text("自动报表在 iPhone 中为这台 Mac 开启。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 480)
        .sheet(isPresented: $showsDownloads) { MacDownloadsView(downloads: library.downloads) }
        .confirmationDialog("清除这台 Mac 的报表缓存？", isPresented: $confirmsClear) {
            Button("清除本机报表", role: .destructive) { connection.clearReport() }
        } message: { Text("手机中的记录会继续保留。") }
    }
}
