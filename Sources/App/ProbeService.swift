import Foundation
import Libbox

/// 未连接时的测速服务：在**应用进程内**起一个 libbox 服务（无 tun、无入站），
/// 让内核按代理协议真实拨号去测每条线路，测完即关。
///
/// 与"连上再测"的区别：不会建立系统 VPN、不会拉起网络扩展，用户无需连接即可看到真实代理时延；
/// 与"TCP 握手测速"的区别：走的是完整代理协议（AnyTLS/TLS 等），探针死了但端口开着也能识别出来。
final class ProbeService: NSObject, ObservableObject, LibboxCommandClientHandlerProtocol {

    /// 收到某条线路的空闲延迟（毫秒）
    var onDelay: ((String, Int) -> Void)?
    /// 一次组测速的收尾（无论成功失败）
    var onFinish: ((String?) -> Void)?

    private var server: LibboxCommandServer?
    private var platform: ProbePlatformInterface?
    private var client: LibboxCommandClient?
    private var isRunning = false

    func start(configText: String) throws {
        guard !isRunning else { return }
        // 与主命令通道共用同一个 basePath：未连接时 container/command.sock 是空闲的。
        try ControlChannel.setupKernel()
        let probeText = try ProbeConfig.make(fromProfileJSON: configText)

        let platform = ProbePlatformInterface()
        self.platform = platform

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platform, platform, &serverError) else {
            throw TrocketError.tunnelStartFailed("探针服务创建失败：\(serverError?.localizedDescription ?? "未知原因")")
        }
        self.server = server
        do {
            try server.start()
            try server.startOrReloadService(probeText, options: LibboxOverrideOptions())
        } catch {
            stop()
            TunnelLog.write("probe service start failed: \((error as NSError).localizedDescription)")
            throw TrocketError.latencyUnavailable
        }

        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandGroup)
        options.statusInterval = 0
        guard let client = LibboxNewCommandClient(self, options) else {
            stop()
            throw TrocketError.latencyUnavailable
        }
        self.client = client
        do {
            try client.connect()
        } catch {
            stop()
            TunnelLog.write("probe client connect failed: \((error as NSError).localizedDescription)")
            throw TrocketError.latencyUnavailable
        }
        isRunning = true
        TunnelLog.write("probe service ready")
    }

    func urlTest(groupTag: String) throws {
        guard let client else { throw TrocketError.latencyUnavailable }
        try client.urlTest(groupTag)
    }

    func stop() {
        if let client {
            try? client.disconnect()
        }
        client = nil
        if let server {
            try? server.closeService()
            server.close()
        }
        server = nil
        platform = nil
        isRunning = false
    }

    // MARK: - LibboxCommandClientHandlerProtocol

    func connected() {}
    func disconnected(_ message: String?) { onFinish?(message) }
    func clearLogs() {}
    func setDefaultLogLevel(_ level: Int32) {}
    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {}
    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}
    func updateClashMode(_ newMode: String?) {}
    func write(_ events: LibboxConnectionEvents?) {}
    func writeOutbounds(_ message: LibboxOutboundGroupItemIteratorProtocol?) {}
    func writeStatus(_ message: LibboxStatusMessage?) {}

    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {
        guard let message else { return }
        var delays: [(String, Int)] = []
        while message.hasNext() {
            guard let group = message.next(), let items = group.getItems() else { continue }
            while items.hasNext() {
                guard let item = items.next() else { continue }
                let delay = Int(item.urlTestDelay)
                if delay > 0 { delays.append((item.tag, delay)) }
            }
        }
        guard !delays.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for (tag, delay) in delays { self?.onDelay?(tag, delay) }
        }
    }
}
