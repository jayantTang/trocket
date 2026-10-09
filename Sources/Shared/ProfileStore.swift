import Foundation

/// 订阅元数据。只记录链接与统计，不保存原始响应体（原始内容整形后写入 profile.json）。
public struct SubscriptionRecord: Codable, Equatable {
    public enum SourceFormat: String, Codable {
        case singboxJSON
        case clashYAML
    }

    public var url: String
    public var importedAt: Date
    public var sourceFormat: SourceFormat
    public var nodeCount: Int
    public var userInfo: SubscriptionUserInfo?

    public init(url: String, importedAt: Date, sourceFormat: SourceFormat, nodeCount: Int, userInfo: SubscriptionUserInfo?) {
        self.url = url
        self.importedAt = importedAt
        self.sourceFormat = sourceFormat
        self.nodeCount = nodeCount
        self.userInfo = userInfo
    }

    /// 是否到了自动刷新窗口（响应头 `profile-update-interval` 默认 24 小时）。
    public func needsRefresh(now: Date = Date(), interval: TimeInterval = 24 * 60 * 60) -> Bool {
        now.timeIntervalSince(importedAt) >= interval
    }
}

/// App Group 容器内的配置读写。原子写：写失败不会破坏已有可用配置。
public struct ProfileStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// 默认位置：App Group 共享容器。
    public static func shared() throws -> ProfileStore {
        ProfileStore(directory: try AppConfiguration.sharedContainerURL())
    }

    public var profileURL: URL {
        directory.appendingPathComponent(AppConfiguration.profileFileName)
    }

    public var subscriptionURL: URL {
        directory.appendingPathComponent(AppConfiguration.subscriptionFileName)
    }

    public var hasProfile: Bool {
        FileManager.default.fileExists(atPath: profileURL.path)
    }

    public func readProfile() throws -> Data {
        guard hasProfile else { throw TrocketError.profileMissing }
        return try Data(contentsOf: profileURL)
    }

    public func readProfileText() throws -> String {
        guard let text = String(data: try readProfile(), encoding: .utf8) else {
            throw TrocketError.profileMissing
        }
        return text
    }

    public func writeProfile(_ data: Data) throws {
        do {
            try data.write(to: profileURL, options: .atomic)
        } catch {
            throw TrocketError.profileWriteFailed(error.localizedDescription)
        }
    }

    public func readSubscription() -> SubscriptionRecord? {
        guard let data = try? Data(contentsOf: subscriptionURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SubscriptionRecord.self, from: data)
    }

    public func writeSubscription(_ record: SubscriptionRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(record).write(to: subscriptionURL, options: .atomic)
        } catch {
            throw TrocketError.profileWriteFailed(error.localizedDescription)
        }
    }
}
