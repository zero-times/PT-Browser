import XCTest

final class MediaViewerUITests: XCTestCase {
    @MainActor private func launchMedia(history: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-media-ui-fixtures"]
        if history { app.launchArguments.append("-history-ui-fixtures") }
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fullscreen-Test", withExtension: "mp4"))
        app.launchEnvironment["PT_UI_FIXTURE_VIDEO"] = try Data(contentsOf: video).base64EncodedString()
        app.launch()
        XCTAssertTrue(app.navigationBars["媒体库"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor func testVideoKeepsPlayingThroughNativeFullScreenAndBack() throws {
        let app = try launchMedia()
        app.buttons["影音"].tap()
        let video = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fullscreen-Test.mp4")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 5)); video.tap()
        let probe = app.staticTexts["playbackProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let running = NSPredicate { _, _ in self.playbackState(probe)?.seconds ?? 0 > 0.5 }
        expectation(for: running, evaluatedWith: probe)
        waitForExpectations(timeout: 10)
        let before = try XCTUnwrap(playbackState(probe))
        let expand = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'full screen' OR label MATCHES[c] '(enter|exit|toggle) fullscreen' OR label CONTAINS '全屏' OR label == 'Expand'")).firstMatch
        if !expand.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        guard expand.waitForExistence(timeout: 5) else { print(app.debugDescription); XCTFail("Native fullscreen control is missing"); return }
        expand.tap()
        Thread.sleep(forTimeInterval: 3)
        let collapse = app.buttons.matching(NSPredicate(format: "(label MATCHES[c] '.*full[- ]?screen.*' AND NOT label CONTAINS[c] '.mp4') OR label CONTAINS '全屏' OR label == 'Done' OR label == '完成' OR label == 'Close' OR label == '关闭'")).firstMatch
        if !collapse.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        guard collapse.waitForExistence(timeout: 3) else {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("PTFullScreen.png")
            try app.screenshot().pngRepresentation.write(to: path)
            print("FULLSCREEN SCREENSHOT \(path.path)\n\(app.debugDescription)")
            XCTFail("Native exit control is missing"); return
        }
        collapse.tap()
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        let after = try XCTUnwrap(playbackState(probe))
        XCTAssertEqual(after.session, before.session, "Fullscreen must keep the same player session")
        XCTAssertGreaterThan(after.seconds, before.seconds + 1, "Playback must advance while fullscreen")
        app.buttons["关闭浏览"].tap()
        XCTAssertTrue(app.navigationBars["媒体库"].waitForExistence(timeout: 5))
    }
    @MainActor func testLongImageModeContinuouslyScrollsThroughMultipleImages() throws {
        let app = try launchMedia()
        app.buttons["图片"].tap()
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Image-1.png")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5)); first.tap()
        app.buttons["浏览设置"].tap()
        let toggle = app.descendants(matching: .any).matching(identifier: "continuousReadingToggle").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        let list = app.scrollViews["continuousImageList"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let imageOne = app.buttons["readingImage-Image-1.png"]
        XCTAssertTrue(imageOne.waitForExistence(timeout: 10))
        var reached = false
        for _ in 0..<10 {
            if app.buttons["readingImage-Image-3.png"].isHittable { reached = true; break }
            list.swipeUp()
        }
        XCTAssertTrue(reached, "The same scroll view must reach subsequent images without paging")
        XCTAssertFalse(app.staticTexts["无法读取图片"].exists)
        app.buttons["关闭浏览"].tap()
    }
    @MainActor func testOneTapDownloadHistoryClearKeepsSavedVideo() throws {
        let app = try launchMedia(history: true)
        app.tabBars.buttons["下载"].tap()
        XCTAssertTrue(app.staticTexts["失败，可重试"].waitForExistence(timeout: 5))
        let clear = app.buttons["clearDownloadHistory"]
        XCTAssertTrue(clear.isEnabled); clear.tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["失败，可重试"].exists)
        XCTAssertFalse(app.staticTexts["已完成"].exists)
        XCTAssertFalse(clear.isEnabled)
        app.tabBars.buttons["媒体库"].tap()
        app.buttons["影音"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fullscreen-Test.mp4")).firstMatch.waitForExistence(timeout: 5))
    }
    @MainActor private func playbackState(_ probe: XCUIElement) -> (session: String, seconds: Double)? {
        let parts = probe.label.split(separator: "|")
        guard parts.count == 3, let seconds = Double(parts[1]) else { return nil }
        return (String(parts[0]), seconds)
    }
}
