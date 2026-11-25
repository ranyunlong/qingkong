import AppKit
import SwiftUI

struct MacPairingView: View {
    let connection: MacDeviceConnection
    @State private var showsHelp = false
    @State private var isRetrying = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                deviceIllustration.padding(.top, 20)
                VStack(spacing: 8) {
                    Text(connection.isConnected ? connection.connectedName ?? "iPhone 已连接" : connection.isHosting ? "等待你的 iPhone" : "连接你的设备")
                        .font(.largeTitle.bold())
                    Text(connection.isConnected ? "音乐接续与个人报表，在设备之间。" : "同一 Apple ID，同一 Wi-Fi。")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    connectionStep("账号验证", symbol: "person.crop.circle.badge.checkmark", completed: connection.trustReady, active: !connection.trustReady)
                    stepLine(completed: connection.isHosting)
                    connectionStep("发现手机", symbol: "antenna.radiowaves.left.and.right", completed: connection.isConnected, active: connection.isHosting && !connection.isConnected)
                    stepLine(completed: connection.isConnected)
                    connectionStep("已连接", symbol: "checkmark.circle", completed: connection.isConnected, active: false)
                }.frame(maxWidth: 500)
                if let issue = connection.connectionIssue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: 520)
                }
                HStack(spacing: 12) {
                    if connection.isConnected {
                        Button("断开连接") { connection.disconnect() }
                    } else {
                        Button {
                            isRetrying = true
                            Task { await connection.refreshTrust(); isRetrying = false }
                        } label: {
                            HStack(spacing: 7) {
                                if isRetrying { ProgressView().controlSize(.small) }
                                Text(isRetrying ? "正在重试" : "重新尝试")
                            }
                        }
                        .buttonStyle(.borderedProminent).disabled(isRetrying)
                    }
                    if !connection.trustReady || connection.connectionIssue != nil {
                        Button("系统设置", systemImage: "gearshape") { openSystemSettings() }
                    }
                    Button("连接帮助", systemImage: "questionmark.circle") { showsHelp = true }
                }
                if connection.isHosting && !connection.isConnected {
                    Label("打开 iPhone 小晴空 → 个性化 → 连接 Mac。", systemImage: "hand.tap")
                        .font(.callout).foregroundStyle(.secondary)
                }
                catalogStatus
                reportStatus
                Spacer(minLength: 0)
            }
            .padding(28).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showsHelp) { helpSheet }
    }

    private var deviceIllustration: some View {
        HStack(spacing: 25) {
            Image(systemName: "iphone").font(.system(size: 68, weight: .ultraLight))
            Image(systemName: connection.isConnected ? "arrow.left.arrow.right" : "arrow.right")
                .font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
            Image(systemName: "desktopcomputer").font(.system(size: 80, weight: .ultraLight))
        }
        .foregroundStyle(connection.isConnected ? Color.accentColor : Color.primary)
        .frame(height: 120).accessibilityLabel(connection.isConnected ? "iPhone 与 Mac 已连接" : "连接 iPhone 与 Mac")
    }

    private func connectionStep(_ title: String, symbol: String, completed: Bool, active: Bool) -> some View {
        VStack(spacing: 9) {
            Image(systemName: completed ? "checkmark.circle.fill" : symbol)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(completed ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())
            Text(title).font(.callout).foregroundStyle(completed || active ? Color.primary : Color.secondary)
        }.frame(width: 100)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(completed ? "已完成" : active ? "等待完成" : "尚未完成")")
    }

    private func stepLine(completed: Bool) -> some View {
        Rectangle().fill(completed ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2))
            .frame(height: 1).offset(y: -13).accessibilityHidden(true)
    }

    private var catalogStatus: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack").font(.system(size: 24)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("专辑目录").font(.headline)
                    if connection.hasMusicCatalog {
                        Text("\(connection.catalogAlbumCount) 张专辑").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if connection.isConnected && !connection.phoneSupportsMusicCatalog {
                    Text("更新 iPhone 小晴空后可自动同步专辑。")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let notice = connection.catalogNotice {
                    Text(notice).font(.callout).foregroundStyle(.secondary)
                } else if let date = connection.catalogReceivedAt {
                    Text("已同步 \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(connection.isConnected ? "在 iPhone 刷新曲库，自动同步专辑列表。" : "连接后自动同步，音乐由 Mac 独立下载。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 580)
    }

    private var reportStatus: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.xyaxis.line").font(.system(size: 24)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("自动报表").font(.headline)
                    Text(syncTitle).font(.caption).foregroundStyle(.secondary)
                    if connection.isSyncing { ProgressView().controlSize(.mini) }
                }
                Text("在 iPhone 中为这台 Mac 开启，并保持小晴空在前台。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 580)
    }

    private var syncTitle: String {
        switch connection.reportSyncState {
        case .disabled: "未开启"
        case .enabled: "手机已开启"
        case .syncing: "正在接收"
        case .failed: "同步未完成"
        case nil: "等待手机确认"
        }
    }

    private var helpSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("连接 iPhone").font(.title2.bold())
                Spacer()
                Button("完成") { showsHelp = false }.keyboardShortcut(.defaultAction)
            }
            Label("两台设备使用同一 Apple ID，并连接同一局域网。", systemImage: "person.crop.circle")
            Label("打开 iPhone 小晴空 → 个性化 → 连接 Mac。", systemImage: "iphone.and.arrow.forward")
            Label("助眠页 → AirPlay → 选择这台 Mac。", systemImage: "airplay.audio")
            Label("系统设置 → 通用 → 隔空投送与接力 → 开启 AirPlay 接收器。", systemImage: "speaker.wave.2")
            Label("自动报表需要在手机上逐台 Mac 开启；保持手机 App 在前台以完成同步。", systemImage: "chart.xyaxis.line")
            Text(connection.serviceStatus).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("未连接不代表权限被拒绝。可在系统设置中检查 Apple ID、Wi-Fi 与小晴空的本地网络访问。")
                .font(.callout).foregroundStyle(.secondary)
            Text("设备之间加密传输每日汇总；原始健康记录与日记正文留在手机。")
                .font(.caption).foregroundStyle(.secondary)
            Button("打开系统设置", systemImage: "gearshape") { openSystemSettings() }
        }.padding(28).frame(width: 500)
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:") else { return }
        NSWorkspace.shared.open(url)
    }
}
