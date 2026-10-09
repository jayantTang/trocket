import SwiftUI

/// 一条线路：名称 + 延迟。延迟用颜色分级，未测/超时显示 `—`。
struct NodeRow: View {
    let node: NodeItem
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.5))
                .imageScale(.medium)

            Text(title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(node.delayText)
                .font(.footnote.monospacedDigit())
                .foregroundColor(color)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch node.quality {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        case .unknown: return .secondary
        }
    }
}
