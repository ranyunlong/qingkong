import AVKit
import SwiftUI

/// The system owns route selection. A paired Bonjour device never implies that
/// AirPlay audio has reached it, and the app never silently chooses a route.
struct PhoneAudioRoutePicker: View {
    let tint: Color
    var body: some View {
        Group {
            if #available(iOS 26, *) {
                NativeAudioRoutePicker(tint: tint).frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            } else {
                NativeAudioRoutePicker(tint: tint).frame(width: 44, height: 44)
                    .background(.thinMaterial, in: Circle())
            }
        }
        .accessibilityIdentifier("playback-device")
    }
}

private struct NativeAudioRoutePicker: UIViewRepresentable {
    let tint: Color
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.prioritizesVideoDevices = false
        picker.tintColor = .secondaryLabel
        picker.activeTintColor = UIColor(tint)
        picker.accessibilityLabel = "播放设备"
        return picker
    }
    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.activeTintColor = UIColor(tint)
    }
}
