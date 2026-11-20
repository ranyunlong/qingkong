import XCTest

final class ECGScrollingUITests: XCTestCase {
    @MainActor
    func testWaveformScrollingPerformance() {
        let app = XCUIApplication()
        app.launch()
        let chart = app.descendants(matching: .any)["ecg-waveform-chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        let frame = chart.frame.intersection(app.frame)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let right = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.85, dy: frame.midY))
        let left = origin.withOffset(CGVector(dx: frame.minX + frame.width * 0.15, dy: frame.midY))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric, XCTCPUMetric(application: app)], options: options) {
            right.press(forDuration: 0.1, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0)
            left.press(forDuration: 0.1, thenDragTo: right, withVelocity: .slow, thenHoldForDuration: 0)
        }
    }

    @MainActor
    func testBrowseEntireWaveformAndScrollPage() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let chart = app.descendants(matching: .any)["ecg-waveform-chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 15))
        let range = app.staticTexts["ecg-visible-range"]
        func swipeWaveform(left: Bool, hold: TimeInterval = 0) {
            let visible = chart.frame.intersection(app.frame)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.minX + visible.width * (left ? 0.85 : 0.15), dy: visible.midY))
            let end = origin.withOffset(CGVector(dx: visible.minX + visible.width * (left ? 0.15 : 0.85), dy: visible.midY))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
        }
        print("ECG_CHART_FRAME", chart.frame, "WINDOW", app.frame)
        for _ in 0..<8 {
            if range.label.hasPrefix("0.0–5.0") { break }
            swipeWaveform(left: false)
        }
        XCTAssertTrue(range.label.hasPrefix("0.0–5.0"), "应能返回记录开头：\(range.label)")
        let header = app.staticTexts["演示波形 · 仅用于交互验证"]
        let initialY = header.frame.midY
        print("ECG_HORIZONTAL_BEGIN")
        swipeWaveform(left: true, hold: 1)
        print("ECG_AFTER_FIRST_DRAG", range.label)
        let dragged = XCTAttachment(screenshot: app.screenshot())
        dragged.name = "心电图横向浏览后无选值浮层"
        dragged.lifetime = .keepAlways
        add(dragged)
        XCTAssertFalse(app.descendants(matching: .any)["chart-selected-reading"].exists)
        XCTAssertFalse(range.label.hasPrefix("0.0–5.0"), "横向拖动应浏览后续波形：\(range.label)")
        XCTAssertEqual(header.frame.midY, initialY, accuracy: 1, "横向拖动不应移动页面")
        for _ in 0..<14 {
            if range.label.hasPrefix("25.0–30.0") { break }
            swipeWaveform(left: true)
        }
        XCTAssertTrue(range.label.hasPrefix("25.0–30.0"), "应能浏览到记录最后一秒：\(range.label)")
        let end = XCTAttachment(screenshot: app.screenshot())
        end.name = "心电图末尾25至30秒"
        end.lifetime = .keepAlways
        add(end)
        swipeWaveform(left: false)
        XCTAssertFalse(range.label.hasPrefix("25.0–30.0"), "应能向回浏览")
        let beforeScroll = chart.frame.midY
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            .press(forDuration: 0.1, thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6)))
        XCTAssertLessThan(chart.frame.midY, beforeScroll - 20, "纵向拖动应滚动页面")
        XCTAssertFalse(app.descendants(matching: .any)["chart-selected-reading"].exists)
    }
}
