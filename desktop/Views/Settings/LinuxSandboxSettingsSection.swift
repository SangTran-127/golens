import SwiftUI
import GoLensFoundation

struct LinuxSandboxSettingsSection: View {
    let workspacePath: String
    @Bindable private var installer = LinuxRuntimeInstaller.shared
    @Bindable private var projects = LinuxSandboxProjects.shared
    @Bindable private var vm = SandboxVMManager.shared
    @State private var confirmRemove = false

    private var projectName: String {
        (workspacePath as NSString).lastPathComponent
    }

    private var footer: String {
        guard installer.isSupported else {
            return "The Linux Sandbox runs Linux for Apple silicon, so it isn’t available on this Mac. Projects run on macOS."
        }
        return "Projects run on macOS unless you turn the sandbox on for them. A sandboxed project builds, tests, runs and gets completions inside an isolated Linux virtual machine. While any open project uses the sandbox, every open project does."
    }

    var body: some View {
        SettingsSection("Linux Sandbox", footer: footer) {
            if !installer.isSupported {
                LabeledContent("Status") {
                    SettingsStatus("Requires a Mac with Apple Silicon", tone: .inactive)
                }
            } else {
                LabeledContent("Status") {
                    HStack(spacing: SettingsMetrics.rowSpacing) {
                        status
                        Spacer(minLength: SettingsMetrics.rowSpacing)
                        actions
                    }
                }
                details
                if let failure = installer.failure {
                    SettingsNote("\(failure.title). \(failure.message)", systemImage: StatusTone.failure.symbol) {
                        Button("Retry", action: retry)
                            .disabled(installer.isBusy)
                    }
                }
                if installer.isInstalled, !workspacePath.isEmpty {
                    Toggle("Run “\(projectName)” in the Linux Sandbox", isOn: Binding(
                        get: { projects.isEnabled(for: workspacePath) },
                        set: { projects.setEnabled($0, for: workspacePath) }
                    ))
                    .accessibilityLabel("Run “\(projectName)” in the Linux Sandbox")
                }
                LabeledContent("Running On") {
                    SettingsValue(vm.executionMode == .linuxVM ? "Linux Sandbox" : "macOS")
                }
            }
        }
        .onAppear {
            if installer.available == nil { installer.checkForRuntime() }
        }
        .alert("Remove the Linux Sandbox?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { installer.remove() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GoLens deletes the runtime\(installer.installed.map { " and frees \(UserMessage.byteCount($0.installedSize))" } ?? ""). Projects that use the sandbox run on macOS until you download it again.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch installer.activity {
        case .checking:
            SettingsStatus(busy: "Checking…")
        case .downloading:
            SettingsStatus(busy: "Downloading…")
        case .verifying:
            SettingsStatus(busy: "Verifying…")
        case .installing:
            SettingsStatus(busy: "Installing…")
        case .removing:
            SettingsStatus(busy: "Removing…")
        case .none:
            if let installed = installer.installed {
                switch installer.availability {
                case .updateAvailable:
                    SettingsStatus("Update Available", detail: "Version \(installed.version)", tone: .info)
                case .installedNeedsUpdate:
                    SettingsStatus("Needs an Update", detail: "Version \(installed.version)", tone: .warning)
                default:
                    SettingsStatus("Installed", detail: "Version \(installed.version)", tone: .success)
                }
            } else {
                SettingsStatus("Not Installed", tone: .inactive)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch installer.activity {
        case .downloading:
            Button("Cancel") { installer.cancelDownload() }
        case .none:
            if installer.isInstalled {
                if case .updateAvailable = installer.availability {
                    Button("Update") { installer.download() }
                }
                Button("Remove…") { confirmRemove = true }
            } else if case .notInstalled = installer.availability {
                Button("Download") { installer.download() }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var details: some View {
        if case let .downloading(received, total) = installer.activity {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .accessibilityLabel("Download Progress")
                Text("\(UserMessage.byteCount(received)) of \(UserMessage.byteCount(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if let installed = installer.installed {
            LabeledContent("Includes") {
                SettingsValue(Self.components(installed))
            }
        } else if let available = installer.available {
            LabeledContent("Size") {
                SettingsValue("\(UserMessage.byteCount(available.archiveSize)) download · \(UserMessage.byteCount(available.installedSize)) on disk")
            }
            if case let .requiresNewerApp(manifest) = installer.availability {
                SettingsNote("This version of the Linux Sandbox needs GoLens \(manifest.minimumAppVersion) or later.", systemImage: StatusTone.warning.symbol)
            }
        }
    }

    private func retry() {
        if installer.available == nil {
            installer.checkForRuntime()
        } else {
            installer.download()
        }
    }

    private static func components(_ manifest: LinuxRuntimeManifest) -> String {
        [("kernel", "Linux"), ("go", "Go"), ("alpine", "Alpine")].compactMap { key, title in
            manifest.components[key].map { "\(title) \($0)" }
        }.joined(separator: " · ")
    }
}
