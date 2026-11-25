import SwiftUI

struct GitStatusBadge: View {
    let status: String
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let isDark = workspace.currentTheme.resolvedIsDark
        Group {
            if status == "U" {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
            } else {
                Text(Self.letter(for: status))
                    .font(.caption.weight(.semibold).monospaced())
            }
        }
        .rowTint(Self.color(for: status, workspace: workspace, isDark: isDark))
        .frame(minWidth: 12)
        .help(Self.name(for: status))
        .accessibilityLabel(Self.name(for: status))
    }

    static func letter(for status: String) -> String {
        status == "??" ? "?" : status
    }

    static func name(for status: String) -> String {
        switch status {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type Changed"
        case "U": return "Merge Conflict"
        case "??": return "Untracked"
        default: return status
        }
    }

    static func color(for status: String, workspace: WorkspaceState, isDark: Bool) -> Color {
        switch status {
        case "A", "??": return StatusTone.success.tint
        case "D", "U": return StatusTone.failure.tint
        default: return ThemeColor.textSecondary
        }
    }
}
