import SwiftUI

/// 订阅抽屉：粘贴链接 → 导入。失败原因直接显示在这里。
struct SubscriptionSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("订阅链接")) {
                    TextField("https://…/link/…", text: $model.subscriptionURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

                Section(footer: Text("链接本身等同账号凭证：只保存在本机，不会上传到任何第三方。")) {
                    Button {
                        Task { await model.importSubscription() }
                    } label: {
                        HStack {
                            if model.isImporting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(model.isImporting ? "正在导入…" : "导入")
                        }
                    }
                    .disabled(model.subscriptionURL.isEmpty || model.isImporting)
                }

                if let record = model.record {
                    Section(header: Text("当前订阅")) {
                        LabeledContentCompat(title: "线路数", value: "\(record.nodeCount)")
                        if let usage = record.userInfo?.usageText {
                            LabeledContentCompat(title: "已用", value: usage)
                        }
                        if let expire = record.userInfo?.expireText {
                            LabeledContentCompat(title: "到期", value: expire)
                        }
                        LabeledContentCompat(
                            title: "导入时间",
                            value: DateFormat.day.string(from: record.importedAt)
                        )
                    }
                }
            }
            .navigationTitle("订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { isPresented = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// iOS 15 兼容的键值行（`LabeledContent` 需要 iOS 16）。
struct LabeledContentCompat: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}
