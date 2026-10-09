import Foundation

/// 单屏界面的全部状态与动作。UI 只读这里的状态、只调这里的方法。
///
/// 隧道状态不在这里镜像一份：`tunnel` 本身是 `ObservableObject`，
/// 界面同时观察它，避免"本地记录与系统实际状态不一致"（宪法/契约第 4 节）。
@MainActor
final class AppModel: ObservableObject {

    @Published var subscriptionURL: String = ""
    @Published private(set) var record: SubscriptionRecord?
    @Published private(set) var nodes: [NodeItem] = []
    @Published private(set) var selectedTag: String = ""
    @Published private(set) var primaryGroupTag: String = ""
    @Published private(set) var automaticGroupTag: String = ""

    @Published private(set) var isImporting = false
    @Published private(set) var isTesting = false
    @Published var isShowingSubscription = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?

    @Published private(set) var testedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var sortByLatency = false
    @Published private(set) var latencySource: LatencySource = .probe
    @Published var isShowingDiagnostics = false
    @Published private(set) var diagnosticsLog: [String] = []

    let tunnel = TunnelController()
    let channel = ControlChannel()
    /// 未连接时的测速通道（应用进程内起内核，不建立 VPN）
    private let probe = ProbeService()

    private let store: ProfileStore?
    private let service: SubscriptionService?
    private let runner = LatencyRunner()
    private var didLoad = false

    private static let selectionKey = "selectedNode"

    init() {
        var resolvedStore: ProfileStore?
        do {
            resolvedStore = try ProfileStore.shared()
        } catch {
            resolvedStore = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        store = resolvedStore
        service = resolvedStore.map { SubscriptionService(store: $0) }
        wireLatency()
    }

    var tunnelState: TunnelState { tunnel.state }

    // MARK: - 生命周期

    func onAppear() async {
        guard !didLoad else { return }
        didLoad = true

        // 主 App 进程也需要 basePath，才能连上扩展的命令通道。
        try? ControlChannel.setupKernel()

        await tunnel.load()
        if tunnel.state.isConnected { channel.attach() }

        if let service, let cached = service.cached() {
            record = cached.record
            subscriptionURL = cached.record.url
            apply(catalog: cached.catalog)
        }

        // 到期刷新：静默，失败不打扰（已连接时尤其不能弹错）
        if let refreshed = await service?.refreshIfNeeded() {
            record = refreshed.record
            apply(catalog: refreshed.catalog)
        }

        #if DEBUG
        // 自动化验证入口（仿真器/有线脚本用）：
        //   TrocketAutoLatency   启动后先跑一次测速
        //   TrocketAutoConnect   启动后自动打开连接
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("TrocketAutoLatency") {
            TunnelLog.write("auto-latency requested by launch argument")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            startLatencyTest()
        }
        if arguments.contains("TrocketAutoConnect") {
            TunnelLog.write("auto-connect requested by launch argument")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            toggleConnection()
            if arguments.contains("TrocketAutoLatency") {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                startLatencyTest()
            }
        }
        #endif
    }

    func refreshDiagnostics() {
        diagnosticsLog = TunnelLog.tail(300)
    }

    func clearDiagnostics() {
        TunnelLog.clear()
        diagnosticsLog = []
    }

    /// 界面从后台回到前台、以及系统 VPN 状态变化时调用。
    func refreshTunnelState() {
        tunnel.refreshState()
        if tunnel.state.isConnected {
            channel.attach()
        } else if !tunnel.state.toggleIsOn {
            channel.detach()
        }
    }

    // MARK: - 订阅

    func importSubscription() async {
        guard let service else {
            errorMessage = TrocketError.appGroupMissing.errorDescription
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            let result = try await service.importSubscription(urlText: subscriptionURL)
            record = result.record
            apply(catalog: result.catalog)
            infoMessage = result.warning
            isShowingSubscription = false
        } catch {
            // 失败保留旧配置：record/nodes 不动
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func apply(catalog: NodeCatalog) {
        primaryGroupTag = catalog.primaryGroup?.tag ?? ""
        automaticGroupTag = catalog.automaticGroup?.tag ?? ""

        var items = catalog.primaryGroup?.items ?? []
        if !automaticGroupTag.isEmpty {
            items.insert(NodeItem(tag: automaticGroupTag, type: "urltest"), at: 0)
        }
        nodes = items
        totalCount = nodes.count
        testedCount = 0

        let remembered = UserDefaults(suiteName: AppConfiguration.appGroupID)?.string(forKey: Self.selectionKey)
        let fallback = catalog.primaryGroup?.selected ?? items.first?.tag ?? ""
        selectedTag = (remembered != nil && items.contains { $0.tag == remembered }) ? (remembered ?? fallback) : fallback

        if sortByLatency { nodes = NodeSorting.sorted(nodes) }
    }

    // MARK: - 连接

    func toggleConnection() {
        Task { await performToggle() }
    }

    private func performToggle() async {
        TunnelLog.write("toggle tapped (state=\(tunnel.state.text), hasProfile=\(hasProfile))")
        if tunnel.state.toggleIsOn {
            await tunnel.stop()
            channel.detach()
            clearLatencyResults()
            return
        }
        guard let store else {
            errorMessage = TrocketError.appGroupMissing.errorDescription
            return
        }
        let configText: String
        do {
            configText = try store.readProfileText()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        do {
            try await tunnel.start(configText: configText)
            channel.attach()
            clearLatencyResults()
        } catch {
            // 授权被拒或扩展启动失败：状态必须回到系统实际值，否则开关会卡在"连接中"
            tunnel.refreshState()
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            TunnelLog.write("start failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 线路

    func displayName(for tag: String) -> String {
        tag == automaticGroupTag && !automaticGroupTag.isEmpty ? "自动选择（按延迟）" : tag
    }

    func selectNode(_ tag: String) {
        selectedTag = tag
        UserDefaults(suiteName: AppConfiguration.appGroupID)?.set(tag, forKey: Self.selectionKey)
        guard tunnel.state.isConnected, !primaryGroupTag.isEmpty else { return }
        do {
            try channel.selectOutbound(groupTag: primaryGroupTag, outboundTag: tag)
        } catch {
            errorMessage = TrocketError.selectFailed((error as NSError).localizedDescription).errorDescription
        }
    }

    func toggleSort() {
        sortByLatency.toggle()
        if sortByLatency {
            nodes = NodeSorting.sorted(nodes)
        }
    }

    // MARK: - 测速

    /// 一键测速：**无论是否连接**都能用。
    /// 已连接 → 走系统隧道的命令通道；未连接 → 在应用进程内起探针服务，同样走代理协议真实测速。
    func startLatencyTest() {
        let tags = nodes.map(\.tag)
        guard !tags.isEmpty, !primaryGroupTag.isEmpty else { return }
        if isTesting { return }
        isTesting = true
        testedCount = 0
        totalCount = tags.count
        latencySource = tunnel.state.isConnected ? .tunnel : .probe
        runner.start(tags: tags)

        if tunnel.state.isConnected {
            do {
                try channel.urlTest(groupTag: primaryGroupTag)
            } catch {
                runner.fail()
                isTesting = false
                errorMessage = "测速请求失败：\((error as NSError).localizedDescription)"
            }
            return
        }

        guard let store, let text = try? store.readProfileText() else {
            isTesting = false
            errorMessage = TrocketError.profileMissing.errorDescription
            return
        }
        do {
            try probe.start(configText: text)
            try probe.urlTest(groupTag: primaryGroupTag)
        } catch {
            probe.stop()
            runner.fail()
            isTesting = false
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelLatencyTest() {
        runner.cancel()
        probe.stop()
        isTesting = false
    }

    private func wireLatency() {
        runner.onProgress = { [weak self] completed, total in
            self?.testedCount = completed
            self?.totalCount = total
        }
        runner.onFinish = { [weak self] _ in
            guard let self else { return }
            self.isTesting = false
            self.probe.stop()   // 探针用完即关，避免占着 command.sock
            if self.sortByLatency {
                self.nodes = NodeSorting.sorted(self.nodes)
            }
        }
        channel.onDelay = { [weak self] tag, delay in
            self?.apply(delay: delay, for: tag)
        }
        probe.onDelay = { [weak self] tag, delay in
            self?.apply(delay: delay, for: tag)
        }
    }

    /// 连接状态一变，旧的测速结果就失效了：不清掉会出现"已连接却显示未连接探针的旧结果"。
    private func clearLatencyResults() {
        for index in nodes.indices {
            nodes[index].delay = nil
            nodes[index].testedAt = nil
        }
        testedCount = 0
    }

    private func apply(delay: Int, for tag: String) {
        if let index = nodes.firstIndex(where: { $0.tag == tag }) {
            nodes[index].delay = delay
            nodes[index].testedAt = Date()
        }
        runner.receive(tag: tag)
    }

    /// 状态文案：本地已有配置但系统还没建立 VPN 配置时，显示"未连接"而不是"未导入订阅"，
    /// 否则用户看到列表却被告知没有订阅。
    var statusText: String {
        if case .unconfigured = tunnel.state {
            return hasProfile ? TunnelState.disconnected.text : TunnelState.unconfigured.text
        }
        return tunnel.state.text
    }

    /// 连接开关是否可用。
    /// 注意：系统里还没有 VPN 配置时 `tunnel.state` 是 `.unconfigured`，
    /// 但本地已有订阅就该允许用户去建配置——不能用 `canToggle` 直接判断，否则开关永远是灰的。
    var canToggleConnection: Bool {
        switch tunnel.state {
        case .connecting, .reasserting:
            return false
        default:
            return hasProfile || tunnel.isInstalled
        }
    }

    /// 界面上只显示一条提示：错误优先，其次信息。
    var currentMessage: String? { errorMessage ?? infoMessage }

    func clearMessages() {
        errorMessage = nil
        infoMessage = nil
    }

    // MARK: - 展示辅助

    enum LatencySource {
        case tunnel, probe

        var label: String {
            switch self {
            case .tunnel: return "代理时延（已连接）"
            case .probe: return "代理时延（未连接·进程内探针）"
            }
        }
    }

    /// 全部线路的平均时延与可用条数
    var latencyStats: LatencyStats {
        LatencyStats(delays: nodes.map(\.delay))
    }

    var latencySummary: String? {
        guard testedCount > 0 else { return nil }
        return latencyStats.summary
    }

    var usageText: String? { record?.userInfo?.usageText }
    var expireText: String? { record?.userInfo?.expireText }
    var nodeCountText: String { "\(nodes.count) 条线路" }
    var hasProfile: Bool { store?.hasProfile ?? false }
}
