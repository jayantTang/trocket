import Foundation
import Libbox

/// 探针服务的平台接口：测速不需要 tun，也不需要任何平台能力，因此全部给最小实现。
/// （`openTun` 只会在配置里有 tun 入站时被调用，探针配置里没有入站，所以直接抛"不支持"。）
final class ProbePlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {

    private func unsupported(_ name: String) -> NSError {
        NSError(domain: "TrocketProbe", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "探测模式未实现 \(name)"])
    }

    // MARK: - LibboxPlatformInterfaceProtocol

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw unsupported("openTun")
    }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {}
    func useProcFS() -> Bool { false }
    func underNetworkExtension() -> Bool { false }
    func includeAllNetworks() -> Bool { false }
    func clearDNSCache() {}
    func writeLog(_ message: String?) {}
    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
                            destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw unsupported("findConnectionOwner")
    }
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol { throw unsupported("getInterfaces") }
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func registerMyInterface(_ name: String?) {}
    func send(_ notification: LibboxNotification?) throws {}
    func cancelNotification(_ identifier: String?, typeID: Int32) throws {}
    func checkPlatformShell() throws { throw unsupported("checkPlatformShell") }
    func usePlatformShell() -> Bool { false }
    func openShellSession(_ user: LibboxPlatformUser?, command: String?,
                          environ: (any LibboxStringIteratorProtocol)?, term: String?,
                          rows: Int32, cols: Int32) throws -> any LibboxShellSessionProtocol {
        throw unsupported("openShellSession")
    }
    func usePlatformBridge() -> Bool { false }
    func createBridge(_ options: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw unsupported("createBridge")
    }
    func lookupUser(_ username: String?) throws -> LibboxPlatformUser { throw unsupported("lookupUser") }
    func lookupSFTPServer(_ error: NSErrorPointer) -> String { "" }
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String { "" }
    func tailscaleHostname() -> String { "Trocket" }
    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {}
    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}
    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {}

    // MARK: - LibboxCommandServerHandlerProtocol

    func serviceStop() throws {}
    func serviceReload() throws {}
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus { LibboxSystemProxyStatus() }
    func setSystemProxyEnabled(_ enabled: Bool) throws {}
    func connectSSHAgent(_ ret0_: UnsafeMutablePointer<Int32>?) throws {}
    func triggerNativeCrash() throws {}
    func writeDebugMessage(_ message: String?) {}
}
