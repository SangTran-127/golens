import SwiftUI

enum FileIconSize {
    static let compact: CGFloat = 14
    static let regular: CGFloat = 16
    static let prominent: CGFloat = 20
}

struct FileIconView: View {
    @Environment(\.windowWorkspace) private var workspace
    let fileName: String
    var path: String? = nil
    var isFolder = false
    var isExpanded = false
    var childNames: [String]? = nil
    let isSelected: Bool
    var size: CGFloat = FileIconSize.regular
    var inMenuLabel = false

    @AppStorage(FileIconPalette.coloredKey) private var colored = true
    @AppStorage(ThemeManager.mascotCostumeKey) private var mascotCostume = "default"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.backgroundProminence) private var prominence
    @State private var resolved: (path: String, icon: FileIcon)?

    var body: some View {
        let root = workspace.activeWorkspacePath
        let theme = workspace.currentTheme
        let isDark = colorScheme == .dark
        let seasonal = ThemeManager.shared.resolvedSeasonalPack(themeId: theme.id, costume: mascotCostume)
        let fallback = FileIconResolver.shared.icon(name: fileName, path: path, root: root, isFolder: isFolder, isExpanded: isExpanded, childNames: childNames)
        let icon = resolved.flatMap { $0.path == path ? $0.icon : nil } ?? fallback.icon
        let multicolor = colored
            ? FileIconResolver.shared.colorImage(icon.name, seasonalPack: seasonal, dark: isDark, highContrast: contrast == .increased)
            : nil
        let template = FileIconResolver.shared.image(icon.name)
        (multicolor.map { Image(nsImage: $0).renderingMode(.original) }
            ?? (inMenuLabel ? Image(nsImage: Self.tinted(template, tint(for: icon) ?? .secondaryLabelColor)).renderingMode(.original)
                : Image(nsImage: template).renderingMode(.template)))
            .resizable()
            .frame(width: size, height: size)
            .foregroundStyle(style(for: icon))
            .accessibilityHidden(true)
            .task(id: TaskKey(path: path, isExpanded: isExpanded, needsIO: fallback.needsIO)) {
                guard fallback.needsIO, let path else { return }
                let name = fileName, folder = isFolder, expanded = isExpanded
                let icon = await Task.detached(priority: .utility) {
                    FileIconResolver.shared.resolvedIcon(name: name, path: path, root: root, isFolder: folder, isExpanded: expanded)
                }.value
                resolved = (path, icon)
            }
    }

    private var onSelection: Bool { isSelected || prominence == .increased }

    private struct TaskKey: Hashable {
        let path: String?
        let isExpanded: Bool
        let needsIO: Bool
    }

    private func tint(for icon: FileIcon) -> NSColor? {
        if onSelection { return .alternateSelectedControlTextColor }
        guard colored else { return nil }
        let isDark = colorScheme == .dark
        let isHC = contrast == .increased
        if icon.palette == FileIconPalette.accentKey {
            return FileIconPalette.accent(.controlAccentColor, background: nil, dark: isDark, highContrast: isHC)
        }
        return FileIconPalette.color(for: icon.palette, dark: isDark, highContrast: isHC)
    }

    private func style(for icon: FileIcon) -> AnyShapeStyle {
        tint(for: icon).map { AnyShapeStyle(Color(nsColor: $0)) } ?? AnyShapeStyle(.secondary)
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
