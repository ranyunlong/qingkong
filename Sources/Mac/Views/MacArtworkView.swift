import SwiftUI
import QingkongCore

struct MacArtworkView: View {
    let item: DesktopQueueItem?
    var cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let track = item?.track {
                    Image(track.image).resizable().scaledToFill()
                } else if let track = item?.onlineTrack, let url = track.coverURL {
                    MacAlbumArtworkView(url: url, identity: "\(track.albumID)|\(track.revision)|\(track.updatedAt.timeIntervalSince1970)", cornerRadius: cornerRadius)
                } else {
                    placeholder
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "music.note").font(.title).foregroundStyle(.secondary)
        }
    }
}

struct MacPlayerSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

func macPlaybackClock(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}
