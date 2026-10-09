import XCTest

final class NodeSortingTests: XCTestCase {

    func testSortingPutsUnknownLastAndKeepsOrderStable() {
        let items = [
            NodeItem(tag: "a", type: "anytls", delay: nil),
            NodeItem(tag: "b", type: "anytls", delay: 320),
            NodeItem(tag: "c", type: "anytls", delay: 88),
            NodeItem(tag: "d", type: "anytls", delay: 0),
            NodeItem(tag: "e", type: "anytls", delay: 320),
            NodeItem(tag: "f", type: "anytls", delay: 150),
        ]
        let sorted = NodeSorting.sorted(items)
        XCTAssertEqual(sorted.map(\.tag), ["c", "f", "b", "e", "a", "d"], "0 与 nil 都算未测，排在最后且保持原顺序")
    }

    func testDelayTextAndQualityBuckets() {
        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: 120).delayText, "120 ms")
        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: 0).delayText, "—")
        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: nil).delayText, "—")

        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: 200).quality, .good)
        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: 201).quality, .fair)
        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: 500).quality, .fair)
        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: 501).quality, .poor)
        XCTAssertEqual(NodeItem(tag: "a", type: "anytls", delay: nil).quality, .unknown)
    }

    func testCatalogStatisticsIgnoreGroupMembers() {
        let group = NodeGroup(
            tag: "节点选择",
            type: "selector",
            selected: "自动选择",
            selectable: true,
            items: [NodeItem(tag: "n1", type: "anytls"), NodeItem(tag: "n2", type: "anytls")]
        )
        let automatic = NodeGroup(
            tag: "自动选择",
            type: "urltest",
            selected: "",
            selectable: false,
            items: [NodeItem(tag: "n1", type: "anytls"), NodeItem(tag: "n2", type: "anytls")]
        )
        let catalog = NodeCatalog(groups: [group, automatic])
        XCTAssertEqual(catalog.nodeCount, 2, "自动选择组内的线路不能重复计数")
        XCTAssertEqual(catalog.primaryGroup?.tag, "节点选择")
        XCTAssertEqual(catalog.automaticGroup?.tag, "自动选择")
        XCTAssertFalse(catalog.isEmpty)
    }
}
