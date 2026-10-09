import Foundation
import Libbox

/// 命令通道的抽象：延迟测试与线路切换只依赖这两个动作，便于单元测试注入假实现。
protocol CommandChannelProtocol: AnyObject {
    /// 测速一次**整个策略组**：sing-box 的 URLTest 对 selector/urltest 组会遍历其全部成员。
    func urlTest(groupTag: String) throws
    func selectOutbound(groupTag: String, outboundTag: String) throws
}

/// 主 App 侧与扩展内核通信的通道。
///
/// 机制（见 contracts/tunnel-control.md）：扩展用 `LibboxCommandServer` 在 App Group 容器里
/// 监听 `command.sock`，主 App 先用相同的 basePath 调 `LibboxSetup`，再用 `LibboxCommandClient`
/// 连上这个本地 socket，订阅状态与线路组，并下发测速/切换命令。
final class ControlChannel: NSObject, ObservableObject, CommandChannelProtocol {

    @Published private(set) var groups: [NodeGroup] = []
    @Published private(set) var attached = false
    @Published private(set) var upload: Int64 = 0
    @Published private(set) var download: Int64 = 0

    /// 收到某条线路的延迟时回调（tag, 毫秒）。0 表示超时。
    var onDelay: ((String, Int) -> Void)?

    private var client: LibboxCommandClient?
    private var serviceReady = false
    private let queue = DispatchQueue(label: "trocket.control-channel")

    /// 主 App 进程也需要 basePath，否则找不到扩展监听的 command.sock。
    static func setupKernel() throws {
        let container = try AppConfiguration.sharedContainerURL()
        let socketBase = try AppConfiguration.commandSocketBaseURL()
        let working = container.appendingPathComponent("Working", isDirectory: true)
        let temp = container.appendingPathComponent("Temp", isDirectory: true)
        for url in [working, temp] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let options = LibboxSetupOptions()
        options.basePath = socketBase.path
        options.workingPath = working.path
        options.tempPath = temp.path
        options.crashReportSource = "TrocketApp"
        options.logMaxLines = 1000
        options.debug = false
        options.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        options.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        var error: NSError?
        LibboxSetup(options, &error)
        if let error {
            throw TrocketError.tunnelStartFailed(error.localizedDescription)
        }
    }

    /// 隧道连上后调用：连接命令通道并订阅状态与线路组。
    func attach() {
        guard client == nil else { return }
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.addCommand(LibboxCommandGroup)
        options.statusInterval = Int64(NSEC_PER_SEC)
        guard let client = LibboxNewCommandClient(self, options) else { return }
        self.client = client
        queue.async { [weak self] in
            do {
                try client.connect()
                DispatchQueue.main.async { self?.attached = true }
            } catch {
                // 未连接时命令通道不可用属正常情况，不打扰用户。
                DispatchQueue.main.async { self?.attached = false }
                self?.detach()
            }
        }
    }

    func detach() {
        guard let client else { return }
        self.client = nil
        queue.async {
            try? client.disconnect()
        }
        DispatchQueue.main.async {
            self.attached = false
            self.groups = []
            self.upload = 0
            self.download = 0
        }
    }

    // MARK: - CommandChannelProtocol

    func urlTest(groupTag: String) throws {
        guard let client else { throw TrocketError.latencyUnavailable }
        try client.urlTest(groupTag)
    }

    func selectOutbound(groupTag: String, outboundTag: String) throws {
        guard let client else { throw TrocketError.selectFailed("命令通道未连接") }
        try client.selectOutbound(groupTag, outboundTag: outboundTag)
    }

    // MARK: - 主线程刷新

    private func publish(_ mutate: @escaping () -> Void) {
        if Thread.isMainThread {
            mutate()
        } else {
            DispatchQueue.main.async(execute: mutate)
        }
    }
}

// MARK: - LibboxCommandClientHandler

extension ControlChannel: LibboxCommandClientHandlerProtocol {

    func connected() {
        publish { self.attached = true }
    }

    func disconnected(_ message: String?) {
        publish { self.attached = false }
    }

    func clearLogs() {}

    func setDefaultLogLevel(_ level: Int32) {}

    func writeLogs(_ messageList: LibboxLogIteratorProtocol?) {}

    func initializeClashMode(_ modeList: LibboxStringIteratorProtocol?, currentMode: String?) {}

    func updateClashMode(_ newMode: String?) {}

    func write(_ events: LibboxConnectionEvents?) {}

    func writeOutbounds(_ message: LibboxOutboundGroupItemIteratorProtocol?) {}

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message else { return }
        publish {
            self.upload = message.uplinkTotal
            self.download = message.downlinkTotal
        }
    }

    func writeGroups(_ message: LibboxOutboundGroupIteratorProtocol?) {
        guard let message else { return }
        var parsed: [NodeGroup] = []
        while message.hasNext() {
            guard let group = message.next() else { continue }
            var items: [NodeItem] = []
            if let iterator = group.getItems() {
                while iterator.hasNext() {
                    guard let item = iterator.next() else { continue }
                    let delay = Int(item.urlTestDelay)
                    let testedAt = item.urlTestTime > 0 ? Date(timeIntervalSince1970: TimeInterval(item.urlTestTime)) : nil
                    items.append(NodeItem(tag: item.tag, type: item.type, delay: delay, testedAt: testedAt))
                }
            }
            parsed.append(NodeGroup(
                tag: group.tag,
                type: group.type,
                selected: group.selected,
                selectable: group.selectable,
                items: items
            ))
        }
        let snapshot = parsed
        publish {
            self.groups = snapshot
            for group in snapshot {
                for item in group.items where item.delay != nil {
                    self.onDelay?(item.tag, item.delay ?? 0)
                }
            }
        }
    }
}
