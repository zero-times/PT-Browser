import XCTest

final class LibraryUITests: XCTestCase {
    @MainActor private func launchLibrary() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting", "-media-ui-fixtures", "-library-ui-fixtures"]
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fullscreen-Test", withExtension: "mp4"))
        app.launchEnvironment["PT_UI_FIXTURE_VIDEO"] = try Data(contentsOf: video).base64EncodedString()
        app.launch()
        XCTAssertTrue(app.buttons["锁定加密库"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor func testWideThumbnailsStayInsideGridAndListCells() throws {
        let app = try launchLibrary()
        app.buttons["图片"].tap()
        let wide = app.buttons["mediaItem-Wide-1.png"]
        let next = app.buttons["mediaItem-Wide-2.png"]
        XCTAssertTrue(wide.waitForExistence(timeout: 10))
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertLessThan(wide.frame.width, app.frame.width / 2)
        XCTAssertLessThanOrEqual(wide.frame.maxX, next.frame.minX)
        XCTAssertLessThan(wide.frame.height, wide.frame.width + 70)
        let grid = XCTAttachment(screenshot: app.screenshot()); grid.name = "Wide grid"; grid.lifetime = .keepAlways; add(grid)
        wide.tap()
        XCTAssertTrue(app.buttons["关闭浏览"].waitForExistence(timeout: 5)); app.buttons["关闭浏览"].tap()
        app.buttons["筛选与排序"].tap()
        app.buttons["列表视图"].tap()
        XCTAssertTrue(wide.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(wide.frame.width, app.frame.width - 40)
        XCTAssertLessThan(wide.frame.height, 100)
        XCTAssertLessThanOrEqual(wide.frame.maxY, next.frame.minY)
        let list = XCTAttachment(screenshot: app.screenshot()); list.name = "Wide list"; list.lifetime = .keepAlways; add(list)
        next.tap()
        XCTAssertTrue(app.buttons["关闭浏览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Wide-2.png"].exists)
        app.buttons["关闭浏览"].tap()
    }
    @MainActor func testHiddenTypeFiltersDateGroupsAndLock() throws {
        let app = try launchLibrary()
        app.buttons["隐藏"].tap()
        let type = app.segmentedControls["hiddenMediaType"]
        XCTAssertTrue(type.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mediaItem-Hidden-Wide.png"].exists)
        XCTAssertFalse(app.buttons["mediaItem-Wide-1.png"].exists)
        type.buttons["视频"].tap()
        XCTAssertTrue(app.buttons["mediaItem-Hidden-Video.mp4"].exists)
        XCTAssertFalse(app.buttons["mediaItem-Hidden-Wide.png"].exists)
        type.buttons["音频"].tap()
        XCTAssertTrue(app.buttons["mediaItem-Hidden-Audio.wav"].exists)
        XCTAssertFalse(app.buttons["mediaItem-Hidden-Video.mp4"].exists)
        type.buttons["图片"].tap()
        app.buttons["筛选与排序"].tap()
        app.buttons["groupMediaByDate"].tap()
        let headings = app.staticTexts.matching(identifier: "mediaDateHeading")
        XCTAssertEqual(headings.count, 2)
        XCTAssertTrue(app.buttons["mediaItem-Hidden-Wide.png"].exists)
        XCTAssertTrue(app.buttons["mediaItem-Hidden-Tall.png"].exists)
        let groups = XCTAttachment(screenshot: app.screenshot()); groups.name = "Hidden date groups"; groups.lifetime = .keepAlways; add(groups)
        app.buttons["mediaItem-Hidden-Wide.png"].tap()
        XCTAssertTrue(app.buttons["关闭浏览"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 / 2"].exists)
        app.buttons["下一项"].tap()
        XCTAssertTrue(app.staticTexts["Hidden-Tall.png"].waitForExistence(timeout: 5))
        app.buttons["关闭浏览"].tap()
        app.buttons["锁定加密库"].tap()
        app.buttons["隐藏"].tap()
        XCTAssertTrue(app.buttons["解锁加密库"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["hiddenMediaType"].exists)
        XCTAssertFalse(app.buttons["mediaItem-Hidden-Wide.png"].exists)
        XCTAssertFalse(app.staticTexts["mediaDateHeading"].exists)
    }
}
