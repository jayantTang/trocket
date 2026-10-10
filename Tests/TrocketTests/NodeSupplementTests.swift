import XCTest

/// 「补齐节点」回归：服务商对 Clash 系客户端会多给一批节点（实测多出美国/德国各 6 条），
/// 只以 sing-box 模板为准会让这些节点在界面上消失。
final class NodeSupplementTests: XCTestCase {

    private let profileJSON = """
    {
      "outbounds": [
        {"type": "anytls", "tag": "香港 01"},
        {"type": "anytls", "tag": "香港 02"},
        {"type": "selector", "tag": "节点选择", "outbounds": ["香港 01", "香港 02"], "default": "香港 01"},
        {"type": "urltest", "tag": "自动选择", "outbounds": ["香港 01", "香港 02"]},
        {"type": "direct", "tag": "direct"}
      ]
    }
    """

    private let clashYAML = """
    proxies:
        - { name: '香港 01', type: anytls, server: hk1.example.com, port: 443, password: p1, sni: a.example.com }
        - { name: '香港 02', type: anytls, server: hk2.example.com, port: 443, password: p2, sni: a.example.com }
        - { name: '美国 01', type: anytls, server: us1.example.com, port: 443, password: p3, sni: a.example.com }
        - { name: '德国 01', type: anytls, server: de1.example.com, port: 443, password: p4, sni: a.example.com }
    """

    func testMissingNodesAreMergedIntoGroups() throws {
        let merged = try XCTUnwrap(NodeSupplement.merge(into: Data(profileJSON.utf8), clashText: clashYAML))
        XCTAssertEqual(merged.added, ["美国 01", "德国 01"])

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let tags = outbounds.compactMap { $0["tag"] as? String }
        XCTAssertTrue(tags.contains("美国 01"))
        XCTAssertTrue(tags.contains("德国 01"))
        XCTAssertEqual(tags.filter { $0 == "香港 01" }.count, 1, "同名节点不能被重复加入")

        for groupTag in ["节点选择", "自动选择"] {
            let group = try XCTUnwrap(outbounds.first { $0["tag"] as? String == groupTag })
            XCTAssertEqual(group["outbounds"] as? [String], ["香港 01", "香港 02", "美国 01", "德国 01"],
                           "\(groupTag) 要把新节点挂上，否则界面上仍看不到")
        }

        // 补进来的节点字段要与 Clash 模板一致（可拨号）
        let us = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "美国 01" })
        XCTAssertEqual(us["type"] as? String, "anytls")
        XCTAssertEqual(us["server"] as? String, "us1.example.com")
        XCTAssertEqual(us["server_port"] as? Int, 443)
    }

    func testNoExtraNodesMeansNoChange() throws {
        let clash = """
        proxies:
            - { name: '香港 01', type: anytls, server: hk1.example.com, port: 443, password: p1 }
        """
        XCTAssertNil(NodeSupplement.merge(into: Data(profileJSON.utf8), clashText: clash))
    }

    func testUnparsableClashTextIsIgnored() throws {
        XCTAssertNil(NodeSupplement.merge(into: Data(profileJSON.utf8), clashText: "<html>not a subscription</html>"))
    }

    /// 端到端：整形后的真实订阅 + Clash 模板 → 线路数应等于两边并集。
    func testMergeWithFixturesKeepsProviderRules() throws {
        let base = try makeRuleSetDirectory()
        try writeBundledRuleSets(in: base)
        let shaped = try ConfigShaping.shape(subscription: try Fixtures.data(Fixtures.singboxSample), base: base)
        let before = try ConfigShaping.catalog(fromProfile: shaped.data).nodeCount

        let clash = """
        proxies:
            - { name: '美国 01', type: anytls, server: us1.example.com, port: 443, password: p3 }
        """
        let merged = try XCTUnwrap(NodeSupplement.merge(into: shaped.data, clashText: clash))
        let after = try ConfigShaping.catalog(fromProfile: merged.data)
        XCTAssertEqual(after.nodeCount, before + 1)

        // 服务商自己的规则必须原样保留（补齐只动 outbounds）
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: merged.data) as? [String: Any])
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: shaped.data) as? [String: Any])
        XCTAssertEqual((root["route"] as? [String: Any])?.count, (original["route"] as? [String: Any])?.count)
        XCTAssertNotNil((root["route"] as? [String: Any])?["rule_set"])
    }
}
