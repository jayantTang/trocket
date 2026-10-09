import Foundation
import os.log

/// 落在 App Group 容器里的诊断日志。
///
/// 为什么不用 os_log：网络扩展的日志只能靠 Xcode 或 sysdiagnose 看，而"有线连接拉日志"
/// 需要一条可脚本化的路径——写文件后 `xcrun devicectl device copy from
/// --domain-type appGroupDataContainer` 就能直接取出来。
///
/// 约束（宪法第 I 条）：只写状态与错误，绝不写订阅链接、节点密码等凭据。
public enum TunnelLog {

    public static let fileName = "tunnel.log"
    private static let maxBytes = 256 * 1024
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 进程名（App / 扩展），用来区分日志来源。
    public static var processTag: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    public static func logURL(in container: URL) -> URL {
        container.appendingPathComponent(fileName)
    }

    public static func write(_ message: String, to container: URL) {
        let line = "[\(formatter.string(from: Date()))] [\(processTag)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let url = logURL(in: container)
        rotateIfNeeded(url)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// 便捷入口：容器不可用时静默失败（日志不能反过来影响主流程）。
    public static func write(_ message: String) {
        guard let container = try? AppConfiguration.sharedContainerURL() else { return }
        write(message, to: container)
    }

    public static func contents() -> String {
        guard let container = try? AppConfiguration.sharedContainerURL(),
              let text = try? String(contentsOf: logURL(in: container), encoding: .utf8) else {
            return ""
        }
        return text
    }

    public static func clear() {
        guard let container = try? AppConfiguration.sharedContainerURL() else { return }
        try? FileManager.default.removeItem(at: logURL(in: container))
    }

    /// 读出来的最后 N 行，供界面展示与问题上报。
    public static func tail(_ lines: Int = 200) -> [String] {
        let all = contents().components(separatedBy: .newlines).filter { !$0.isEmpty }
        return Array(all.suffix(lines))
    }

    private static func rotateIfNeeded(_ url: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxBytes else { return }
        let backup = url.deletingLastPathComponent().appendingPathComponent(fileName + ".1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
