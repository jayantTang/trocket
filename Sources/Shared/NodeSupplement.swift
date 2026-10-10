import Foundation

/// 把 Clash 模板里多出来的节点并进 sing-box 配置。
///
/// 为什么需要：服务商按 UA 返回**不同模板**。实测同一个订阅链接：
/// 带 `sing-box/1.14.2` 只给 32 条（香港 13 / 日本 10 / 新加坡 9），
/// 带 Clash UA 给 44 条（多出美国 6、德国 6）——于是出现"同样的链接，
/// Shadowrocket 有美国/德国，我们没有"。
///
/// 做法：仍然以 sing-box 模板为准（保留服务商自己的分流规则与 DNS 设置），
/// 只把 JSON 里没有的节点补进来，并挂到主选择组与自动选择组上，使它们可选、可测速。
public enum NodeSupplement {

    public struct Result: Equatable {
        public let data: Data
        /// 本次补进来的节点 tag
        public let added: [String]
    }

    /// - Parameters:
    ///   - shaped: 已整形的 sing-box 配置（JSON）
    ///   - clashText: 同一订阅用 Clash UA 拉到的内容
    /// - Returns: 补到节点时返回新配置，没有可补的返回 nil。
    public static func merge(into shaped: Data, clashText: String) -> Result? {
        guard var root = try? JSONSerialization.jsonObject(with: shaped) as? [String: Any],
              var outbounds = root["outbounds"] as? [[String: Any]] else { return nil }

        let existingTags = Set(outbounds.compactMap { $0["tag"] as? String })
        let candidates = ClashYAML.nodeOutbounds(from: clashText).outbounds
        let missing = candidates.filter { outbound in
            guard let tag = outbound["tag"] as? String else { return false }
            return !existingTags.contains(tag)
        }
        guard !missing.isEmpty else { return nil }

        let addedTags = missing.compactMap { $0["tag"] as? String }
        outbounds.append(contentsOf: missing)

        // 只挂到应用真正使用的两个组：主选择组（第一个 selector）与自动选择组（第一个 urltest）
        if let index = outbounds.firstIndex(where: { ($0["type"] as? String) == "selector" }) {
            append(tags: addedTags, to: &outbounds[index])
        }
        if let index = outbounds.firstIndex(where: { ($0["type"] as? String) == "urltest" }) {
            append(tags: addedTags, to: &outbounds[index])
        }

        root["outbounds"] = outbounds
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return nil }
        return Result(data: data, added: addedTags)
    }

    static func append(tags: [String], to group: inout [String: Any]) {
        var members = group["outbounds"] as? [String] ?? []
        for tag in tags where !members.contains(tag) {
            members.append(tag)
        }
        group["outbounds"] = members
    }
}
