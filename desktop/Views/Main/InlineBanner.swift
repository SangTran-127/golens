import SwiftUI

enum InlineBannerIcon {
    case status(StatusTone)
    case symbol(String, tone: StatusTone? = nil)
    case accent(String)

    var systemImage: String {
        switch self {
        case .status(let tone): tone.symbol
        case .symbol(let name, _), .accent(let name): name
        }
    }

    var tint: Color {
        switch self {
        case .status(let tone): tone.tint
        case .symbol(_, let tone): tone?.tint ?? ThemeColor.textSecondary
        case .accent: .accentColor
        }
    }
}

struct InlineBanner<Actions: View>: View {
    let icon: InlineBannerIcon
    let title: String
    let message: String?
    let detail: String?
    let onClose: (() -> Void)?
    let actions: Actions

    init(
        _ icon: InlineBannerIcon,
        title: String,
        message: String? = nil,
        detail: String? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.detail = detail
        self.onClose = onClose
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
            Image(systemName: icon.systemImage)
                .foregroundStyle(icon.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(detail)
                }
            }
            Spacer(minLength: Spacing.standard)
            actions
                .controlSize(.small)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ThemeColor.textSecondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.standard)
        .background(ThemeColor.panelSurface)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension InlineBanner where Actions == EmptyView {
    init(
        _ icon: InlineBannerIcon,
        title: String,
        message: String? = nil,
        detail: String? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.init(icon, title: title, message: message, detail: detail, onClose: onClose) {
            EmptyView()
        }
    }
}
