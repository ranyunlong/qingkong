import SwiftUI
import QingkongCore

struct RelaxationReminderSettingsSection: View {
    @Environment(AppServices.self) private var app
    var body: some View {
        Section {
            Toggle("放松提醒", isOn: Binding(get: { app.reminders.enabled }, set: { enabled in
                Task { await app.reminders.setEnabled(enabled) }
            })).accessibilityIdentifier("relaxation-reminders-enabled")
            LabeledContent("通知", value: app.reminders.permissionText)
                .font(.subheadline)
            if app.reminders.anyEnabled && !app.reminders.authorized {
                if app.reminders.authorization == .notDetermined {
                    Button("允许通知") { Task { await app.reminders.requestPermissionIfNeeded() } }.buttonStyle(.automatic)
                } else {
                    Button("前往系统通知设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(.automatic)
                }
            }
            if app.reminders.pausedToday {
                Text("今天已暂停，明天恢复").font(.subheadline).foregroundStyle(Color.readableSecondary)
                Button("恢复今天的提醒") { app.reminders.resumeToday() }.buttonStyle(.automatic)
            }
            NavigationLink("提醒规则与放松建议") {
                RelaxationAdviceView(openSounds: { app.reminders.destination = .sounds })
            }
            if let error = app.reminders.error { Text(error).font(.footnote).foregroundStyle(Color.readableSecondary) }
            if let warning = app.health.backgroundDeliveryWarning { Text(warning).font(.footnote).foregroundStyle(Color.readableSecondary) }
        } header: { Text("给自己一点松弛") } footer: {
            Text("默认开启。新的自动 HRV 读数比个人基线低至少 30% 时考虑提醒，每天最多 2 次、间隔至少 4 小时。通知声音和展示遵循系统专注设置；不代表心理压力诊断，也不保证实时检测。")
        }
    }
}

struct VitalReminderSettingsSection: View {
    @Environment(AppServices.self) private var app

    var body: some View {
        Section {
            ForEach(VitalReminderKind.allCases) { kind in
                VStack(alignment: .leading, spacing: 20) {
                    Toggle(kind.title, isOn: Binding(get: { app.reminders.vitalRules[kind]?.delivery.enabled ?? true }, set: { enabled in
                        Task { await app.reminders.setVitalEnabled(kind, enabled) }
                    })).frame(minHeight: 44)
                        .accessibilityIdentifier("reminder-\(kind.rawValue)")
                    if let rule = app.reminders.vitalRules[kind], rule.delivery.enabled {
                        VStack(alignment: .leading, spacing: 10) {
                            Stepper(value: Binding(get: { rule.threshold }, set: { app.reminders.setVitalThreshold(kind, $0) }), in: kind.thresholdRange, step: kind.thresholdStep) {
                                Text("\(kind == .highHeartRate ? "高于" : "低于") \(Int(rule.threshold)) \(kind == .lowOxygen ? "%" : "次/分")")
                                    .font(.subheadline)
                            }.frame(minHeight: 44)
                                .accessibilityIdentifier("threshold-\(kind.rawValue)")
                            Text(kind == .lowOxygen ? "至少两条偏低读数，相隔 1 分钟以上。" : "仅使用明确标记为静息的记录，连续异常记录跨度至少 10 分钟。")
                                .font(.caption).foregroundStyle(Color.readableSecondary)
                            if rule.delivery.mutedUntil.map({ $0 > .now }) ?? false {
                                Button("恢复今天的\(kind.title)提醒") { app.reminders.resumeVitalToday(kind) }.buttonStyle(.automatic)
                            }
                        }
                    }
                }.padding(.vertical, 8)
            }
            NavigationLink("通知检查与测试") { NotificationDiagnosticsView() }
                .accessibilityIdentifier("notification-diagnostics")
        } header: { Text("健康变化提醒") } footer: {
            Text("默认开启，各类每天最多 2 次、间隔至少 4 小时。阈值是可调整的产品规则，不是医疗标准或实时报警；没有足够的新记录时不会提醒。如有不适，请及时就医，不要等待应用通知。")
        }
    }
}

struct NotificationDiagnosticsView: View {
    @Environment(AppServices.self) private var app
    @State private var testing = false
    var body: some View {
        List {
            Section("系统通知") {
                Text(app.reminders.permissionText)
                Text(app.reminders.deliveryText).font(.footnote).foregroundStyle(Color.readableSecondary)
                Button("打开系统通知设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(.automatic)
                Button("发送测试通知") {
                    Task { testing = true; await app.reminders.sendTestNotification(); testing = false }
                }.buttonStyle(.automatic).disabled(testing).accessibilityIdentifier("send-test-notification")
                if let status = app.reminders.testStatus { Text(status).font(.footnote) }
            }
            Section("最近一次数据检查") {
                if let date = app.reminders.lastCheckedAt {
                    Text(date, format: .dateTime.month().day().hour().minute().second())
                } else { Text("尚未完成健康数据检查") }
                LabeledContent("HRV", value: app.reminders.checkResults["hrv"] ?? "等待可读取的健康记录")
                ForEach(VitalReminderKind.allCases) { kind in
                    LabeledContent(kind.title, value: app.reminders.checkResults[kind.rawValue] ?? "等待可读取的健康记录")
                }
                if let warning = app.health.backgroundDeliveryWarning { Text(warning).font(.footnote) }
                if let warning = app.health.observerWarning { Text(warning).font(.footnote) }
                if let error = app.health.error { Text(error).font(.footnote) }
                if let error = app.reminders.error { Text(error).font(.footnote) }
                Button("刷新检查") {
                    Task { await app.health.restoreBackgroundDelivery(); await app.health.refresh() }
                }.buttonStyle(.automatic)
            }
            Section("后台检查记录") {
                if let date = app.health.lastObserverUpdateAt {
                    LabeledContent("健康更新回调") { Text(date, format: .dateTime.month().day().hour().minute().second()) }
                } else { Text("尚未记录健康更新回调") }
                if let date = app.reminders.lastBackgroundCheckedAt {
                    LabeledContent("上次后台判断") { Text(date, format: .dateTime.month().day().hour().minute().second()) }
                    LabeledContent("HRV", value: app.reminders.backgroundCheckResults["hrv"] ?? "尚无判断结果")
                } else { Text("尚未记录后台判断") }
                if let date = app.reminders.lastSubmittedAt {
                    LabeledContent("最近健康提醒提交") { Text(date, format: .dateTime.month().day().hour().minute().second()) }
                } else { Text("尚未向系统提交健康提醒") }
                Text("记录会在重新打开应用后保留。健康更新回调也可能发生在前台，不等同于后台成功送达；提交成功也不等同于通知已经展示。")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            }.accessibilityIdentifier("notification-background-diagnostics")
            Section {
                Text("测试通知用于检查系统送达，不代表健康异常。健康提醒只根据新记录判断；授权成功也不表示健康库中一定有数据。后台更新、通知展示及手表镜像由系统安排。")
                Text("不需要一直停留在应用界面。请避免从多任务中强制关闭应用；新数据到达及后台处理的时间由系统决定，锁屏时健康数据也可能暂时无法读取。")
            }.font(.footnote)
        }.navigationTitle("通知检查").navigationBarTitleDisplayMode(.inline)
            .task { await app.reminders.refreshAuthorization() }
    }
}

struct RelaxationAdviceView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.dismiss) private var dismiss
    var inSheet = false
    let openSounds: () -> Void
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "leaf").font(.largeTitle).foregroundStyle(app.scene.accent).accessibilityHidden(true)
                    Text("把节奏放慢一点").font(.title2.weight(.semibold))
                    Text("如果你正忙碌，可以留一小段时间照顾自己。按当下的感受选择就好。")
                        .foregroundStyle(Color.readableSecondary)
                }.padding(.vertical, 10)
            }
            Section("试一件轻松的小事") {
                Label("放下手边的事，休息一两分钟。", systemImage: "cup.and.saucer")
                Label("放松肩膀，用舒服的节奏自然呼吸。", systemImage: "wind")
                Label("如果方便，起身走走，看看远处。", systemImage: "figure.walk")
                Button("听听自然声音", systemImage: "waveform", action: openSounds).buttonStyle(.automatic)
            }
            Section("什么情况下会提醒？") {
                Text("使用同一来源此前 7 天的日均 HRV 作为个人基线，至少需要 3 个有效日。")
                Text("最新一条自动 HRV 读数比个人基线低至少 30%，且距当前不超过 1 小时，就会考虑提醒，不再要求多条读数跨度达到十分钟。最新读数已恢复时不提醒。")
                Text("30% 是首版的产品参考规则，未经临床验证，不能判断你是否有心理压力。活动、呼吸和睡眠等也会影响 HRV。")
                Text("每天最多两次，至少间隔四小时。后台更新由系统安排；没有足够的新记录时不会提醒，不补发旧提醒。")
                Text("通知按 iPhone 的系统规则显示在手机或配对手表上，遵循专注模式与通知设置。无需两端各发一次。")
            }.font(.subheadline)
            Section("提醒样例") {
                Text("给自己一点放松时间").font(.headline)
                Text("最近的 HRV 较个人参考水平有明显变化。可以先休息片刻，按舒服的节奏呼吸，或听一段自然声音。这不代表你一定有心理压力。")
                Text("这里是文案预览，不代表已检测到你的数据变化。")
                    .font(.caption).foregroundStyle(Color.readableSecondary)
            }
            if app.reminders.enabled && !app.reminders.pausedToday {
                Section {
                    Button("今天不再提醒") {
                        Task { await app.reminders.pauseToday(); dismiss() }
                    }.buttonStyle(.automatic)
                }
            }
        }.tint(app.scene.accent).navigationTitle("放松一下").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if inSheet {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(.automatic) }
                }
            }
    }
}
