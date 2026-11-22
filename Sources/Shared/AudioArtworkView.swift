import SwiftUI
import ImageIO
import QingkongCore

struct AudioArtworkView: View {
    let state: AudioState

    var body: some View {
        GeometryReader { geometry in
            Group {
                switch state.artwork {
                case .bundled(let name): Image(name).resizable().scaledToFill()
                case .remote(let url):
                    RemoteAudioArtwork(url: url)
                case .placeholder: placeholder
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
        }
    }
}

private struct RemoteAudioArtwork: View {
    let url: URL
    @State private var image: CGImage?
    @MainActor private static let cache: NSCache<NSURL, CGImage> = {
        let cache = NSCache<NSURL, CGImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
                }
            }
        }
        .transaction { $0.animation = nil }
        .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            // Keep the previous cover in place until the replacement is ready.
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                      response.url.map(PublicContentURL.isHTTPS) == true, data.count <= 8_000_000,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let loaded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 512,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { image = nil; return }
                Self.cache.setObject(loaded, forKey: url as NSURL, cost: loaded.bytesPerRow * loaded.height)
                image = loaded
            } catch {
                if !Task.isCancelled { image = nil }
            }
        }
    }
}
