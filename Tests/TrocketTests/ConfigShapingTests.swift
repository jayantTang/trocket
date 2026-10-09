import XCTest

final class ConfigShapingTests: XCTestCase {

    func testShapeMigratesLegacySyntaxAndReplacesInbounds() throws {
        let shaped = try ConfigShaping.shape(subscription: try Fixtures.data(Fixtures.singboxSample))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: shaped.data) as? [String: Any])

        // 入站只剩我们自己的 tun，且不带 1.13 起被移除的旧字段
        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 1, "桌面端的 socks/mixed 入站必须被替换掉")
        let tun = try XCTUnwrap(inbounds.first)
        XCTAssertEqual(tun["type"] as? String, "tun")
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        XCTAssertEqual(tun["mtu"] as? Int, ConfigShaping.tunMTU)
        XCTAssertEqual(tun["auto_route"] as? Bool, true)
        XCTAssertEqual(tun["strict_route"] as? Bool, false)
        XCTAssertNil(tun["sniff"], "sniff 属旧入站字段，内核 1.13 起会拒绝加载")
        XCTAssertNil(tun["domain_strategy"], "domain_strategy 属旧入站字段")

        // DNS 服务器迁移到新语法
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let remote = try XCTUnwrap(servers.first { $0["tag"] as? String == "remote" })
        XCTAssertEqual(remote["type"] as? String, "https")
        XCTAssertEqual(remote["server"] as? String, "1.1.1.1")
        XCTAssertNil(remote["address"])

        // 已废弃的 dns 出站被移除
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertFalse(outbounds.contains { $0["type"] as? String == "dns" })
        XCTAssertEqual(outbounds.count, 36, "37 个出站里有 1 个是已废弃的 dns 出站")

        // 路由层：sniff 动作 + hijack-dns + 默认解析器
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["action"] as? String, "sniff")
        XCTAssertTrue(rules.contains { $0["action"] as? String == "hijack-dns" })
        XCTAssertFalse(rules.contains { $0["outbound"] as? String == "dns-out" })
        let resolver = try XCTUnwrap(route["default_domain_resolver"] as? [String: Any])
        XCTAssertEqual(resolver["server"] as? String, "local")

        XCTAssertFalse(shaped.migrationNotes.isEmpty, "真实订阅是旧语法，应产生迁移记录")
        XCTAssertNotNil(root["experimental"], "experimental 段必须透传")
    }

    func testCatalogFromRealFixture() throws {
        let shaped = try ConfigShaping.shape(subscription: try Fixtures.data(Fixtures.singboxSample))
        let catalog = try ConfigShaping.catalog(fromProfile: shaped.data)

        XCTAssertEqual(catalog.nodeCount, 32)
        XCTAssertEqual(catalog.primaryGroup?.tag, "节点选择")
        XCTAssertEqual(catalog.automaticGroup?.tag, "自动选择")
        XCTAssertEqual(catalog.primaryGroup?.items.count, 32, "分组型出站不能被当成线路")
        XCTAssertEqual(catalog.primaryGroup?.selected, "自动选择")
        XCTAssertFalse(catalog.isEmpty)
    }

    func testShapeRejectsMissingOutbounds() throws {
        let payload = Data(#"{"inbounds":[],"outbounds":[]}"#.utf8)
        XCTAssertThrowsError(try ConfigShaping.shape(subscription: payload)) { error in
            XCTAssertEqual(error as? TrocketError, .missingOutbounds)
        }
    }

    func testShapeRejectsConfigWithoutNodes() throws {
        let payload = Data(#"{"outbounds":[{"type":"selector","tag":"节点选择","outbounds":[]}]}"#.utf8)
        XCTAssertThrowsError(try ConfigShaping.shape(subscription: payload)) { error in
            XCTAssertEqual(error as? TrocketError, .noNodes)
        }
    }

    func testDetectFormat() throws {
        XCTAssertEqual(
            ConfigShaping.detectFormat(data: try Fixtures.data(Fixtures.singboxSample), contentType: "application/json"),
            .singboxJSON
        )
        XCTAssertEqual(
            ConfigShaping.detectFormat(data: try Fixtures.data(Fixtures.clashSample), contentType: "text/yaml"),
            .clashYAML
        )
        XCTAssertNil(ConfigShaping.detectFormat(data: Data("Payment Required".utf8), contentType: "text/html"))
    }
}
