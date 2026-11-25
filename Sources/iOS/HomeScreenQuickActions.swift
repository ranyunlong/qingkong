import Foundation
import Observation

enum HomeScreenQuickAction: String, CaseIterable {
    case relaxation = "cn.geckoai.qingkong.relaxation"
    case trends = "cn.geckoai.qingkong.trends"
    case recordMood = "cn.geckoai.qingkong.record-mood"
    case music = "cn.geckoai.qingkong.music"
}

@MainActor
@Observable
final class HomeScreenQuickActions {
    static let shared = HomeScreenQuickActions()
    private(set) var pendingAction: HomeScreenQuickAction?

    @discardableResult
    func receive(type: String) -> Bool {
        guard let action = HomeScreenQuickAction(rawValue: type) else { return false }
        pendingAction = action
        return true
    }

    func takePendingAction() -> HomeScreenQuickAction? {
        defer { pendingAction = nil }
        return pendingAction
    }
}

#if os(iOS)
import UIKit

final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = connectingSceneSession.configuration
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let shortcut = connectionOptions.shortcutItem {
            HomeScreenQuickActions.shared.receive(type: shortcut.type)
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(HomeScreenQuickActions.shared.receive(type: shortcutItem.type))
    }
}
#endif
