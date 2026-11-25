import SwiftUI
import QingkongCore

struct MacKnowledgeView: View {
    let content: ContentLibrary
    @State private var search = ""
    @State private var category = "全部"
    @State private var favoritesOnly = false
    @State private var selectedID: String?
    @State private var articles: [PublicArticle] = []
    @State private var categories: [String] = []
    @State private var filtered: [PublicArticle] = []

    var body: some View {
        // Keep the list mounted so returning preserves its exact scroll position and filters.
        ZStack {
            articleList
                .opacity(selectedID == nil ? 1 : 0)
                .allowsHitTesting(selectedID == nil)
                .accessibilityHidden(selectedID != nil)
            if let selectedID {
                MacArticleView(content: content, articleID: selectedID, selectArticle: { self.selectedID = $0 })
                    .id(selectedID)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索标题或正文")
        .toolbar {
            if selectedID != nil {
                ToolbarItem(placement: .navigation) {
                    Button("返回知识库", systemImage: "chevron.left") { selectedID = nil }
                        .labelStyle(.iconOnly).help("返回知识库")
                        .keyboardShortcut("[", modifiers: .command)
                }
            } else {
                ToolbarItem {
                    Button { Task { await content.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新知识库").accessibilityLabel("刷新知识库").disabled(content.isRefreshing)
                }
            }
        }
        .onChange(of: content.snapshot, initial: true) { _, _ in
            articles = content.articles
            categories = Array(Set(articles.map(\.category))).sorted()
            if category != "全部" && !categories.contains(category) { category = "全部" }
            updateFilter()
        }
        .onChange(of: content.favoriteIDs) { _, _ in updateFilter() }
        .onChange(of: category) { _, _ in updateFilter() }
        .onChange(of: favoritesOnly) { _, _ in updateFilter() }
        .onChange(of: search) { _, _ in updateFilter() }
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("知识库").font(.largeTitle.bold())
                Spacer()
                Picker("分类", selection: $category) {
                    Text("全部分类").tag("全部")
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().fixedSize()
                Toggle(isOn: $favoritesOnly) { Image(systemName: "bookmark") }
                    .toggleStyle(.button).help("只看收藏").accessibilityLabel("只看收藏")
            }.padding(.horizontal, 28).padding(.vertical, 20)
            if filtered.isEmpty {
                if content.isRefreshing && articles.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(favoritesOnly ? "还没有收藏" : "没有找到文章", systemImage: favoritesOnly ? "bookmark" : "magnifyingglass")
                }
            } else {
                List(filtered) { article in
                    Button { selectedID = article.id } label: {
                        MacKnowledgeRow(content: content, article: article)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.inset)
                .accessibilityIdentifier("mac-knowledge-list")
            }
            Text(content.statusMessage).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 12)
        }
    }

    private func updateFilter() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = articles.filter {
            (category == "全部" || $0.category == category) &&
            (!favoritesOnly || content.isFavorite($0.id)) &&
            (query.isEmpty || $0.title.localizedStandardContains(query) ||
                $0.summary.localizedStandardContains(query) || $0.body.localizedStandardContains(query))
        }
    }
}

private struct MacKnowledgeRow: View {
    let content: ContentLibrary
    let article: PublicArticle

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let url = article.coverURL {
                MacArticleImage(content: content, articleID: article.id, url: url, alt: "文章封面", contentMode: .fill, maximumPixelSize: 192)
                    .frame(width: 52, height: 58).clipped().clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 5) {
                    Text(article.title).font(.callout.weight(.semibold)).lineLimit(2)
                    if content.isFavorite(article.id) { Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.tint).accessibilityLabel("已收藏") }
                }
                Text(article.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 5) {
                    Text(article.category)
                    if content.isRead(article.id) { Text("· 已读") }
                    if article.testOnly == true { Text("· 测试") }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7).contentShape(Rectangle())
        .contextMenu {
            Button(content.isFavorite(article.id) ? "取消收藏" : "收藏", systemImage: content.isFavorite(article.id) ? "bookmark.slash" : "bookmark") {
                content.toggleFavorite(article.id)
            }
        }
    }
}

private struct MacArticleView: View {
    let content: ContentLibrary
    let articleID: String
    let selectArticle: (String) -> Void
    @State private var richText: PublicArticleRichText?
    @State private var parsedRevision: String?

    var body: some View {
        Group {
            if let article = content.article(id: articleID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(alignment: .center) {
                            Text(article.category).font(.callout).foregroundStyle(.secondary)
                            if article.testOnly == true {
                                Label("测试内容 · 未专业审核", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                content.toggleFavorite(article.id)
                            } label: {
                                Label(content.isFavorite(article.id) ? "已收藏" : "收藏", systemImage: content.isFavorite(article.id) ? "bookmark.fill" : "bookmark")
                            }
                            .help(content.isFavorite(article.id) ? "取消收藏" : "收藏并保存至本机")
                            .accessibilityIdentifier("mac-article-favorite")
                        }
                        Text(article.title).font(.largeTitle.bold()).textSelection(.enabled)
                        Text(article.summary).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("\(article.updatedAt.formatted(date: .abbreviated, time: .omitted)) · 修订 \(article.revision)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let url = article.coverURL {
                            MacArticleImage(content: content, articleID: article.id, url: url, alt: "文章封面")
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if let richText, parsedRevision == "\(article.id)|\(article.revision)|\(article.updatedAt)" {
                            MacArticleRichText(content: content, articleID: article.id, document: richText)
                        } else {
                            Text(article.body).font(.body).lineSpacing(7).textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Label(article.testOnly == true ? "功能测试 · 未专业审核" : "专业审核", systemImage: article.testOnly == true ? "testtube.2" : "checkmark.seal")
                                .font(.headline)
                            Text("\(article.review.reviewer) · \(article.review.credentials)")
                            Text(article.review.reviewedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                        if !article.references.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("参考来源", systemImage: "link").font(.headline)
                                ForEach(Array(article.references.enumerated()), id: \.offset) { _, reference in
                                    if PublicContentURL.isHTTPS(reference.url) {
                                        Link(reference.title, destination: reference.url)
                                    }
                                }
                            }
                        }
                        let related = Array(content.articles.filter { $0.category == article.category && $0.id != article.id }.prefix(3))
                        if !related.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("相关文章").font(.headline)
                                ForEach(related) { item in
                                    Button { selectArticle(item.id) } label: {
                                        HStack {
                                            Text(item.title).multilineTextAlignment(.leading)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .padding(30).frame(maxWidth: 780, alignment: .leading).frame(maxWidth: .infinity)
                }
                .task(id: "\(article.id)|\(article.revision)|\(article.updatedAt)") {
                    richText = PublicArticleRichText.parse(article.bodyHTML)
                    parsedRevision = "\(article.id)|\(article.revision)|\(article.updatedAt)"
                    content.markRead(article.id)
                }
                .accessibilityIdentifier("mac-article-reader")
            } else {
                ContentUnavailableView("文章已撤回或不再可用", systemImage: "doc.badge.ellipsis")
            }
        }
    }
}
