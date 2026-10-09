import Foundation

/// 把服务商给的 sing-box 配置整形为 iOS 可用配置，并从中抽取线路清单。
///
/// 整形只做两件事：替换 `inbounds`（桌面参数在 iOS 上不可用），校验出站结构。
/// `dns` / `route` / `experimental` / `outbounds` 原样透传，
/// 分流规则（可能上千条）不做任何解析（见 research.md R3）。
public enum ConfigShaping {

    public static let tunAddress = "172.19.0.1/30"
    public static let tunMTU = 4064
    /// tun 栈：Apple 平台用 system（可用环境变量 TROCKET_TUN_STACK 临时覆盖做对照实验）
    public static var tunStack: String {
        ProcessInfo.processInfo.environment["TROCKET_TUN_STACK"] ?? "system"
    }

    /// iOS 专用入站：tun 由 libbox 经网络扩展创建。
    ///
    /// 注意：`sniff` / `sniff_override_destination` / `domain_strategy` 这些字段在 sing-box 1.13 起
    /// 已从入站移除，必须改用路由动作（`action: sniff`）与 `route.default_domain_resolver`，
    /// 否则内核加载配置直接报 "legacy inbound fields … removed"（见 ConfigMigration）。
    public static func inbounds() -> [[String: Any]] {
        [[
            "type": "tun",
            "tag": "tun-in",
            "address": [tunAddress],
            "mtu": tunMTU,
            "auto_route": true,
            "strict_route": false,
            // Apple 平台上 system 栈走系统自己的 TCP/IP 实现，是上游 Apple 客户端的默认；
            // 服务商下发的配置也用的是 system。先前选 gvisor 没有真机依据，实机表现为
            // "隧道/路由/DNS 都正常但数据面不转发"，因此改回 system。
            "stack": tunStack,
            "endpoint_independent_nat": true,
        ], [
            // 仅供扩展自检用：本机回环上的 mixed 入口，不外露
            "type": "mixed",
            "tag": "self-test-in",
            "listen": "127.0.0.1",
            "listen_port": SelfTest.port,
        ]]
    }

    public struct ShapedProfile {
        public let data: Data
        /// 迁移过程中做的改动说明（界面可提示用户"配置已按新语法迁移"）
        public let migrationNotes: [String]
    }

    /// 整形：迁移旧语法 → 替换入站 → 校验 → 返回可直接写入 profile.json 的紧凑 JSON。
    public static func shape(subscription data: Data) throws -> ShapedProfile {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrocketError.unparsableSubscription
        }
        guard let outbounds = root["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw TrocketError.missingOutbounds
        }

        // 迁移必须在替换入站之前：旧配置的 sniff/domain_strategy 写在入站里，
        // 替换后就看不到了，而它们要转成路由动作。
        var shaped = root
        var migration = ConfigMigration.migrate(&shaped)
        // 远端规则集若没有本地文件，服务启动时下载失败会 FATAL（实测），这里直接摘掉并告知用户。
        let stripped = ConfigMigration.stripUnavailableRemoteRuleSets(&shaped)
        if !stripped.isEmpty {
            migration.notes.append("移除无法离线使用的远端规则集：\(stripped.joined(separator: "、"))")
        }
        shaped["inbounds"] = inbounds()

        guard let migratedOutbounds = shaped["outbounds"] as? [[String: Any]] else {
            throw TrocketError.missingOutbounds
        }
        let catalog = try catalog(fromOutbounds: migratedOutbounds)
        guard !catalog.isEmpty else { throw TrocketError.noNodes }
        guard let result = try? JSONSerialization.data(withJSONObject: shaped, options: [.sortedKeys]) else {
            throw TrocketError.unparsableSubscription
        }
        return ShapedProfile(data: result, migrationNotes: migration.notes)
    }

    /// 从已整形的配置里读取线路清单（未连接也能显示列表）。
    public static func catalog(fromProfile data: Data) throws -> NodeCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else {
            throw TrocketError.profileMissing
        }
        return try catalog(fromOutbounds: outbounds)
    }

    static func catalog(fromOutbounds outbounds: [[String: Any]]) throws -> NodeCatalog {
        var typeByTag: [String: String] = [:]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String, let type = outbound["type"] as? String else { continue }
            typeByTag[tag] = type
        }

        var groups: [NodeGroup] = []
        for outbound in outbounds {
            guard let type = outbound["type"] as? String,
                  type == "selector" || type == "urltest",
                  let tag = outbound["tag"] as? String else { continue }
            let members = (outbound["outbounds"] as? [String]) ?? []
            let items = members.compactMap { member -> NodeItem? in
                guard let memberType = typeByTag[member], !ConfigShaping.groupTypes.contains(memberType) else { return nil }
                return NodeItem(tag: member, type: memberType)
            }
            guard !items.isEmpty else { continue }
            groups.append(NodeGroup(
                tag: tag,
                type: type,
                selected: (outbound["default"] as? String) ?? items[0].tag,
                selectable: type == "selector",
                items: items
            ))
        }
        return NodeCatalog(groups: groups)
    }

    /// 取用于测速的策略组 tag（自检与 App 都用它）。
    public static func groupTagForTesting(configText: String) -> String {
        guard let data = configText.data(using: .utf8),
              let catalog = try? catalog(fromProfile: data) else { return "" }
        return catalog.primaryGroup?.tag ?? ""
    }

    /// 出站里这些类型不是"线路"，而是分组/内建出站。
    public static let groupTypes: Set<String> = ["selector", "urltest", "direct", "block", "dns"]

    /// 内容嗅探：判断服务商返回的是哪种格式。无法识别返回 nil。
    public static func detectFormat(data: Data, contentType: String?) -> SubscriptionRecord.SourceFormat? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["outbounds"] is [[String: Any]] {
            return .singboxJSON
        }
        if let text = String(data: data, encoding: .utf8), text.contains("proxies:") {
            return .clashYAML
        }
        if contentType?.contains("json") == true {
            return .singboxJSON
        }
        return nil
    }
}


/// 自检用的本机端口（扩展在连接后经此端口真实访问一次外网并写日志）
public enum SelfTest {
    public static let port = 10809
    public static let url = "https://www.google.com/generate_204"
}


extension ConfigShaping {
    /// 无论手机里存的是哪一版配置，扩展启动时都补上自检用的本机入口。
    /// （教训：只在"导入整形"里加是不够的——用户不重新导入订阅时配置里就没有它，
    /// 实测表现为自检 24ms 失败"无法连接服务器"。）
    public static func ensureSelfTestInbound(configText: String) -> String {
        guard let data = configText.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return configText }
        var inbounds = root["inbounds"] as? [[String: Any]] ?? []
        guard !inbounds.contains(where: { $0["tag"] as? String == "self-test-in" }) else { return configText }
        inbounds.append([
            "type": "mixed", "tag": "self-test-in",
            "listen": "127.0.0.1", "listen_port": SelfTest.port,
        ])
        root["inbounds"] = inbounds
        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8) else { return configText }
        return text
    }
}
