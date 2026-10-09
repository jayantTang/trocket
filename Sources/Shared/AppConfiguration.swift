import Foundation

/// 全局常量：App Group、文件名、内核版本。两个 target 共用。
public enum AppConfiguration {

    /// 请求订阅时使用的 User-Agent。服务商按此返回"面向内核的 JSON 配置"。
    /// 升级内核版本时同步修改（见 specs/001-ios-vpn-client/research.md R2）。
    public static let kernelUserAgent = "sing-box/1.14.2"

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
