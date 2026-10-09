import XCTest

final class LatencyRunnerTests: XCTestCase {

    func testAllTagsReportedFinishesBatch() {
        let runner = LatencyRunner(overallTimeout: 5, perTagTimeout: 5)
        var lastProgress: (Int, Int)?
        let finished = expectation(description: "全部回填后结束")
        runner.onProgress = { completed, total in lastProgress = (completed, total) }
        runner.onFinish = { cancelled in
            XCTAssertFalse(cancelled)
            finished.fulfill()
        }

        runner.start(tags: ["a", "b"])
        runner.receive(tag: "a")
        runner.receive(tag: "b")
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(lastProgress?.0, 2)
        XCTAssertEqual(lastProgress?.1, 2)
        XCTAssertFalse(runner.isRunning)
    }

    func testUnreportedTagsTimeOutButBatchStillFinishes() {
        // 内核只会给"能连上的线路"回填延迟，剩下的必须由超时兜底收尾，否则界面会一直转圈。
        let runner = LatencyRunner(overallTimeout: 5, perTagTimeout: 0.3)
        var progressValues: [(Int, Int)] = []
        let finished = expectation(description: "超时后结束")
        runner.onProgress = { completed, total in progressValues.append((completed, total)) }
        runner.onFinish = { cancelled in
            XCTAssertFalse(cancelled)
            finished.fulfill()
        }

        runner.start(tags: ["a", "b", "c"])
        runner.receive(tag: "a")
        wait(for: [finished], timeout: 3)
        XCTAssertTrue(progressValues.contains { $0 == (1, 3) }, "收到 1 条时必须如实显示 1/3")
        XCTAssertEqual(progressValues.last?.0, 3, "超时兜底后未回填的线路也算处理完，进度收在 3/3")
        XCTAssertEqual(progressValues.last?.1, 3)
        XCTAssertFalse(runner.isRunning)
    }

    func testFailFinishesWithoutCancel() {
        let runner = LatencyRunner(overallTimeout: 5, perTagTimeout: 5)
        let finished = expectation(description: "请求失败也要收尾")
        runner.onFinish = { cancelled in
            XCTAssertFalse(cancelled)
            finished.fulfill()
        }
        runner.start(tags: ["a"])
        runner.fail()
        wait(for: [finished], timeout: 3)
        XCTAssertFalse(runner.isRunning)
    }

    func testCancelFinishesOnceAndStopsCallbacks() {
        let runner = LatencyRunner(overallTimeout: 5, perTagTimeout: 0.4)
        let finished = expectation(description: "取消后结束")
        finished.assertForOverFulfill = true
        var cancelledFlag = false
        var progressAfterCancel = 0

        runner.onFinish = { cancelled in
            cancelledFlag = cancelled
            finished.fulfill()
        }
        runner.onProgress = { completed, total in
            if cancelledFlag { progressAfterCancel += 1 }
            _ = (completed, total)
        }

        runner.start(tags: ["a", "b", "c"])
        runner.cancel()
        wait(for: [finished], timeout: 3)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(cancelledFlag)
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(progressAfterCancel, 0, "取消之后不应再回报进度")
    }
}
