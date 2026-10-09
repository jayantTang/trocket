import XCTest

final class TunnelStateTests: XCTestCase {

    func testTexts() {
        XCTAssertEqual(TunnelState.unconfigured.text, "未导入订阅")
        XCTAssertEqual(TunnelState.disconnected.text, "未连接")
        XCTAssertEqual(TunnelState.connecting.text, "连接中")
        XCTAssertEqual(TunnelState.connected(connectedAt: nil, upload: 0, download: 0).text, "已连接")
        XCTAssertEqual(TunnelState.reasserting.text, "网络切换中")
        XCTAssertEqual(TunnelState.failed("配置加载失败").text, "配置加载失败")
    }

    func testToggleAvailability() {
        XCTAssertFalse(TunnelState.unconfigured.canToggle)
        XCTAssertFalse(TunnelState.connecting.canToggle)
        XCTAssertFalse(TunnelState.reasserting.canToggle)
        XCTAssertTrue(TunnelState.disconnected.canToggle)
        XCTAssertTrue(TunnelState.connected(connectedAt: nil, upload: 0, download: 0).canToggle)
        XCTAssertTrue(TunnelState.failed("x").canToggle)
    }

    func testTogglePositionFollowsConnection() {
        XCTAssertTrue(TunnelState.connected(connectedAt: nil, upload: 0, download: 0).toggleIsOn)
        XCTAssertTrue(TunnelState.connecting.toggleIsOn)
        XCTAssertTrue(TunnelState.reasserting.toggleIsOn)
        XCTAssertFalse(TunnelState.disconnected.toggleIsOn)
        XCTAssertFalse(TunnelState.failed("x").toggleIsOn)
    }

    func testTrafficTextOnlyWhenConnectedWithData() {
        XCTAssertNil(TunnelState.disconnected.trafficText)
        XCTAssertNil(TunnelState.connected(connectedAt: nil, upload: 0, download: 0).trafficText)
        XCTAssertEqual(
            TunnelState.connected(connectedAt: nil, upload: 1024, download: 2048).trafficText,
            "↑ 1 KB · ↓ 2 KB"
        )
    }

    func testIllegalTransitionsAreRejected() {
        // 没有 connecting 就直接 connected：系统上报也需要经过连接中，出现即视为异常
        XCTAssertFalse(TunnelState.unconfigured.canTransition(to: .connected(connectedAt: nil, upload: 0, download: 0)))
        XCTAssertFalse(TunnelState.connecting.canTransition(to: .unconfigured))
        XCTAssertTrue(TunnelState.disconnected.canTransition(to: .connecting))
        XCTAssertTrue(TunnelState.connecting.canTransition(to: .connected(connectedAt: nil, upload: 0, download: 0)))
        XCTAssertTrue(TunnelState.connected(connectedAt: nil, upload: 0, download: 0).canTransition(to: .disconnected))
        XCTAssertTrue(TunnelState.connected(connectedAt: nil, upload: 0, download: 0).canTransition(to: .reasserting))
        XCTAssertTrue(TunnelState.reasserting.canTransition(to: .connected(connectedAt: nil, upload: 0, download: 0)))
    }
}
