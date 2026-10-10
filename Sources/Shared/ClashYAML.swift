import Foundation

/// Clash 系配置的兜底解析。
///
/// 只支持 `proxies:` 下的行内流式映射（`- { name: ..., type: ... }`）与简单块式映射，
/// 这是 Clash 系服务商的常见输出。无法识别的条目会被跳过并计数，由界面提示"有 N 条线路无法解析"。
/// 生成的是本项目自带的 dns/route 默认值 + 一个 selector 组（`节点选择`）与一个 urltest 组（`自动选择`）。
public enum ClashYAML {

    public struct Result {
        public let config: Data
        public let skipped: Int
    }

    /// Clash → sing-box。`base` 是规则集目录（App Group 容器），用于把国内直连规则指到本地文件；
    /// 传 nil 或内置规则集不可用时，生成的配置依旧可用，只是没有国内直连分流。
    public static func convert(_ text: String, base: URL? = nil) throws -> Result {
        let entries = parseProxies(text)
        var outbounds: [[String: Any]] = []
        var nodeTags: [String] = []
        var skipped = 0

        for entry in entries {
            guard let outbound = makeOutbound(entry) else {
                skipped += 1
                continue
            }
            outbounds.append(outbound)
            nodeTags.append(outbound["tag"] as! String)
        }

        guard !nodeTags.isEmpty else { throw TrocketError.noNodes }

        outbounds.append([
            "type": "selector",
            "tag": "节点选择",
            "outbounds": nodeTags,
            "default": nodeTags[0],
        ])
        outbounds.append([
            "type": "urltest",
            "tag": "自动选择",
            "outbounds": nodeTags,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "3m",
            "tolerance": 50,
        ])
        outbounds.append(["type": "direct", "tag": "direct"])

        // 国内直连：Clash 的规则我们不复刻，但至少要保证国内域名/IP 不走代理（详见 RuleSetStore）
        RuleSetStore.ensureBundled(base: base)
        var ruleSets: [[String: Any]] = []
        var chinaTags: [String] = []
        for name in RuleSetStore.bundledNames {
            guard let local = RuleSetStore.localURL(fileName: name, base: base) else { continue }
            let tag = String(name.dropLast(4))
            chinaTags.append(tag)
            ruleSets.append(["tag": tag, "type": "local", "format": "binary", "path": local.path])
        }

        var rules: [[String: Any]] = [
            ["action": "sniff"],
            // 开关走内核 Clash 模式：全局 = 全部走所选线路，直连 = 全部直连
            ["clash_mode": "global", "outbound": "节点选择"],
            ["clash_mode": "direct", "outbound": "direct"],
            ["ip_is_private": true, "outbound": "direct"],
        ]
        if !chinaTags.isEmpty {
            rules.append(["rule_set": chinaTags, "outbound": "direct"])
        }

        var dns: [String: Any] = [
            "servers": [
                ["type": "https", "server": "223.5.5.5", "tag": "local", "detour": "direct"],
                ["type": "https", "server": "1.1.1.1", "tag": "remote", "detour": "节点选择"],
            ],
            "rules": [
                ["clash_mode": "global", "server": "remote"],
            ],
            "strategy": "prefer_ipv4",
        ]
        if !chinaTags.isEmpty {
            dns["rules"] = [["clash_mode": "global", "server": "remote"],
                            ["rule_set": ["geosite-cn"], "server": "local"]]
        }

        var route: [String: Any] = [
            "auto_detect_interface": true,
            "final": "节点选择",
            // 1.14 语法：嗅探与默认解析器都在路由层，不在入站里
            "default_domain_resolver": ["server": "local", "strategy": "prefer_ipv4"],
            "rules": rules,
        ]
        if !ruleSets.isEmpty { route["rule_set"] = ruleSets }

        let root: [String: Any] = [
            "dns": dns,
            "inbounds": ConfigShaping.inbounds(),
            "outbounds": outbounds,
            "route": route,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
            throw TrocketError.unparsableSubscription
        }
        return Result(config: data, skipped: skipped)
    }

    // MARK: - 解析

    /// 取出 `proxies:` 段的每一条目（键值对字典）。
    static func parseProxies(_ text: String) -> [[String: String]] {
        var entries: [[String: String]] = []
        var inside = false
        var current: [String] = []

        func flush() {
            guard !current.isEmpty else { return }
            let joined = current.joined(separator: "\n")
            if let map = parseEntry(joined), !map.isEmpty {
                entries.append(map)
            } else {
                entries.append([:])
            }
            current = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !inside {
                if line == "proxies:" || line.hasPrefix("proxies:") {
                    inside = true
                    // 允许 `proxies: [...]` 这种极简写法（此处不支持，交给后面的行处理）
                }
                continue
            }
            if line.isEmpty { continue }
            let indented = rawLine.first == " " || rawLine.first == "\t"
            if !indented {
                break // 到了下一个顶层键
            }
            if line.hasPrefix("-") {
                flush()
                current = [String(line.dropFirst())]
            } else if !current.isEmpty {
                current.append(line)
            } else {
                // 段内出现无归属的行：忽略
                continue
            }
        }
        flush()
        return entries
    }

    private static func parseEntry(_ entry: String) -> [String: String]? {
        if let open = entry.firstIndex(of: "{") {
            let close = entry.lastIndex(of: "}") ?? entry.endIndex
            guard open < close else { return nil }
            let inner = String(entry[entry.index(after: open)..<close])
            return parsePairs(inner)
        }
        // 块式：每行 `key: value`
        let pairs = entry.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                guard line.contains(":") else { return nil }
                return line
            }
        let map = parsePairs(pairs.joined(separator: ","))
        return map.isEmpty ? nil : map
    }

    private static func parsePairs(_ body: String) -> [String: String] {
        var map: [String: String] = [:]
        for chunk in splitTopLevel(body) {
            let parts = chunk.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = unquote(parts[1].trimmingCharacters(in: .whitespaces))
            guard !key.isEmpty, !value.isEmpty else { continue }
            map[key] = value
        }
        return map
    }

    /// 按顶层逗号切分，忽略引号与括号内的逗号（`alpn: ['h3','h2']`、`name: "a, b"`）。
    static func splitTopLevel(_ body: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var depth = 0
        var inSingle = false
        var inDouble = false

        for character in body {
            switch character {
            case "'" where !inDouble:
                inSingle.toggle()
                current.append(character)
            case "\"" where !inSingle:
                inDouble.toggle()
                current.append(character)
            case "[" , "{" where !inSingle && !inDouble:
                depth += 1
                current.append(character)
            case "]", "}" where !inSingle && !inDouble:
                depth -= 1
                current.append(character)
            case "," where depth == 0 && !inSingle && !inDouble:
                chunks.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func unquote(_ value: String) -> String {
        var result = value
        if result.count >= 2,
           (result.hasPrefix("'") && result.hasSuffix("'")) || (result.hasPrefix("\"") && result.hasSuffix("\"")) {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }

    // MARK: - 类型映射

    static func makeOutbound(_ entry: [String: String]) -> [String: Any]? {
        guard let name = entry["name"], let type = entry["type"]?.lowercased(),
              let server = entry["server"], let portText = entry["port"], let port = Int(portText) else {
            return nil
        }
        var outbound: [String: Any] = [
            "tag": name,
            "server": server,
            "server_port": port,
        ]

        let sni = entry["sni"] ?? entry["servername"]
        let insecure = (entry["skip-cert-verify"] ?? "false") == "true"
        let tlsEnabled = (entry["tls"] ?? "false") == "true"

        func tlsObject(enabled: Bool) -> [String: Any] {
            var tls: [String: Any] = ["enabled": enabled]
            if enabled {
                tls["insecure"] = insecure
                if let sni { tls["server_name"] = sni }
            }
            return tls
        }

        switch type {
        case "anytls":
            guard let password = entry["password"] else { return nil }
            outbound["type"] = "anytls"
            outbound["password"] = password
            outbound["tls"] = tlsObject(enabled: true)
        case "ss", "shadowsocks":
            guard let method = entry["cipher"] ?? entry["method"], let password = entry["password"] else { return nil }
            outbound["type"] = "shadowsocks"
            outbound["method"] = method
            outbound["password"] = password
        case "vmess":
            guard let uuid = entry["uuid"] else { return nil }
            outbound["type"] = "vmess"
            outbound["uuid"] = uuid
            outbound["security"] = entry["cipher"] ?? "auto"
            outbound["alter_id"] = Int(entry["alterId"] ?? "0") ?? 0
            outbound["tls"] = tlsObject(enabled: tlsEnabled)
        case "vless":
            guard let uuid = entry["uuid"] else { return nil }
            outbound["type"] = "vless"
            outbound["uuid"] = uuid
            if let flow = entry["flow"] { outbound["flow"] = flow }
            outbound["tls"] = tlsObject(enabled: tlsEnabled)
        case "trojan":
            guard let password = entry["password"] else { return nil }
            outbound["type"] = "trojan"
            outbound["password"] = password
            outbound["tls"] = tlsObject(enabled: true)
        default:
            return nil
        }
        return outbound
    }
}
