import SwiftUI

struct RelaxationReminderSettingsSection: View {
    @Environment(AppServices.self) private var app
    var body: some View {
        Section {
            Toggle("放松提醒", isOn: Binding(get: { app.reminders.enabled }, set: { enabled in
                Task { await app.reminders.setEnabled(enabled) }
            })).accessibilityIdentifier("relaxation-reminders-enabled")
            LabeledContent("通知", value: app.reminders.permissionText)
                .font(.subheadline)
            if app.reminders.enabled && !app.reminders.authorized {
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
            Text("默认开启。仅在近期 HRV 持续明显低于个人基线时提醒，每天最多 2 次、间隔至少 4 小时。通知声音和展示遵循系统专注设置；不代表心理压力诊断，也不保证实时检测。")
        }
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
                Text("最近一小时内，连续两次 HRV 均比基线低至少 30%，两次间隔至少 10 分钟，且最新读数不超过 15 分钟，才会考虑提醒。")
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
