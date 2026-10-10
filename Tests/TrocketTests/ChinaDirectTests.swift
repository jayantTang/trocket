import XCTest

/// 国内直连（规则集本地化 + 兜底规则）与「规则 / 全局」开关的回归用例。
final class ChinaDirectTests: XCTestCase {

    // MARK: - 整形后的真实订阅

    /// 内置规则集就位时：订阅里那条 `rule_set: [geosite-cn, geoip-cn] → direct` 必须活下来，
    /// 而且指向容器里的本地文件（此前会被整条摘掉，表现为国内流量也走代理）。
    func testShapedProfileKeepsChinaDirectRuleWithLocalRuleSets() throws {
        let base = try makeRuleSetDirectory()
        try writeBundledRuleSets(in: base)

        let shaped = try ConfigShaping.shape(subscription: try Fixtures.data(Fixtures.singboxSample), base: base)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: shaped.data) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        for tag in ["geosite-cn", "geoip-cn"] {
            let entry = try XCTUnwrap(ruleSets.first { $0["tag"] as? String == tag }, "缺少 \(tag) 规则集")
            XCTAssertEqual(entry["type"] as? String, "local")
            let path = try XCTUnwrap(entry["path"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "\(tag) 必须指向真实存在的本地文件")
        }

        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let chinaDirect = rules.contains { rule in
            (rule["outbound"] as? String) == "direct"
                && (rule["rule_set"] as? [String])?.contains("geosite-cn") == true
        }
        XCTAssertTrue(chinaDirect, "国内直连规则必须保留")

        // 国产域名/IP 的 DNS 解析也要走本地服务器，否则解析结果会让判定偏
        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains { ($0["rule_set"] as? [String])?.contains("geosite-cn") == true })
    }

    /// 订阅里没有国内直连规则时（例如只给节点、规则靠远端规则集但全都拿不到）要兜底补一条。
    func testChinaDirectRuleIsAppendedWhenMissing() throws {
        let base = try makeRuleSetDirectory()
        try writeBundledRuleSets(in: base)

        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "selector", "tag": "节点选择", "outbounds": ["direct"]}],
          "route": {"rules": [{"action": "sniff"}, {"ip_is_private": true, "outbound": "direct"}], "final": "节点选择"}
        }
        """.utf8)) as? [String: Any])

        let note = ConfigShaping.ensureChinaDirectRule(&root, base: base)
        XCTAssertNotNil(note, "补规则要给出提示文案")

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let last = try XCTUnwrap(rules.last)
        XCTAssertEqual(last["outbound"] as? String, "direct")
        XCTAssertEqual(Set(try XCTUnwrap(last["rule_set"] as? [String])), ["geosite-cn", "geoip-cn"])
        // 兜底规则必须排在最后：服务商自己的分流优先级更高
        XCTAssertEqual(rules.count, 3)
        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.count, 2, "两个内置规则集都要挂上")
    }

    /// App Group 容器路径会随"删除后重装"变化：老 profile 里的绝对路径必须按文件名修好，
    /// 否则国内直连规则会被静默丢掉（回到"什么都走代理"）。
    func testStaleLocalRuleSetPathIsRepaired() throws {
        let base = try makeRuleSetDirectory()
        try writeBundledRuleSets(in: base)

        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "outbounds": [{"type": "direct", "tag": "direct"}],
          "route": {
            "rule_set": [{"tag": "geosite-cn", "type": "local", "format": "binary",
                          "path": "/private/var/mobile/Containers/Shared/AppGroup/OLD-UUID/rule-set/geosite-cn.srs"}],
            "rules": [{"rule_set": ["geosite-cn"], "outbound": "direct"}],
            "final": "direct"
          }
        }
        """.utf8)) as? [String: Any])

        let result = ConfigMigration.localizeRemoteRuleSets(&root, base: base)
        XCTAssertEqual(result.localized, ["geosite-cn"])
        XCTAssertTrue(result.removed.isEmpty, "能修好的不能当摘除处理")

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let entry = try XCTUnwrap((route["rule_set"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["path"] as? String, base.appendingPathComponent("rule-set/geosite-cn.srs").path)
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1, "国内直连规则必须保留")
    }

    /// 订阅自己已经有国内直连规则时不要重复补。
    func testChinaDirectRuleIsNotDuplicated() throws {
        let base = try makeRuleSetDirectory()
        try writeBundledRuleSets(in: base)

        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "outbounds": [{"type": "direct", "tag": "direct"}],
          "route": {
            "rule_set": [{"tag": "geosite-cn", "type": "local", "format": "binary", "path": "/tmp/geosite-cn.srs"}],
            "rules": [{"rule_set": ["geosite-cn"], "outbound": "direct"}],
            "final": "direct"
          }
        }
        """.utf8)) as? [String: Any])
        XCTAssertNil(ConfigShaping.ensureChinaDirectRule(&root, base: base))
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
    }

    // MARK: - 模式开关

    /// 订阅没写 clash_mode 规则时要补上，否则切「全局」毫无反应。
    func testClashModeRulesAreAddedWhenMissing() throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "dns": {"servers": [{"type": "https", "server": "1.1.1.1", "tag": "remote"},
                              {"type": "https", "server": "223.5.5.5", "tag": "local"}],
                  "rules": [{"rule_set": ["geosite-cn"], "server": "local"}]},
          "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "selector", "tag": "节点选择", "outbounds": ["direct"]}],
          "route": {"rules": [{"action": "sniff"}, {"ip_is_private": true, "outbound": "direct"}], "final": "节点选择"}
        }
        """.utf8)) as? [String: Any])

        let notes = ConfigShaping.ensureClashModeRules(&root, primaryTag: "节点选择")
        XCTAssertFalse(notes.isEmpty)

        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let global = try XCTUnwrap(rules.first { $0["clash_mode"] as? String == "global" })
        XCTAssertEqual(global["outbound"] as? String, "节点选择")
        XCTAssertTrue(rules.contains { $0["clash_mode"] as? String == "direct" && $0["outbound"] as? String == "direct" })
        // sniff 动作规则仍在最前
        XCTAssertEqual(rules.first?["action"] as? String, "sniff")

        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.contains { $0["clash_mode"] as? String == "global" && $0["server"] as? String == "remote" },
                      "全局模式下 DNS 也要走远端服务器")
    }

    func testClashModeRulesAreNotDuplicated() throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "dns": {"servers": [{"type": "https", "server": "1.1.1.1", "tag": "remote"}],
                  "rules": [{"clash_mode": "global", "server": "remote"}]},
          "outbounds": [{"type": "direct", "tag": "direct"}],
          "route": {
            "rules": [{"action": "sniff"},
                      {"clash_mode": "global", "outbound": "节点选择"},
                      {"clash_mode": "direct", "outbound": "direct"}],
            "final": "节点选择"
          }
        }
        """.utf8)) as? [String: Any])
        XCTAssertTrue(ConfigShaping.ensureClashModeRules(&root, primaryTag: "节点选择").isEmpty)
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 3)
    }

    func testRoutingModeRoundTrip() throws {
        let suiteName = "trocket.tests.routing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(RoutingMode.load(defaults: defaults), .rule, "默认必须是规则模式（国内直连）")
        RoutingMode.save(.global, defaults: defaults)
        XCTAssertEqual(RoutingMode.load(defaults: defaults), .global)
        XCTAssertEqual(RoutingMode.global.clashMode, "global")
        XCTAssertEqual(RoutingMode.rule.clashMode, "rule")
    }

    // MARK: - Clash 兜底转换

    /// Clash 订阅走兜底解析，生成的配置同样要带国内直连（此前完全没有）。
    func testClashConversionIncludesChinaDirect() throws {
        let base = try makeRuleSetDirectory()
        try writeBundledRuleSets(in: base)

        let result = try ClashYAML.convert(try Fixtures.text(Fixtures.clashSample), base: base)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.config) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String])?.contains("geosite-cn") == true
                                        && $0["outbound"] as? String == "direct" })
        XCTAssertTrue(rules.contains { $0["clash_mode"] as? String == "global" && $0["outbound"] as? String == "节点选择" })
        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.count, 2)
        XCTAssertTrue(ruleSets.allSatisfy { ($0["path"] as? String).map { FileManager.default.fileExists(atPath: $0) } == true })
        XCTAssertEqual(route["final"] as? String, "节点选择", "未命中规则的流量仍然走所选线路")
    }

    /// 没有内置规则集时（异常打包）不能崩，也不能生成引用不存在文件的规则。
    func testClashConversionWithoutRuleSetsStillWorks() throws {
        let empty = try makeRuleSetDirectory()
        let result = try ClashYAML.convert(try Fixtures.text(Fixtures.clashSample), base: empty)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.config) as? [String: Any])
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertNil(route["rule_set"])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertFalse(rules.contains { $0["rule_set"] != nil })
        XCTAssertTrue(rules.contains { $0["ip_is_private"] as? Bool == true })
    }
}
