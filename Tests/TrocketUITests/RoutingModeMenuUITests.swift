import XCTest

/// 仿真器界面验证：菜单里的「路由模式」两项，以及模式的持久化。
///
/// 网络扩展在 iOS 仿真器不可用（见 `specs/001-ios-vpn-client/verification/auto-verification.md`），
/// 所以这里只验界面与状态：菜单能打开、两项都在、切换后有对勾、重启后仍在。
/// 「国内直连真的生效」「全局真的全走线路」必须真机验证。
final class RoutingModeMenuUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testRoutingModeMenuAndPersistence() {
        let app = XCUIApplication()
        app.launch()

        openMenu(app, step: "01")

        let ruleItem = app.buttons.matching(labelBeginsWith: "规则（国内直连）").firstMatch
        let globalItem = app.buttons.matching(labelBeginsWith: "全局（全部走线路）").firstMatch
        XCTAssertTrue(ruleItem.waitForExistence(timeout: 5), "菜单里没有「规则」项")
        XCTAssertTrue(globalItem.exists, "菜单里没有「全局」项")
        attach(app, name: "01~路由模式菜单")

        // 切到「全局」：菜单里该项要带对勾
        globalItem.tap()
        openMenu(app, step: "02")
        let globalChecked = app.buttons.matching(labelBeginsWith: "全局（全部走线路）✓").firstMatch
        XCTAssertTrue(globalChecked.waitForExistence(timeout: 5), "切到全局后没有对勾")
        attach(app, name: "02~全局已选中")

        // 杀进程重开：模式必须保留（App Group 持久化）
        app.terminate()
        app.launch()
        openMenu(app, step: "03")
        XCTAssertTrue(app.buttons.matching(labelBeginsWith: "全局（全部走线路）✓").firstMatch.waitForExistence(timeout: 5),
                      "重启后模式没有保留")
        attach(app, name: "03~重启后仍是全局")

        // 还原成「规则」，避免影响后续用例
        app.buttons.matching(labelBeginsWith: "规则（国内直连）").firstMatch.tap()
        openMenu(app, step: "04")
        XCTAssertTrue(app.buttons.matching(labelBeginsWith: "规则（国内直连）✓").firstMatch.waitForExistence(timeout: 5),
                      "切回规则后没有对勾")
        attach(app, name: "04~已还原规则")
    }

    // MARK: - 辅助

    private func openMenu(_ app: XCUIApplication, step: String) {
        let menu = app.buttons["菜单"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "[\(step)] 找不到菜单按钮")
        menu.tap()
        XCTAssertTrue(app.buttons.matching(labelBeginsWith: "规则（国内直连）").firstMatch.waitForExistence(timeout: 8),
                      "[\(step)] 菜单没有展开（看不到路由模式项）")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

extension XCUIElementQuery {
    /// 菜单项的对勾会拼在标题里（`规则（国内直连）✓`），所以按前缀匹配
    func matching(labelBeginsWith prefix: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
    }
}
