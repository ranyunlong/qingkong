import SwiftUI
import CoreGraphics
import QingkongCore

/// Render only the shared parser's allowlisted text and validated image resources.
struct MacArticleRichText: View {
    let content: ContentLibrary
    let articleID: String
    let document: PublicArticleRichText

    private enum Segment {
        case text([PublicArticleRichText.Block])
        case image(PublicArticleRichText.Image)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var text: [PublicArticleRichText.Block] = []
        for block in document.blocks {
            if let image = block.image {
                if !text.isEmpty { result.append(.text(text)); text = [] }
                result.append(.image(image))
            } else { text.append(block) }
        }
        if !text.isEmpty { result.append(.text(text)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let blocks):
                    Text(attributedText(blocks)).lineSpacing(7).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mac-article-body-rich-text")
                case .image(let image):
                    MacArticleImage(content: content, articleID: articleID, url: image.url, alt: image.alt)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func attributedText(_ blocks: [PublicArticleRichText.Block]) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { result += AttributedString("\n\n") }
            if let marker = block.marker {
                result += AttributedString(String(repeating: "  ", count: max(0, block.listDepth - 1)) + marker + "  ")
            }
            if block.quoted { result += AttributedString("│  ") }
            for run in block.runs {
                var value = AttributedString(run.text)
                var font: Font = block.headingLevel == 2 ? .title2.weight(.semibold) : block.headingLevel == 3 ? .headline : .body
                if run.bold { font = font.bold() }
                if run.italic { font = font.italic() }
                value.font = font
                if run.underlined { value.underlineStyle = .single }
                if run.struckThrough { value.strikethroughStyle = .single }
                if let url = run.link, PublicContentURL.isHTTPS(url) { value.link = url }
                if block.quoted { value.foregroundColor = .secondary }
                result += value
            }
        }
        return result
    }
}

struct MacArticleImage: View {
    let content: ContentLibrary
    let articleID: String
    let url: URL
    let alt: String
    var contentMode: ContentMode = .fit
    var maximumPixelSize: Int = 1600
    @State private var image: CGImage?
    @State private var imageIdentity: String?
    @State private var failed = false
    @State private var requestID = UUID()

    private var resourceIdentity: String {
        (content.articleImages.identity(for: url, articleID: articleID) ?? "") + "|\(maximumPixelSize)"
    }

    var body: some View {
        Group {
            if let image, imageIdentity == resourceIdentity {
                Image(image, scale: 1, label: Text(alt)).resizable().aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: 1000)
                    .accessibilityLabel(alt)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
                    else { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity, minHeight: contentMode == .fit ? 140 : 0)
                .accessibilityLabel(failed ? "\(alt)，暂时无法显示" : "正在加载\(alt)")
            }
        }
        .task(id: resourceIdentity) {
            let request = UUID()
            requestID = request
            let identity = resourceIdentity
            image = nil
            imageIdentity = nil
            failed = false
            do {
                let loaded = try await content.articleImages.image(for: url, articleID: articleID, maximumPixelSize: maximumPixelSize)
                guard !Task.isCancelled, requestID == request else { return }
                image = loaded
                imageIdentity = identity
            } catch {
                guard !Task.isCancelled, requestID == request else { return }
                failed = true
            }
        }
        .onDisappear { requestID = UUID(); image = nil; imageIdentity = nil }
    }
}
