import SwiftUI

struct DockerStatusBarItem: View {
    @Bindable var workspace: WorkspaceState
    private let docker = DockerState.shared
    @State private var showDetails = false

    var body: some View {
        let secondaryColor = ThemeColor.textSecondary
        let status = docker.status
        let isWarning = status.map { !$0.isOK } ?? false
        let label = status?.statusLabel ?? "Docker"
        Button {
            showDetails.toggle()
        } label: {
            HStack(spacing: Spacing.compact) {
                if status == nil && docker.isChecking {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: isWarning ? StatusTone.warning.symbol : "shippingbox")
                        .foregroundStyle(isWarning ? AnyShapeStyle(StatusTone.warning.tint) : AnyShapeStyle(secondaryColor))
                        .accessibilityHidden(true)
                }
                Text(label)
                    .foregroundStyle(secondaryColor)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(status.map { "\($0.title). \($0.explanation)" } ?? "Checking Docker…")
        .accessibilityLabel(label)
        .accessibilityValue(status?.title ?? "Checking")
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            DockerStatusDetail(workspace: workspace)
        }
        .onAppear {
            if docker.status == nil { workspace.refreshDockerStatus() }
        }
    }
}

private struct DockerStatusDetail: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.dismiss) private var dismiss
    private let docker = DockerState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            if let info = docker.status {
                Text(info.title)
                    .font(.headline)
                Text(info.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    row("Docker CLI", info.cliPath.isEmpty ? "Not found" : [info.cliPath, info.cliVersion].filter { !$0.isEmpty }.joined(separator: ", "))
                    row("Compose", info.composeVersion.isEmpty ? "Not available" : info.composeVersion)
                    row("Context", info.contextName)
                    if !info.endpoint.isEmpty {
                        row("Endpoint", info.endpoint)
                    }
                    row("Engine", info.serverVersion.isEmpty ? "Not reachable" : info.serverVersion)
                }
                .font(.subheadline)
                if !info.error.isEmpty && !info.isOK {
                    Text(info.error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            } else {
                Text("Checking Docker…")
                    .font(.headline)
            }
            HStack(spacing: Spacing.standard) {
                if docker.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking Docker")
                }
                Button("Show in Services") {
                    dismiss()
                    workspace.showServicesPanel()
                }
                .help("Show containers, logs and details in the Services tab")
                Spacer()
                if let info = docker.status, !info.isOK, !info.providerApp.isEmpty {
                    Button("Open \(info.provider.isEmpty ? "Docker" : info.provider)") {
                        workspace.openDockerProvider()
                    }
                    .help("Start \(info.provider.isEmpty ? "the Docker engine" : info.provider), then check again")
                }
                Button("Retry") {
                    workspace.refreshDockerStatus(force: true)
                }
                .disabled(docker.isChecking)
                .help("Check Docker again")
            }
            .padding(.top, Spacing.standard)
        }
        .padding(Spacing.section)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
