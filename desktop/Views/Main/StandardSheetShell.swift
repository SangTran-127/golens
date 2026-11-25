import SwiftUI

struct StandardSheetShell<HeaderTrailing: View, FooterLeading: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var scopeBadge: String? = nil
    var size: SheetSize = .standard
    var primaryTitle: String? = nil
    var primaryAccessibilityLabel: String? = nil
    var isPrimaryDisabled: Bool = false
    var closeTitle: String = "Close"
    var closeAccessibilityLabel: String? = nil
    var onPrimary: (() -> Void)? = nil
    let onClose: () -> Void
    @ViewBuilder var headerTrailing: () -> HeaderTrailing
    @ViewBuilder var footerLeading: () -> FooterLeading
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        scopeBadge: String? = nil,
        size: SheetSize = .standard,
        primaryTitle: String? = nil,
        primaryAccessibilityLabel: String? = nil,
        isPrimaryDisabled: Bool = false,
        closeTitle: String = "Close",
        closeAccessibilityLabel: String? = nil,
        onPrimary: (() -> Void)? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder headerTrailing: @escaping () -> HeaderTrailing = { EmptyView() },
        @ViewBuilder footerLeading: @escaping () -> FooterLeading = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scopeBadge = scopeBadge
        self.size = size
        self.primaryTitle = primaryTitle
        self.primaryAccessibilityLabel = primaryAccessibilityLabel
        self.isPrimaryDisabled = isPrimaryDisabled
        self.closeTitle = closeTitle
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self.onPrimary = onPrimary
        self.onClose = onClose
        self.headerTrailing = headerTrailing
        self.footerLeading = footerLeading
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            HStack(alignment: .top, spacing: Spacing.comfortable) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    HStack(spacing: Spacing.standard) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(.isHeader)

                        if let scopeBadge, !scopeBadge.isEmpty {
                            Text(scopeBadge)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, Spacing.row)
                                .padding(.vertical, Spacing.hairline)
                                .wellBackground(cornerRadius: CornerRadius.small)
                        }
                    }

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Spacing.standard)

                headerTrailing()
            }

            content()

            Divider()

            HStack(spacing: Spacing.standard) {
                footerLeading()

                Spacer(minLength: Spacing.standard)

                if let primaryTitle {
                    Button(closeTitle, role: .cancel, action: onClose)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(closeAccessibilityLabel ?? closeTitle)

                    Button(primaryTitle) {
                        onPrimary?()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isPrimaryDisabled)
                    .accessibilityLabel(primaryAccessibilityLabel ?? primaryTitle)
                } else {
                    Button(closeTitle, action: onClose)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(closeAccessibilityLabel ?? closeTitle)
                }
            }
        }
        .padding(Spacing.section)
        .sheetFrame(size)
        .onExitCommand(perform: onClose)
    }
}
