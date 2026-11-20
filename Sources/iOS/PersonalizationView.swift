import SwiftUI
import Photos
import UniformTypeIdentifiers
import ClockKit
import QingkongCore

struct PersonalizationView: View {
    @Environment(AppServices.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var wallpaper = false
    @State private var faceGuide = false
    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal) {
                    GlassButtonGroup(spacing: 10) {
                      HStack(spacing: 14) {
                        ForEach(SceneTheme.allCases) { scene in
                            Button {
                                app.store.updatePreferences { $0.selectScene(scene) }
                            } label: {
                                VStack(spacing: 9) {
                                    ZStack(alignment: .bottomTrailing) {
                                        Image(scene.image).resizable().scaledToFill().frame(width: 86, height: 112).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                                        if app.scene == scene { Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, scene.accent).padding(6) }
                                    }
                                    Text(scene.name).font(.subheadline)
                                }
                            }.qingkongGlassButton(shape: .roundedRectangle(radius: 20)).accessibilityLabel("选择\(scene.name)主题")
                                .accessibilityValue(app.scene == scene ? "已选中" : "未选中")
                                .accessibilityIdentifier("theme-\(scene.id)")
                        }
                      }
                    }.padding(.vertical, 4)
                }.scrollIndicators(.hidden)
                Button("预览与保存桌面图片", systemImage: "photo") { wallpaper = true }
            } header: { Text("换一种日常") } footer: { Text("按钮、开关和重点文字与场景协调变化。手动选择主题会关闭压力联动。") }

            Section {
                Toggle("跟随压力感受换景", isOn: Binding(get: { app.store.preferences.automaticScene }, set: { value in app.store.updatePreferences { $0.automaticScene = value } }))
                    .accessibilityIdentifier("auto-scene")
                Picker("我喜欢的放松场景", selection: Binding(get: { app.store.preferences.relaxingScene }, set: { value in app.store.updatePreferences { $0.relaxingScene = value } })) {
                    ForEach(SceneTheme.allCases.filter { $0 != .clear }) { Text($0.name).tag($0) }
                }
            } header: { Text("跟随感受，温柔换景") } footer: { Text("仅根据今天最新的主动压力记录联动。达到 4/5 时切换应用内场景，不自动更改系统壁纸。") }

            RelaxationReminderSettingsSection()
            VitalReminderSettingsSection()

            Section {
                HStack(spacing: 12) {
                    Image("mood-\(MoodSummary.latest(in: app.store.records)?.value ?? 3)")
                        .resizable().scaledToFit().frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("心情团子").font(.headline)
                        Text("随最近的心情记录更新，陪你看看日常健康。")
                            .font(.footnote).foregroundStyle(Color.readableSecondary)
                    }
                }
                Text("主屏幕：长按空白处 → 编辑 → 添加小组件 → 小晴空 → 心情团子。支持小号和中号。")
                    .font(.footnote)
                Text("锁定屏幕：长按锁屏 → 自定 → 锁定屏幕 → 添加小组件 → 小晴空。")
                    .font(.footnote)
            } header: { Text("屏幕上的小团子") } footer: {
                Text("组件显示最近可读取的健康数据及采样时间，按系统调度刷新。点按打开应用；无记录时显示空缺。")
            }

            Section {
                watchPreview
                Picker("显示指标", selection: Binding(get: { app.store.preferences.complicationMetric }, set: { value in app.store.updatePreferences { $0.complicationMetric = value } })) {
                    ForEach(HealthMetric.allCases) { Text($0.name).tag($0) }
                }
                Toggle("显示迷你趋势", isOn: Binding(get: { app.store.preferences.showComplicationTrend }, set: { value in app.store.updatePreferences { $0.showComplicationTrend = value } }))
                Button("在系统中添加表盘组件", systemImage: "applewatch") { faceGuide = true }
                Label(app.link.syncMessage, systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(Color.readableSecondary)
                if let error = app.link.error { Text(error).font(.footnote).foregroundStyle(Color.readableSecondary) }
            } header: { Text("手腕上的晴空") } footer: { Text("团子预览对应手表 App 页面；系统表盘中的「心情团子」是进入页面的入口。下面的指标与趋势设置用于原有健康组件。组件按系统调度更新。") }

            Section("数据与隐私") {
                Button("检查 Apple 健康连接", systemImage: "heart.text.clipboard") { Task { await app.health.authorize() } }
                Button("打开应用设置", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                NavigationLink("隐私说明") { PrivacyView() }
                LabeledContent("版本", value: "0.1.0 · 开发版")
            }
        }.tint(app.scene.accent).navigationTitle("个性化").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(.automatic) } }
            .sheet(isPresented: $wallpaper) { WallpaperView(scene: app.scene) }
            .sheet(isPresented: $faceGuide) { WatchFaceGuideView() }
    }

    private var watchPreview: some View {
        let mood = MoodSummary.latest(in: app.store.records)
        return VStack(spacing: 10) {
            Text("手表团子页面预览").font(.caption).foregroundStyle(Color.readableSecondary)
            VStack(spacing: 8) {
                HStack { Spacer(); Text(Date.now, style: .time).font(.caption2.monospacedDigit()) }
                Image("mood-\(mood?.value ?? 3)").resizable().scaledToFit().frame(height: 100)
                Text(mood?.label ?? "心情待记录").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(HealthMetric.allCases) { metric in
                        VStack(spacing: 3) {
                            Text(metric.name).font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(app.health.latest(metric).map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                            Text(metric.unit).font(.system(size: 8)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }.foregroundStyle(.white).padding(20).frame(width: 176).background(.black, in: RoundedRectangle(cornerRadius: 38))
            Text("健康数值取自 iPhone；真实表盘使用手表上的可读记录。 ").font(.caption2).foregroundStyle(Color.readableSecondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

struct WallpaperView: View {
    @Environment(\.dismiss) private var dismiss
    let scene: SceneTheme
    @State private var saving = false
    @State private var result: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(scene.image).resizable().scaledToFill().frame(width: 220, height: 360).clipped().clipShape(RoundedRectangle(cornerRadius: 28))
                    Text(scene.caption).font(.headline)
                    Button { Task { await save() } } label: { Label("保存到照片", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(8) }
                        .qingkongGlassButton(prominent: true).disabled(saving)
                    if let url = Bundle.main.url(forResource: scene.image, withExtension: scene == .clear ? "png" : "jpg") {
                        ShareLink(item: url) { Label("分享图片", systemImage: "square.and.arrow.up") }
                    }
                    if let result { Text(result).font(.subheadline).foregroundStyle(Color.readableSecondary) }
                    Text("保存后，可在「设置 → 墙纸」中选择图片。压力联动只改变应用内场景，系统墙纸由你决定。 ").font(.footnote).foregroundStyle(Color.readableSecondary).multilineTextAlignment(.center)
                }.padding(24)
            }.navigationTitle("留住喜欢的风景").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(.automatic) } }
        }.tint(scene.accent)
    }
    private func save() async {
        saving = true
        defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { result = "尚不能保存照片，你可以使用分享，或在设置中允许添加照片。"; return }
        guard let image = UIImage(named: scene.image) else { result = "图片暂时无法打开，请重试。"; return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
            result = "图片已保存到照片，可以在系统设置中选为墙纸。"
        } catch { result = "图片尚未保存，请稍后重试。" }
    }
}

struct WatchFaceGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var message: String?
    var body: some View {
        NavigationStack {
            List {
                Section("把晴空放到表盘上") {
                    Label("先在配对的 Apple Watch 安装晴空并打开一次。", systemImage: "1.circle")
                    Label("长按当前表盘，点「编辑」，滑到复杂功能。", systemImage: "2.circle")
                    Label("选一个圆形、大矩形或单行文字位置，在「所有 App」中找到「小晴空」，再选 HRV、心率或血氧。", systemImage: "3.circle")
                    Label("若选择「跟随 iPhone 配置」，此页的指标与趋势设置会在连接后同步到手表。", systemImage: "4.circle")
                }
                Section("心情团子") {
                    Text("选择系统表盘中的圆形或大矩形位置，在小晴空里选择「心情团子」。圆形显示团子与 HRV，矩形显示团子和三项健康摘要。")
                    Text("点按组件进入手表 App 的团子页面。页面再次亮屏活跃时播放一次表情动作，随后静止；点按团子可重播。系统仍可能按设置返回原来的表盘。")
                    Text("团子使用最近一次主动记录的心情，不根据健康数值推断情绪。没有记录时显示中性团子。")
                }
                Section("找不到组件时") {
                    Text("可先使用「健身记录数字」表盘，编辑左上或右上的圆形位置，再到「所有 App」中查找。")
                    Text("「动态」的水母样式可选择顶部或底部的单行文字位置；中间的日期位置由系统限定为日期，不能放健康组件。")
                    Text("小晴空支持圆形、大矩形和单行文字组件，不支持角落位置。表盘图库中没有独立的小晴空表盘，需要先选择系统表盘，再编辑复杂功能。")
                }
                Section {
                    Button("添加已有的 .watchface 文件", systemImage: "square.and.arrow.down") { importing = true }
                } footer: { Text("若你保存过系统分享的表盘文件，可以交给系统添加。晴空不会直接重写系统表盘布局。") }
                if let message { Text(message).font(.footnote).foregroundStyle(Color.readableSecondary) }
            }.navigationTitle("添加表盘组件").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(.automatic) } }
                .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "watchface") ?? .data]) { result in
                    switch result {
                    case .success(let url): addFace(url)
                    case .failure: message = "未能打开表盘文件，请重新选择。"
                    }
                }
        }
    }
    private func addFace(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("watchface")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            CLKWatchFaceLibrary().addWatchFace(at: copy) { error in
                Task { @MainActor in
                    message = error == nil ? "系统已完成表盘添加流程，请在 Watch App 中查看。" : "系统未完成添加，请确认文件与手表兼容后重试。"
                    try? FileManager.default.removeItem(at: copy)
                }
            }
        } catch { message = "未能读取这个表盘文件，请重试。" }
    }
}

struct PrivacyView: View {
    var body: some View {
        List {
            Section("你掌握自己的记录") {
                Text("晴空不要求注册，不展示广告，不将健康数据和日记上传至服务器。应用没有云端 AI 或广告分析服务。")
                Text("健康数据保留在 Apple 健康中，晴空只读取你允许的数据。心情、日记和偏好保存在本机；配对设备通过 Apple WatchConnectivity 同步心情与偏好。")
                Text("iPhone 与手表会在各自本地共享容器保存最少量的健康摘要及最近心情档位、时间，供屏幕或表盘组件显示；不包含日记或压力评分。原始健康记录不通过晴空跨设备传送。")
            }
            Section("权限与删除") {
                Text("你可以在「健康」App 中调整数据访问，在「心情日记」中删除记录。删除标记会在配对设备恢复连接后同步，防止旧记录再次出现。")
                Text("健康提醒在 iPhone 本地分析你允许读取的 HRV、心率及血氧；各类开关默认开启，系统通知仍需你授权。提醒账本只保留必要时间，不上传健康数据，通知不包含具体健康值或日记。可在个性化中关闭提醒，并在系统设置中调整通知和专注规则。")
                Text("保存壁纸时仅请求向照片添加图片的权限。晴空不读取你的照片库。")
                Text("系统备份是否包含本地应用数据由你的设备备份设置决定。晴空不建立自己的云端副本。")
            }
            Section("健康提示") { Text("趋势、HRV 个人基线与心情解读用于日常参考，不构成疾病诊断。出现持续不适时，请联系医疗专业人士。") }
        }.navigationTitle("隐私说明")
    }
}
