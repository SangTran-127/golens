import SwiftUI

struct ToolSetupChecklist: View {
    @Bindable var status = ToolSetupStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("Set Up Your Mac for Go")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("GoLens uses the Go tools installed on this Mac. Install the missing ones to build, debug and get completions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(ToolSetupStatus.Tool.allCases) { tool in
                let path = status.paths[tool]
                let tone: StatusTone = path == nil ? .warning : .success
                SetupChecklistRow(
                    symbol: tone.symbol,
                    tint: tone.tint,
                    title: tool.title,
                    detail: path ?? "Not installed · \(tool.purpose)",
                    wrapsDetail: path == nil,
                    accessibilityLabel: path == nil ? "\(tool.title), not installed" : "\(tool.title), installed"
                ) {
                    if path == nil {
                        actionButton(for: tool)
                    }
                }
            }

            if let failure = status.installFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Check Again") { status.check() }
                    .disabled(status.isChecking || status.installing != nil)
            }
        }
        .padding(Spacing.comfortable)
        .wellBackground()
    }

    @ViewBuilder
    private func actionButton(for tool: ToolSetupStatus.Tool) -> some View {
        switch tool {
        case .go:
            Button("Download Go…") { status.install(.go) }
                .help("Open go.dev/dl to download the Go installer")
        case .git:
            Button("Install…") { status.install(.git) }
                .help("Install the Command Line Tools, which include Git")
        case .gopls, .dlv:
            if status.installing == tool {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Installing \(tool.title)")
            } else {
                Button("Install") { status.install(tool) }
                    .disabled(status.paths[.go] == nil || status.installing != nil)
                    .help(status.paths[.go] == nil ? "Install Go first" : "Run go install \(tool.installPackage ?? "")")
            }
        }
    }
}
