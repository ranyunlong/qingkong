import SwiftUI
import QingkongCore

struct MoodView: View {
    @Environment(AppServices.self) private var app
    @Binding var selectedMood: Int
    @State private var stress = 2
    @State private var note = ""
    @State private var tags: Set<LifeTag> = []
    @State private var result: String?
    @State private var error: String?
    @State private var noteFrame: CGRect = .zero
    @FocusState private var writing: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageIntro(eyebrow: "此刻，听听自己", title: "今天的你，\n感觉怎么样？", subtitle: "每一种感受，都值得被好好接住。")
                MoodChoices(selection: $selectedMood)
                Surface {
                    VStack(alignment: .leading, spacing: 15) {
                        HStack { Text("此刻的压力").font(.headline); Spacer(); Text("\(stress) / 5").monospacedDigit().foregroundStyle(Color.readableSecondary) }
                        Picker("压力等级", selection: $stress) {
                            ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("stress-picker")
                        HStack { Text("很放松"); Spacer(); Text("有些紧绷") }.font(.caption).foregroundStyle(Color.readableSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("想说些什么？").font(.headline); Spacer(); Text("可选 · \(note.count)/1000").font(.caption).foregroundStyle(Color.readableSecondary) }
                    TextEditor(text: $note).focused($writing).frame(minHeight: 120).padding(10)
                        .scrollContentBackground(.hidden).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(alignment: .topLeading) {
                            if note.isEmpty {
                                Text("写下此刻的心情或今天的小事…")
                                    .font(.body).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 15).padding(.top, 18)
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("mood-page"))
                        } action: { noteFrame = $0 }
                        .accessibilityLabel("心情日记").accessibilityIdentifier("mood-note")
                        .onChange(of: note) { _, value in if value.count > 1000 { note = String(value.prefix(1000)) } }
                }
                DisclosureGroup("生活标签（可选）") {
                    VStack(spacing: 0) {
                        ForEach(LifeTag.allCases) { tag in
                            if tag != LifeTag.allCases.first { Divider() }
                            Toggle(tag.name, isOn: Binding(get: { tags.contains(tag) }, set: { selected in
                                if selected { tags.insert(tag) } else { tags.remove(tag) }
                            }))
                            .toggleStyle(.switch)
                            .padding(.trailing, 8)
                            .frame(minHeight: 52)
                            .accessibilityIdentifier("life-tag-\(tag.rawValue)")
                        }
                    }.padding(.top, 8)
                }
                .padding(16)
                .background(app.scene.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
                Button {
                    writing = false
                    do {
                        try app.store.add(mood: selectedMood, stress: stress, note: note, tags: LifeTag.allCases.filter { tags.contains($0) })
                        note = ""; tags = []; result = "已记下此刻"; error = nil
                        app.updateClock()
                    } catch { self.error = "记录未能保存，请重试。"; result = nil }
                } label: {
                    Text("记下此刻").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.qingkongGlassButton(prominent: true).accessibilityIdentifier("save-mood")
                if let result { Label(result, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(app.scene.accent).accessibilityIdentifier("mood-saved") }
                if let error { Text(error).font(.subheadline).foregroundStyle(Color.readableSecondary) }
                if let latest = app.store.entries.first {
                    Surface {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("给此刻的你").font(.headline)
                            Text(latest.reflection).font(.subheadline).lineSpacing(6)
                            Text("依据：你最近主动记录的心情与压力感受。 ").font(.caption).foregroundStyle(Color.readableSecondary)
                        }
                    }
                }
                NavigationLink { MoodHistoryView() } label: {
                    HStack { Label("心情日记", systemImage: "book.closed"); Spacer(); Text("\(app.store.entries.count) 条记录").foregroundStyle(Color.readableSecondary); Image(systemName: "chevron.right") }.font(.subheadline).padding(.vertical, 10)
                }.accessibilityIdentifier("mood-history")
                NavigationLink { CompanionTimelineView() } label: { Label("身体与心情时间线", systemImage: "clock") }
                NavigationLink { WeeklyReviewView() } label: { Label("每周回顾", systemImage: "calendar") }
                NavigationLink { KnowledgeView(content: app.content) } label: { Label("安心小知识", systemImage: "book") }
                NavigationLink { MoodPostcardView() } label: { Label("心情明信片", systemImage: "envelope") }
                NavigationLink { CompanionMilestonesView(practices: app.companion.practices, moods: app.store.records) } label: { Label("团子陪伴", systemImage: "sparkles") }
                Text("只保存在你的设备上，并通过配对设备同步。你可以随时删除记录。 ").font(.caption).foregroundStyle(Color.readableSecondary)
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named("mood-page")).onEnded { tap in
                    if writing && !noteFrame.contains(tap.location) { writing = false }
                }
            )
            .coordinateSpace(name: "mood-page")
            .scrollDismissesKeyboard(.interactively)
            .toolbar { if writing { ToolbarItem(placement: .topBarLeading) { Button("完成") { writing = false }.buttonStyle(.automatic) } } }
    }
}

struct MoodHistoryView: View {
    @Environment(AppServices.self) private var app
    @State private var deleting: MoodRecord?
    @State private var error: String?
    var body: some View {
        List {
            if app.store.entries.isEmpty { ContentUnavailableView("还没有心情记录", systemImage: "book.closed", description: Text("从今天的一点感受开始。")) }
            ForEach(app.store.entries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Image("mood-\(entry.mood)").resizable().scaledToFit().frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("\(entry.label) · 压力 \(entry.stress)/5").font(.headline)
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(Color.readableSecondary)
                        if !entry.note.isEmpty { Text(entry.note).font(.subheadline) }
                    }
                    Spacer(minLength: 0)
                    Button("删除记录", systemImage: "trash", role: .destructive) { deleting = entry }
                        .labelStyle(.iconOnly).qingkongGlassButton(shape: .circle).frame(minWidth: 44, minHeight: 44)
                }.padding(.vertical, 6)
                    .swipeActions { Button("删除", role: .destructive) { deleting = entry } }
            }
        }.navigationTitle("心情日记")
            .confirmationDialog("删除这条心情记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除记录", role: .destructive) {
                    if let deleting {
                        do { try app.store.delete(deleting) } catch { self.error = "记录未能删除，请重试。" }
                    }
                    deleting = nil
                }.accessibilityIdentifier("confirm-delete-mood")
            } message: { Text("删除会在配对设备恢复连接后同步。") }
            .alert("未能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}
