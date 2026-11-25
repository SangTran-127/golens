import AppKit
import SwiftUI

enum CompletionLayout {
    static let nameInset: CGFloat = 30
    static let rowPadding: CGFloat = 4
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 640
    static let footerWidthPadding: CGFloat = 20

    static func rowHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 6
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func nameWidth(_ row: CompletionRow, font: NSFont) -> CGFloat {
        let bold = TechnicalTypography.codeCanvasNSFont(size: font.pointSize, weight: .bold)
        let name = NSMutableAttributedString(string: row.label + (row.params ?? ""), attributes: [.font: font])
        let label = row.label as NSString
        for p in row.m ?? [] where p < label.length {
            name.addAttribute(.font, value: bold, range: NSRange(location: p, length: 1))
        }
        return ceil(name.size().width)
    }

    static func size(rows: [CompletionRow], doc: CompletionDocInfo?, font: NSFont) -> NSSize {
        let small = TechnicalTypography.codeCanvasNSFont(size: font.pointSize - 1, weight: .regular)
        var widest: CGFloat = 0
        for row in rows.prefix(CompletionController.maxVisibleRows + 2) {
            let name = nameWidth(row, font: font)
            var tail = textWidth(row.type ?? "", font: small)
            if let pkg = row.pkg, !pkg.isEmpty {
                tail += textWidth(pkg, font: small) + 6
            }
            widest = max(widest, name + tail)
        }
        let chrome = nameInset + 6 + 12 + 6 + 10 + 12
        let width = min(maxWidth, max(minWidth, ceil(widest + chrome)))
        var height = rows.isEmpty ? 0 : CGFloat(min(rows.count, CompletionController.maxVisibleRows)) * rowHeight(font) + rowPadding * 2
        if let doc, !doc.doc.isEmpty || !doc.signature.isEmpty {
            height += footerHeight(doc, width: width, font: font)
        }
        return NSSize(width: width, height: ceil(height))
    }

    static func footerHeight(_ doc: CompletionDocInfo, width: CGFloat, font: NSFont) -> CGFloat {
        let inner = width - footerWidthPadding
        var h: CGFloat = 13
        if !doc.signature.isEmpty {
            let sig = (doc.signature as NSString).boundingRect(with: NSSize(width: inner, height: 60), options: [.usesLineFragmentOrigin], attributes: [.font: TechnicalTypography.codeCanvasNSFont(size: font.pointSize - 1, weight: .regular)])
            h += min(ceil(sig.height), 48) + 4
        }
        if !doc.doc.isEmpty {
            let body = (doc.doc as NSString).boundingRect(with: NSSize(width: inner, height: 200), options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
            h += min(ceil(body.height), 64)
        }
        return h
    }
}

final class CompletionPanel: NSPanel {
    static let cornerRadius: CGFloat = 8
    private let host = NSHostingView(rootView: CompletionListView())
    private var lastAppliedThemeId: String = ""
    private var lastReduceTransparency: Bool = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        hidesOnDeactivate = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        host.sizingOptions = []
        host.safeAreaRegions = []
        updateBackground()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateBackground()
        }
        setAccessibilityLabel("Completions")
    }

    func syncThemeAppearance() {
        let theme = CompletionController.shared.ws.currentTheme
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if lastAppliedThemeId != theme.id || lastReduceTransparency != reduce {
            updateBackground()
        }
    }

    private func updateBackground() {
        let theme = CompletionController.shared.ws.currentTheme
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        lastAppliedThemeId = theme.id
        lastReduceTransparency = reduce
        host.removeFromSuperview()
        if reduce {
            let box = NSBox()
            box.boxType = .custom
            box.titlePosition = .noTitle
            host.translatesAutoresizingMaskIntoConstraints = true
            box.fillColor = .windowBackgroundColor
            box.borderColor = .separatorColor
            box.borderWidth = 1
            box.cornerRadius = Self.cornerRadius
            box.contentViewMargins = .zero
            box.contentView = host
            contentView = box
        } else {
            host.translatesAutoresizingMaskIntoConstraints = true
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = host
            contentView = glass
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct CompletionListView: View {
    @Bindable private var controller = CompletionController.shared
    private var workspace: WorkspaceState { controller.ws }

    private var codeFont: NSFont { TechnicalTypography.codeCanvasNSFont(size: workspace.editorFontSize, weight: .regular) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !controller.rows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(controller.rows.enumerated()), id: \.element.id) { index, row in
                                Button {
                                    if let tv = workspace.activeTextView as? GoLensTextView {
                                        controller.commit(index, in: tv)
                                    }
                                } label: {
                                    CompletionRowView(row: row, isSelected: index == controller.selected, font: codeFont, theme: workspace.currentTheme, isDark: workspace.currentTheme.resolvedIsDark)
                                        .frame(height: CompletionLayout.rowHeight(codeFont))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .onContinuousHover { phase in
                                    if case .active = phase, index != controller.selected {
                                        PopupMouseTracker.performHoverSelect {
                                            controller.select(index)
                                        }
                                    }
                                }
                                .id(row.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel([row.label, row.kind, row.type ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
                                .accessibilityValue("row \(index + 1) of \(controller.rows.count)")
                            }
                        }
                        .padding(.vertical, CompletionLayout.rowPadding)
                    }
                    .scrollIndicators(controller.rows.count > CompletionController.maxVisibleRows ? .automatic : .never)
                    .frame(height: CGFloat(min(controller.rows.count, CompletionController.maxVisibleRows)) * CompletionLayout.rowHeight(codeFont) + CompletionLayout.rowPadding * 2)
                    .onChange(of: controller.selected) { _, newValue in
                        guard !PopupMouseTracker.isHoverSelecting else { return }
                        if controller.rows.indices.contains(newValue) {
                            proxy.scrollTo(controller.rows[newValue].id)
                        }
                    }
                }
            }
            if let doc = controller.doc, !doc.doc.isEmpty || !doc.signature.isEmpty {
                if !controller.rows.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    if !doc.signature.isEmpty {
                        Text(doc.signature)
                            .font(Font(TechnicalTypography.codeCanvasNSFont(size: workspace.editorFontSize - 1, weight: .regular)))
                            .foregroundStyle(ThemeColor.textSecondary)
                            .lineLimit(3)
                    }
                    if !doc.doc.isEmpty {
                        Text(doc.doc)
                            .font(.body)
                            .foregroundStyle(ThemeColor.textPrimary)
                            .lineLimit(4)
                    }
                }
                .padding(.horizontal, Spacing.inset)
                .padding(.vertical, Spacing.row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct CompletionRowView: View {
    let row: CompletionRow
    let isSelected: Bool
    let font: NSFont
    let theme: Theme
    let isDark: Bool

    private var kindColor: Color {
        switch row.kind {
        case "func", "method": return Color(theme.functionColor(isDark: isDark))
        case "type", "struct", "interface": return Color(theme.typeColor(isDark: isDark))
        case "package": return Color(theme.namespaceColor(isDark: isDark))
        case "keyword", "snippet": return Color(theme.keywordColor(isDark: isDark))
        case "const": return Color(theme.numberColor(isDark: isDark))
        case "field": return Color(theme.propertyColor(isDark: isDark))
        default: return Color(theme.variableColor(isDark: isDark))
        }
    }

    private var glyph: String {
        switch row.kind {
        case "func": return "f"
        case "method": return "m"
        case "field": return "F"
        case "const": return "c"
        case "type": return "T"
        case "struct": return "S"
        case "interface": return "I"
        case "package": return "P"
        case "keyword": return "K"
        case "snippet": return "{}"
        default: return "v"
        }
    }

    private var name: AttributedString {
        var s = AttributedString(row.label)
        s.font = Font(font)
        let matched = Set(row.m ?? [])
        if !matched.isEmpty {
            let units = Array(row.label.utf16)
            var offset = 0
            for idx in s.characters.indices {
                let ch = s.characters[idx]
                let len = String(ch).utf16.count
                if matched.contains(offset) {
                    s[idx..<s.characters.index(after: idx)].font = Font(TechnicalTypography.codeCanvasNSFont(size: font.pointSize, weight: .bold))
                }
                offset += len
                if offset >= units.count { break }
            }
        }
        if row.dep == true {
            s.strikethroughStyle = .single
        }
        return s
    }

    var body: some View {
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        let primaryText = ThemeColor.textPrimary
        let secondaryText = ThemeColor.textSecondary
        let secondary: Color = isSelected ? selectedText : secondaryText
        let small = Font(TechnicalTypography.codeCanvasNSFont(size: font.pointSize - 1, weight: .regular))
        let rowShape = RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
        HStack(spacing: Spacing.row) {
            SymbolIconView(kind: row.kind, isSelected: isSelected, size: 16)
            HStack(spacing: 0) {
                Text(name).foregroundStyle(isSelected ? selectedText : primaryText)
                if let params = row.params {
                    Text(params).font(Font(font)).foregroundStyle(secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
            Spacer(minLength: 12)
            if let type = row.type, !type.isEmpty {
                Text(type).font(small).foregroundStyle(secondary).lineLimit(1)
            }
            if let pkg = row.pkg, !pkg.isEmpty {
                Text(pkg).font(small).foregroundStyle(isSelected ? AnyShapeStyle(selectedText) : AnyShapeStyle(secondaryText)).lineLimit(1)
            }
        }
        .padding(.leading, Spacing.standard)
        .padding(.trailing, Spacing.inset)
        .frame(maxHeight: .infinity)
        .background(
            rowShape
                .fill(isSelected ? ChromeColor.selection : .clear)
                .padding(.horizontal, Spacing.compact)
        )
    }
}
