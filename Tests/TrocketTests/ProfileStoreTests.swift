import XCTest

final class ProfileStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trocket-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testProfileRoundTripAndOverwrite() throws {
        let store = ProfileStore(directory: directory)
        XCTAssertFalse(store.hasProfile)
        XCTAssertThrowsError(try store.readProfile()) { error in
            XCTAssertEqual(error as? TrocketError, .profileMissing)
        }

        try store.writeProfile(Data(#"{"inbounds":[]}"#.utf8))
        XCTAssertTrue(store.hasProfile)
        XCTAssertEqual(try store.readProfileText(), #"{"inbounds":[]}"#)

        // 覆盖写：新内容完整，不出现半写状态
        try store.writeProfile(Data(#"{"inbounds":[{"type":"tun"}]}"#.utf8))
        XCTAssertEqual(try store.readProfileText(), #"{"inbounds":[{"type":"tun"}]}"#)
    }

    func testSubscriptionRecordRoundTrip() throws {
        let store = ProfileStore(directory: directory)
        XCTAssertNil(store.readSubscription())

        let record = SubscriptionRecord(
            url: "https://example.com/link/secret",
            importedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sourceFormat: .singboxJSON,
            nodeCount: 32,
            userInfo: SubscriptionUserInfo(
                upload: 1024,
                download: 2048,
                total: 4096,
                expire: Date(timeIntervalSince1970: 1_804_165_320)
            )
        )
        try store.writeSubscription(record)

        let restored = try XCTUnwrap(store.readSubscription())
        XCTAssertEqual(restored.url, record.url)
        XCTAssertEqual(restored.sourceFormat, .singboxJSON)
        XCTAssertEqual(restored.nodeCount, 32)
        XCTAssertEqual(restored.userInfo?.total, 4096)
        XCTAssertEqual(
            restored.importedAt.timeIntervalSince1970,
            record.importedAt.timeIntervalSince1970,
            accuracy: 1
        )
        XCTAssertEqual(restored.userInfo?.expireText, "2027-03-04")
    }

    func testCachedSubscriptionIsIndependentFromProfileWrite() throws {
        let store = ProfileStore(directory: directory)
        try store.writeProfile(Data(#"{"outbounds":[]}"#.utf8))
        XCTAssertNil(store.readSubscription(), "只有 profile 没有元数据时不能当成有效缓存")
    }
}
