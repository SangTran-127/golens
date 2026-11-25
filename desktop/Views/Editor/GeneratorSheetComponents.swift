import AppKit
import SwiftUI

struct HighlightedCodeText: View {
    let code: String
    var path = "preview.go"
    @Environment(\.colorScheme) private var colorScheme

    init(_ code: String, path: String = "preview.go") {
        self.code = code
        self.path = path
    }

    var body: some View {
        Text(Self.attributed(code, path: path, isDark: colorScheme == .dark))
    }

    static func attributed(_ code: String, path: String = "preview.go", isDark: Bool) -> AttributedString {
        let theme = WorkspaceState.shared.currentTheme
        var result = AttributedString(code)
        result.foregroundColor = Color(theme.textColor(isDark: isDark))
        let length = (code as NSString).length
        let colors = SyntaxHighlighter(path: path).attributes(for: NSTextStorage(string: code), isDark: isDark, theme: theme, in: NSRange(location: 0, length: length))
        for (range, color) in colors where NSMaxRange(range) <= length {
            guard let r = Range(range, in: code), let ar = Range(r, in: result) else { continue }
            result[ar].foregroundColor = Color(color)
        }
        return result
    }
}

struct GeneratorCodePreview: View {
    let code: String
    var placeholder: String = ""
    let accessibilityLabel: String
    var path = "preview.go"
    var copyHelp = "Copy generated Go code to clipboard"
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if code.isEmpty {
                    Text(placeholder.isEmpty ? "No preview available." : placeholder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(Spacing.comfortable)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        HighlightedCodeText(code, path: path)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(Spacing.comfortable)
                            .accessibilityLabel(accessibilityLabel)
                    }
                    .defaultScrollAnchor(.topLeading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)

            if !code.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(Spacing.standard)
                .help(copyHelp)
                .accessibilityLabel(didCopy ? "Copied generated code" : "Copy generated code")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }
}

struct GeneratorOptionToggle: View {
    let title: String
    var detail: String = ""
    @Binding var isOn: Bool
    var accessibilityLabel: String = ""

    var body: some View {
        Toggle(isOn: $isOn) {
            if detail.isEmpty {
                Text(title)
            } else {
                Text(title) + Text("  \(detail)").foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(accessibilityLabel.isEmpty ? title : accessibilityLabel)
    }
}

struct GeneratorSheet<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    let primaryTitle: String
    let primaryAccessibilityLabel: String
    let primaryAccessibilityIdentifier: String
    let primaryHelp: String
    let cancelAccessibilityLabel: String
    let cancelAccessibilityIdentifier: String
    let canConfirm: Bool
    let isUpdating: Bool
    let errorMessage: String
    let footnote: String
    let preview: GeneratorCodePreview?
    let previewDetail: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let content: Content
    let accessory: Accessory

    init(
        title: String,
        subtitle: String,
        primaryTitle: String,
        primaryAccessibilityLabel: String = "",
        primaryAccessibilityIdentifier: String = "",
        primaryHelp: String = "",
        cancelAccessibilityLabel: String = "",
        cancelAccessibilityIdentifier: String = "",
        canConfirm: Bool,
        isUpdating: Bool = false,
        errorMessage: String = "",
        footnote: String = "",
        preview: GeneratorCodePreview?,
        previewDetail: String = "",
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryAccessibilityLabel = primaryAccessibilityLabel.isEmpty ? primaryTitle : primaryAccessibilityLabel
        self.primaryAccessibilityIdentifier = primaryAccessibilityIdentifier
        self.primaryHelp = primaryHelp
        self.cancelAccessibilityIdentifier = cancelAccessibilityIdentifier
        self.cancelAccessibilityLabel = cancelAccessibilityLabel.isEmpty ? "Cancel" : cancelAccessibilityLabel
        self.canConfirm = canConfirm
        self.isUpdating = isUpdating
        self.errorMessage = errorMessage
        self.footnote = footnote
        self.preview = preview
        self.previewDetail = previewDetail
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            header
            content
            if let preview {
                previewSection(preview)
            } else {
                Spacer(minLength: 0)
            }
            footer
        }
        .padding(Spacing.section)
        .sheetFrame(SheetSize.generator)
        .onExitCommand(perform: onCancel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                accessory
                Spacer(minLength: 0)
                InspectorScanningIndicator(isScanning: isUpdating, label: "Updating…")
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previewSection(_ preview: GeneratorCodePreview) -> some View {
        GeneratorSection("Preview") {
            preview
        } trailing: {
            if !previewDetail.isEmpty {
                GeneratorDetail(previewDetail)
            }
        }
        .staleWhileScanning(isUpdating)
    }

    private var footer: some View {
        HStack(spacing: Spacing.standard) {
            if !errorMessage.isEmpty {
                GeneratorStatusMessage(errorMessage, tone: .failure)
                    .lineLimit(2)
            } else if !footnote.isEmpty {
                Text(footnote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(cancelAccessibilityLabel)
                .accessibilityIdentifier(cancelAccessibilityIdentifier)
            Button(primaryTitle, action: onConfirm)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
                .accessibilityLabel(primaryAccessibilityLabel)
                .accessibilityIdentifier(primaryAccessibilityIdentifier)
                .help(primaryHelp)
        }
    }
}

extension GeneratorSheet where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String,
        primaryTitle: String,
        primaryAccessibilityLabel: String = "",
        primaryAccessibilityIdentifier: String = "",
        primaryHelp: String = "",
        cancelAccessibilityLabel: String = "",
        cancelAccessibilityIdentifier: String = "",
        canConfirm: Bool,
        isUpdating: Bool = false,
        errorMessage: String = "",
        footnote: String = "",
        preview: GeneratorCodePreview?,
        previewDetail: String = "",
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            primaryTitle: primaryTitle,
            primaryAccessibilityLabel: primaryAccessibilityLabel,
            primaryAccessibilityIdentifier: primaryAccessibilityIdentifier,
            primaryHelp: primaryHelp,
            cancelAccessibilityLabel: cancelAccessibilityLabel,
            cancelAccessibilityIdentifier: cancelAccessibilityIdentifier,
            canConfirm: canConfirm,
            isUpdating: isUpdating,
            errorMessage: errorMessage,
            footnote: footnote,
            preview: preview,
            previewDetail: previewDetail,
            onCancel: onCancel,
            onConfirm: onConfirm,
            content: content,
            accessory: { EmptyView() }
        )
    }
}

struct GeneratorSection<Content: View, Trailing: View>: View {
    let title: String
    let content: Content
    let trailing: Trailing

    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            HStack(spacing: Spacing.standard) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                trailing
            }
            content
        }
    }
}

extension GeneratorSection where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, trailing: { EmptyView() })
    }
}

struct GeneratorDetail: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

struct GeneratorChip: View {
    let text: String
    var symbol: String?
    var isDimmed = false

    init(_ text: String, symbol: String? = nil, isDimmed: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.isDimmed = isDimmed
    }

    var body: some View {
        HStack(spacing: Spacing.row) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(isDimmed ? Color.secondary : Color(nsColor: .controlAccentColor))
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(isDimmed ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.compact)
        .wellBackground(cornerRadius: CornerRadius.control)
    }
}

struct GeneratorChipStrip<Content: View>: View {
    let isEmpty: Bool
    let emptyMessage: String
    let content: Content

    init(isEmpty: Bool, emptyMessage: String, @ViewBuilder content: () -> Content) {
        self.isEmpty = isEmpty
        self.emptyMessage = emptyMessage
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.standard) {
                if isEmpty {
                    GeneratorNote(emptyMessage)
                } else {
                    content
                }
            }
            .padding(.vertical, Spacing.hairline)
        }
    }
}

struct GeneratorNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneratorStatusMessage: View {
    let text: String
    let tone: StatusTone

    init(_ text: String, tone: StatusTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Label {
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: tone.symbol)
                .foregroundStyle(tone.tint)
        }
    }
}
