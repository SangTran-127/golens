import SwiftUI

struct SetupChecklistRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var wrapsDetail = true
    let accessibilityLabel: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.body)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(wrapsDetail ? 2 : 1)
                        .truncationMode(wrapsDetail ? .tail : .middle)
                        .fixedSize(horizontal: false, vertical: wrapsDetail)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            Spacer(minLength: Spacing.standard)
            accessory()
        }
    }
}

extension SetupChecklistRow where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: String, detail: String, wrapsDetail: Bool = true, accessibilityLabel: String) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, wrapsDetail: wrapsDetail, accessibilityLabel: accessibilityLabel) { EmptyView() }
    }
}
