import XCTest

final class QingkongUITests: XCTestCase {
    @MainActor
    func testHomeHRVChartAllowsPageScrolling() {
        let app = launch(demo: true)
        let chart = app.descendants(matching: .any)["today-hrv-chart"].firstMatch
        for _ in 0..<4 {
            if chart.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(chart.isHittable)
        let originalY = chart.frame.midY
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.5)))
        XCTAssertLessThan(chart.frame.midY, originalY - 20)
        XCTAssertFalse(app.descendants(matching: .any)["chart-selected-reading"].exists)
    }

    @MainActor
    func testTrendChartAllowsVerticalPageScrolling() {
        let app = launch(demo: true)
        app.tabBars.buttons["趋势"].tap()
        let chart = app.descendants(matching: .any)["health-trend-hrv"].firstMatch
        if !chart.isHittable { app.swipeUp() }
        XCTAssertTrue(chart.isHittable)
        let originalY = chart.frame.midY
        print("CHART_VERTICAL_BEGIN")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.1, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.8)))
        XCTAssertLessThan(chart.frame.midY, originalY - 20, "从图表纵向拖动也应滚动页面")
        XCTAssertFalse(app.descendants(matching: .any)["chart-selected-reading"].exists)
    }

    @MainActor
    func testFirstHealthIntroductionCanBeDeferredWithoutRepeating() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-reset", "--ui-health-introduction"]
        app.launch()
        XCTAssertTrue(app.buttons["initial-connect-health"].waitForExistence(timeout: 15))
        let skip = app.buttons["skip-initial-health"]
        if !skip.isHittable { app.swipeUp() }
        skip.tap()
        XCTAssertFalse(app.buttons["initial-connect-health"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-health-introduction"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["心情"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["initial-connect-health"].exists)
        app.buttons["open-settings"].tap()
        for _ in 0..<8 {
            if app.buttons["检查 Apple 健康连接"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["检查 Apple 健康连接"].isHittable)
    }

    @MainActor
    func testHealthReminderSettingsAndDiagnostics() {
        let app = launch()
        app.buttons["open-settings"].tap()
        for kind in ["highHeartRate", "lowHeartRate", "lowOxygen"] {
            let toggle = app.switches["reminder-\(kind)"].firstMatch
            for _ in 0..<6 {
                if toggle.isHittable { break }
                app.swipeUp()
            }
            XCTAssertEqual(toggle.value as? String, "1")
            XCTAssertTrue(app.steppers["threshold-\(kind)"].exists)
        }
        let diagnostics = app.buttons["notification-diagnostics"]
        for _ in 0..<4 {
            if diagnostics.isHittable { break }
            app.swipeUp()
        }
        diagnostics.tap()
        XCTAssertTrue(app.buttons["send-test-notification"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["尚未完成健康数据检查"].exists)
    }

    @MainActor
    func testTrendChartSelectionGesture() {
        let app = launch(demo: true)
        app.tabBars.buttons["趋势"].tap()
        for metric in ["HRV", "心率", "血氧"] {
            app.segmentedControls["trend-metric"].buttons[metric].tap()
            let id = metric == "HRV" ? "hrv" : metric == "心率" ? "heartRate" : "oxygen"
            let chart = app.descendants(matching: .any)["health-trend-\(id)"].firstMatch
            for _ in 0..<3 {
                if chart.isHittable && chart.frame.maxY < app.frame.maxY - 100 { break }
                app.swipeUp()
            }
            XCTAssertTrue(chart.isHittable)
            print("CHART_GESTURE_BEGIN_\(id)")
            chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.3, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 4)
            XCTAssertFalse(app.descendants(matching: .any)["chart-selected-reading"].exists)
        }
    }

    @MainActor
    func launch(reset: Bool = true, demo: Bool = false, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if reset { app.launchArguments.append("--ui-reset") }
        if demo { app.launchArguments.append("--demo-health") }
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["心情"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    func testFourTabsAndEmptyHealthState() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["基线积累中 · 至少需要 3 个有效日"].exists)
        for label in ["趋势", "心情", "助眠", "今日"] {
            app.tabBars.buttons[label].tap()
            XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 3))
        }
        XCTAssertFalse(app.staticTexts["演示健康数据，仅用于界面预览"].exists)
    }

    @MainActor
    func testMoodPersistsAcrossRelaunchAndDeletion() {
        let app = launch()
        app.tabBars.buttons["心情"].tap()
        app.buttons["mood-4"].tap()
        app.textViews["mood-note"].tap()
        app.textViews["mood-note"].typeText("A quiet moment")
        if app.buttons["完成"].exists { app.buttons["完成"].tap() }
        app.swipeUp()
        app.buttons["save-mood"].tap()
        XCTAssertTrue(app.staticTexts["mood-saved"].waitForExistence(timeout: 4))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["心情"].tap()
        app.swipeUp()
        app.buttons["mood-history"].tap()
        XCTAssertTrue(app.staticTexts["A quiet moment"].waitForExistence(timeout: 4))
        app.buttons["删除记录"].firstMatch.tap()
        app.buttons["confirm-delete-mood"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["还没有心情记录"].waitForExistence(timeout: 4))
        app.terminate()
        app.launch()
        app.tabBars.buttons["心情"].tap()
        app.swipeUp()
        app.buttons["mood-history"].tap()
        XCTAssertTrue(app.staticTexts["还没有心情记录"].waitForExistence(timeout: 4))
    }

    @MainActor
    func testThemesAndAudioPlayback() {
        let app = launch()
        app.buttons["open-settings"].tap()
        app.buttons["theme-forest"].tap()
        XCTAssertEqual(app.buttons["theme-forest"].value as? String, "已选中")
        app.buttons["完成"].tap()
        app.tabBars.buttons["助眠"].tap()
        app.swipeUp()
        app.buttons["player-toggle"].tap()
        XCTAssertTrue(app.buttons["暂停播放"].waitForExistence(timeout: 5))
        app.buttons["下一首"].tap()
        let title = app.staticTexts["current-track-title"]
        expectation(for: NSPredicate(format: "label == %@", "慢慢听海"), evaluatedWith: title)
        waitForExpectations(timeout: 3)
        app.buttons["player-toggle"].tap()
        XCTAssertTrue(app.buttons["开始播放"].exists)
    }

    @MainActor
    func testPressureThemeAndManualOverride() {
        let app = launch()
        app.buttons["open-settings"].tap()
        app.switches["auto-scene"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["auto-scene"].firstMatch.value as? String, "1")
        app.buttons["完成"].tap()
        app.tabBars.buttons["心情"].tap()
        app.segmentedControls["stress-picker"].buttons["4"].tap()
        XCTAssertTrue(app.segmentedControls["stress-picker"].buttons["4"].isSelected)
        app.swipeUp()
        app.buttons["save-mood"].tap()
        XCTAssertTrue(app.staticTexts["mood-saved"].waitForExistence(timeout: 4))
        app.buttons["open-settings"].tap()
        XCTAssertEqual(app.buttons["theme-forest"].value as? String, "已选中")
        app.buttons["theme-night"].tap()
        XCTAssertEqual(app.buttons["theme-night"].value as? String, "已选中")
        XCTAssertEqual(app.switches["auto-scene"].firstMatch.value as? String, "0")
    }

    @MainActor
    func testDesignPreviewScreenshot() {
        let app = launch(demo: true)
        XCTAssertTrue(app.staticTexts["演示健康数据，仅用于界面预览"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "晴空-01-今日"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAccessibilityOfMainScreens() throws {
        let app = launch()
        for label in ["今日", "趋势", "心情", "助眠"] {
            app.tabBars.buttons[label].tap()
            try app.performAccessibilityAudit(for: [.dynamicType, .textClipped, .trait, .sufficientElementDescription])
        }
    }

    @MainActor
    func testLargestTextSizeMoodAndPlayback() throws {
        let app = launch(largeType: true)
        app.tabBars.buttons["心情"].tap()
        try app.performAccessibilityAudit(for: [.textClipped, .sufficientElementDescription])
        for _ in 0..<5 {
            if app.buttons["mood-5"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["mood-5"].tap()
        for _ in 0..<6 {
            if app.buttons["save-mood"].isHittable { break }
            app.swipeUp()
        }
        app.buttons["save-mood"].tap()
        XCTAssertTrue(app.staticTexts["mood-saved"].waitForExistence(timeout: 4))
        app.tabBars.buttons["助眠"].tap()
        for _ in 0..<6 {
            if app.buttons["player-toggle"].isHittable { break }
            app.swipeUp()
        }
        try app.performAccessibilityAudit(for: [.textClipped, .sufficientElementDescription])
        app.buttons["player-toggle"].tap()
        XCTAssertTrue(app.buttons["暂停播放"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "最大辅助字号-助眠"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["player-toggle"].tap()
    }

    @MainActor
    func testSleepTimerFollowsPlaybackStateAcrossTabs() {
        let app = launch()
        app.tabBars.buttons["助眠"].tap()
        app.swipeUp()
        app.segmentedControls["sleep-timer"].buttons["30 分"].tap()
        XCTAssertTrue(app.segmentedControls["sleep-timer"].buttons["30 分"].isSelected)
        app.tabBars.buttons["今日"].tap()
        app.tabBars.buttons["助眠"].tap()
        XCTAssertTrue(app.segmentedControls["sleep-timer"].buttons["30 分"].isSelected)
        app.buttons["下一首"].tap()
        XCTAssertTrue(app.segmentedControls["sleep-timer"].buttons["30 分"].isSelected)
        app.segmentedControls["sleep-timer"].buttons["关闭"].tap()
        XCTAssertTrue(app.segmentedControls["sleep-timer"].buttons["关闭"].isSelected)
    }

    @MainActor
    func testThemeTextContrast() throws {
        let app = launch(demo: true)
        for theme in ["clear", "forest", "ocean", "night"] {
            app.buttons["open-settings"].tap()
            app.buttons["theme-\(theme)"].tap()
            app.buttons["完成"].tap()
            for position in 0..<3 {
                try auditVisibleContentContrast(in: app)
                if position < 2 { app.swipeUp() }
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "主题对比度-\(theme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            for _ in 0..<3 { app.swipeDown() }
        }
    }

    @MainActor
    private func auditVisibleContentContrast(in app: XCUIApplication) throws {
        let top = app.navigationBars.firstMatch.frame.maxY
        let bottom = app.tabBars.firstMatch.frame.minY
        let visibleContent = CGRect(x: app.frame.minX, y: top, width: app.frame.width, height: max(0, bottom - top))
        try app.performAccessibilityAudit(for: [.contrast]) { issue in
            guard let element = issue.element else { return false }
            // Native glass bars also expose scrolled-out text in the AX tree.
            // Audit it after scrolling into view, not through the system overlay.
            return !visibleContent.contains(element.frame)
        }
    }
}
