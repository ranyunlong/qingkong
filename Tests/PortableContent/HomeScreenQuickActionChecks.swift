import Foundation

private enum CheckFailure: Error { case failed(String) }

@main
struct HomeScreenQuickActionChecks {
    @MainActor static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Config/iOS-Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        let items = plist["UIApplicationShortcutItems"] as? [[String: String]] ?? []
        try check(items.map { $0["UIApplicationShortcutItemTitle"] ?? "" } == ["陪我缓一缓", "当前趋势", "记录此刻", "听听音乐"], "安装包必须按指定顺序提供四个入口")
        let types = items.map { $0["UIApplicationShortcutItemType"] ?? "" }
        try check(types == HomeScreenQuickAction.allCases.map(\.rawValue), "菜单中的每个入口必须由实际路由支持")
        try check(items.allSatisfy { !($0["UIApplicationShortcutItemIconSymbolName"] ?? "").isEmpty }, "每个入口需要图标")
        print("PASS: four static menu entries match the app's supported actions")

        let actions = HomeScreenQuickActions()
        try check(actions.takePendingAction() == nil, "普通启动不能产生快捷动作")
        for action in HomeScreenQuickAction.allCases {
            try check(actions.receive(type: action.rawValue), "应接收所有已配置动作")
            try check(actions.pendingAction == action, "冷启动或首次说明未完成时应保留待处理动作")
            try check(!actions.receive(type: "unknown-action"), "未知动作不能误跳转")
            try check(actions.pendingAction == action, "未知动作不能覆盖有效待处理动作")
            try check(actions.takePendingAction() == action, "界面就绪后应取出原动作")
            try check(actions.takePendingAction() == nil, "动作只能消费一次")
            try check(actions.receive(type: action.rawValue), "同一入口应能重复使用")
            try check(actions.takePendingAction() == action, "再次点击同一入口不能丢失")
        }
        actions.receive(type: HomeScreenQuickAction.relaxation.rawValue)
        actions.receive(type: HomeScreenQuickAction.music.rawValue)
        try check(actions.takePendingAction() == .music, "界面未就绪时应采用最近一次明确选择")
        print("PASS: deferred, repeated, unknown, and replacement actions behave correctly")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
}
