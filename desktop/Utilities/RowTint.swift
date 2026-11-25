import SwiftUI

private struct RowTint: ViewModifier {
    let color: Color
    @Environment(\.backgroundProminence) private var prominence

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color(nsColor: .alternateSelectedControlTextColor) : color)
    }
}

extension View {
    func rowTint(_ color: Color) -> some View {
        modifier(RowTint(color: color))
    }
}
