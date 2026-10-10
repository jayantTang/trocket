import Foundation

/// 规则集本地化：把订阅里引用的远端 `rule_set` 落地成本地文件，供内核以 `type: local` 加载。
///
/// 为什么要做：远端 `rule_set` 由内核在**服务启动时**下载，失败即 FATAL（实测），
/// 用户看到的现象是"连不上"。此前为了不炸只能把远端规则集整条摘掉，副作用是国内直连规则
/// （`geosite-cn` / `geoip-cn`）一起消失，表现为"国内流量也走代理"。
///
/// 现在分三层：
/// 1. `geosite-cn` / `geoip-cn` 随包内置，任何时候都可用（离线保底）；
/// 2. 主 App 导入订阅时，把订阅里其它远端规则集下载进 App Group 容器；
/// 3. 网络扩展只读容器里的文件，读不到的才摘除（并保留提示）。
public enum RuleSetStore {

    /// 容器内的规则集目录（App 与网络扩展共享）。
    public static let directoryName = "rule-set"

    /// 随包内置的规则集文件名。文件名同时是远端 URL 的最后一个路径片段。
    public static let bundledNames = ["geosite-cn.srs", "geoip-cn.srs"]

    /// 内置资源在 bundle 里的子目录（XcodeGen 也可能把它们平铺到根目录，两种都找）。
    static let bundleSubdirectory = "RuleSets"

    /// 单次导入最多缓存多少个远端规则集，避免订阅里挂几十个文件时导入卡住。
    public static let prefetchLimit = 8

    public enum StoreError: LocalizedError {
        case invalidURL(String)
        case httpStatus(Int)
        case emptyBody
        case invalidFormat

        public var errorDescription: String? {
            switch self {
            case .invalidURL(let url): return "规则集地址无效：\(url)"
            case .httpStatus(let code): return "规则集下载失败（HTTP \(code)）"
            case .emptyBody: return "规则集下载失败（内容为空）"
            case .invalidFormat: return "规则集下载失败（不是 sing-box 规则集格式）"
            }
        }
    }

    // MARK: - 目录

    /// 规则集目录。`base` 供单元测试注入，生产环境用 App Group 容器。
    public static func directory(base: URL? = nil) throws -> URL {
        let root: URL
        if let base = base {
            root = base
        } else {
            root = try AppConfiguration.sharedContainerURL()
        }
        let dir = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 内置保底

    /// 把随包内置的规则集拷进容器（缺失或字节数不同才覆盖），返回容器里可用的文件名。
    ///
    /// 只应由主 App 调用：内置资源只打包进 App target，扩展的 Bundle 里没有。
    @discardableResult
    public static func ensureBundled(bundle: Bundle = .main, base: URL? = nil) -> [String] {
        guard let dir = try? directory(base: base) else { return [] }
        var available: [String] = []
        for name in bundledNames {
            let destination = dir.appendingPathComponent(name)
            guard let source = bundledURL(named: name, bundle: bundle) else {
                // 测试或异常打包下没有内置文件：已有缓存仍然可用
                if FileManager.default.fileExists(atPath: destination.path) { available.append(name) }
                continue
            }
            if let src = fileSize(source), let dst = fileSize(destination), src == dst {
                available.append(name)
                continue
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                available.append(name)
            } catch {
                if FileManager.default.fileExists(atPath: destination.path) { available.append(name) }
            }
        }
        return available
    }

    static func bundledURL(named name: String, bundle: Bundle) -> URL? {
        let url = URL(fileURLWithPath: name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return bundle.url(forResource: base, withExtension: ext)
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: bundleSubdirectory)
    }

    // MARK: - 远端 → 本地

    /// 远端 `rule_set` 对应的本地文件名：优先取 URL 的文件名，取不到再按 tag 匹配内置名。
    public static func fileName(tag: String?, remoteURL: String?) -> String? {
        if let remoteURL = remoteURL, let url = URL(string: remoteURL) {
            let last = url.lastPathComponent
            if last.hasSuffix(".srs"), !last.isEmpty { return last }
        }
        if let tag = tag,
           let match = bundledNames.first(where: { normalize(String($0.dropLast(4))) == normalize(tag) }) {
            return match
        }
        return nil
    }

    /// 本地可用文件（内置已拷进容器，或此前下载缓存过）。
    public static func localURL(fileName: String, base: URL? = nil) -> URL? {
        guard let dir = try? directory(base: base) else { return nil }
        let url = dir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 去除分隔符与大小写后比较：`geosite-cn` / `geosite_cn` / `GeositeCN` 视为同一个。
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - 下载（只由主 App 调用）

    public struct RemoteRuleSet: Equatable {
        public let tag: String
        public let url: String
        public let fileName: String
    }

    /// 从配置文本里取出所有远端 `rule_set`（按文件名去重）。
    public static func remoteRuleSets(inConfig text: String) -> [RemoteRuleSet] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = root["route"] as? [String: Any],
              let ruleSets = route["rule_set"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var result: [RemoteRuleSet] = []
        for ruleSet in ruleSets {
            guard (ruleSet["type"] as? String) == "remote",
                  let url = ruleSet["url"] as? String,
                  let fileName = fileName(tag: ruleSet["tag"] as? String, remoteURL: url),
                  seen.insert(fileName).inserted else { continue }
            result.append(RemoteRuleSet(tag: (ruleSet["tag"] as? String) ?? fileName, url: url, fileName: fileName))
        }
        return result
    }

    /// 下载一个远端规则集到容器；同名文件已存在则直接复用（除非 `force`）。
    @discardableResult
    public static func download(_ remote: RemoteRuleSet, base: URL? = nil, force: Bool = false,
                                session: URLSession? = nil, timeout: TimeInterval = 12) async throws -> URL {
        let dir = try directory(base: base)
        let destination = dir.appendingPathComponent(remote.fileName)
        if !force, FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard let url = URL(string: remote.url) else { throw StoreError.invalidURL(remote.url) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(AppConfiguration.kernelUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await (session ?? makeSession()).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StoreError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw StoreError.emptyBody }
        // 只接受真正的二进制规则集（SRS 魔数），避免把错误页当规则集缓存下来
        guard data.count > 16, data.prefix(3) == Data("SRS".utf8) else { throw StoreError.invalidFormat }

        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// 导入时批量缓存。全部失败也不抛错：拿不到的规则集由 `ConfigMigration` 摘除并提示。
    public static func prefetch(_ remotes: [RemoteRuleSet], base: URL? = nil,
                                session: URLSession? = nil) async -> (cached: [String], failed: [String]) {
        let targets = Array(remotes.prefix(prefetchLimit))
        guard !targets.isEmpty else { return ([], []) }
        let session = session ?? makeSession()
        return await withTaskGroup(of: (String, Bool).self) { group in
            for remote in targets {
                group.addTask {
                    do {
                        _ = try await download(remote, base: base, session: session)
                        return (remote.fileName, true)
                    } catch {
                        return (remote.fileName, false)
                    }
                }
            }
            var cached: [String] = []
            var failed: [String] = []
            for await (name, ok) in group {
                if ok { cached.append(name) } else { failed.append(name) }
            }
            return (cached.sorted(), failed.sorted())
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }
}
