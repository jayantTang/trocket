import Darwin
import Foundation
import Libbox
import NetworkExtension
import os.log

/// 网络扩展入口。启动顺序见 contracts/tunnel-control.md 第 2 节：
/// LibboxSetup → LibboxNewCommandServer → start → startOrReloadService(config)。
///
/// 每一步都写进 App Group 的 `tunnel.log`：连接失败时这是唯一能带出设备现场的线索
/// （有线拉取：`xcrun devicectl device copy from --domain-type appGroupDataContainer`）。
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private lazy var platformInterface = TunnelPlatformInterface(provider: self)
    private let logger = Logger(subsystem: "com.trocket.tunnel", category: "provider")
    private var container: URL?

    private var configContent: String? {
        (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?[AppConfiguration.configContentKey] as? String
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        // container 供日志/工作目录使用（必须在 App Group）；socket 另用短路径，
        // 因为 UDS 路径有 104 字节上限，仿真器下的 App Group 路径会超出。
        let container = try AppConfiguration.sharedContainerURL()
        let socketBase = try AppConfiguration.commandSocketBaseURL()
        self.container = container
        // 每次连接覆盖重写日志：用户整份拷贝时给的就是最新这一次的完整现场
        TunnelLog.clear()
        TunnelLog.write("startTunnel begin (options=\(options == nil ? "system" : "user"))", to: container)

        guard let configContent, !configContent.isEmpty else {
            throw failure("本地配置缺失，请在应用内重新导入订阅", to: container)
        }

        let working = container.appendingPathComponent("Working", isDirectory: true)
        let temp = container.appendingPathComponent("Temp", isDirectory: true)
        for url in [working, temp] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let options = LibboxSetupOptions()
        options.basePath = socketBase.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.crashReportSource = "NetworkExtension"
        options.logMaxLines = 3000
        // 开 debug：让内核把每一次拨号/握手的失败原因写到日志里（需要真机定位最后一跳）
        options.debug = true
        options.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        options.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw failure("内核初始化失败：\(setupError.localizedDescription)", to: container)
        }
        TunnelLog.write("libbox setup ok (kernel \(LibboxVersion()))", to: container)

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError) else {
            throw failure("命令服务创建失败：\(serverError?.localizedDescription ?? "未知原因")", to: container)
        }
        commandServer = server
        do {
            try server.start()
            TunnelLog.write("command server started", to: container)
        } catch {
            throw failure("命令服务启动失败：\((error as NSError).localizedDescription)", to: container)
        }

        // 兜底：设备上可能存着迁移前落盘的旧语法配置（升级前导入的），这里再过一遍，幂等。
        var effectiveConfig = ConfigMigration.migrate(configText: configContent)
        if effectiveConfig != configContent {
            TunnelLog.write("legacy config migrated at tunnel start", to: container)
        }
        effectiveConfig = ConfigShaping.ensureSelfTestInbound(configText: effectiveConfig)

        do {
            try server.startOrReloadService(effectiveConfig, options: LibboxOverrideOptions())
            TunnelLog.write("service started (config \(effectiveConfig.utf8.count) bytes)", to: container)
        } catch {
            throw failure("配置加载失败：\((error as NSError).localizedDescription)", to: container)
        }
        logger.info("tunnel started")
        TunnelLog.write("startTunnel done", to: container)

        // 自检：在扩展进程内直接对策略组做一次 URLTest。
        // 它能区分两种完全不同的故障：
        //   - 自检成功 → 扩展里拨号没问题，问题在 tun 转发/系统路由
        //   - 自检失败 → 扩展进程内根本出不去（多半是出站自环回 tun）
        runSelfTest(container: container)
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        logger.info("tunnel stopping, reason: \(reason.rawValue)")
        if let container {
            TunnelLog.write("stopTunnel reason=\(reason.rawValue)", to: container)
        }
        stopServiceFromKernel()
        if let server = commandServer {
            server.close()
            commandServer = nil
        }
    }

    // MARK: - 供平台接口回调

    func stopServiceFromKernel() {
        do {
            try commandServer?.closeService()
        } catch {
            logger.error("closeService failed: \((error as NSError).localizedDescription, privacy: .public)")
        }
        platformInterface.reset()
    }

    /// 导入新订阅后热重载配置（不重建隧道）。
    func reloadServiceFromKernel() async throws {
        guard let configContent, let server = commandServer else {
            throw TrocketError.tunnelStartFailed("配置或命令服务不可用")
        }
        reasserting = true
        defer { reasserting = false }
        let effectiveConfig = ConfigMigration.migrate(configText: configContent)
        do {
            try server.startOrReloadService(effectiveConfig, options: LibboxOverrideOptions())
            if let container { TunnelLog.write("service reloaded", to: container) }
        } catch {
            if let container {
                TunnelLog.write("service reload failed: \((error as NSError).localizedDescription)", to: container)
            }
            throw TrocketError.tunnelStartFailed("配置重载失败：\((error as NSError).localizedDescription)")
        }
    }

    override func sleep() async {
        commandServer?.pause()
    }

    override func wake() {
        commandServer?.wake()
    }

    /// 扩展内自检：让**内核自己**对策略组做一次 URLTest，并把返回的延迟写进日志。
    /// 有延迟 = 内核拨号没问题（问题在 tun 转发或自检通道）；
    /// 全是 0/超时报错 = 内核拨号失败（问题在出站），两者修法不同。
    private var selfTestClient: LibboxCommandClient?

    private func runSelfTest(container: URL) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            let group = ConfigShaping.groupTagForTesting(configText: self.configContent ?? "")
            let options = LibboxCommandClientOptions()
            options.addCommand(LibboxCommandGroup)
            options.statusInterval = 0
            let handler = SelfTestHandler(container: container)
            guard let client = LibboxNewCommandClient(handler, options) else {
                TunnelLog.write("self-test: cannot create command client", to: container)
                return
            }
            self.selfTestClient = client
            do {
                try client.connect()
                try client.urlTest(group)
                TunnelLog.write("self-test: urlTest issued for \(group)", to: container)
            } catch {
                TunnelLog.write("self-test FAILED: \((error as NSError).localizedDescription)", to: container)
            }
        }
    }

    // MARK: - 辅助

    private func failure(_ message: String, to container: URL) -> Error {
        logger.error("\(message, privacy: .public)")
        TunnelLog.write("ERROR \(message)", to: container)
        return TrocketError.tunnelStartFailed(message)
    }
}


/// 自检命令通道的回调：只把策略组里前几条线路的延迟写进日志。
private final class SelfTestHandler: NSObject, LibboxCommandClientHandlerProtocol {
    private let container: URL
    private var reported = false

    init(container: URL) { self.container = container }

    func connected() {}
    func disconnected(_ message: String?) {
        TunnelLog.write("self-test channel disconnected: \(message ?? "-")", to: container)
    }
    func clearLogs() {}
    func setDefaultLogLevel(_ level: Int32) {}
    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {}
    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
    func writeOutbounds(_ message: LibboxOutboundGroupItemIteratorProtocol?) {}
    func writeStatus(_ message: LibboxStatusMessage?) {}

    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {
        guard let message, !reported else { return }
        reported = true
        while message.hasNext() {
            guard let group = message.next(), let items = group.getItems() else { continue }
            var samples: [String] = []
            while items.hasNext(), samples.count < 6 {
                guard let item = items.next() else { continue }
                samples.append("\(item.tag)=\(item.urlTestDelay)ms")
            }
            if !samples.isEmpty {
                TunnelLog.write("self-test delays [\(group.tag)]: \(samples.joined(separator: ", "))", to: container)
            }
        }
    }
}
