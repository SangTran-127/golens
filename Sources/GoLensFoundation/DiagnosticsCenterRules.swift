import Foundation

public enum DiagnosticsIssueCategory: Equatable, Sendable {
    case issue
    case safety
    case complexity(rating: String)
    case todo
    case bookmark
    case breakpoint
}

public enum DiagnosticsScopeFilterKind: Equatable, Sendable {
    case all
    case errors
    case warnings
    case safety
    case todos
    case bookmarks
    case breakpoints
}

public enum DiagnosticsCenterRules {
    public static let onAppearWorkspaceCooldown: TimeInterval = 8.0
    public static let saveWorkspaceCooldown: TimeInterval = 15.0

    public static func shouldIncludeComplexityInIssues(rating: String) -> Bool {
        rating.lowercased() == "high"
    }

    public static func shouldThrottleWorkspaceRefresh(
        activeWorkspace: String,
        lastWorkspace: String,
        now: TimeInterval,
        lastTimestamp: TimeInterval,
        cooldown: TimeInterval
    ) -> Bool {
        guard !activeWorkspace.isEmpty, activeWorkspace == lastWorkspace else {
            return false
        }
        return (now - lastTimestamp) < cooldown
    }

    public static func matchesScope(
        category: DiagnosticsIssueCategory,
        severity: Int,
        scope: DiagnosticsScopeFilterKind
    ) -> Bool {
        switch scope {
        case .all:
            switch category {
            case .todo, .bookmark, .breakpoint:
                return false
            case .complexity(let rating):
                return shouldIncludeComplexityInIssues(rating: rating)
            case .issue, .safety:
                return true
            }
        case .errors:
            switch category {
            case .todo, .bookmark, .breakpoint, .complexity:
                return false
            case .issue, .safety:
                return severity == 1
            }
        case .warnings:
            switch category {
            case .todo, .bookmark, .breakpoint:
                return false
            case .complexity(let rating):
                return shouldIncludeComplexityInIssues(rating: rating) && severity == 2
            case .issue, .safety:
                return severity == 2
            }
        case .safety:
            return category == .safety
        case .todos:
            return category == .todo
        case .bookmarks:
            return category == .bookmark
        case .breakpoints:
            return category == .breakpoint
        }
    }
}
