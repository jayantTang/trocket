import XCTest

/// 迁移规则逐条验证。真实订阅（夹具）就是旧语法，因此这些用例同时是回归保护。
final class ConfigMigrationTests: XCTestCase {

    private func migrate(_ json: String) throws -> (root: [String: Any], notes: [String]) {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let result = ConfigMigration.migrate(&root)
        return (root, result.notes)
    }

    func testLegacyDNSServersAreUpgraded() throws {
        let (root, notes) = try migrate("""
        {
          "dns": {"servers": [
            {"address": "https://1.1.1.1/dns-query", "detour": "节点选择", "tag": "remote"},
            {"address": "tls://8.8.8.8:853", "tag": "tls"},
            {"address": "223.5.5.5", "tag": "plain"},
            {"address": "local", "tag": "local"}
          ]},
          "outbounds": [{"type": "direct", "tag": "direct"}]
        }
        """)
        let servers = try XCTUnwrap((root["dns"] as? [String: Any])?["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 4)

        let remote = try XCTUnwrap(servers.first { $0["tag"] as? String == "remote" })
        XCTAssertEqual(remote["type"] as? String, "https")
        XCTAssertEqual(remote["server"] as? String, "1.1.1.1")
        XCTAssertEqual(remote["detour"] as? String, "节点选择")
        XCTAssertNil(remote["address"])

        let tls = try XCTUnwrap(servers.first { $0["tag"] as? String == "tls" })
        XCTAssertEqual(tls["type"] as? String, "tls")
        XCTAssertEqual(tls["server_port"] as? Int, 853)

        let plain = try XCTUnwrap(servers.first { $0["tag"] as? String == "plain" })
        XCTAssertEqual(plain["type"] as? String, "udp")
        XCTAssertEqual(plain["server"] as? String, "223.5.5.5")

        let local = try XCTUnwrap(servers.first { $0["tag"] as? String == "local" })
        XCTAssertEqual(local["type"] as? String, "local")

        XCTAssertFalse(notes.isEmpty)
    }

    func testUnconvertibleServerAndItsRuleAreDropped() throws {
        let (root, _) = try migrate("""
        {
          "dns": {
            "servers": [{"address": "rcode://success", "tag": "block"},
                        {"address": "1.1.1.1", "tag": "remote"}],
            "rules": [{"server": "block", "clash_mode": "direct"}, {"server": "remote"}]
          },
          "outbounds": [{"type": "direct", "tag": "direct"}]
        }
        """)
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 1, "rcode:// 在新语法里没有等价物，应被丢弃")
        let rules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1, "引用被移除服务器的规则必须一起丢弃，否则加载会失败")
        XCTAssertEqual(rules.first?["server"] as? String, "remote")
    }

    func testLegacyDNSOutboundAndHijackRule() throws {
        let (root, _) = try migrate("""
        {
          "outbounds": [
            {"type": "selector", "tag": "节点选择", "outbounds": ["dns-out", "hk"], "default": "dns-out"},
            {"type": "dns", "tag": "dns-out"},
            {"type": "anytls", "tag": "hk"}
          ],
          "route": {"rules": [{"outbound": "dns-out", "protocol": "dns"}]}
        }
        """)
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertFalse(outbounds.contains { $0["type"] as? String == "dns" })

        let selector = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "节点选择" })
        XCTAssertEqual(selector["outbounds"] as? [String], ["hk"], "分组里对被删出站的引用要清掉")
        XCTAssertEqual(selector["default"] as? String, "hk", "默认项被删时要回落到其它成员")

        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let dnsRule = try XCTUnwrap(rules.first { $0["protocol"] as? String == "dns" })
        XCTAssertEqual(dnsRule["action"] as? String, "hijack-dns")
        XCTAssertNil(dnsRule["outbound"])
    }

    func testLegacyInboundFieldsBecomeRouteActions() throws {
        let (root, _) = try migrate("""
        {
          "inbounds": [{"type": "tun", "tag": "tun-in", "sniff": true,
                        "sniff_override_destination": true, "domain_strategy": "prefer_ipv4"}],
          "dns": {"servers": [{"address": "1.1.1.1", "tag": "local"}],
                  "rules": [{"outbound": ["any"], "server": "local"}]},
          "outbounds": [{"type": "direct", "tag": "direct"}],
          "route": {"rules": [{"ip_is_private": true, "outbound": "direct"}]}
        }
        """)
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertNil(inbound["sniff"])
        XCTAssertNil(inbound["sniff_override_destination"])
        XCTAssertNil(inbound["domain_strategy"])

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["action"] as? String, "sniff", "sniff 必须换成路由动作且排在最前")
        XCTAssertTrue(rules.contains { $0["ip_is_private"] as? Bool == true }, "原有规则不能被丢掉")

        let resolver = try XCTUnwrap(route["default_domain_resolver"] as? [String: Any])
        XCTAssertEqual(resolver["server"] as? String, "local")
        XCTAssertEqual(resolver["strategy"] as? String, "prefer_ipv4")
        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertTrue(dnsRules.isEmpty, "outbound 项已迁移，不应残留")
    }

    func testAlreadyModernConfigIsUntouched() throws {
        let (root, notes) = try migrate("""
        {
          "dns": {"servers": [{"type": "https", "server": "1.1.1.1", "tag": "remote"}]},
          "inbounds": [{"type": "tun", "tag": "tun-in"}],
          "outbounds": [{"type": "anytls", "tag": "hk"}],
          "route": {"rules": [{"action": "sniff"}]}
        }
        """)
        XCTAssertTrue(notes.isEmpty, "已经是新语法时不应产生迁移记录")
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1, "不应重复插入 sniff 动作")
    }
}

/// 真机"点开关立刻弹回"的根因回归：detour 指向空的 direct 出站会让内核启动直接 FATAL。
final class DetourAndProbeTests: XCTestCase {

    func testDetourToEmptyDirectOutboundIsRemoved() throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "dns": {"servers": [
            {"type": "https", "server": "223.5.5.5", "tag": "local", "detour": "direct"},
            {"type": "https", "server": "1.1.1.1", "tag": "remote", "detour": "节点选择"}
          ]},
          "outbounds": [
            {"type": "direct", "tag": "direct"},
            {"type": "selector", "tag": "节点选择", "outbounds": ["hk"]},
            {"type": "anytls", "tag": "hk"}
          ]
        }
        """.utf8)) as? [String: Any])
        let result = ConfigMigration.migrate(&root)
        let servers = try XCTUnwrap((root["dns"] as? [String: Any])?["servers"] as? [[String: Any]])
        let local = try XCTUnwrap(servers.first { $0["tag"] as? String == "local" })
        XCTAssertNil(local["detour"], "指向空 direct 出站的 detour 必须去掉，否则 start service 直接 FATAL")
        let remote = try XCTUnwrap(servers.first { $0["tag"] as? String == "remote" })
        XCTAssertEqual(remote["detour"] as? String, "节点选择", "指向真实出站的 detour 要保留")
        XCTAssertTrue(result.notes.contains { $0.contains("detour") })
    }

    func testUnavailableRemoteRuleSetsAreStripped() throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "outbounds": [{"type": "direct", "tag": "direct"}],
          "route": {
            "rule_set": [{"tag": "geosite-cn", "type": "remote", "format": "binary", "url": "https://example.com/a.srs"}],
            "rules": [{"rule_set": ["geosite-cn"], "outbound": "direct"}, {"ip_is_private": true, "outbound": "direct"}],
            "final": "direct"
          }
        }
        """.utf8)) as? [String: Any])
        // base 指向空目录：本地拿不到规则集，只能摘除（真机上是"内置也没有、下载也失败"的兜底路径）
        let empty = try makeRuleSetDirectory()
        let result = ConfigMigration.localizeRemoteRuleSets(&root, base: empty)
        XCTAssertEqual(result.removed, ["geosite-cn"])
        XCTAssertTrue(result.localized.isEmpty)
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertTrue((route["rule_set"] as? [[String: Any]])?.isEmpty == true)
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1, "引用被摘除规则集的规则要一起去掉")
        XCTAssertTrue(rules[0]["ip_is_private"] as? Bool == true)
    }

    /// 本地有规则集文件时必须改写成本地引用，而不是摘除——国内直连就靠这条活下来。
    func testRemoteRuleSetIsLocalizedWhenFileExists() throws {
        let base = try makeRuleSetDirectory()
        try writeRuleSet(named: "geosite-cn.srs", in: base)
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("""
        {
          "outbounds": [{"type": "direct", "tag": "direct"}],
          "route": {
            "rule_set": [{"tag": "geosite-cn", "type": "remote", "format": "binary",
                          "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"}],
            "rules": [{"rule_set": ["geosite-cn"], "outbound": "direct"}],
            "final": "direct"
          }
        }
        """.utf8)) as? [String: Any])
        let result = ConfigMigration.localizeRemoteRuleSets(&root, base: base)
        XCTAssertEqual(result.localized, ["geosite-cn"])
        XCTAssertTrue(result.removed.isEmpty)

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let entry = try XCTUnwrap((route["rule_set"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["type"] as? String, "local")
        XCTAssertEqual(entry["format"] as? String, "binary")
        XCTAssertEqual(entry["path"] as? String, base.appendingPathComponent("rule-set/geosite-cn.srs").path)
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1, "改写不能丢规则")
        XCTAssertEqual(rules[0]["outbound"] as? String, "direct")
    }

    func testProbeConfigHasNoInboundAndKeepsOutbounds() throws {
        let shape = try ConfigShaping.shape(subscription: try Fixtures.data(Fixtures.singboxSample))
        let text = try XCTUnwrap(String(data: shape.data, encoding: .utf8))
        let probe = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try ProbeConfig.make(fromProfileJSON: text).utf8)) as? [String: Any])

        XCTAssertEqual((probe["inbounds"] as? [[String: Any]])?.count, 0, "探针不能带 tun 入站")
        let outbounds = try XCTUnwrap(probe["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbounds.count, 36)
        XCTAssertNil(probe["dns"], "探针不需要 DNS 段，越薄启动越快")
        XCTAssertEqual((probe["route"] as? [String: Any])?["final"] as? String, "节点选择")
    }

    func testLatencyStatsAverage() {
        XCTAssertEqual(LatencyStats(delays: [100, 200, 300]).average, 200)
        XCTAssertEqual(LatencyStats(delays: [100, 200, 300]).available, 3)
        // 超时（nil / 0）不计入平均，只影响可用条数
        let mixed = LatencyStats(delays: [100, nil, 0, 300])
        XCTAssertEqual(mixed.average, 200)
        XCTAssertEqual(mixed.available, 2)
        XCTAssertEqual(mixed.total, 4)
        XCTAssertEqual(mixed.summary, "平均 200 ms · 2/4 可用")
        XCTAssertEqual(LatencyStats(delays: [nil, 0]).summary, "全部超时")
        XCTAssertNil(LatencyStats(delays: [nil, 0]).average)
    }
}

extension ConfigMigrationTests {
    /// 真机回归：只清 route.rules 不够，dns.rules 里的 rule_set 引用同样会让隧道起不来。
    func testDNSRuleReferencingStrippedRuleSetIsRemoved() throws {
        let json = #"{"dns":{"servers":[{"type":"https","server":"223.5.5.5","tag":"local"}],"rules":[{"rule_set":["geosite-cn"],"server":"local"},{"clash_mode":"direct","server":"local"}]},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rule_set":[{"tag":"geosite-cn","type":"remote","format":"binary","url":"https://example.com/a.srs"}],"rules":[{"rule_set":["geosite-cn"],"outbound":"direct"}],"final":"direct"}}"#
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        _ = ConfigMigration.localizeRemoteRuleSets(&root, base: try makeRuleSetDirectory())
        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(dnsRules.count, 1, "引用被摘除规则集的 DNS 规则必须一起去掉")
        XCTAssertEqual(dnsRules.first?["clash_mode"] as? String, "direct")
    }
}

extension ConfigMigrationTests {
    /// 真机/真网回归：anytls 节点带 alpn=["h3"] 时服务端拒绝握手（tls: no application protocol），
    /// 表现为"隧道连上但上不了网"。迁移必须去掉它。
    func testAnyTLSALPNIsStripped() throws {
        let json = #"{"outbounds":[{"type":"anytls","tag":"hk","tls":{"enabled":true,"alpn":["h3"],"server_name":"a.example.com"}},{"type":"trojan","tag":"tw","tls":{"enabled":true,"alpn":["h3"]}}]}"#
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let notes = ConfigMigration.migrate(&root).notes
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let hk = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "hk" })
        XCTAssertNil((hk["tls"] as? [String: Any])?["alpn"], "anytls 的 alpn 必须去掉")
        XCTAssertEqual((hk["tls"] as? [String: Any])?["server_name"] as? String, "a.example.com", "其它 TLS 字段保留")
        let tw = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "tw" })
        XCTAssertNotNil((tw["tls"] as? [String: Any])?["alpn"], "只动 anytls，别误伤其它协议")
        XCTAssertTrue(notes.contains { $0.contains("ALPN") })
    }
}
