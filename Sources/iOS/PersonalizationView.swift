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
    @State private var homePreferenceError: String?
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
                Toggle("安心首页", isOn: Binding(get: { app.companion.calmHome }, set: { enabled in
                    do { try app.companion.setCalmHome(enabled); homePreferenceError = nil }
                    catch { homePreferenceError = "首页偏好暂未保存，请重试。" }
                }))
                .accessibilityIdentifier("calm-home")
                if let homePreferenceError { Text(homePreferenceError).font(.footnote).foregroundStyle(Color.readableSecondary) }
            } header: { Text("按自己的节奏") } footer: { Text("默认开启，首页突出团子、心情与放松。关闭后显示首页健康数据，趋势页始终可主动查看。") }

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
                Button("在系统中添加表盘组件", systemImage: "applewatch") { faceGuide = true }
                Label(app.link.syncMessage, systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(Color.readableSecondary)
                if let error = app.link.error { Text(error).font(.footnote).foregroundStyle(Color.readableSecondary) }
            } header: { Text("手腕上的小晴空") } footer: { Text("团子页面始终显示 HRV、心率和血氧三项数值。点按系统表盘中的「心情团子」可进入手表 App 的动画页面。") }

            Section {
                Picker("默认显示指标", selection: Binding(get: { app.store.preferences.complicationMetric }, set: { value in app.store.updatePreferences { $0.complicationMetric = value } })) {
                    ForEach(HealthMetric.allCases) { Text($0.name).tag($0) }
                }
                Toggle("允许矩形组件显示趋势", isOn: Binding(get: { app.store.preferences.showComplicationTrend }, set: { value in app.store.updatePreferences { $0.showComplicationTrend = value } }))
            } header: { Text("健康指标组件") } footer: {
                Text("默认指标仅用于手表上选择了「跟随 iPhone 配置」的健康组件；单独选择 HRV、心率或血氧的组件保持原指标。矩形健康组件需同时开启自身的「显示迷你趋势」。设置会同步到手表，组件按系统调度刷新，不影响心情团子。")
            }

            Section("数据与隐私") {
                Button("检查 Apple 健康连接", systemImage: "heart.text.clipboard") { Task { await app.health.authorize() } }
                Button("打开应用设置", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                NavigationLink("隐私说明") { PrivacyView() }
                LabeledContent("版本", value: "0.1.0 · 开发版")
            }
            Section {
                Link(destination: URL(string: "https://github.com/ranyunlong/qingkong")!) {
                    Label("GitHub · ranyunlong/qingkong", systemImage: "chevron.left.forwardslash.chevron.right")
                }.accessibilityIdentifier("open-github-repository")
                Link(destination: URL(string: "https://github.com/ranyunlong/qingkong/issues")!) {
                    Label("问题反馈 · Issues", systemImage: "bubble.left.and.bubble.right")
                }.accessibilityIdentifier("open-github-issues")
            } header: { Text("开源与反馈") } footer: {
                Text("小晴空是 GitHub 开源项目。服务端仅提供文章与音乐，不同步你的健康、心情或日记数据；这些个人数据保留在你的设备上。")
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
            VStack(spacing: 0) {
                HStack { Spacer(); Text(Date.now, style: .time).font(.caption2.monospacedDigit()) }
                Image("mood-\(mood?.value ?? 3)")
                    .resizable().scaledToFit().frame(width: 112, height: 112)
                    .offset(y: -6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .accessibilityHidden(true)
                Text(mood?.label ?? "心情待记录")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.top, 2).padding(.bottom, 8)
                HStack(spacing: 0) {
                    ForEach(HealthMetric.allCases) { metric in
                        VStack(spacing: 2) {
                            Label(metric.name, systemImage: metric.symbol).font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(app.health.latest(metric).map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                                .font(.system(size: 18, weight: .medium, design: .rounded))
                                .monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                            Text(metric.unit).font(.system(size: 8)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            .dynamicTypeSize(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 18)
            .frame(width: 184, height: 224)
            .background(.black, in: RoundedRectangle(cornerRadius: 40))
            .clipShape(RoundedRectangle(cornerRadius: 40))
            Text("预览数值取自 iPhone；手表页面使用手表上可读取的记录。").font(.caption2).foregroundStyle(Color.readableSecondary).multilineTextAlignment(.center)
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
                Section("把小晴空放到表盘上") {
                    Label("先在配对的 Apple Watch 安装小晴空并打开一次。", systemImage: "1.circle")
                    Label("长按当前表盘，点「编辑」，滑到复杂功能。", systemImage: "2.circle")
                    Label("选一个圆形、大矩形或单行文字位置，在「所有 App」中找到「小晴空」，再选 HRV、心率或血氧。", systemImage: "3.circle")
                    Label("若选择「跟随 iPhone 配置」，将使用个性化中「健康指标组件」的默认指标；趋势开关只作用于矩形健康组件。设置会在连接后同步到手表。", systemImage: "4.circle")
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
                } footer: { Text("若你保存过系统分享的表盘文件，可以交给系统添加。小晴空不会直接重写系统表盘布局。") }
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
                Text("小晴空不要求注册，不展示广告，不将健康数据和日记上传至服务器。应用没有云端 AI 或广告分析服务。")
                Text("健康数据保留在 Apple 健康中，小晴空读取你允许的数据。手表开始舒缓呼吸或安静陪伴时，单独申请体能训练权限以持续采集心率，结束后丢弃训练，不保存训练记录；本次最后有效心率随陪伴记录保存在手表本机，用于结果页与陪伴回顾，不上传或跨端同步。心情、日记和偏好保存在本机；配对设备通过 Apple WatchConnectivity 同步心情与偏好。")
                Text("iPhone 与手表会在各自本地共享容器保存最少量的健康摘要及最近心情档位、时间，供屏幕或表盘组件显示；不包含日记或压力评分。原始健康记录不通过小晴空跨设备传送。")
            }
            Section("权限与删除") {
                Text("你可以在「健康」App 中调整数据访问，在「心情日记」中删除记录。删除标记会在配对设备恢复连接后同步，防止旧记录再次出现。")
                Text("健康提醒在 iPhone 本地分析你允许读取的 HRV、心率及血氧；各类开关默认开启，系统通知仍需你授权。提醒账本只保留必要时间，不上传健康数据，通知不包含具体健康值或日记。可在个性化中关闭提醒，并在系统设置中调整通知和专注规则。")
                Text("保存壁纸时仅请求向照片添加图片的权限。小晴空不读取你的照片库。")
                Text("系统备份是否包含本地应用数据由你的设备备份设置决定。小晴空不建立自己的云端副本。")
                Text("睡眠记录在你主动连接后单独请求读取，只在本机生成概览与周回顾。你可以在 Apple 健康管理睡眠访问与源记录。练习、时间线摘要和睡前方案可在对应页面删除。")
                Text("团子动作只在本机保存点头、摇摆是否解锁的两个标记，不保留对应记录内容、不跨端同步。删除记录不会收回已解锁动作；清除该设备应用数据会清除标记。")
            }
            Section("公共内容与网络") {
                Text("小晴空的服务端仅提供公共文章与音乐。打开知识库、刷新曲库及播放或下载线上音频时，会向公共内容服务或媒体地址发起网络请求。请求不携带健康、心情、日记、生活标签或练习记录。收藏、已读与下载索引仅保存在本机。")
                Text("iPhone 与手表默认使用同一公共内容服务，无需填写地址；手表自行获取目录和下载音轨，两端缓存分开验证与保存。手表默认下载避开蜂窝与昂贵网络，实际路由由系统选择，可能经手机代理；关闭限制可能使用移动数据。手表下载需保持曲库页面在前台，离页或退后台会中断，可返回重试。")
                Text("公共内容服务 https://xqk.geckoai.cn 运行于阿里云 ECS，由应用自动连接。服务器会记录 IP、请求时间、路径、来源页及浏览器／系统信息；访问与错误日志配置按日轮转，最多保留 52 份历史归档，空日志不轮转，未设置固定天数上限。云平台及正式媒体提供方的日志规则仍待确认。")
                Text("内容后端不记录请求正文或个人健康记录。离线文章显示上次检查时间，联网后同步修订与撤回；正式媒体服务及其日志规则在音源发布前补充说明。")
            }
            Section("健康提示") { Text("趋势、HRV 个人基线与心情解读用于日常参考，不构成疾病诊断。出现持续不适时，请联系医疗专业人士。") }
        }.navigationTitle("隐私说明")
    }
}
