import SwiftUI
import QingkongCore

struct BedtimeView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var mood = 3
    @State private var stress = 2
    @State private var recordMood = false
    @State private var track: Track = .rain
    @State private var scene: SceneTheme = .night
    @State private var minutes = 30
    @State private var savePlan = true
    @State private var name = "我的睡前方案"
    @State private var moodRecordID = UUID()
    @State private var planID = UUID()
    @State private var starting = false
    @State private var error: String?
    var body: some View {
        Form {
            if step == 0 {
                Section("先关心此刻的你") {
                    Toggle("记下此刻心情（可跳过）", isOn: $recordMood)
                    if recordMood {
                        Picker("心情", selection: $mood) { ForEach(1...5, id: \.self) { Text(MoodRecord.labels[$0 - 1]).tag($0) } }
                        Picker("主观压力", selection: $stress) { ForEach(1...5, id: \.self) { Text("\($0)/5").tag($0) } }
                    }
                    Button { step = 1 } label: {
                        Text("继续").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }.qingkongGlassButton(prominent: true)
                    Text("不记录也可以进入安静播放。").font(.footnote)
                }
            } else {
                Section("声音与场景") {
                    Picker("本地声音", selection: $track) { ForEach(Track.allCases) { Text($0.name).tag($0) } }
                    Picker("场景", selection: $scene) { ForEach(SceneTheme.allCases) { Text($0.name).tag($0) } }
                    Picker("停止时间", selection: $minutes) { Text("15 分钟").tag(15); Text("30 分钟").tag(30); Text("60 分钟").tag(60) }
                    Toggle("保存为个人方案", isOn: $savePlan)
                    if savePlan { TextField("方案名称", text: $name).onChange(of: name) { _, value in name = String(value.prefix(40)) } }
                    Button { Task { await start() } } label: {
                        Text("开始安静播放").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }.qingkongGlassButton(prominent: true).disabled(starting || app.player.activating)
                    Button { step = 0 } label: {
                        Text("返回心情选择").font(.body).frame(maxWidth: .infinity, minHeight: 44)
                    }.qingkongGlassButton()
                }
            }
            if !app.companion.bedtimePlans.isEmpty {
                Section("喜欢的睡前方案") {
                    ForEach(app.companion.bedtimePlans) { plan in
                        Button {
                            Task {
                                app.store.updatePreferences { $0.selectScene(plan.scene) }
                                await app.player.select(plan.track, autoplay: true)
                                let receipt = await app.player.handle(AudioCommand(action: .timer, amount: Double(plan.stopAfterMinutes)))
                                if let message = receipt.error { error = message }
                                else if app.player.state.playing { dismiss() } else { error = app.player.error }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.name).font(.body.weight(.medium))
                                Text("\(plan.track.name) · \(plan.scene.name) · \(plan.stopAfterMinutes) 分钟").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.qingkongGlassButton().swipeActions { Button("删除", role: .destructive) {
                            do { try app.companion.deletePlan(plan.id) } catch { self.error = "方案暂未删除，请重试。" }
                        } }
                    }
                }
            }
            if let error { Text(error).font(.footnote) }
        }.navigationTitle("睡前陪伴")
    }

    private func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        do {
            if recordMood { try app.store.save(MoodRecord(id: moodRecordID, mood: mood, stress: stress, note: "")) }
            if savePlan { try app.companion.savePlan(.init(id: planID, name: name.isEmpty ? "我的睡前方案" : name, track: track, scene: scene, stopAfterMinutes: minutes)) }
            app.store.updatePreferences { $0.selectScene(scene) }
            await app.player.select(track, autoplay: true)
            let receipt = await app.player.handle(AudioCommand(action: .timer, amount: Double(minutes)))
            if let message = receipt.error { error = message }
            else if app.player.state.playing { dismiss() } else { error = app.player.error }
        } catch { self.error = "记录或方案暂未保存，请重试。" }
    }
}
