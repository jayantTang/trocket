import Foundation

/// 全局常量：App Group、文件名、内核版本。两个 target 共用。
public enum AppConfiguration {

    /// 请求订阅时使用的 User-Agent。服务商按此返回"面向内核的 JSON 配置"。
    /// 升级内核版本时同步修改（见 specs/001-ios-vpn-client/research.md R2）。
    public static let kernelUserAgent = "sing-box/1.14.2"

    /// 补拉节点时使用的 User-Agent：服务商对 Clash 系客户端返回**更全的节点集**
    /// （实测同一订阅：sing-box 模板 32 条，Clash 模板 44 条，多出美国/德国各 6 条）。
    /// 见 `NodeSupplement`。
    public static let clashUserAgent = "ClashforWindows/0.20.39"

    /// 当前内核版本，写入隧道启动参数用于判断配置是否过期。
    public static let kernelVersion = "1.14.2"

    public static let profileFileName = "profile.json"
    public static let subscriptionFileName = "subscription.json"
    public static let configContentKey = "configContent"
    public static let tunnelVersionKey = "tunnelVersion"
    public static let localeKey = "locale"
    public static let vpnDescription = "Trocket"

    /// App Group 标识由 build 时的 Info.plist 注入（project.yml → TrocketAppGroup），
    /// 保证工程配置与本文件不会各写一份而漂移。
    public static var appGroupID: String? {
        Bundle.main.object(forInfoDictionaryKey: "TrocketAppGroup") as? String
    }

    /// 两个进程共享的容器目录。
    /// 命令通道（Unix socket）用的 basePath。
    /// macOS/iOS 的 UDS 路径上限约 104 字节：真机 App Group 路径够短，但仿真器路径约 139 字节，
    /// 会直接 `bind: invalid argument`（表现为"未连接时无法测速"）。过长时退回到短目录。
    public static func commandSocketBaseURL() throws -> URL {
        let limit = 100
        let reserved = "/command.sock".utf8.count
        let container = try sharedContainerURL()
        if container.path.utf8.count + reserved <= limit { return container }
        let tmp = FileManager.default.temporaryDirectory
        if tmp.path.utf8.count + reserved <= limit { return tmp }
        return URL(fileURLWithPath: "/tmp")
    }

    public static func sharedContainerURL() throws -> URL {
        guard let appGroupID else {
            throw TrocketError.appGroupMissing
        }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw TrocketError.appGroupUnavailable(appGroupID)
        }
        return url
    }
}
