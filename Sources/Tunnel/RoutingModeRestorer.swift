import Foundation
import Libbox

/// 隧道启动时把用户选择的「规则 / 全局」模式写回内核。
///
/// 为什么需要：模式是内核的运行时状态（Clash 模式），不会跟着配置落盘。
/// 扩展被系统回收后自动重启时，内核回到默认的 `rule`，而主 App 可能根本没在前台，
/// 于是「全局」会悄悄变回「规则」。扩展侧没有 `LibboxCommandServer.setClashMode` 的
/// Swift 绑定（Go 侧有实现，只是没导出），所以这里用命令通道**自连一次**下发模式。
///
/// 只影响启动瞬间；之后用户切换仍走主 App 的命令通道（不断线生效）。
final class RoutingModeRestorer: NSObject {

    private var client: LibboxCommandClient?

    /// 在 `startOrReloadService` 之后调用：服务已起来，SetClashMode 才会落到路由上。
    func restore(_ mode: RoutingMode, container: URL) {
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandClashMode)
        options.statusInterval = 0
        guard let client = LibboxNewCommandClient(self, options) else {
            TunnelLog.write("clash mode restore failed: 命令客户端创建失败", to: container)
            return
        }
        self.client = client
        do {
            try client.connect()
            try client.setClashMode(mode.clashMode)
            TunnelLog.write("clash mode restored: \(mode.clashMode)", to: container)
        } catch {
            TunnelLog.write("clash mode restore failed: \((error as NSError).localizedDescription)", to: container)
        }
        try? client.disconnect()
        self.client = nil
    }
}

// MARK: - LibboxCommandClientHandlerProtocol

extension RoutingModeRestorer: LibboxCommandClientHandlerProtocol {

    func connected() {}
    func disconnected(_ message: String?) {}
    func clearLogs() {}
    func setDefaultLogLevel(_ level: Int32) {}
    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {}
    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
    func writeOutbounds(_ message: LibboxOutboundGroupItemIteratorProtocol?) {}
    func writeStatus(_ message: LibboxStatusMessage?) {}
    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {}
}
