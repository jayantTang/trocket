import Foundation

/// 路由模式：内核 Clash 模式的两种取值，用户在应用内切换。
///
/// - `rule`：按订阅里的分流规则走（国内直连、其余走所选线路），默认。
/// - `global`：全部流量走所选线路（保留局域网直连）。
///
/// 之所以用内核的 Clash 模式而不是改写配置：配置在扩展启动时就固定了，
/// 而 `LibboxCommandServer.setClashMode` 可以在**不断线**的情况下切换；
/// 订阅里通常自带 `clash_mode: global` 规则，没有的由 `ConfigShaping` 补。
public enum RoutingMode: String, CaseIterable, Identifiable {
    case rule
    case global

    public var id: String { rawValue }

    /// 传给内核的 Clash 模式名。
    public var clashMode: String {
        switch self {
        case .rule: return "rule"
        case .global: return "global"
        }
    }

    public var title: String {
        switch self {
        case .rule: return "规则"
        case .global: return "全局"
        }
    }

    /// 菜单里的一行说明（用户要能看懂两者的区别）。
    public var detail: String {
        switch self {
        case .rule: return "国内直连，其余走所选线路"
        case .global: return "全部流量走所选线路"
        }
    }

    public static let defaultsKey = "routingMode"

    /// 读取当前模式；App Group 不可用（单元测试）时退回默认值。
    public static func load(defaults: UserDefaults? = nil) -> RoutingMode {
        guard let defaults = defaults ?? sharedDefaults else { return .rule }
        return defaults.string(forKey: defaultsKey).flatMap(RoutingMode.init(rawValue:)) ?? .rule
    }

    public static func save(_ mode: RoutingMode, defaults: UserDefaults? = nil) {
        guard let defaults = defaults ?? sharedDefaults else { return }
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }

    static var sharedDefaults: UserDefaults? {
        guard let id = AppConfiguration.appGroupID else { return nil }
        return UserDefaults(suiteName: id)
    }
}
