import XCTest

final class ClashYAMLTests: XCTestCase {

    func testConvertClashSample() throws {
        let result = try ClashYAML.convert(try Fixtures.text(Fixtures.clashSample))

        // WG-01（不支持的类型）与 BROKEN-01（缺 server/port）被跳过
        XCTAssertEqual(result.skipped, 2)

        let catalog = try ConfigShaping.catalog(fromProfile: try ConfigShaping.shape(subscription: result.config).data)
        XCTAssertEqual(catalog.nodeCount, 6)
        XCTAssertEqual(catalog.primaryGroup?.tag, "节点选择")
        XCTAssertEqual(catalog.automaticGroup?.tag, "自动选择")
        XCTAssertTrue(catalog.primaryGroup?.items.contains { $0.tag == "Block-01" } == true, "块式映射也要能解析")
    }

    func testOutboundFieldMapping() throws {
        let result = try ClashYAML.convert(try Fixtures.text(Fixtures.clashSample))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])

        func outbound(_ tag: String) -> [String: Any]? {
            outbounds.first { $0["tag"] as? String == tag }
        }

        let anytls = try XCTUnwrap(outbound("HK-01 [Normal x0.5]"))
        XCTAssertEqual(anytls["type"] as? String, "anytls")
        XCTAssertEqual(anytls["server_port"] as? Int, 1443)
        XCTAssertEqual((anytls["tls"] as? [String: Any])?["server_name"] as? String, "sni.example.com")
        XCTAssertEqual((anytls["tls"] as? [String: Any])?["enabled"] as? Bool, true)

        let ss = try XCTUnwrap(outbound("JP-01"))
        XCTAssertEqual(ss["type"] as? String, "shadowsocks")
        XCTAssertEqual(ss["method"] as? String, "aes-256-gcm")

        let vmess = try XCTUnwrap(outbound("US-01"))
        XCTAssertEqual(vmess["type"] as? String, "vmess")
        XCTAssertEqual((vmess["tls"] as? [String: Any])?["enabled"] as? Bool, true)

        let vless = try XCTUnwrap(outbound("SG-01"))
        XCTAssertEqual(vless["type"] as? String, "vless")
        XCTAssertEqual(vless["flow"] as? String, "xtls-rprx-vision")

        let trojan = try XCTUnwrap(outbound("TW-01"))
        XCTAssertEqual(trojan["type"] as? String, "trojan")
        XCTAssertEqual((trojan["tls"] as? [String: Any])?["insecure"] as? Bool, true)

        // 生成的配置里必须有 selector 与 urltest，且默认走节点选择
        XCTAssertNotNil(outbound("节点选择"))
        XCTAssertNotNil(outbound("自动选择"))
        XCTAssertEqual((root["route"] as? [String: Any])?["final"] as? String, "节点选择")
    }

    func testSplitTopLevelKeepsQuotedAndNestedCommas() {
        let chunks = ClashYAML.splitTopLevel("name: 'a, b', alpn: ['h3','h2'], port: 443")
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].trimmingCharacters(in: .whitespaces), "name: 'a, b'")
        XCTAssertEqual(chunks[2].trimmingCharacters(in: .whitespaces), "port: 443")
    }

    func testUnsupportedOnlyThrowsNoNodes() {
        let text = """
        proxies:
            - { name: 'W', type: wireguard, server: w.example.com, port: 51820, password: x }
        """
        XCTAssertThrowsError(try ClashYAML.convert(text)) { error in
            XCTAssertEqual(error as? TrocketError, .noNodes)
        }
    }
}
