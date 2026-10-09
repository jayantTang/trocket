import Foundation

/// 订阅拉取、格式识别、整形、落盘。
///
/// 失败契约（见 contracts/subscription-fetch.md）：
/// 任何失败都返回可读中文原因，并且**不覆盖**上一次成功的配置。
final class SubscriptionService {

    struct ImportResult {
        let record: SubscriptionRecord
        let catalog: NodeCatalog
        /// 兜底解析时无法识别的条目数（>0 时界面提示）
        let skippedNodes: Int
        /// 为适配当前内核做的语法迁移说明
        let migrationNotes: [String]

        var warning: String? {
            var parts: [String] = []
            if skippedNodes > 0 {
                parts.append("有 \(skippedNodes) 条线路无法解析，已跳过")
            }
            if !migrationNotes.isEmpty {
                parts.append("订阅用的是旧版配置语法，已自动迁移 \(migrationNotes.count) 处")
            }
            return parts.isEmpty ? nil : parts.joined(separator: "；")
        }
    }

    private let store: ProfileStore
    private let session: URLSession

    init(store: ProfileStore, session: URLSession? = nil) {
        self.store = store
        self.session = session ?? SubscriptionService.makeSession()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": AppConfiguration.kernelUserAgent]
        return URLSession(configuration: configuration)
    }

    // MARK: - 导入

    func importSubscription(urlText: String) async throws -> ImportResult {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            throw TrocketError.invalidSubscriptionURL
        }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(AppConfiguration.kernelUserAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TrocketError.network((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TrocketError.unparsableSubscription
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TrocketError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else {
            throw TrocketError.emptyBody
        }

        guard let format = ConfigShaping.detectFormat(data: data, contentType: http.value(forHTTPHeaderField: "Content-Type")) else {
            throw TrocketError.unparsableSubscription
        }

        let shaped: ConfigShaping.ShapedProfile
        let skipped: Int
        switch format {
        case .singboxJSON:
            shaped = try ConfigShaping.shape(subscription: data)
            skipped = 0
        case .clashYAML:
            guard let text = String(data: data, encoding: .utf8) else { throw TrocketError.unparsableSubscription }
            let result = try ClashYAML.convert(text)
            shaped = try ConfigShaping.shape(subscription: result.config)
            skipped = result.skipped
        }

        let catalog = try ConfigShaping.catalog(fromProfile: shaped.data)

        // 先落配置，再落元数据：中途失败时至少配置与元数据不会互相矛盾。
        try store.writeProfile(shaped.data)

        let userInfo = http.value(forHTTPHeaderField: "subscription-userinfo")
            .flatMap(SubscriptionUserInfo.parse(headerValue:))

        let record = SubscriptionRecord(
            url: trimmed,
            importedAt: Date(),
            sourceFormat: format,
            nodeCount: catalog.nodeCount,
            userInfo: userInfo
        )
        try store.writeSubscription(record)
        return ImportResult(
            record: record,
            catalog: catalog,
            skippedNodes: skipped,
            migrationNotes: shaped.migrationNotes
        )
    }

    // MARK: - 缓存

    /// 启动时读取本地缓存（不联网）。没有缓存返回 nil。
    func cached() -> (record: SubscriptionRecord, catalog: NodeCatalog)? {
        guard let record = store.readSubscription(),
              let data = try? store.readProfile(),
              let catalog = try? ConfigShaping.catalog(fromProfile: data) else {
            return nil
        }
        return (record, catalog)
    }

    /// 到期刷新：静默执行，失败不影响当前使用（用户已连接时尤其不能打扰）。
    @discardableResult
    func refreshIfNeeded(now: Date = Date()) async -> ImportResult? {
        guard let record = store.readSubscription(), record.needsRefresh(now: now) else { return nil }
        return try? await importSubscription(urlText: record.url)
    }
}
