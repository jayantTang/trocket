import Foundation

/// 隧道状态。以系统（NetworkExtension）的实际上报为准，本类型只负责展示与迁移校验。
public enum TunnelState: Equatable {
    case unconfigured
    case disconnected
    case connecting
    case connected(connectedAt: Date?, upload: Int64, download: Int64)
    case reasserting
    case failed(String)

    public var text: String {
        switch self {
        case .unconfigured: return "未导入订阅"
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .connected: return "已连接"
        case .reasserting: return "网络切换中"
        case .failed(let reason): return reason
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// 连接按钮是否可用。连接中/切换中/未配置时不可点。
    public var canToggle: Bool {
        switch self {
        case .unconfigured, .connecting, .reasserting: return false
        case .disconnected, .connected, .failed: return true
        }
    }

    /// 连接按钮的开关位置。
    public var toggleIsOn: Bool {
        switch self {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    /// 流量补充信息，例如 `↑ 46.5 MB · ↓ 1.4 GB`。
    public var trafficText: String? {
        guard case .connected(_, let upload, let download) = self else { return nil }
        guard upload > 0 || download > 0 else { return nil }
        return "↑ \(ByteFormat.human(upload)) · ↓ \(ByteFormat.human(download))"
    }

    /// 迁移校验：非法迁移（例如没有 connecting 直接 connected）由调用方拒绝并记录。
    public func canTransition(to next: TunnelState) -> Bool {
        switch (self, next) {
        case (.unconfigured, .unconfigured),
             (.unconfigured, .disconnected),
             (.unconfigured, .connecting),
             (.disconnected, .connecting),
             (.disconnected, .connected),
             (.disconnected, .failed),
             (.connecting, .connected),
             (.connecting, .disconnected),
             (.connecting, .failed),
             (.connected, .connected),
             (.connected, .disconnected),
             (.connected, .reasserting),
             (.connected, .failed),
             (.reasserting, .connected),
             (.reasserting, .disconnected),
             (.reasserting, .failed),
             (.failed, .connecting),
             (.failed, .disconnected),
             (.failed, .unconfigured):
            return true
        default:
            return false
        }
    }
}
