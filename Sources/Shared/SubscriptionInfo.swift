import Foundation

/// 订阅用量与到期信息，来自响应头 `subscription-userinfo`。
/// 服务商不给这个头时整块为 nil，界面必须隐藏该区域（不能显示 0）。
public struct SubscriptionUserInfo: Codable, Equatable {
    public var upload: Int64
    public var download: Int64
    public var total: Int64
    public var expire: Date?

    public init(upload: Int64, download: Int64, total: Int64, expire: Date?) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expire = expire
    }

    /// 解析形如 `upload=1; download=2; total=3; expire=1804165320` 的头。
    /// 全部字段缺失或为空时返回 nil。
    public static func parse(headerValue: String) -> SubscriptionUserInfo? {
        var values: [String: Int64] = [:]
        for pair in headerValue.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            if let number = Int64(raw) {
                values[key] = number
            }
        }
        guard !values.isEmpty else { return nil }
        let expireSeconds = values["expire"] ?? 0
        return SubscriptionUserInfo(
            upload: values["upload"] ?? 0,
            download: values["download"] ?? 0,
            total: values["total"] ?? 0,
            expire: expireSeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(expireSeconds)) : nil
        )
    }

    public var used: Int64 { upload + download }

    /// 例：`1.44 GB / 200 GB`
    public var usageText: String {
        guard total > 0 else { return ByteFormat.human(used) }
        return "\(ByteFormat.human(used)) / \(ByteFormat.human(total))"
    }

    /// 例：`2027-03-04`
    public var expireText: String? {
        guard let expire else { return nil }
        return DateFormat.day.string(from: expire)
    }
}

/// 字节数的人类可读格式（1024 进制，去掉多余的 0）。
public enum ByteFormat {
    public static func human(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        let units: [(Double, String)] = [
            (1024 * 1024 * 1024, "GB"),
            (1024 * 1024, "MB"),
            (1024, "KB"),
        ]
        for (scale, unit) in units where value >= scale {
            return "\(trim(value / scale)) \(unit)"
        }
        return "\(Int(value)) B"
    }

    private static func trim(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        var trimmed = text
        while trimmed.contains(".") && (trimmed.hasSuffix("0") || trimmed.hasSuffix(".")) {
            trimmed.removeLast()
        }
        return trimmed
    }
}

public enum DateFormat {
    /// 固定 UTC + POSIX，保证跨时区、跨语言环境输出一致（测试可断言）。
    public static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
