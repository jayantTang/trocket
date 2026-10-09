import Foundation

/// 一条可选择的线路。数据来源：订阅配置里的出站项（离线可得），
/// 延迟与选中状态在连接后由内核命令通道回填。
public struct NodeItem: Identifiable, Equatable, Hashable {
    public let tag: String
    public let type: String
    public var delay: Int?
    public var testedAt: Date?

    public init(tag: String, type: String, delay: Int? = nil, testedAt: Date? = nil) {
        self.tag = tag
        self.type = type
        self.delay = delay
        self.testedAt = testedAt
    }

    public var id: String { tag }

    /// 未测/超时显示 `—`（不能显示 0ms，那会被误读成极快）。
    public var delayText: String {
        guard let delay, delay > 0 else { return "—" }
        return "\(delay) ms"
    }

    public var quality: DelayQuality {
        guard let delay, delay > 0 else { return .unknown }
        if delay <= 200 { return .good }
        if delay <= 500 { return .fair }
        return .poor
    }
}

public enum DelayQuality: String, Equatable {
    case good, fair, poor, unknown
}

/// 一个策略组。本应用只用两种：`selector`（手动选）与 `urltest`（自动选）。
public struct NodeGroup: Identifiable, Equatable {
    public let tag: String
    public let type: String
    public var selected: String
    public let selectable: Bool
    public var items: [NodeItem]

    public init(tag: String, type: String, selected: String, selectable: Bool, items: [NodeItem]) {
        self.tag = tag
        self.type = type
        self.selected = selected
        self.selectable = selectable
        self.items = items
    }

    public var id: String { tag }
    public var isAutomatic: Bool { type == "urltest" }

    /// 自动选择在界面上作为一个特殊条目（不是线路本身）。
    public var displayName: String {
        isAutomatic ? "自动选择（按延迟）" : tag
    }
}

/// 订阅解析结果：线路组 + 线路总数。
public struct NodeCatalog: Equatable {
    public var groups: [NodeGroup]

    public init(groups: [NodeGroup]) {
        self.groups = groups
    }

    public var nodeCount: Int {
        groups.filter { !$0.isAutomatic }.reduce(0) { $0 + $1.items.count }
    }

    /// 界面默认操作的手动选择组。
    public var primaryGroup: NodeGroup? {
        groups.first { !$0.isAutomatic && $0.selectable } ?? groups.first { !$0.isAutomatic }
    }

    public var automaticGroup: NodeGroup? {
        groups.first { $0.isAutomatic }
    }

    public var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty } }
}

public enum NodeSorting {

    /// 延迟升序；未测/超时排最后；相同延迟保持原有顺序（稳定排序，避免列表跳动）。
    public static func sorted(_ items: [NodeItem]) -> [NodeItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element)
                let right = rank(rhs.element)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func rank(_ item: NodeItem) -> Int {
        guard let delay = item.delay, delay > 0 else { return Int.max }
        return delay
    }
}
