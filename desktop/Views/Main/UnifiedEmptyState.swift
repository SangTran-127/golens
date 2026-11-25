import SwiftUI

struct UnifiedEmptyState: View {
    enum StateKind {
        case empty(
            symbol: String,
            badge: String? = nil,
            title: String,
            message: String,
            actionTitle: String? = nil,
            action: (() -> Void)? = nil,
            secondaryActionTitle: String? = nil,
            secondaryAction: (() -> Void)? = nil
        )
        case filteredEmpty(itemNoun: String, onReset: () -> Void)
        case loading(message: String)
        case failed(title: String, message: String, recoveryTitle: String? = nil, recovery: (() -> Void)? = nil, onRetry: () -> Void)
    }

    let state: StateKind

    init(_ state: StateKind) {
        self.state = state
    }

    static func empty(
        symbol: String,
        badge: String? = nil,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> UnifiedEmptyState {
        UnifiedEmptyState(
            .empty(
                symbol: symbol,
                badge: badge,
                title: title,
                message: message,
                actionTitle: actionTitle,
                action: action,
                secondaryActionTitle: secondaryActionTitle,
                secondaryAction: secondaryAction
            )
        )
    }

    static func filteredEmpty(itemNoun: String, onReset: @escaping () -> Void) -> UnifiedEmptyState {
        UnifiedEmptyState(.filteredEmpty(itemNoun: itemNoun, onReset: onReset))
    }

    static func loading(message: String) -> UnifiedEmptyState {
        UnifiedEmptyState(.loading(message: message))
    }

    static func failed(
        title: String,
        message: String,
        recoveryTitle: String? = nil,
        recovery: (() -> Void)? = nil,
        onRetry: @escaping () -> Void
    ) -> UnifiedEmptyState {
        UnifiedEmptyState(.failed(title: title, message: message, recoveryTitle: recoveryTitle, recovery: recovery, onRetry: onRetry))
    }

    var body: some View {
        VStack(spacing: Spacing.standard) {
            switch state {
            case let .empty(symbol, badge, title, message, actionTitle, action, secondaryActionTitle, secondaryAction):
                if let badge {
                    EmptyStateBadgeView(badge: badge, size: 32)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(ChromeColor.textTertiary)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ChromeColor.textPrimary)
                    .multilineTextAlignment(.center)

                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(ChromeColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                if actionTitle != nil || secondaryActionTitle != nil {
                    HStack(spacing: Spacing.standard) {
                        if let actionTitle, let action {
                            Button(actionTitle, action: action)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        if let secondaryActionTitle, let secondaryAction {
                            Button(secondaryActionTitle, action: secondaryAction)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, Spacing.compact)
                }

            case let .filteredEmpty(itemNoun, onReset):
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
                    .foregroundStyle(ChromeColor.textTertiary)
                    .accessibilityHidden(true)

                Text("No Matching \(itemNoun)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ChromeColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text("Adjust or clear the active filters to show all \(itemNoun.lowercased()).")
                    .font(.subheadline)
                    .foregroundStyle(ChromeColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)

                Button("Reset Filters", action: onReset)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, Spacing.compact)

            case let .loading(message):
                ProgressView()
                    .controlSize(.small)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(ChromeColor.textSecondary)
                    .multilineTextAlignment(.center)

            case let .failed(title, message, recoveryTitle, recovery, onRetry):
                Image(systemName: StatusTone.warning.symbol)
                    .font(.title2)
                    .foregroundStyle(StatusTone.warning.tint)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ChromeColor.textPrimary)
                    .multilineTextAlignment(.center)

                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(ChromeColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                HStack(spacing: Spacing.standard) {
                    if let recoveryTitle, let recovery {
                        Button(recoveryTitle, action: recovery)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, Spacing.compact)
            }
        }
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
