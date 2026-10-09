import SwiftUI

/// 单屏界面：顶部状态卡 → 线路列表 → 底部连接开关。
/// 只有这一个界面（宪法第 II 条：单屏四件事）。
struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var showingSubscription = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                StatusHeader(model: model, tunnel: model.tunnel)
                Divider()
                nodeList
                Divider()
                ConnectBar(model: model, tunnel: model.tunnel)
            }
            .navigationTitle("Trocket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showingSubscription) {
                SubscriptionSheet(model: model, isPresented: $showingSubscription)
            }
            .sheet(isPresented: $model.isShowingDiagnostics) {
                DiagnosticsSheet(model: model)
            }
            // 只用一个 alert：同一视图挂两个 alert 在新旧系统上表现不一致
            .alert("提示", isPresented: messageBinding) {
                Button("知道了", role: .cancel) { model.clearMessages() }
            } message: {
                Text(model.currentMessage ?? "")
            }
            .onAppear { model.refreshTunnelState() }
        }
        .navigationViewStyle(.stack)
    }

    private var nodeList: some View {
        List {
            ForEach(model.nodes) { node in
                NodeRow(
                    node: node,
                    title: model.displayName(for: node.tag),
                    isSelected: node.tag == model.selectedTag
                )
                .contentShape(Rectangle())
                .onTapGesture { model.selectNode(node.tag) }
            }
        }
        .listStyle(.plain)
        .overlay(emptyState)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.nodes.isEmpty {
            VStack(spacing: 12) {
                Image("KittyIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .pink.opacity(0.25), radius: 10, y: 4)
                Text(model.hasProfile ? "尚未解析出线路" : "还没有订阅")
                    .font(.headline)
                Text("粘贴订阅链接后即可选择线路并连接")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("粘贴订阅链接") { showingSubscription = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Menu {
                Button("订阅…") { showingSubscription = true }
                Button("诊断日志…") {
                    model.refreshDiagnostics()
                    model.isShowingDiagnostics = true
                }
            } label: {
                Text("菜单")
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if model.isTesting {
                Button("停止") { model.cancelLatencyTest() }
            } else {
                Button("测速") { model.startLatencyTest() }
                    .disabled(model.nodes.isEmpty)
            }
            Button(model.sortByLatency ? "排序 ✓" : "排序") { model.toggleSort() }
                .disabled(model.nodes.isEmpty)
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(
            get: { model.currentMessage != nil },
            set: { if !$0 { model.clearMessages() } }
        )
    }
}

/// 顶部状态卡：连接状态、流量、订阅用量与到期，以及测速进度。
struct StatusHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tunnel: TunnelController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image("KittyIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Circle()
                    .fill(tunnel.state.isConnected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(model.statusText)
                    .font(.headline)
                Spacer()
                if model.isTesting {
                    Text("测速 \(model.testedCount)/\(model.totalCount)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text(model.nodeCountText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            if let traffic = trafficText {
                Text(traffic)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let summary = model.latencySummary {
                Text("\(summary) · \(model.latencySource.label)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let usage = model.usageText {
                HStack(spacing: 12) {
                    Text("已用 \(usage)")
                    if let expire = model.expireText {
                        Text("到期 \(expire)")
                    }
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// 已连接时显示内核上报的累计流量（关闭时显示系统状态里的数据）。
    private var trafficText: String? {
        if model.channel.upload > 0 || model.channel.download > 0 {
            return "↑ \(ByteFormat.human(model.channel.upload)) · ↓ \(ByteFormat.human(model.channel.download))"
        }
        return tunnel.state.trafficText
    }
}

/// 底部连接开关。开关位置来自系统实际状态。
struct ConnectBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tunnel: TunnelController

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tunnel.state.toggleIsOn ? "已开启" : "未开启")
                    .font(.headline)
                Text("切换后立即生效，无需断开")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Toggle("连接", isOn: Binding(
                get: { tunnel.state.toggleIsOn },
                set: { _ in model.toggleConnection() }
            ))
            .labelsHidden()
            .disabled(!model.canToggleConnection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
