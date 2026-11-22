import XCTest

final class FeatureCompletionUITests: XCTestCase {
    @MainActor
    func testHomeMoreButtonsAndLifeTagSpacing() {
        let app = launch()
        let albums = app.buttons["open-album-library"]
        reveal(albums, in: app)
        let refresh = app.buttons["refresh-home-album"]
        XCTAssertEqual(albums.frame.height, refresh.frame.height, accuracy: 1)
        albums.tap()
        XCTAssertTrue(app.navigationBars["专辑与声音"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let articles = app.buttons["open-knowledge-library"]
        reveal(articles, in: app)
        XCTAssertEqual(articles.frame.height, refresh.frame.height, accuracy: 1)
        articles.tap()
        XCTAssertTrue(app.navigationBars["安心小知识"].waitForExistence(timeout: 5))
        app.tabBars.buttons["心情"].tap()
        let tags = app.buttons["生活标签（可选）"]
        reveal(tags, in: app)
        tags.tap()
        let work = app.switches["life-tag-work"]
        reveal(work, in: app)
        let family = app.switches["life-tag-family"]
        XCTAssertGreaterThanOrEqual(family.frame.minY - work.frame.minY, 52)
        XCTAssertGreaterThanOrEqual(family.frame.minY, work.frame.maxY)
        capture(app, name: "手机-生活标签开关间距")
    }

    @MainActor
    func testSleepSeekAndMiniPlayerNavigation() {
        let app = launch()
        app.tabBars.buttons["助眠"].tap()
        app.buttons["player-toggle"].tap()
        let progress = app.sliders["playback-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        app.buttons["player-toggle"].tap()
        func seconds(_ text: String) -> Double {
            let parts = text.components(separatedBy: ":").compactMap(Double.init)
            return parts.count == 2 ? parts[0] * 60 + parts[1] : 0
        }
        let values = (progress.value as? String ?? "").components(separatedBy: "，共 ")
        XCTAssertEqual(values.count, 2)
        let fraction = values.count == 2 ? seconds(values[0]) / max(1, seconds(values[1])) : 0
        let inset = 16 / progress.frame.width
        let start = progress.coordinate(withNormalizedOffset: CGVector(dx: inset + fraction * (1 - 2 * inset), dy: 0.5))
        let end = progress.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        let elapsed = app.staticTexts["playback-elapsed"]
        let advanced = NSPredicate { _, _ in
            let parts = elapsed.label.replacingOccurrences(of: "已播放 ", with: "").components(separatedBy: ":").compactMap(Int.init)
            return parts.count == 2 && parts[0] * 60 + parts[1] > 8
        }
        expectation(for: advanced, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.buttons["player-toggle"].label, "开始播放", "定位不应自动恢复已暂停的音频")
        app.buttons["player-toggle"].tap()
        XCTAssertFalse(app.buttons["mini-player-toggle"].exists)
        let settings = app.buttons["睡前陪伴与个人方案"]
        reveal(settings, in: app)
        settings.tap()
        XCTAssertTrue(app.buttons["mini-player-toggle"].waitForExistence(timeout: 5), "助眠子页面仍显示悬浮播放条")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["mini-player-toggle"].exists, "回到助眠主页后隐藏")
        app.tabBars.buttons["心情"].tap()
        XCTAssertTrue(app.buttons["mini-player-toggle"].waitForExistence(timeout: 5))
        capture(app, name: "手机-进度拖动与悬浮播放条")
    }

    @MainActor
    private func launch(demo: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-reset"] + (demo ? ["--demo-health"] : [])
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["心情"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHealthCardsShowSampleProvenance() {
        let app = launch(demo: true)
        app.buttons["open-settings"].tap()
        let calm = app.switches["calm-home"]
        reveal(calm, in: app)
        if calm.value as? String == "1" {
            calm.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(calm.value as? String, "0", "先关闭安心首页，再检查健康卡")
        app.buttons["完成"].tap()
        let source = app.staticTexts["来源：演示数据"].firstMatch
        reveal(source, in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "日均依据 ")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "最近采样：")).firstMatch.exists)
        capture(app, name: "手机-健康来源与采样时间-演示数据")
    }

    @MainActor
    func testMoodUnlocksExpressionAndPostcardPreview() {
        let app = launch()
        app.tabBars.buttons["心情"].tap()
        app.buttons["mood-2"].tap()
        reveal(app.buttons["save-mood"], in: app)
        app.buttons["save-mood"].tap()
        XCTAssertTrue(app.staticTexts["mood-saved"].waitForExistence(timeout: 5))
        let postcard = app.buttons["心情明信片"]
        reveal(postcard, in: app)
        postcard.tap()
        let expression = app.buttons["postcard-expression-gentleSmile"]
        reveal(expression, in: app)
        XCTAssertTrue(expression.isEnabled)
        expression.tap()
        let scenery = app.buttons["postcard-collected-scenery"]
        reveal(scenery, in: app)
        scenery.tap()
        app.buttons["晨光草地"].tap()
        reveal(app.buttons["preview-postcard"], in: app)
        app.buttons["preview-postcard"].tap()
        XCTAssertTrue(app.navigationBars["分享前预览"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["share-postcard-image"].exists)
        capture(app, name: "手机-新增表情风景明信片预览")
        app.buttons["返回编辑"].tap()
        XCTAssertTrue(app.navigationBars["心情明信片"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCompletedPracticeUnlocksSecondCollection() {
        let app = launch()
        app.buttons["open-relaxation"].tap()
        let start = app.buttons["start-relaxation"]
        reveal(start, in: app)
        start.tap()
        XCTAssertTrue(app.buttons["pause-relaxation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["暂时不想记录感受"].waitForExistence(timeout: 80))
        app.buttons["暂时不想记录感受"].tap()
        app.buttons["完成"].tap()
        app.tabBars.buttons["心情"].tap()
        reveal(app.buttons["心情明信片"], in: app)
        app.buttons["心情明信片"].tap()
        let expression = app.buttons["postcard-expression-brightEyes"]
        reveal(expression, in: app)
        XCTAssertTrue(expression.isEnabled)
        expression.tap()
        let scenery = app.buttons["postcard-collected-scenery"]
        reveal(scenery, in: app)
        scenery.tap()
        XCTAssertTrue(app.buttons["月下湖畔"].waitForExistence(timeout: 5))
        app.buttons["月下湖畔"].tap()
        reveal(app.buttons["preview-postcard"], in: app)
        app.buttons["preview-postcard"].tap()
        XCTAssertTrue(app.navigationBars["分享前预览"].waitForExistence(timeout: 10))
        capture(app, name: "手机-完成陪伴解锁月下湖畔")
    }
}
