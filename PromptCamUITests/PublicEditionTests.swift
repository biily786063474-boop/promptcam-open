import XCTest

final class PublicEditionTests: XCTestCase {
    func testCameraOffersOnlyPublicModes() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let dismiss = app.alerts.buttons["知道了"]
        if dismiss.waitForExistence(timeout: 5) { dismiss.tap() }
        XCTAssertTrue(app.buttons["单摄"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["双摄"].exists)
        XCTAssertFalse(app.buttons["换脸"].exists, "Public edition must not expose the private capture mode")
        XCTAssertFalse(app.buttons["选个角色"].exists)
    }
}
