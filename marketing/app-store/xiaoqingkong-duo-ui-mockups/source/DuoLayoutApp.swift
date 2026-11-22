import SwiftUI
import UIKit
import QingkongCore

@main
final class DuoLayoutApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var host: UIHostingController<LayoutCanvas>?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in
            do {
                let services = try AppServices()
                await services.start()
                try await Task.sleep(for: .seconds(1))
                let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DuoLayoutRenders")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: output.appendingPathComponent("COMPLETE"))
                for (name, width, height) in [("outer", 1398, 2034), ("inner", 2007, 2853)] {
                    let size = CGSize(width: CGFloat(width) / 3, height: CGFloat(height) / 3)
                    for page in 0..<6 {
                        if ProcessInfo.processInfo.arguments.contains("--privacy-only") && page != 5 { continue }
                        let canvas = LayoutCanvas(services: services, page: page, size: size)
                        let hosting = UIHostingController(rootView: canvas)
                        hosting.safeAreaRegions = []
                        hosting.overrideUserInterfaceStyle = .light
                        root.addChild(hosting)
                        hosting.view.frame = CGRect(origin: .zero, size: size)
                        hosting.view.backgroundColor = .white
                        root.view.addSubview(hosting.view)
                        hosting.didMove(toParent: root)
                        host?.willMove(toParent: nil)
                        host?.view.removeFromSuperview()
                        host?.removeFromParent()
                        host = hosting
                        hosting.view.setNeedsLayout()
                        hosting.view.layoutIfNeeded()
                        try await Task.sleep(for: .seconds(4))
                        root.view.layoutIfNeeded()
                        hosting.view.layoutIfNeeded()
                        let format = UIGraphicsImageRendererFormat()
                        format.scale = 3
                        format.opaque = true
                        var complete = false
                        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                            UIColor.white.setFill()
                            context.fill(CGRect(origin: .zero, size: size))
                            complete = hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
                        }
                        let pages = ["01-today", "02-mood", "03-sleep", "04-trends", "05-scenes", "06-privacy"]
                        let file = "\(name)-\(pages[page])-\(width)x\(height).png"
                        try image.pngData()!.write(to: output.appendingPathComponent(file))
                        print("DUO_LAYOUT_EXPORTED \(file) complete=\(complete)")
                    }
                }
                try "complete".write(to: output.appendingPathComponent("COMPLETE"), atomically: true, encoding: .utf8)
                print("DUO_LAYOUT_COMPLETE \(output.path)")
            } catch { print("DUO_LAYOUT_ERROR \(error)") }
        }
        return true
    }
}

struct LayoutCanvas: View {
    let services: AppServices
    let page: Int
    let size: CGSize
    @State private var mood = 4
    @State private var metric: HealthMetric = .hrv
    @State private var selectedTab: Int

    init(services: AppServices, page: Int, size: CGSize) {
        self.services = services
        self.page = page
        self.size = size
        _selectedTab = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Text("9:41").font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }.font(.system(size: 15, weight: .medium)).foregroundStyle(.black)
                .padding(.horizontal, 30).frame(height: 46)
            Group {
                if page < 4 {
                    TabView(selection: $selectedTab) {
                        navigation("今日") { TodayView(selectedMood: $mood, openMood: {}, openSleep: {}) }
                            .tabItem { Label("今日", systemImage: "sun.max") }.tag(0)
                        navigation("趋势") { TrendsView(metric: $metric) }
                            .tabItem { Label("趋势", systemImage: "chart.bar") }.tag(3)
                        navigation("心情") { MoodView(selectedMood: $mood) }
                            .tabItem { Label("心情", systemImage: "face.smiling") }.tag(1)
                        navigation("助眠") { SleepView() }
                            .tabItem { Label("助眠", systemImage: "moon.stars") }.tag(2)
                    }.task { selectedTab = page }
                } else if page == 4 {
                    NavigationStack { PersonalizationView() }
                } else {
                    NavigationStack {
                        PrivacyView().navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("返回", systemImage: "chevron.left") {}.labelStyle(.iconOnly).buttonStyle(.automatic)
                                }
                            }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Capsule().fill(.black).frame(width: 134, height: 5).frame(height: 24)
        }
        .frame(width: size.width, height: size.height)
        .background(.white)
        .environment(services)
        .environment(\.horizontalSizeClass, .compact)
        .environment(\.verticalSizeClass, .regular)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.colorScheme, .light)
        .environment(\.symbolVariants, .none)
        .tint(services.scene.accent)
    }

    private func navigation<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("个性化", systemImage: "slider.horizontal.3") {}.buttonStyle(.automatic)
                    }
                }
        }
    }
}
