import SwiftUI
import UIKit
import QingkongCore

struct MoodPostcardView: View {
    @Environment(AppServices.self) private var app
    @State private var mood = 3
    @State private var scene: SceneTheme = .clear
    @State private var expression: CompanionExpression?
    @State private var scenery: CompanionScenery?
    @State private var message = "慢慢来，今天也值得被温柔对待。"
    @State private var preview: PostcardPreview?
    @State private var renderError: String?
    @FocusState private var editingMessage: Bool
    private var actionLibrary = CompanionActionLibrary()
    private var availableActions: [CompanionAction] { actionLibrary.actions(moods: app.store.records, practices: app.companion.practices) }
    private var collection: CompanionCollectionAvailability { CompanionCollectionAvailability(actions: availableActions) }

    private var messageBinding: Binding<String> {
        Binding(get: { message }, set: { value in
            let sentence = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            message = String(sentence.prefix(100))
        })
    }

    var body: some View {
        Form {
            Section {
                Text("选一位团子、一处风景，留一句想说的话。")
                Text("图片只包含你在这里选择的团子、场景和短句。确认预览后，再由你选择分享方式。")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            }
            Section("选一位团子") {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { value in
                        Button { mood = value; expression = nil } label: {
                            VStack(spacing: 6) {
                                Image("mood-\(value)").resizable().scaledToFit().frame(height: 44)
                                Text(MoodRecord.labels[value - 1]).font(.caption2)
                            }.frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .qingkongGlassButton(prominent: mood == value, shape: .roundedRectangle(radius: 14))
                        .accessibilityLabel("\(MoodRecord.labels[value - 1])团子")
                        .accessibilityAddTraits(mood == value ? .isSelected : [])
                        .accessibilityIdentifier("postcard-mood-\(value)")
                    }
                }
            }
            expressionSection
            Section("选一处风景") {
                Picker("明信片场景", selection: $scene) {
                    ForEach(SceneTheme.allCases) { Text($0.name).tag($0) }
                }
                Picker("收藏风景", selection: $scenery) {
                    Text("使用上方主题").tag(Optional<CompanionScenery>.none)
                    ForEach(collection.scenery) { Text($0.name).tag(Optional($0)) }
                }.accessibilityIdentifier("postcard-collected-scenery")
                if collection.scenery.isEmpty {
                    Text("主动记录心情或完成一次陪伴，会多一处明信片风景。")
                        .font(.footnote).foregroundStyle(Color.readableSecondary)
                }
            }
            Section {
                TextField("写一句想说的话", text: messageBinding, axis: .vertical)
                    .lineLimit(2...5).focused($editingMessage)
                    .accessibilityIdentifier("postcard-message")
                Text("\(message.count)/100 字").font(.caption).foregroundStyle(Color.readableSecondary)
            } header: { Text("留一句话") } footer: {
                Text("内容由你填写，可以留空。")
            }
            Section("明信片画面") {
                MoodPostcardArtwork(mood: mood, scene: scene, message: message, expression: expression, scenery: scenery)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("\(scenery?.name ?? scene.name)场景，\(expression?.name ?? MoodRecord.labels[mood - 1])团子。\(message)")
                Button("预览明信片", systemImage: "photo") { preparePreview() }
                    .accessibilityIdentifier("preview-postcard")
                if let renderError { Text(renderError).font(.footnote).foregroundStyle(Color.readableSecondary) }
            }
        }
        .tint(scene.accent)
        .navigationTitle("心情明信片")
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $preview) { item in PostcardPreviewView(preview: item) }
        .onAppear { actionLibrary.remember(availableActions) }
        .onChange(of: availableActions) { _, actions in actionLibrary.remember(actions) }
        .onChange(of: scene) { _, _ in scenery = nil }
    }

    private var expressionSection: some View {
        Section("收藏表情") {
            HStack(spacing: 12) {
                ForEach(CompanionExpression.allCases) { item in
                    let unlocked = collection.expressions.contains(item)
                    Button { expression = item } label: {
                        VStack(spacing: 6) {
                            CompanionExpressionView(expression: item).frame(height: 70)
                            Label(item.name, systemImage: unlocked ? (expression == item ? "checkmark.circle.fill" : "circle") : "lock")
                                .font(.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .qingkongGlassButton(prominent: expression == item, shape: .roundedRectangle(radius: 14))
                    .disabled(!unlocked)
                    .accessibilityLabel(item.name + (unlocked ? "团子" : "，尚未解锁"))
                    .accessibilityIdentifier("postcard-expression-\(item.rawValue)")
                }
            }
            if expression != nil {
                Button("使用上方心情团子") { expression = nil }
                    .frame(minHeight: 44)
            }
            Text("记下心情解锁眯眼微笑，完成陪伴解锁眼里有光。没有连续记录要求。")
                .font(.footnote).foregroundStyle(Color.readableSecondary)
        }
    }

    @MainActor private func preparePreview() {
        editingMessage = false
        // Only the explicitly selected artwork and message enter the exported image.
        let artwork = MoodPostcardArtwork(mood: mood, scene: scene, message: message, expression: expression, scenery: scenery)
            .frame(width: 360, height: 480)
            .environment(\.dynamicTypeSize, .medium)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 3
        guard let image = renderer.uiImage else {
            renderError = "图片暂未生成，请重试。"
            return
        }
        renderError = nil
        preview = PostcardPreview(image: image)
    }
}

private struct MoodPostcardArtwork: View {
    let mood: Int
    let scene: SceneTheme
    let message: String
    let expression: CompanionExpression?
    let scenery: CompanionScenery?

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 360
            ZStack {
                if let scenery {
                    CompanionSceneryView(scenery: scenery)
                } else {
                    Image(scene.image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                Color.black.opacity(0.08)
                VStack(spacing: 22 * scale) {
                    Spacer(minLength: 0)
                    Group {
                        if let expression { CompanionExpressionView(expression: expression) }
                        else { Image("mood-\(mood)").resizable().scaledToFit() }
                    }.frame(width: 184 * scale, height: 184 * scale)
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 22 * scale, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.86))
                            .multilineTextAlignment(.center)
                            .lineLimit(8).minimumScaleFactor(0.65)
                            .frame(maxHeight: 150 * scale)
                            .padding(18 * scale)
                            .frame(maxWidth: .infinity)
                            .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 20 * scale))
                    }
                    Spacer(minLength: 0)
                }.padding(24 * scale)
            }
        }.accessibilityElement(children: .ignore)
    }
}

private struct PostcardPreview: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct PostcardPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let preview: PostcardPreview

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(uiImage: preview.image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel("即将分享的明信片图片")
                    Text("这就是将要导出的图片。确认后，由你在系统分享面板选择保存或分享对象。")
                        .font(.subheadline).foregroundStyle(Color.readableSecondary)
                    ShareLink(item: Image(uiImage: preview.image), preview: SharePreview("心情明信片", image: Image(uiImage: preview.image))) {
                        Label("选择分享方式", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.qingkongGlassButton(prominent: true)
                        .accessibilityIdentifier("share-postcard-image")
                }.padding(22)
            }
            .navigationTitle("分享前预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回编辑", systemImage: "chevron.backward") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.automatic)
                }
            }
        }.presentationDragIndicator(.visible)
    }
}

struct CompanionMilestonesView: View {
    let practices: [RelaxationRecord]
    let moods: [MoodRecord]
    private var actionLibrary = CompanionActionLibrary()

    init(practices: [RelaxationRecord], moods: [MoodRecord]) {
        self.practices = practices; self.moods = moods
    }

    var body: some View {
        let available = actionLibrary.actions(moods: moods, practices: practices)
        List {
            Section {
                Text("每一次愿意照顾自己，都可以被温柔记住。")
                Text("这里没有连续打卡，也不用每天完成。团子一直都在。")
                    .font(.footnote).foregroundStyle(Color.readableSecondary)
            }
            Section("随时打个招呼") {
                CompanionMilestoneRow(action: .greeting, reached: true, mood: 3,
                    title: "轻轻招呼", caption: "不需要先记录，点按团子就能打个招呼。")
            }
            Section("给此刻留一个位置") {
                let reached = available.contains(.nod)
                CompanionMilestoneRow(action: .nod, reached: reached, mood: 4,
                    title: "记下过一次心情 · 温柔点头",
                    caption: reached ? "你为自己的感受留了一个位置，点按团子重播温柔点头。" : "记下心情后，会多一种温柔点头。现在也可以和团子打个招呼。")
            }
            Section("给自己一小段时间") {
                let reached = available.contains(.sway)
                CompanionMilestoneRow(action: .sway, reached: reached, mood: 5,
                    title: "完成过一次放松陪伴 · 轻轻摇摆",
                    caption: reached ? "你给自己留了一段安静，点按团子重播轻轻摇摆。" : "完成陪伴后，会多一种轻轻摇摆。想歇一会儿时再来就好。")
            }
            Section {
                NavigationLink("表情与风景收藏") { CompanionCollectionView(actions: available) }
                    .accessibilityIdentifier("open-companion-collection")
            }
        }.navigationTitle("和团子的日常")
            .onAppear { actionLibrary.remember(available) }
            .onChange(of: available) { _, actions in actionLibrary.remember(actions) }
    }
}

private struct CompanionMilestoneRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: CompanionAction
    let reached: Bool
    let mood: Int
    let title: String
    let caption: String

    var body: some View {
        VStack(spacing: 16) {
            CompanionActionCharacter(mood: reached ? mood : 3, action: reached ? action : .greeting)
                .frame(height: 120)
            Text(title).font(.headline)
            Text(caption).font(.subheadline).foregroundStyle(Color.readableSecondary).multilineTextAlignment(.center)
            if reduceMotion {
                Text("团子正安静陪着你。").font(.footnote).foregroundStyle(Color.readableSecondary)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}
