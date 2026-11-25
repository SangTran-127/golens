import SwiftUI
import AppKit

struct SymbolIconView: View {
    let icon: SymbolIcon
    let isSelected: Bool
    var size: CGFloat = 16
    var inMenuLabel: Bool = false

    @AppStorage(FileIconPalette.coloredKey) private var colored = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.backgroundProminence) private var prominence

    init(kind: String, isSelected: Bool, size: CGFloat = 16, inMenuLabel: Bool = false) {
        self.icon = SymbolIconResolver.shared.icon(forKind: kind)
        self.isSelected = isSelected
        self.size = size
        self.inMenuLabel = inMenuLabel
    }

    init(lspKind: Int, fallbackModeIsCall: Bool = false, isSelected: Bool, size: CGFloat = 16, inMenuLabel: Bool = false) {
        self.icon = SymbolIconResolver.shared.icon(forLSPKind: lspKind, fallbackModeIsCall: fallbackModeIsCall)
        self.isSelected = isSelected
        self.size = size
        self.inMenuLabel = inMenuLabel
    }

    var body: some View {
        let template = SymbolIconResolver.shared.image(icon.name)
        (inMenuLabel
            ? Image(nsImage: Self.tinted(template, tint ?? .secondaryLabelColor)).renderingMode(.original)
            : Image(nsImage: template).renderingMode(.template))
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(style)
            .accessibilityHidden(true)
    }

    private var onSelection: Bool { isSelected || prominence == .increased }

    private var tint: NSColor? {
        if onSelection { return .alternateSelectedControlTextColor }
        guard colored else { return nil }
        let isDark = colorScheme == .dark
        let isHC = contrast == .increased
        return FileIconPalette.color(for: icon.palette, dark: isDark, highContrast: isHC)
    }

    private var style: AnyShapeStyle {
        tint.map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(.secondary)
    }

    private static func tinted(_ template: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}

struct EmptyStateBadgeView: View {
    let badge: String
    var size: CGFloat = 32

    var body: some View {
        let secondary = SymbolIconResolver.shared.image("empty-\(badge)-secondary")
        let primary = SymbolIconResolver.shared.image("empty-\(badge)-primary")
        ZStack {
            Image(nsImage: secondary)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(.tertiary)
            Image(nsImage: primary)
                .renderingMode(.template)
                .resizable()
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
