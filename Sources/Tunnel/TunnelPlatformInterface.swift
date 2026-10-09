import Foundation
import Libbox
import Network
import NetworkExtension
import os.log

/// libbox 与系统之间的桥：
/// - `LibboxPlatformInterfaceProtocol`：内核需要平台能力时回调（大头是 `openTun`，即创建系统 tun）；
/// - `LibboxCommandServerHandlerProtocol`：内核/命令通道要求扩展停止或重载服务时回调。
///
/// 只实现本产品需要的部分，其余按协议要求给出最小实现或明确抛"不支持"（见 contracts/tunnel-control.md 第 5 节）。
final class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {

    private weak var provider: PacketTunnelProvider?
    private var pathMonitor: NWPathMonitor?
    private var interfaceListener: LibboxInterfaceUpdateListenerProtocol?
    private var lastNetworkPath: String?
    private let logger = Logger(subsystem: "com.trocket.tunnel", category: "platform")

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func reset() {
        pathMonitor?.cancel()
        pathMonitor = nil
        interfaceListener = nil
        lastNetworkPath = nil
    }

    // MARK: - Tun

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw TrocketError.tunnelStartFailed("缺少 tun 参数")
        }
        var failure: Error?
        var descriptor: Int32 = -1
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                descriptor = try await applyTunSettings(options)
            } catch {
                failure = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            TunnelLog.write("openTun failed: \(failure.localizedDescription)")
            throw failure
        }
        guard descriptor >= 0 else {
            TunnelLog.write("openTun failed: invalid file descriptor")
            throw TrocketError.tunnelStartFailed("无法取得 tun 文件描述符")
        }
        TunnelLog.write("openTun ok: fd=\(descriptor), mtu=\(options.getMTU()), autoRoute=\(options.getAutoRoute())")
        ret0_?.pointee = descriptor
    }

    private func applyTunSettings(_ options: LibboxTunOptionsProtocol) async throws -> Int32 {
        guard let provider else {
            throw TrocketError.tunnelStartFailed("扩展已释放")
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        if options.getAutoRoute() {
            settings.mtu = NSNumber(value: options.getMTU())

            var dnsServers: [String] = []
            let dnsIterator = try options.getDNSServerAddress()
            while dnsIterator.hasNext() {
                dnsServers.append(dnsIterator.next())
            }
            if !dnsServers.isEmpty {
                settings.dnsSettings = NEDNSSettings(servers: dnsServers)
            }

            var ipv4Addresses: [String] = []
            var ipv4Masks: [String] = []
            if let iterator = options.getInet4Address() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv4Addresses.append(prefix.address())
                    ipv4Masks.append(prefix.mask())
                }
            }
            if !ipv4Addresses.isEmpty {
                let ipv4 = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
                var included: [NEIPv4Route] = []
                if let iterator = options.getInet4RouteAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        included.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                    }
                }
                ipv4.includedRoutes = included.isEmpty ? [NEIPv4Route.default()] : included
                var excluded: [NEIPv4Route] = []
                if let iterator = options.getInet4RouteExcludeAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        excluded.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                    }
                }
                ipv4.excludedRoutes = excluded
                settings.ipv4Settings = ipv4
            }

            var ipv6Addresses: [String] = []
            var ipv6Prefixes: [NSNumber] = []
            if let iterator = options.getInet6Address() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    ipv6Addresses.append(prefix.address())
                    ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
                }
            }
            if !ipv6Addresses.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
                var included: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        included.append(NEIPv6Route(
                            destinationAddress: prefix.address(),
                            networkPrefixLength: NSNumber(value: prefix.prefix())
                        ))
                    }
                }
                ipv6.includedRoutes = included.isEmpty ? [NEIPv6Route.default()] : included
                var excluded: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteExcludeAddress() {
                    while iterator.hasNext() {
                        guard let prefix = iterator.next() else { continue }
                        excluded.append(NEIPv6Route(
                            destinationAddress: prefix.address(),
                            networkPrefixLength: NSNumber(value: prefix.prefix())
                        ))
                    }
                }
                ipv6.excludedRoutes = excluded
                settings.ipv6Settings = ipv6
            }
        }

        try await provider.setTunnelNetworkSettings(settings)
        // 记录真正下发给系统的网络设置：tun 无流量时这里是第一现场
        let v4 = settings.ipv4Settings
        TunnelLog.write("tun settings: stack=\(ConfigShaping.tunStack), mtu=\(settings.mtu ?? 0), v4=\(v4?.addresses.joined(separator: ",") ?? "-")/\(v4?.subnetMasks.joined(separator: ",") ?? "-"), routes=\(v4?.includedRoutes?.count ?? 0), dns=\(settings.dnsSettings?.servers.joined(separator: ",") ?? "-")")

        // 两种取 fd 的方式都试，并把结果写进日志：
        // 之前的现象是"隧道已连接但完全没流量"，怀疑私有 KVC 拿到的 fd 并不是真正的 utun，
        // 于是优先用 libbox 的 utun 扫描（kanged from wireguard-apple），KVC 作为兜底。
        let scanned = LibboxGetTunnelFileDescriptor()
        let kvc = (provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32) ?? -1
        TunnelLog.write("openTun fd: utunScan=\(scanned), kvc=\(kvc)")
        if scanned != -1 { return scanned }
        return kvc
    }

    // MARK: - 必需但本项目用不到的能力

    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {
        throw unsupported("autoDetectControl")
    }

    func useProcFS() -> Bool { false }
    func underNetworkExtension() -> Bool { true }
    func includeAllNetworks() -> Bool { false }

    func clearDNSCache() {}

    func writeLog(_ message: String?) {
        guard let message else { return }
        logger.debug("\(message, privacy: .public)")
        // 内核自己报的失败原因（anytls 握手、拨号、规则匹配）是定位的最后一手证据
        TunnelLog.write("kernel: \(message)")
    }

    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32
    ) throws -> LibboxConnectionOwner {
        throw unsupported("findConnectionOwner")
    }

    /// 内核用它解析"默认出口网卡"（networkManager.UpdateInterfaces → GetInterfaces）。
    /// 之前抛"不支持"导致默认出口一直是 nil，system 栈绑不了出站，内核在隧道里全 0ms。
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        guard let path = pathMonitor?.currentPath else {
            throw unsupported("getInterfaces: monitor not started")
        }
        if path.status == .unsatisfied {
            return NetworkInterfaceArray([])
        }
        var interfaces: [LibboxNetworkInterface] = []
        for interface in path.availableInterfaces {
            let item = LibboxNetworkInterface()
            item.name = interface.name
            item.index = Int32(interface.index)
            switch interface.type {
            case .wifi:
                item.type = LibboxInterfaceTypeWIFI
            case .cellular:
                item.type = LibboxInterfaceTypeCellular
            case .wiredEthernet:
                item.type = LibboxInterfaceTypeEthernet
            default:
                item.type = LibboxInterfaceTypeOther
            }
            interfaces.append(item)
        }
        return NetworkInterfaceArray(interfaces)
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func registerMyInterface(_ name: String?) {}

    func send(_ notification: LibboxNotification?) throws {}

    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}

    func checkPlatformShell() throws {
        throw unsupported("checkPlatformShell")
    }

    func usePlatformShell() -> Bool { false }
    func openShellSession(
        _ user: LibboxPlatformUser?,
        command: String?,
        environ: (any LibboxStringIteratorProtocol)?,
        term: String?,
        rows: Int32,
        cols: Int32
    ) throws -> any LibboxShellSessionProtocol {
        throw unsupported("openShellSession")
    }

    func usePlatformBridge() -> Bool { false }
    func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw unsupported("createBridge")
    }

    func lookupUser(_ username: String?) throws -> LibboxPlatformUser {
        throw unsupported("lookupUser")
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = unsupported("lookupSFTPServer")
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = unsupported("readSystemSSHHostKey")
        return ""
    }

    func tailscaleHostname() -> String { "Trocket" }

    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}

    // MARK: - 默认接口监视（内核做策略路由需要）

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        TunnelLog.write("interface monitor: start requested")
        interfaceListener = listener
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        var first = true
        monitor.pathUpdateHandler = { [weak self] path in
            self?.report(path, to: listener)
            if first {
                first = false
                semaphore.signal()
            }
        }
        monitor.start(queue: DispatchQueue(label: "trocket.path-monitor"))
        semaphore.wait()
        TunnelLog.write("interface monitor: first path reported (\(lastNetworkPath ?? "-"))")
    }

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        reset()
    }

    private func report(_ path: Network.NWPath, to listener: LibboxInterfaceUpdateListenerProtocol) {
        let description = "\(path.status) \(path.availableInterfaces.map(\.name).joined(separator: ","))"
        listener.updateNetworkPath(description)
        guard description != lastNetworkPath else { return }
        lastNetworkPath = description
        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        // libbox 用这个索引做出站绑定（IP_BOUND_IF）；必须传 BSD 的接口索引，
        // 而不是 Network.framework 的 NWInterface.index —— 传错会让内核自己的拨号
        // 落回 tun（自环），实测症状正是"TCP 直连节点正常，但经协议只撑到 TLS 就断"。
        let bsdIndex = Int32(if_nametoindex(interface.name))
        let reportedIndex = bsdIndex > 0 ? bsdIndex : Int32(interface.index)
        listener.updateDefaultInterface(
            interface.name,
            interfaceIndex: reportedIndex,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
        TunnelLog.write("interface -> name=\(interface.name) bsdIndex=\(reportedIndex) nwIndex=\(interface.index) expensive=\(path.isExpensive)")
    }

    // MARK: - LibboxCommandServerHandlerProtocol

    func serviceStop() throws {
        TunnelLog.write("kernel requested serviceStop")
        provider?.stopServiceFromKernel()
    }

    func serviceReload() throws {
        guard let provider else { return }
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { try await provider.reloadServiceFromKernel() } catch { failure = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure { throw failure }
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_ enabled: Bool) throws {}

    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw unsupported("connectSSHAgent")
    }

    func triggerNativeCrash() throws {
        throw unsupported("triggerNativeCrash")
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        logger.debug("\(message, privacy: .public)")
    }

    // MARK: - 辅助

    private func unsupported(_ name: String) -> NSError {
        NSError(
            domain: "TrocketTunnel",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "本客户端未实现 \(name)"]
        )
    }
}

/// 简单数组迭代器，喂给内核的 GetInterfaces。
private final class NetworkInterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private let items: [LibboxNetworkInterface]
    private var cursor = 0

    init(_ items: [LibboxNetworkInterface]) {
        self.items = items
    }

    func hasNext() -> Bool { cursor < items.count }

    func next() -> LibboxNetworkInterface? {
        guard cursor < items.count else { return nil }
        defer { cursor += 1 }
        return items[cursor]
    }
}
