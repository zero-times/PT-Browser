import XCTest
final class AppUITests: XCTestCase {
    @MainActor func testTabsAndVaultCreation() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitesting"]
        app.launch()
        XCTAssertTrue(app.navigationBars["媒体库"].waitForExistence(timeout: 10))
        app.buttons["隐藏"].tap()
        app.buttons["创建加密库"].tap()
        let password = app.secureTextFields["vaultPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap(); password.typeText("test-password-123")
        app.secureTextFields["vaultConfirmation"].tap(); app.secureTextFields["vaultConfirmation"].typeText("test-password-123")
        app.buttons["vaultSubmit"].tap()
        XCTAssertTrue(app.buttons["锁定加密库"].waitForExistence(timeout: 10))
        app.buttons["锁定加密库"].tap()
        app.tabBars.buttons["浏览器"].tap()
        XCTAssertTrue(app.textFields["browserAddress"].waitForExistence(timeout: 5))
        app.tabBars.buttons["下载"].tap()
        XCTAssertTrue(app.navigationBars["下载"].waitForExistence(timeout: 5))
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["选择 / 恢复已有文件夹"].waitForExistence(timeout: 5))
    }
}
