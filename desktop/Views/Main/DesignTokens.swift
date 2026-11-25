import AppKit
import GoLensFoundation
import SwiftUI

enum CornerRadius {
    static let panel: CGFloat = 14
    static let panelRow: CGFloat = 6
    static let compactPanel: CGFloat = 8
    static let control: CGFloat = 6
    static let hud: CGFloat = 16
    static let sidebarPanel: CGFloat = 18
    static let small: CGFloat = 4
}

enum Spacing {
    static let hairline: CGFloat = 2
    static let compact: CGFloat = 4
    static let row: CGFloat = 6
    static let standard: CGFloat = 8
    static let inset: CGFloat = 10
    static let comfortable: CGFloat = 12
    static let section: CGFloat = 16
    static let content: CGFloat = 24
    static let hero: CGFloat = 32
    static let hudBottomOffset: CGFloat = 56
    static let welcomeHorizontal: CGFloat = 64
}

enum Stroke {
    static let hairline: CGFloat = 0.5
    static let standard: CGFloat = 1
}

enum FinderPopup {
    static let topInset: CGFloat = 96
}

enum ToolbarLayout {
    static let titleHardMinWidth: CGFloat = ToolbarClusterMetrics.titleHardMinWidth
    static let titleCompactMinWidth: CGFloat = ToolbarClusterMetrics.titleCompactMinWidth
    static let titleMaxWidth: CGFloat = ToolbarClusterMetrics.titleMaxWidthCap
    static let activityPillMinWidth: CGFloat = ToolbarClusterMetrics.pillMinWidth
    static let activityPillMaxWidth: CGFloat = ToolbarClusterMetrics.pillMaxWidthCap
    static let branchPopoverWidth: CGFloat = BranchPopoverLayoutMath.popoverWidth
    static let branchPopoverMinListHeight: CGFloat = BranchPopoverLayoutMath.minListHeight
    static let branchPopoverMaxListHeight: CGFloat = BranchPopoverLayoutMath.maxListHeight
}

enum WindowLayout {
    static let minWidth: CGFloat = WorkspaceColumnLayoutMath.minWindowWidth
    static let minHeight: CGFloat = WorkspaceColumnLayoutMath.minWindowHeight
    static let defaultWidth: CGFloat = WorkspaceColumnLayoutMath.defaultWindowWidth
    static let defaultHeight: CGFloat = WorkspaceColumnLayoutMath.defaultWindowHeight
    static let sidebarMinWidth: CGFloat = WorkspaceColumnLayoutMath.sidebarMinWidth
    static let sidebarIdealWidth: CGFloat = WorkspaceColumnLayoutMath.sidebarIdealWidth
    static let sidebarMaxWidth: CGFloat = WorkspaceColumnLayoutMath.sidebarMaxWidth
    static let editorMinWidth: CGFloat = WorkspaceColumnLayoutMath.editorMinWidth
    static let gopilotMinWidth: CGFloat = WorkspaceColumnLayoutMath.gopilotMinWidth
    static let gopilotIdealWidth: CGFloat = WorkspaceColumnLayoutMath.gopilotIdealWidth
    static let gopilotMaxWidth: CGFloat = WorkspaceColumnLayoutMath.gopilotMaxWidth
}

enum StatusTone {
    case success, warning, failure, inactive, info

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        case .inactive: "minus.circle"
        case .info: "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .success: .green
        case .warning: .orange
        case .failure: .red
        case .inactive, .info: .secondary
        }
    }

    var fill: Color { ThemeColor.tintFill(tint) }
}

enum GitGraphStyle {
    static let laneWidth: CGFloat = Spacing.comfortable
    static let nodeDiameter: CGFloat = Spacing.standard
    static let lineWidth: CGFloat = 1.5
    static let maxVisibleLanes = 12
    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemPink, .systemIndigo, .systemBrown, .systemCyan, .systemMint]

    static func laneColor(_ index: Int) -> Color {
        Color(nsColor: palette[index % palette.count])
    }
}

enum MergeConflictStyle {
    static let leftNSColor: NSColor = .systemTeal
    static let rightNSColor: NSColor = .systemIndigo
    static var left: Color { Color(nsColor: leftNSColor) }
    static var right: Color { Color(nsColor: rightNSColor) }
    static let tintOpacity: Double = 0.16
}

enum ChromeColor {
    static var textPrimary: Color { .primary }
    static var textSecondary: Color { .secondary }
    static var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    static var accent: Color { .accentColor }
    static var selection: Color { Color(nsColor: .selectedContentBackgroundColor) }
    static var selectedText: Color { Color(nsColor: .alternateSelectedControlTextColor) }
    static var selectedSecondaryText: Color { Color(nsColor: .alternateSelectedControlTextColor).opacity(0.82) }
    static var hover: Color { Color(nsColor: .quaternarySystemFill) }
    static var separator: Color { Color(nsColor: .separatorColor) }
    static var panelSurface: Color { Color(nsColor: .controlBackgroundColor) }
}

enum CodeSurfaceTheme {
    private static var theme: Theme { WorkspaceState.shared.currentTheme }
    static var isDark: Bool { theme.resolvedIsDark }
    private static var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }

    static var nsBackground: NSColor { theme.codeBackgroundNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsTextPrimary: NSColor { theme.codeTextPrimaryNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsTextSecondary: NSColor { theme.codeTextSecondaryNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsLineNumber: NSColor { theme.codeLineNumberNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsCurrentLineFill: NSColor { theme.codeCurrentLineFillNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsIndentGuide: NSColor { theme.codeIndentGuideNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsLensMarginBackground: NSColor { theme.codeLensMarginBackgroundNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsLensDivider: NSColor { theme.codeLensDividerNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsLensActionText: NSColor { theme.codeLensActionTextNSColor(isDark: isDark, highContrast: highContrast) }
    static var nsLensMetadataText: NSColor { theme.codeLensMetadataTextNSColor(isDark: isDark, highContrast: highContrast) }

    static var background: Color {
        theme.id == "xcode"
            ? Color(nsColor: .textBackgroundColor)
            : Color(nsColor: nsBackground)
    }
    static var textPrimary: Color { Color(nsColor: nsTextPrimary) }
    static var textSecondary: Color { Color(nsColor: nsTextSecondary) }
    static var lineNumber: Color { Color(nsColor: nsLineNumber) }
    static var currentLineFill: Color { Color(nsColor: theme.codeCurrentLineFillNSColor(isDark: isDark, highContrast: highContrast)) }
    static var indentGuide: Color { Color(nsColor: theme.codeIndentGuideNSColor(isDark: isDark, highContrast: highContrast)) }
    static var lensMarginBackground: Color { Color(nsColor: theme.codeLensMarginBackgroundNSColor(isDark: isDark, highContrast: highContrast)) }
    static var lensDivider: Color { Color(nsColor: theme.codeLensDividerNSColor(isDark: isDark, highContrast: highContrast)) }
    static var lensActionText: Color { Color(nsColor: theme.codeLensActionTextNSColor(isDark: isDark, highContrast: highContrast)) }
    static var lensMetadataText: Color { Color(nsColor: theme.codeLensMetadataTextNSColor(isDark: isDark, highContrast: highContrast)) }
}

enum TechnicalTypography {
    nonisolated(unsafe) private static let monospacedFonts: NSCache<NSString, NSFont> = {
        let cache = NSCache<NSString, NSFont>()
        cache.countLimit = 64
        return cache
    }()
    private static let monospacedFontAttempts = 4

    static func codeCanvas(size: CGFloat) -> Font {
        Font(codeCanvasNSFont(size: size))
    }

    static func codeCanvasNSFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let key = "\(size)-\(weight.rawValue)" as NSString
        if let cached = monospacedFonts.object(forKey: key) { return cached }
        for _ in 0..<monospacedFontAttempts {
            let created: NSFont? = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            if let created {
                monospacedFonts.setObject(created, forKey: key)
                return created
            }
        }
        return NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func lensRail(size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(codeCanvasNSFont(size: max(10, size - 2), weight: weight))
    }

    static var codeCompact: Font { .subheadline.monospaced() }
    static var metricMono: Font { .caption.monospacedDigit() }
    static var badgeMicro: Font { .caption2.weight(.medium) }
}

enum DataVizTone {
    static func heatFill(fraction: Double, isDark: Bool) -> Color {
        DataVizPalette.heatFill(fraction: fraction, isDark: isDark)
    }

    static func heatStroke(fraction: Double, isDark: Bool) -> Color {
        DataVizPalette.heatStroke(fraction: fraction, isDark: isDark)
    }

    enum TraceStateKind: String, CaseIterable {
        case running
        case runnable
        case syscall
        case blocked
        case gc

        func color(isDark: Bool) -> Color {
            DataVizPalette.traceStateColor(rawValue, isDark: isDark)
        }

        var shortCode: String {
            switch self {
            case .running: "RUN"
            case .runnable: "RDY"
            case .syscall: "SYS"
            case .blocked: "WAIT"
            case .gc: "GC"
            }
        }

        var label: String {
            switch self {
            case .running: "Running"
            case .runnable: "Runnable"
            case .syscall: "Syscall"
            case .blocked: "Waiting"
            case .gc: "GC"
            }
        }
    }
}

enum ThemeColor {
    static var textPrimary: Color { ChromeColor.textPrimary }
    static var textSecondary: Color { ChromeColor.textSecondary }
    static var textTertiary: Color { ChromeColor.textTertiary }

    static var editorSurface: Color { CodeSurfaceTheme.background }
    static var contentSurface: Color { Color(nsColor: .textBackgroundColor) }
    static var panelSurface: Color { ChromeColor.panelSurface }

    static var accent: Color { ChromeColor.accent }
    static var selection: Color { ChromeColor.selection }
    static var hover: Color { ChromeColor.hover }
    static var separator: Color { ChromeColor.separator }

    static let wellFill = Color.primary.opacity(0.045)
    static let wellStroke = Color.primary.opacity(0.08)
    static func tintFill(_ color: Color) -> Color { color.opacity(0.14) }
}

enum Motion {
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static var quick: Animation? { reducesMotion ? nil : .smooth(duration: 0.15) }
    static var standard: Animation? { reducesMotion ? nil : .snappy(duration: 0.22, extraBounce: 0) }
    static var emphasized: Animation? { reducesMotion ? nil : .smooth(duration: 0.3) }
}

struct SheetSize {
    let minWidth: CGFloat?
    let idealWidth: CGFloat?
    let maxWidth: CGFloat?
    let minHeight: CGFloat?
    let idealHeight: CGFloat?
    let maxHeight: CGFloat?
    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?

    init(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        fixedWidth: CGFloat? = nil,
        fixedHeight: CGFloat? = nil
    ) {
        self.minWidth = minWidth
        self.idealWidth = idealWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.idealHeight = idealHeight
        self.maxHeight = maxHeight
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
    }

    static let compact = SheetSize(fixedWidth: 440)
    static let standard = SheetSize(fixedWidth: 520)
    static let medium = SheetSize(fixedWidth: 560)
    static let standardTall = SheetSize(fixedWidth: 560, fixedHeight: 440)
    static let comparison = SheetSize(fixedWidth: 640)
    static let settings = SheetSize(fixedWidth: 720)
    static let keymapImport = SheetSize(fixedWidth: 520, fixedHeight: 440)
    static let valueInspector = SheetSize(fixedWidth: 540, fixedHeight: 380)
    static let httpExerciser = SheetSize(fixedWidth: 540, fixedHeight: 560)
    static let recovery = SheetSize(minWidth: 520, minHeight: 360)
    static let valueInspectorContent = SheetSize(
        minWidth: 460,
        idealWidth: 540,
        minHeight: 260,
        idealHeight: 320
    )
    static let review = SheetSize(
        minWidth: 560,
        idealWidth: 640,
        minHeight: 420,
        idealHeight: 560
    )
    static let wide = SheetSize(
        minWidth: 620,
        idealWidth: 660,
        maxWidth: 860,
        minHeight: 400,
        idealHeight: 460,
        maxHeight: 700
    )
    static let inspector = SheetSize(
        minWidth: 660,
        idealWidth: 700,
        maxWidth: 960,
        minHeight: 440,
        idealHeight: 500,
        maxHeight: 760
    )
    static let multiBuffer = SheetSize(
        minWidth: 700,
        idealWidth: 850,
        minHeight: 450,
        idealHeight: 650
    )
    static let splitInspector = SheetSize(
        minWidth: 760,
        idealWidth: 860,
        maxWidth: .infinity,
        minHeight: 480,
        idealHeight: 560,
        maxHeight: .infinity
    )
    static let generator = SheetSize(
        minWidth: 680,
        idealWidth: 720,
        maxWidth: 920,
        minHeight: 440,
        idealHeight: 500,
        maxHeight: 720
    )
    static let runConfigurations = SheetSize(
        minWidth: 760,
        idealWidth: 840,
        maxWidth: 1200,
        minHeight: 560,
        idealHeight: 680,
        maxHeight: 1000
    )
}

enum WelcomeLayout {
    static let introWidth: CGFloat = 440
    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 480
    static let cloneSheetWidth: CGFloat = 460
}

enum OccurrenceHighlight {
    static var read: NSColor { NSColor.selectedTextBackgroundColor.withAlphaComponent(0.28) }
    static var write: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.22) }
    static var edited: NSColor { NSColor.controlAccentColor }
}

enum PopupWidth: CGFloat {
    case hover = 400
    case compact = 420
    case standard = 500
    case medium = 520
    case wide = 560

    static func omniFinder(in windowWidth: CGFloat) -> CGFloat {
        guard windowWidth > 0 else { return wide.rawValue }
        return min(wide.rawValue, max(360, windowWidth - 32))
    }
}

extension View {
    func sheetFrame(_ size: CGSize) -> some View {
        frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    func sheetFrame(_ size: SheetSize) -> some View {
        if let fixedWidth = size.fixedWidth, let fixedHeight = size.fixedHeight {
            frame(width: fixedWidth, height: fixedHeight)
        } else if let fixedWidth = size.fixedWidth {
            frame(width: fixedWidth)
        } else {
            frame(
                minWidth: size.minWidth,
                idealWidth: size.idealWidth,
                maxWidth: size.maxWidth,
                minHeight: size.minHeight,
                idealHeight: size.idealHeight,
                maxHeight: size.maxHeight
            )
        }
    }

    func popupWidth(_ width: PopupWidth, height: CGFloat? = nil) -> some View {
        frame(width: width.rawValue, height: height)
    }

    func omniFinderWidth(in windowWidth: CGFloat) -> some View {
        frame(width: PopupWidth.omniFinder(in: windowWidth))
    }

    func wellBackground(cornerRadius: CGFloat = CornerRadius.compactPanel) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(ThemeColor.wellFill))
            .overlay(shape.strokeBorder(ThemeColor.wellStroke, lineWidth: Stroke.hairline))
    }
}
