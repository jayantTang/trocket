import Foundation

/// 一次"测速"批次的登记与收尾。
///
/// 真正发起测试的是内核：`urlTest(groupTag:)` 一次就把**整个策略组**的成员都测一遍
/// （sing-box 的 `URLTest` 对 selector/urltest 组会遍历其全部成员），
/// 结果随后以"组内条目"的形式回流。因此这里只负责：
/// 登记本次要等的线路、按条回填、给未被回填的条目兜底超时、以及整体 20 秒收尾。
/// 并发由内核控制，客户端不需要（也不应该）自己开一堆请求（见 research.md R5）。
final class LatencyRunner {

    private let overallTimeout: TimeInterval
    private let perTagTimeout: TimeInterval
    private let lock = NSLock()

    private var pending: Set<String> = []
    private var total = 0
    private var generation = 0
    private var running = false

    /// (已完成, 总数)
    var onProgress: ((Int, Int) -> Void)?
    /// (是否被取消)
    var onFinish: ((Bool) -> Void)?

    init(overallTimeout: TimeInterval = 20, perTagTimeout: TimeInterval = 8) {
        self.overallTimeout = overallTimeout
        self.perTagTimeout = perTagTimeout
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 开始一批：登记要等的线路标签（不发起请求）。
    func start(tags: [String]) {
        lock.lock()
        generation += 1
        let token = generation
        pending = Set(tags)
        total = tags.count
        running = true
        lock.unlock()

        guard total > 0 else {
            finish(token: token, cancelled: false)
            return
        }
        reportProgress(token: token)

        for tag in Set(tags) {
            DispatchQueue.global().asyncAfter(deadline: .now() + perTagTimeout) { [weak self] in
                self?.complete(tag: tag, token: token)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + overallTimeout) { [weak self] in
            self?.finish(token: token, cancelled: false)
        }
    }

    /// 内核回流了某条线路的延迟（或判定为超时，delay 为 0）。
    func receive(tag: String) {
        lock.lock()
        let token = generation
        lock.unlock()
        complete(tag: tag, token: token)
    }

    /// 测速请求本身失败时调用：结束本批次。
    func fail() {
        lock.lock()
        let token = generation
        lock.unlock()
        finish(token: token, cancelled: false)
    }

    func cancel() {
        lock.lock()
        generation += 1
        let token = generation
        let wasRunning = running
        lock.unlock()
        guard wasRunning else { return }
        finish(token: token, cancelled: true)
    }

    // MARK: - 内部

    private func complete(tag: String, token: Int) {
        lock.lock()
        guard token == generation, running else { lock.unlock(); return }
        let removed = pending.remove(tag) != nil
        let empty = pending.isEmpty
        lock.unlock()
        guard removed else { return }
        reportProgress(token: token)
        if empty {
            finish(token: token, cancelled: false)
        }
    }

    private func reportProgress(token: Int) {
        lock.lock()
        guard token == generation else { lock.unlock(); return }
        let completed = total - pending.count
        let totalCount = total
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(completed, totalCount)
        }
    }

    private func finish(token: Int, cancelled: Bool) {
        lock.lock()
        guard token == generation, running else { lock.unlock(); return }
        running = false
        let completed = total - pending.count
        let totalCount = total
        pending.removeAll()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onProgress?(completed, totalCount)
            self.onFinish?(cancelled)
        }
    }
}
