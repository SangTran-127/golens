import AppKit
import SwiftUI

struct GoToolchainsSettingsPage: View {
    @Bindable private var workspace = WorkspaceState.shared
    @Bindable private var vm = SandboxVMManager.shared

    @State private var hostToolchain: HostGoToolchainStatus?
    @State private var isCheckingHostToolchain = true
    @State private var operationErrorTitle = "Toolchain Action Failed"
    @State private var operationError: String?

    private static var hostArchLabel: String {
        #if arch(x86_64)
        "darwin/amd64"
        #else
        "darwin/arm64"
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = operationError {
                InlineBanner(
                    .status(.failure),
                    title: operationErrorTitle,
                    message: errorMessage,
                    onClose: { operationError = nil }
                )
            }

            SettingsForm {
                SettingsSection(
                    "Host Toolchain (macOS)",
                    footer: "Used when Execution Environment is set to Host macOS Toolchain. Go downloads additional versions automatically when GOTOOLCHAIN allows it."
                ) {
                    if isCheckingHostToolchain && hostToolchain == nil {
                        SettingsStatus(busy: "Detecting Go installation…")
                    } else if let host = hostToolchain {
                        SettingsItemRow(
                            "Go \(host.version)",
                            subtitle: "\(Self.hostArchLabel) · GOROOT \(host.goroot.isEmpty ? host.goBinaryPath : host.goroot)"
                        ) {
                            if vm.executionMode == .host {
                                SettingsBadge("Active", tint: StatusTone.success.tint)
                            }
                            if host.isCustom {
                                SettingsBadge("Custom")
                            }
                        } accessory: {
                            if host.isCustom {
                                Button("Use Default PATH") {
                                    workspace.customGoBinaryPath = ""
                                    reloadHostToolchain()
                                }
                                .accessibilityLabel("Use Default PATH Go Binary")
                            }
                        }

                        LabeledContent("Go Binary") {
                            SettingsValue(host.goBinaryPath)
                        }
                    } else {
                        SettingsStatus(
                            "No Go Toolchain Found on macOS",
                            detail: "Install Go from go.dev or choose an existing go binary on this Mac.",
                            tone: .warning
                        )
                    }

                    SettingsActionRow {
                        Button("Choose Go Binary…") {
                            chooseHostGoBinary()
                        }
                        .accessibilityLabel("Choose Go Binary")
                    } trailing: {
                        Button {
                            if let url = URL(string: "https://go.dev/dl/") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open go.dev Downloads", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityLabel("Open go.dev Downloads")
                    }
                }

                SettingsSection(
                    "Linux Machine Toolchain",
                    footer: "Used when Execution Environment is set to Isolated Linux Machine. It ships with the GoLens Linux runtime and is shared read-only with every workspace."
                ) {
                    if let version = vm.linuxGoVersion {
                        SettingsItemRow("Go \(version)", subtitle: "linux/arm64 · /usr/local/go") {
                            if vm.executionMode == .linuxVM {
                                SettingsBadge("Active", tint: StatusTone.success.tint)
                            }
                            SettingsBadge("Bundled")
                        } accessory: {
                            EmptyView()
                        }
                    } else {
                        SettingsStatus(
                            "No Go Toolchain in the Linux Runtime",
                            detail: "The Linux runtime folder has no Go toolchain. Use the Host macOS Toolchain until the runtime is restored.",
                            tone: .warning
                        )
                    }
                }
            }
        }
        .task {
            vm.refreshLinuxGoVersion()
            await refreshHostToolchain()
        }
    }

    private func reloadHostToolchain() {
        Task {
            await refreshHostToolchain()
        }
    }

    private func refreshHostToolchain() async {
        isCheckingHostToolchain = true
        hostToolchain = await workspace.detectHostGoToolchain()
        isCheckingHostToolchain = false
    }

    private func chooseHostGoBinary() {
        let panel = NSOpenPanel()
        panel.title = "Choose Go Binary"
        panel.message = "Select the go executable (for example /usr/local/go/bin/go or /opt/homebrew/bin/go)."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let chosenPath = selectedURL.resolvingSymlinksInPath().path
        Task {
            if let verified = await WorkspaceState.inspectGoBinary(at: chosenPath, isCustom: true) {
                operationError = nil
                workspace.customGoBinaryPath = chosenPath
                hostToolchain = verified
            } else {
                operationErrorTitle = "Invalid Go Binary"
                operationError = "“\(selectedURL.lastPathComponent)” did not respond to “go env GOVERSION GOROOT”. Choose a valid macOS go executable."
            }
        }
    }
}
