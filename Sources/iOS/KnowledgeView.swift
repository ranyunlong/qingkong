import SwiftUI
import UIKit
import QingkongCore

struct KnowledgeView: View {
    let content: ContentLibrary
    var onRelax: (() -> Void)? = nil
    @State private var search = ""
    @State private var category = "全部"
    @State private var favoritesOnly = false

    private var filtered: [PublicArticle] {
        content.articles.filter {
            (category == "全部" || $0.category == category) &&
            (!favoritesOnly || content.isFavorite($0.id)) &&
            (search.isEmpty || ($0.title + $0.summary + $0.body).localizedStandardContains(search))
        }
    }
    var body: some View {
        List {
            Section {
                Picker("分类", selection: $category) {
                    Text("全部").tag("全部")
                    ForEach(Array(Set(content.articles.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Toggle("只看收藏", isOn: $favoritesOnly)
            }
            if filtered.isEmpty {
                if content.isRefreshing && content.articles.isEmpty { ProgressView("正在加载文章…") }
                else {
                    ContentUnavailableView(content.articles.isEmpty ? "暂时没有可读文章" : "没有找到相关文章", systemImage: "book.closed", description: Text("可下拉刷新。只有已发布内容会显示，已读和收藏保存在本机。"))
                }
            }
            ForEach(filtered) { article in
                NavigationLink {
                    KnowledgeArticleView(content: content, articleID: article.id, onRelax: onRelax)
                } label: {
                    KnowledgeArticleRow(content: content, article: article, isRead: content.isRead(article.id), isFavorite: content.isFavorite(article.id))
                }
            }
        }
        .navigationTitle("安心小知识")
        .searchable(text: $search, prompt: "搜索标题或正文")
        .refreshable { await content.refresh() }
        .task { await content.refresh() }
    }
}

struct KnowledgeHighlightsView: View {
    let content: ContentLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("安心小知识").font(.title3.weight(.semibold))
                Spacer()
                NavigationLink {
                    KnowledgeView(content: content)
                } label: { Text("更多").font(.subheadline).frame(height: 20) }
                    .controlSize(.regular).frame(height: 44)
                    .accessibilityLabel("更多安心小知识").accessibilityIdentifier("open-knowledge-library")
            }
            if content.articles.isEmpty {
                Surface {
                    if content.isRefreshing { ProgressView("正在加载文章…") }
                    else { Text("暂时没有可读文章，可下拉刷新。").font(.subheadline).foregroundStyle(Color.readableSecondary) }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(content.articles.prefix(3))) { article in
                        NavigationLink {
                            KnowledgeArticleView(content: content, articleID: article.id, onRelax: nil)
                        } label: {
                            KnowledgeArticleRow(content: content, article: article, isRead: content.isRead(article.id), isFavorite: content.isFavorite(article.id))
                                .padding(.horizontal, 12).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("home-article-\(article.id)")
                    }
                }
            }
        }
    }
}

private struct KnowledgeArticleRow: View {
    @Environment(AppServices.self) private var app
    let content: ContentLibrary
    let article: PublicArticle
    let isRead: Bool
    let isFavorite: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let url = article.coverURL, PublicContentURL.isHTTPS(url) {
                    CachedPublicCoverImage(content: content, url: url,
                        identity: "article|\(article.id)|\(article.revision)|\(article.updatedAt.timeIntervalSince1970)",
                        maximumPixelSize: 288) { Image(app.scene.image).resizable().scaledToFill() }
                } else { Image(app.scene.image).resizable().scaledToFill() }
            }.frame(width: 80, height: 92).clipped().clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 4) {
                    Text(article.title).font(.headline).foregroundStyle(Color.primary).lineLimit(2)
                    if isFavorite { Image(systemName: "bookmark.fill").foregroundStyle(app.scene.accent).accessibilityLabel("已收藏") }
                }
                Text(article.summary).font(.subheadline).foregroundStyle(Color.readableSecondary).lineLimit(2)
                Text("\(article.category)\(isRead ? " · 已读" : "") · \(article.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(Color.readableSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 5)
    }
}

private struct KnowledgeArticleView: View {
    let content: ContentLibrary
    let articleID: String
    let onRelax: (() -> Void)?
    var body: some View {
        Group {
            if let article = content.article(id: articleID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(article.title).font(.largeTitle.bold())
                        if let url = article.coverURL, PublicContentURL.isHTTPS(url) {
                            CachedPublicCoverImage(content: content, url: url,
                                identity: "article|\(article.id)|\(article.revision)|\(article.updatedAt.timeIntervalSince1970)",
                                maximumPixelSize: 960) { Color.secondary.opacity(0.08) }
                                .accessibilityLabel("文章封面")
                                .frame(height: 200).clipped().clipShape(RoundedRectangle(cornerRadius: 20)).accessibilityHidden(true)
                        }
                        Text(article.summary).font(.title3).foregroundStyle(.secondary)
                        Text(content.statusMessage).font(.caption).foregroundStyle(.secondary)
                        Text("更新于 \(article.updatedAt.formatted(date: .abbreviated, time: .shortened)) · 修订 \(article.revision)").font(.caption).foregroundStyle(.secondary)
                        if let richText = PublicArticleRichText.parse(article.bodyHTML) {
                            KnowledgeRichText(content: content, articleID: article.id, document: richText)
                        } else {
                            Text(article.body).lineSpacing(7).textSelection(.enabled)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text(article.testOnly == true ? "功能测试 · 未专业审核" : "专业审核").font(.headline)
                            Text("\(article.review.reviewer) · \(article.review.credentials)")
                            Text(article.review.reviewedAt.formatted(date: .abbreviated, time: .omitted)).font(.caption)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("参考来源").font(.headline)
                            ForEach(Array(article.references.enumerated()), id: \.offset) { _, reference in
                                if PublicContentURL.isHTTPS(reference.url) {
                                    Link(destination: reference.url) {
                                        Text(reference.title).foregroundStyle(.tint).underline()
                                    }.buttonStyle(.plain)
                                        .accessibilityHint("在浏览器中打开参考来源")
                                }
                            }
                        }
                        Text("这些内容用于帮助理解和日常支持，不能替代针对个人情况的专业评估。身体不适明显或持续时，请寻求专业帮助。").font(.footnote).foregroundStyle(.secondary)
                        if let onRelax { Button("陪我缓一缓", action: onRelax).buttonStyle(.borderedProminent) }
                        else { NavigationLink { RelaxationView() } label: { Label("陪我缓一缓", systemImage: "leaf") } }
                        let related = Array(content.articles.filter { $0.category == article.category && $0.id != article.id }.prefix(3))
                        if !related.isEmpty {
                            Text("也可以了解").font(.headline)
                            ForEach(related) { item in
                                NavigationLink(item.title) { KnowledgeArticleView(content: content, articleID: item.id, onRelax: onRelax) }
                            }
                        }
                    }.padding(22)
                }
                .toolbar {
                    Button(content.isFavorite(articleID) ? "取消收藏" : "收藏", systemImage: content.isFavorite(articleID) ? "bookmark.fill" : "bookmark") { content.toggleFavorite(articleID) }
                        .buttonStyle(.automatic)
                        .accessibilityIdentifier("article-favorite")
                }
                .onAppear { content.markRead(articleID) }
            } else {
                ContentUnavailableView("文章已撤回或不再可用", systemImage: "doc.badge.ellipsis", description: Text("成功刷新后，修订与撤回会同步至本机。"))
            }
        }.navigationBarTitleDisplayMode(.inline)
    }
}


private struct KnowledgeRichText: View {
    let content: ContentLibrary
    let articleID: String
    let document: PublicArticleRichText

    private enum Segment {
        case text([PublicArticleRichText.Block])
        case image(PublicArticleRichText.Image)
    }

    private var segments: [Segment] {
        var segments: [Segment] = []
        var text: [PublicArticleRichText.Block] = []
        for block in document.blocks {
            if let image = block.image {
                if !text.isEmpty { segments.append(.text(text)); text = [] }
                segments.append(.image(image))
            } else { text.append(block) }
        }
        if !text.isEmpty { segments.append(.text(text)) }
        return segments
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let blocks): KnowledgeRichTextContent(blocks: blocks)
                case .image(let image): KnowledgeArticleImage(content: content, articleID: articleID, url: image.url, alt: image.alt).id(image.url)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct KnowledgeArticleImage: View {
    let content: ContentLibrary
    let articleID: String
    let url: URL
    let alt: String
    var contentMode: ContentMode = .fit
    var fallbackAsset: String? = nil
    @State private var image: UIImage?
    @State private var failed = false
    @State private var requestID = UUID()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: 1_200)
                    .accessibilityLabel(alt)
            } else if let fallbackAsset {
                Image(fallbackAsset).resizable().scaledToFill()
            } else {
                VStack(spacing: 10) {
                    if failed { Image(systemName: "photo.badge.exclamationmark").font(.title2) }
                    else { ProgressView().accessibilityLabel("正在加载图片") }
                    Text(failed ? "图片暂时无法显示" : "正在加载图片…").font(.subheadline)
                    Text(alt).font(.caption).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }
        }
        .task(id: content.articleImages.identity(for: url, articleID: articleID)) {
            let request = UUID()
            requestID = request
            image = nil
            failed = false
            do {
                let loaded = try await content.articleImages.image(for: url, articleID: articleID)
                guard !Task.isCancelled, requestID == request else { return }
                image = UIImage(cgImage: loaded)
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                failed = true
            }
        }
        .onDisappear {
            requestID = UUID()
            image = nil
        }
    }
}

/// UITextView supplies native selection, dynamic type and link accessibility.
/// It receives attributed text, never remote HTML or image attachments.
private struct KnowledgeRichTextContent: UIViewRepresentable {
    @Environment(\.openURL) private var openURL
    @Environment(\.sizeCategory) private var sizeCategory
    let blocks: [PublicArticleRichText.Block]

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.dataDetectorTypes = []
        view.writingToolsBehavior = .none
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "article-body-rich-text"
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.openURL = { url in openURL(url) }
        let text = attributedText()
        // Preserve the reader's selection during unrelated article updates.
        if uiView.attributedText != text { uiView.attributedText = text }
        uiView.linkTextAttributes = [.foregroundColor: uiView.tintColor ?? UIColor.link, .underlineStyle: NSUnderlineStyle.single.rawValue]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openURL: ((URL) -> Void)?

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content, PublicContentURL.isHTTPS(url) else { return nil }
            return UIAction { [weak self] _ in self?.openURL?(url) }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            // Avoid system link previews fetching a URL before an explicit tap.
            nil
        }
    }

    private func attributedText() -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let traits = UITraitCollection(preferredContentSizeCategory: uiContentSizeCategory)
        for (index, block) in blocks.enumerated() {
            let textStyle: UIFont.TextStyle = block.headingLevel == 2 ? .title2 : (block.headingLevel == 3 ? .headline : .body)
            let baseFont = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 7
            paragraph.paragraphSpacing = 12
            let indent = CGFloat(block.listDepth) * baseFont.pointSize * 1.2 + (block.quoted ? baseFont.pointSize : 0)
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = block.marker == nil ? indent : max(0, indent - baseFont.pointSize * 1.2)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont, .foregroundColor: block.quoted ? UIColor.secondaryLabel : UIColor.label,
                .paragraphStyle: paragraph
            ]
            if let marker = block.marker { result.append(NSAttributedString(string: marker + "  ", attributes: attributes)) }
            for run in block.runs {
                var styled = attributes
                var symbolicTraits = baseFont.fontDescriptor.symbolicTraits
                if run.bold || block.headingLevel != nil { symbolicTraits.insert(.traitBold) }
                if run.italic { symbolicTraits.insert(.traitItalic) }
                if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(symbolicTraits) {
                    styled[.font] = UIFont(descriptor: descriptor, size: baseFont.pointSize)
                }
                if run.underlined { styled[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.struckThrough { styled[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link { styled[.link] = link }
                result.append(NSAttributedString(string: run.text, attributes: styled))
            }
            if index < blocks.count - 1 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
        }
        return result
    }

    private var uiContentSizeCategory: UIContentSizeCategory {
        switch sizeCategory {
        case .extraSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .extraLarge: .extraLarge
        case .extraExtraLarge: .extraExtraLarge
        case .extraExtraExtraLarge: .extraExtraExtraLarge
        case .accessibilityMedium: .accessibilityMedium
        case .accessibilityLarge: .accessibilityLarge
        case .accessibilityExtraLarge: .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
