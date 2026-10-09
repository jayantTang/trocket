import Foundation
import NetworkExtension

/// 系统 VPN 配置的封装。状态一律以 `NETunnelProviderManager` 的实际上报为准，
/// 不用本地记录推断（见 contracts/tunnel-control.md 第 4 节）。
@MainActor
final class TunnelController: ObservableObject {

    @Published private(set) var state: TunnelState = .unconfigured

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    /// 扩展的 bundle id：主 App bundle id + `.tunnel`（与 project.yml 一致）。
    private var providerBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.trocket.app") + ".tunnel"
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 装载

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
            } ?? managers.first
            startObserving()
            refreshState()
        } catch {
            state = .failed("读取系统 VPN 配置失败：\(error.localizedDescription)")
        }
    }

    private func startObserving() {
        guard observer == nil, let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshState() }
        }
    }

    func refreshState() {
        guard let manager else {
            state = .unconfigured
            return
        }
        let previous = state
        defer {
            if previous != state {
                TunnelLog.write("tunnel status -> \(state.text)")
            }
        }
        switch manager.connection.status {
        case .invalid:
            state = .unconfigured
        case .disconnected:
            state = .disconnected
        case .connecting:
            state = .connecting
        case .connected:
            state = .connected(connectedAt: manager.connection.connectedDate, upload: 0, download: 0)
        case .reasserting:
            state = .reasserting
        case .disconnecting:
            state = .disconnected
        @unknown default:
            state = .disconnected
        }
    }

    var isInstalled: Bool { manager != nil }

    // MARK: - 连接 / 断开

    func start(configText: String) async throws {
        let manager = try await preparedManager(configText: configText)
        TunnelLog.write("startVPNTunnel requested")
        try manager.connection.startVPNTunnel()
        state = .connecting
        TunnelLog.write("startVPNTunnel returned (status=\(manager.connection.status.rawValue))")
    }

    func stop() async {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        state = .disconnected
    }

    private func preparedManager(configText: String) async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = AppConfiguration.vpnDescription
        proto.providerConfiguration = [
            AppConfiguration.configContentKey: configText,
            AppConfiguration.tunnelVersionKey: AppConfiguration.kernelVersion,
            AppConfiguration.localeKey: "zh-Hans",
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = AppConfiguration.vpnDescription
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
            // 保存后必须重新装载，否则 startVPNTunnel 会拿到过期配置。
            try await manager.loadFromPreferences()
        } catch {
            throw TrocketError.tunnelStartFailed(error.localizedDescription)
        }
        self.manager = manager
        startObserving()
        return manager
    }
}
