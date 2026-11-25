import SwiftUI

enum PanelListDetailMetrics {
    static let listWidth: CGFloat = 248
}

struct PanelListDetail<ListContent: View, Detail: View>: View {
    var listWidth: CGFloat = PanelListDetailMetrics.listWidth
    @ViewBuilder var list: () -> ListContent
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            list()
                .frame(width: listWidth)
            Divider()
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
