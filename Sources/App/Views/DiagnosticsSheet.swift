import SwiftUI

/// 诊断日志：把 App Group 里的 `tunnel.log` 直接显示出来。
/// 有线排查时也可以直接从设备容器拉这个文件（见 quickstart 的排查一节）。
struct DiagnosticsSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if model.diagnosticsLog.isEmpty {
                        Text("暂无日志")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(model.diagnosticsLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("刷新") { model.refreshDiagnostics() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("一键拷贝全部日志") {
                        UIPasteboard.general.string = model.diagnosticsLog.joined(separator: "\n")
                        model.infoMessage = "日志已复制到剪贴板"
                    }
                    .disabled(model.diagnosticsLog.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { model.isShowingDiagnostics = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
