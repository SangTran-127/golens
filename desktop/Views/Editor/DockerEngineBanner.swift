import SwiftUI

struct DockerEngineBanner: View {
    let info: DockerEngineInfo
    @Environment(\.windowWorkspace) private var workspace
    private let docker = DockerState.shared

    var body: some View {
        InlineBanner(
            .status(.warning),
            title: info.title,
            message: info.explanation,
            detail: info.detail
        ) {
            if docker.isChecking {
                ProgressView()
                    .accessibilityLabel("Checking Docker")
            }
            if !info.providerApp.isEmpty {
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
    }
}
