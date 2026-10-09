import Foundation

/// 全部面向用户的错误。界面只展示 `errorDescription`，不直接透出底层错误栈。
public enum TrocketError: LocalizedError, Equatable {
    case invalidSubscriptionURL
    case network(String)
    case httpStatus(Int)
    case emptyBody
    case unparsableSubscription
    case noNodes
    case missingOutbounds
    case appGroupMissing
    case appGroupUnavailable(String)
    case profileMissing
    case profileWriteFailed(String)
    case tunnelStartFailed(String)
    case selectFailed(String)
    case latencyUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidSubscriptionURL:
            return "订阅链接格式不正确"
        case .network(let detail):
            return "网络不可用：\(detail)"
        case .httpStatus(let code):
            switch code {
            case 402:
                return "服务商返回 402：订阅已到期或余额不足"
            case 403:
                return "服务商返回 403：拒绝访问，请核对链接"
            case 404:
                return "服务商返回 404：链接不存在"
            default:
                return "服务商返回 HTTP \(code)"
            }
        case .emptyBody:
            return "该链接没有返回内容，可能不支持当前客户端标识"
        case .unparsableSubscription:
            return "订阅内容无法识别（既不是 sing-box 配置也不是 Clash 配置）"
        case .noNodes:
            return "订阅中没有可用线路"
        case .missingOutbounds:
            return "订阅内容缺少线路定义"
        case .appGroupMissing:
            return "App Group 未配置，请重新运行 scripts/bootstrap.sh 后重装应用"
        case .appGroupUnavailable(let id):
            return "无法访问 App Group 容器（\(id)）"
        case .profileMissing:
            return "本地还没有配置，请先导入订阅"
        case .profileWriteFailed(let detail):
            return "配置写入失败：\(detail)"
        case .tunnelStartFailed(let detail):
            return "连接失败：\(detail)"
        case .selectFailed(let detail):
            return "切换线路失败：\(detail)"
        case .latencyUnavailable:
            return "未连接时无法测速"
        }
    }
}
