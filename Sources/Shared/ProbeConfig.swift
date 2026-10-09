import Foundation

/// 未连接时用于测速的"极简探针配置"：只要出站，不要 tun、不要 DNS 规则、不要远端规则集。
///
/// 为什么单独造一份：完整配置在**服务启动时**会下载远端 rule_set、初始化 DNS/路由，
/// 慢且可能 FATAL；测速只需要"能拨通出站"，配置越薄越稳、越快（实测启动从数十秒降到 <1s）。
public enum ProbeConfig {

    public static func make(fromProfileJSON text: String) throws -> String {
        // 探针也必须过一遍迁移：手机里可能存着导入时还没修复的旧配置
        // （实测症状：旧配置带 alpn=["h3"]，探针全部超时，表现为"测速无法连接"）
        let migrated = ConfigMigration.migrate(configText: text)
        return try makeOnce(fromMigratedJSON: migrated)
    }

    static func makeOnce(fromMigratedJSON text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]],
              !outbounds.isEmpty else {
            throw TrocketError.profileMissing
        }
        let primaryTag = try ConfigShaping.catalog(fromProfile: data).primaryGroup?.tag

        var probe: [String: Any] = [
            "log": ["level": "warn"],
            "inbounds": [],           // 没有 tun：不建立 VPN，也就不会碰系统网络扩展
            "outbounds": outbounds,
        ]
        if let primaryTag {
            probe["route"] = ["final": primaryTag]
        }
        guard let output = try? JSONSerialization.data(withJSONObject: probe, options: [.sortedKeys]),
              let result = String(data: output, encoding: .utf8) else {
            throw TrocketError.unparsableSubscription
        }
        return result
    }
}

/// 一次测速的结果统计（平均时延 / 可用条数）。纯计算，便于单测。
public struct LatencyStats: Equatable {
    public let available: Int
    public let total: Int
    public let average: Int?

    public init(delays: [Int?]) {
        let valid = delays.compactMap { delay -> Int? in
            guard let delay, delay > 0 else { return nil }
            return delay
        }
        available = valid.count
        total = delays.count
        average = valid.isEmpty ? nil : Int((Double(valid.reduce(0, +)) / Double(valid.count)).rounded())
    }

    /// 例：`平均 168 ms · 32/33 可用`
    public var summary: String? {
        guard let average else { return total > 0 ? "全部超时" : nil }
        return "平均 \(average) ms · \(available)/\(total) 可用"
    }
}
