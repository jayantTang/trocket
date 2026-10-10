import Foundation

/// 把服务商给的**旧语法** sing-box 配置迁移到本项目内核（1.14.x）能加载的新语法。
///
/// 为什么需要：服务商目前仍按 1.11/1.12 时代的写法下发配置，而这些写法在内核升级后已被**移除**，
/// 直接喂给 1.14 会在加载时报错（实测报错原文）：
/// - `dns.servers[0]: legacy DNS server formats … removed in sing-box 1.14.0`
/// - `outbounds[3]: dns outbound is deprecated … removed in sing-box 1.13.0`
/// - `initialize inbound[0]: legacy inbound fields are deprecated … removed in sing-box 1.13.0`
///
/// 迁移规则逐条对照 sing-box 官方 migration 文档，并用 `sing-box check`（1.14.2，本地）验证通过。
public enum ConfigMigration {

    public struct Result: Equatable {
        public var notes: [String]
        public var failure: String?

        public init(notes: [String] = [], failure: String? = nil) {
            self.notes = notes
            self.failure = failure
        }
    }

    /// 已是新语法的配置（例如我们自己生成的 Clash 兜底配置）会原样返回、notes 为空。
    public static func migrate(_ root: inout [String: Any]) -> Result {
        var notes: [String] = []
        var droppedServerTags = Set<String>()

        // 1) DNS 服务器：address → type/server
        var dns = root["dns"] as? [String: Any] ?? [:]
        if let servers = dns["servers"] as? [[String: Any]] {
            var migrated: [[String: Any]] = []
            var upgradedCount = 0
            for server in servers {
                if let upgraded = upgrade(server: server, droppedTags: &droppedServerTags) {
                    if server["address"] != nil { upgradedCount += 1 }
                    migrated.append(upgraded)
                } else if let address = server["address"] as? String {
                    if let tag = server["tag"] as? String {
                        droppedServerTags.insert(tag)
                    }
                    notes.append("丢弃无法迁移的 DNS 服务器 \(address)")
                }
            }
            dns["servers"] = migrated
            if upgradedCount > 0 {
                notes.append("DNS 服务器已迁移为新语法（\(upgradedCount) 个）")
            }
        }

        // 2) 出站的旧字段（sniff / domain_strategy 等）→ 路由动作
        var sniffEnabled = false
        var domainStrategy: String?
        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        for index in inbounds.indices {
            if inbounds[index]["sniff"] as? Bool == true { sniffEnabled = true }
            if let strategy = inbounds[index]["domain_strategy"] as? String, !strategy.isEmpty {
                domainStrategy = strategy
            }
            for field in Self.legacyInboundFields {
                inbounds[index].removeValue(forKey: field)
            }
        }
        root["inbounds"] = inbounds

        // 3) DNS 规则里的 outbound 项 → route.default_domain_resolver
        var resolverServer: String?
        if var rules = dns["rules"] as? [[String: Any]] {
            var remaining: [[String: Any]] = []
            for var rule in rules {
                if let server = rule["server"] as? String, droppedServerTags.contains(server) {
                    notes.append("丢弃引用了已移除 DNS 服务器的规则")
                    continue
                }
                if rule["outbound"] != nil, let server = rule["server"] as? String {
                    resolverServer = server
                    notes.append("DNS 规则的 outbound 项迁移为 default_domain_resolver")
                    continue
                }
                rule.removeValue(forKey: "outbound")
                remaining.append(rule)
            }
            rules = remaining
            dns["rules"] = rules
        }
        // 服务商给 "local" 这类服务器写了 detour: "direct"，而 direct 出站没有额外选项，
        // sing-box 1.14 在**启动服务**时会直接 FATAL：
        //   start dns/https[local]: detour to an empty direct outbound makes no sense
        // （check 不报，只有 run 才炸 —— 这就是"点开关立刻弹回"的根因）。
        if var servers = dns["servers"] as? [[String: Any]] {
            let emptyDirectTags = Set(outboundsForDirectCheck(in: root).compactMap { outbound -> String? in
                guard outbound["type"] as? String == "direct" else { return nil }
                let meaningfulKeys = Set(outbound.keys).subtracting(["type", "tag"])
                return meaningfulKeys.isEmpty ? outbound["tag"] as? String : nil
            })
            var stripped = 0
            for index in servers.indices {
                if let detour = servers[index]["detour"] as? String, emptyDirectTags.contains(detour) {
                    servers[index].removeValue(forKey: "detour")
                    stripped += 1
                }
            }
            if stripped > 0 {
                notes.append("去掉指向空 direct 出站的 detour（\(stripped) 处，否则内核启动即失败）")
            }
            dns["servers"] = servers
        }

        root["dns"] = dns

        // 4) 移除已废弃的 dns 出站，并清理分组里的引用
        var outbounds = root["outbounds"] as? [[String: Any]] ?? []
        let dnsOutboundTags = Set(outbounds.compactMap { outbound -> String? in
            outbound["type"] as? String == "dns" ? outbound["tag"] as? String : nil
        })
        if !dnsOutboundTags.isEmpty {
            outbounds.removeAll { $0["type"] as? String == "dns" }
            for index in outbounds.indices {
                if let members = outbounds[index]["outbounds"] as? [String] {
                    outbounds[index]["outbounds"] = members.filter { !dnsOutboundTags.contains($0) }
                }
                if let fallback = outbounds[index]["default"] as? String, dnsOutboundTags.contains(fallback) {
                    let members = outbounds[index]["outbounds"] as? [String] ?? []
                    if let first = members.first {
                        outbounds[index]["default"] = first
                    } else {
                        outbounds[index].removeValue(forKey: "default")
                    }
                }
            }
            root["outbounds"] = outbounds
            notes.append("移除已废弃的 dns 出站")
        }

        // 4.5) AnyTLS 出站去掉 ALPN。
        // 实测（本机脚本，同一内核 1.14.2）：服务商给 anytls 节点写了 tls.alpn=["h3"]，
        // 服务端在 TLS 握手时回 "remote error: tls: no application protocol"，
        // 表现为"隧道能建起来、但所有出站都拨不通"（测速全超时、打开网页失败）。
        // 去掉 alpn 后同一条线路：delay=355ms，经代理 curl gstatic 返回 204。
        if let outbounds = root["outbounds"] as? [[String: Any]] {
            var strippedALPN = 0
            var updated = outbounds
            for index in updated.indices where updated[index]["type"] as? String == "anytls" {
                guard var tls = updated[index]["tls"] as? [String: Any], tls["alpn"] != nil else { continue }
                tls.removeValue(forKey: "alpn")
                updated[index]["tls"] = tls
                strippedALPN += 1
            }
            if strippedALPN > 0 {
                root["outbounds"] = updated
                notes.append("去掉 AnyTLS 节点上服务端不接受的 ALPN 标记（\(strippedALPN) 个）")
            }
        }

        // 5) 路由：sniff 动作 + hijack-dns + 默认解析器
        var route = root["route"] as? [String: Any] ?? [:]
        var rules = route["rules"] as? [[String: Any]] ?? []

        for index in rules.indices {
            guard let outbound = rules[index]["outbound"] as? String else { continue }
            if dnsOutboundTags.contains(outbound) || outbound == "dns-out" {
                rules[index].removeValue(forKey: "outbound")
                rules[index]["action"] = "hijack-dns"
                notes.append("路由规则 outbound=dns-out 改写为 action=hijack-dns")
            }
        }

        if sniffEnabled || !rules.isEmpty {
            if !rules.contains(where: { $0["action"] as? String == "sniff" }) {
                rules.insert(["action": "sniff"], at: 0)
                if sniffEnabled {
                    notes.append("inbound.sniff 迁移为路由动作 action=sniff")
                }
            }
        }
        route["rules"] = rules

        if let resolverServer {
            var resolver: [String: Any] = ["server": resolverServer]
            if let domainStrategy { resolver["strategy"] = domainStrategy }
            route["default_domain_resolver"] = resolver
        }
        root["route"] = route

        return Result(notes: notes)
    }

    /// 远端 rule_set 的本地化结果。
    public struct RuleSetLocalization: Equatable {
        /// 已改写成本地文件引用的 tag。
        public var localized: [String] = []
        /// 本地拿不到、只能摘除（连同引用它的规则）的 tag。
        public var removed: [String] = []

        public init(localized: [String] = [], removed: [String] = []) {
            self.localized = localized
            self.removed = removed
        }
    }

    /// 把远端 rule_set 改写成本地文件引用；本地拿不到的才连同引用规则一起摘除。
    ///
    /// 为什么必须改写而不是摘除：远端 rule_set 在**服务启动时**下载，失败即 FATAL（用户看到"连不上"）；
    /// 但直接摘掉会把国内直连规则（`geosite-cn` / `geoip-cn`）一起带走，表现为"国内流量也走代理"。
    /// 内置保底由 `RuleSetStore.ensureBundled` 落进容器，主 App 导入时还会缓存其它远端规则集。
    @discardableResult
    public static func localizeRemoteRuleSets(_ root: inout [String: Any],
                                              base: URL? = nil) -> RuleSetLocalization {
        var result = RuleSetLocalization()
        guard var route = root["route"] as? [String: Any],
              let ruleSets = route["rule_set"] as? [[String: Any]] else { return result }

        var removedTags = Set<String>()
        var kept: [[String: Any]] = []
        for ruleSet in ruleSets {
            let tag = ruleSet["tag"] as? String
            if (ruleSet["type"] as? String) == "remote" {
                if let tag = tag,
                   let fileName = RuleSetStore.fileName(tag: tag, remoteURL: ruleSet["url"] as? String),
                   let local = RuleSetStore.localURL(fileName: fileName, base: base) {
                    var entry: [String: Any] = ["tag": tag, "type": "local", "path": local.path]
                    entry["format"] = (ruleSet["format"] as? String) ?? "binary"
                    kept.append(entry)
                    result.localized.append(tag)
                } else if let tag = tag {
                    removedTags.insert(tag)
                    result.removed.append(tag)
                }
                continue
            }
            // 已经是本地引用：路径不在时先按文件名在当前容器里找同名文件修复。
            // 必须修的原因：App Group 容器的绝对路径会随"删除后重装"变化，
            // 老 profile 里存的是老容器的路径，不修就会静默丢掉国内直连规则。
            if let path = ruleSet["path"] as? String, !FileManager.default.fileExists(atPath: path) {
                if let tag = tag, let repaired = RuleSetStore.repairedPath(forStalePath: path, base: base) {
                    var entry = ruleSet
                    entry["path"] = repaired.path
                    kept.append(entry)
                    result.localized.append(tag)
                    continue
                }
                if let tag = tag {
                    removedTags.insert(tag)
                    result.removed.append(tag)
                }
                continue
            }
            kept.append(ruleSet)
        }

        guard !removedTags.isEmpty || !result.localized.isEmpty else { return result }

        route["rule_set"] = kept
        if let rules = route["rules"] as? [[String: Any]] {
            route["rules"] = rules.compactMap { rule -> [String: Any]? in
                guard let referenced = rule["rule_set"] as? [String] else { return rule }
                let remaining = referenced.filter { !removedTags.contains($0) }
                if remaining.isEmpty { return nil }
                var updated = rule
                updated["rule_set"] = remaining
                return updated
            }
        }
        // dns.rules 里也会引用 rule_set（实测漏了这处会让内核报
        // "initialize dns router: dns rule[2]: rule-set not found"，隧道起不来）
        if var dns = root["dns"] as? [String: Any], let dnsRules = dns["rules"] as? [[String: Any]] {
            dns["rules"] = dnsRules.compactMap { rule -> [String: Any]? in
                guard let referenced = rule["rule_set"] as? [String] else { return rule }
                let remaining = referenced.filter { !removedTags.contains($0) }
                if remaining.isEmpty { return nil }
                var updated = rule
                updated["rule_set"] = remaining
                return updated
            }
            root["dns"] = dns
        }

        root["route"] = route
        result.removed.sort()
        result.localized.sort()
        return result
    }

    private static func outboundsForDirectCheck(in root: [String: Any]) -> [[String: Any]] {
        root["outbounds"] as? [[String: Any]] ?? []
    }

    /// 文本进、文本出的便捷入口：已经是新语法时原样返回。
    /// 网络扩展在启动时也会跑一遍，这样即使设备上存的是迁移前落盘的旧配置也能连上。
    public static func migrate(configText: String) -> String {
        guard let data = configText.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return configText
        }
        var result = migrate(&root)
        let localization = localizeRemoteRuleSets(&root)
        if !localization.removed.isEmpty {
            result.notes.append("移除无法离线使用的远端规则集 \(localization.removed.joined(separator: ", "))")
        }
        // 本地化本身不需要打扰用户（导入时已经做过一次），但它会改动配置，必须落盘
        let localized = !localization.localized.isEmpty
        guard !result.notes.isEmpty || localized,
              let upgraded = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: upgraded, encoding: .utf8) else {
            return configText
        }
        return text
    }

    /// 旧写法里这些字段在内核 1.13.0 起被移除。
    static let legacyInboundFields = [
        "sniff",
        "sniff_override_destination",
        "sniff_timeout",
        "domain_strategy",
        "udp_disable_domain_unmapping",
    ]

    // MARK: - DNS 服务器升级

    private static func upgrade(server: [String: Any], droppedTags: inout Set<String>) -> [String: Any]? {
        if server["type"] != nil { return server }
        guard let address = server["address"] as? String else { return nil }

        var rest = server
        rest.removeValue(forKey: "address")
        let lower = address.lowercased()

        if lower.hasPrefix("local") {
            var upgraded: [String: Any] = ["type": "local"]
            upgraded.merge(rest) { _, new in new }
            return upgraded
        }

        if let parsed = parseSchemeAddress(address) {
            var upgraded: [String: Any] = ["type": parsed.scheme, "server": parsed.host]
            if let port = parsed.port { upgraded["server_port"] = port }
            if let path = parsed.path, path != "/dns-query", path != "/" {
                upgraded["path"] = path
            }
            upgraded.merge(rest) { _, new in new }
            return upgraded
        }

        // 纯 IP（可带端口）→ udp
        if let hostPort = parseHostPort(address) {
            var upgraded: [String: Any] = ["type": "udp", "server": hostPort.host]
            if let port = hostPort.port { upgraded["server_port"] = port }
            upgraded.merge(rest) { _, new in new }
            return upgraded
        }

        if let tag = server["tag"] as? String { droppedTags.insert(tag) }
        return nil
    }

    private struct SchemeAddress {
        let scheme: String
        let host: String
        let port: Int?
        let path: String?
    }

    private static let schemeTypes: Set<String> = ["https", "h3", "quic", "tls", "tcp", "udp"]

    private static func parseSchemeAddress(_ address: String) -> SchemeAddress? {
        guard let separator = address.range(of: "://") else { return nil }
        let scheme = String(address[address.startIndex..<separator.lowerBound]).lowercased()
        guard schemeTypes.contains(scheme) else { return nil }
        let remainder = String(address[separator.upperBound...])
        let hostPart = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? remainder
        let path = remainder.contains("/") ? "/" + remainder.split(separator: "/", maxSplits: 1)[1] : nil
        guard let hostPort = parseHostPort(hostPart) else { return nil }
        return SchemeAddress(scheme: scheme, host: hostPort.host, port: hostPort.port, path: path)
    }

    private static func parseHostPort(_ value: String) -> (host: String, port: Int?)? {
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("[") { // IPv6 字面量
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let tail = value[value.index(after: close)...]
            if tail.hasPrefix(":") { return (host, Int(tail.dropFirst())) }
            return (host, nil)
        }
        let parts = value.split(separator: ":")
        if parts.count == 2, let port = Int(parts[1]) {
            return (String(parts[0]), port)
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:")
        let isAddressLiteral = value.unicodeScalars.allSatisfy({ allowed.contains($0) })
        guard isAddressLiteral else { return nil }
        // 无端口的 IPv4 或裸 IPv6 字面量
        return (value, nil)
    }
}
