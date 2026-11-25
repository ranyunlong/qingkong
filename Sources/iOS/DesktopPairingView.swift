import SwiftUI
import QingkongCore

struct DesktopPairingView: View {
    @Environment(AppServices.self) private var app
    @State private var consentingDevice: PhoneMacDevice?
    @State private var showsConsent = false
    @State private var showsHelp = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 24) {
                    Image(systemName: "iphone").font(.system(size: 38))
                    Image(systemName: app.desktopSync.isConnected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.title2).foregroundStyle(app.desktopSync.isConnected ? Color.green : Color.secondary)
                    Image(systemName: "desktopcomputer").font(.system(size: 38))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(app.desktopSync.isConnected ? "iPhone 与 Mac 已连接" : "正在查找同账号的 Mac")
                Label(app.desktopSync.isConnected ? "设备已连接" : "正在查找 Mac",
                      systemImage: app.desktopSync.isConnected ? "checkmark.circle" : "wifi")
                if !app.desktopSync.isConnected {
                    Text("同一 Apple ID · 同一 Wi-Fi · 打开 Mac 小晴空")
                        .font(.footnote).foregroundStyle(Color.readableSecondary)
                    Button("重新检查", systemImage: "arrow.clockwise") { Task { await app.desktopSync.start() } }
                }
            }

            if !app.desktopSync.devices.isEmpty {
                Section("附近的 Mac") {
                    ForEach(app.desktopSync.devices) { device in
                        deviceRow(device)
                    }
                }
                Section {
                    if app.desktopSync.devices.count > 1 {
                        Picker("接收设备", selection: Binding(get: {
                            app.desktopSync.selectedReportDeviceID ?? ""
                        }, set: { app.desktopSync.selectedReportDeviceID = $0.isEmpty ? nil : $0 })) {
                            Text("选择 Mac").tag("")
                            ForEach(app.desktopSync.devices) { Text($0.name).tag($0.id) }
                        }
                    }
                    Button {
                        Task { await app.desktopSync.syncReport() }
                    } label: {
                        HStack {
                            Label("立即同步报表", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if app.desktopSync.isSyncing { ProgressView().controlSize(.small) }
                        }
                    }.disabled(app.desktopSync.isSyncing || app.health.isDemo)
                } footer: {
                    Text(app.desktopSync.reportFeedback ?? "自动同步仅在手机前台进行。")
                }
            }

            let offline = app.desktopSync.authorizedReportMacs.filter { $0.connectedDeviceID == nil }
            if !offline.isEmpty {
                Section("已授权的设备") {
                    ForEach(offline) { mac in
                        HStack {
                            Label(mac.name, systemImage: "desktopcomputer")
                            Spacer()
                            Text("离线").font(.caption).foregroundStyle(Color.readableSecondary)
                            Button("关闭自动同步") { app.desktopSync.setAutomaticReport(false, hostID: mac.id) }
                                .font(.caption)
                        }
                    }
                }
            }

            Section {
                Label("音乐设备在助眠页切换", systemImage: "music.note")
                Label("仅同步每日汇总", systemImage: "lock.shield")
                Button("连接帮助与同步范围", systemImage: "questionmark.circle") { showsHelp = true }
            }
        }
        .navigationTitle("连接 Mac")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("开启自动同步？", isPresented: $showsConsent, titleVisibility: .visible) {
            if let device = consentingDevice, let hostID = device.hostID {
                Button("允许同步到这台 Mac") { app.desktopSync.setAutomaticReport(true, hostID: hostID) }
            }
            Button("取消", role: .cancel) { consentingDevice = nil }
        } message: {
            Text("允许将最近 38 天的健康日均、睡眠、心情与压力计数、已完成陪伴汇总，自动发送到“\(consentingDevice?.name ?? "Mac")”。仅在手机前台、局域网连接时同步，不含日记正文或原始健康记录，可随时关闭。")
        }
        .sheet(isPresented: $showsHelp) {
            NavigationStack {
                Form {
                    Section("连接") {
                        Label("两端登录同一 Apple ID", systemImage: "person.crop.circle")
                        Label("连接同一 Wi-Fi", systemImage: "wifi")
                        Label("打开 Mac 上的小晴空", systemImage: "desktopcomputer")
                        Text(app.desktopSync.trustStatus).font(.footnote)
                        if !app.desktopSync.message.isEmpty {
                            Text(app.desktopSync.message).font(.footnote)
                        }
                    }
                    Section("同步") {
                        Text("每台 Mac 单独授权。手机进入后台后不再发起新的报表传输，重新打开后检查更新。关闭自动同步不会删除 Mac 已保存的报表，可在 Mac 报表页清除。")
                        Text("连接凭据使用 iCloud 私有空间；报表只在设备间通过局域网加密传输。")
                    }
                    Section("音乐") {
                        Label("助眠页 → AirPlay → 选择 Mac", systemImage: "airplay.audio")
                        Text("手机负责播放与停止定时，Mac 接收声音并同步画面。Mac 的系统设置需开启 AirPlay 接收器；使用音频输出，不使用屏幕镜像。报表授权不会切换音乐设备。")
                    }
                }
                .navigationTitle("连接帮助")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showsHelp = false } } }
            }
        }
    }

    @ViewBuilder private func deviceRow(_ device: PhoneMacDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(device.name, systemImage: "desktopcomputer").font(.headline)
            if !device.supportsMusicCatalog {
                Label("更新 Mac 后可同步专辑目录", systemImage: "square.stack")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            } else if let error = app.desktopSync.catalogErrors[device.id] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            } else if let date = app.desktopSync.catalogSyncedAt[device.id] {
                Label("专辑已同步 \(date.formatted(date: .omitted, time: .shortened))", systemImage: "square.stack")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            }
            if let hostID = device.hostID, device.supportsAutoReport {
                Toggle("自动同步报表", isOn: Binding(get: {
                    app.desktopSync.automaticReportEnabled(for: hostID)
                }, set: { enabled in
                    if enabled { consentingDevice = device; showsConsent = true }
                    else { app.desktopSync.setAutomaticReport(false, hostID: hostID) }
                }))
            } else {
                Label("更新 Mac 后可开启自动同步", systemImage: "arrow.down.circle")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            }
            if let error = app.desktopSync.reportErrors[device.id] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
            } else if app.desktopSync.reportStates[device.id] == .syncing {
                HStack { ProgressView().controlSize(.small); Text("正在同步").font(.footnote) }
            } else if let date = app.desktopSync.reportSyncedAt[device.id] {
                Label("已同步 \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            }
        }.padding(.vertical, 4)
    }
}
