import SwiftUI

@main
struct QingkongApp: App {
    @State private var services: AppServices? = try? PhoneAppRuntime.services()
    var body: some Scene {
        WindowGroup {
            Group {
                if let services { RootView().environment(services) }
                else { RecoveryView(retry: initialize) }
            }.qingkongGlassButton()
        }
    }
    private func initialize() {
        services = try? PhoneAppRuntime.services()
    }
}
