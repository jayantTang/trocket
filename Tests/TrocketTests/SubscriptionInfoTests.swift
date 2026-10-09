import XCTest

final class SubscriptionInfoTests: XCTestCase {

    func testParseRealHeader() throws {
        let info = try XCTUnwrap(SubscriptionUserInfo.parse(
            headerValue: "upload=48749466; download=1499199982; total=214748364800; expire=1804165320"
        ))
        XCTAssertEqual(info.upload, 48749466)
        XCTAssertEqual(info.download, 1499199982)
        XCTAssertEqual(info.total, 214748364800)
        XCTAssertEqual(info.used, 1547949448)
        XCTAssertEqual(info.usageText, "1.44 GB / 200 GB")
        XCTAssertEqual(info.expireText, "2027-03-04")
    }

    func testParseHeaderWithoutExpire() throws {
        let info = try XCTUnwrap(SubscriptionUserInfo.parse(headerValue: "upload=0; download=1024"))
        XCTAssertNil(info.expire)
        XCTAssertNil(info.expireText)
        XCTAssertEqual(info.usageText, "1 KB")
    }

    func testParseHeaderMissingReturnsNil() {
        XCTAssertNil(SubscriptionUserInfo.parse(headerValue: ""))
        XCTAssertNil(SubscriptionUserInfo.parse(headerValue: "expire=abc; total="))
    }

    func testByteFormat() {
        XCTAssertEqual(ByteFormat.human(0), "0 B")
        XCTAssertEqual(ByteFormat.human(999), "999 B")
        XCTAssertEqual(ByteFormat.human(1024), "1 KB")
        XCTAssertEqual(ByteFormat.human(1536), "1.5 KB")
        XCTAssertEqual(ByteFormat.human(15 * 1024 * 1024), "15 MB")
        XCTAssertEqual(ByteFormat.human(214748364800), "200 GB")
    }

    func testNeedsRefreshUses24HourWindow() {
        let record = SubscriptionRecord(
            url: "https://example.com/link/x",
            importedAt: Date(timeIntervalSince1970: 1_000_000),
            sourceFormat: .singboxJSON,
            nodeCount: 1,
            userInfo: nil
        )
        XCTAssertFalse(record.needsRefresh(now: Date(timeIntervalSince1970: 1_000_000 + 60 * 60)))
        XCTAssertTrue(record.needsRefresh(now: Date(timeIntervalSince1970: 1_000_000 + 25 * 60 * 60)))
    }
}
