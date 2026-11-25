import SwiftUI
import Virtualization

struct ContainerSettingsPane: View {
    @Bindable private var workspace = WorkspaceState.shared
    @Bindable private var vm = SandboxVMManager.shared

    @AppStorage("GoLensContainerPauseMinutes") private var pauseMinutes = 5
    @AppStorage("GoLensContainerFastResume") private var fastResume = true
    @AppStorage("GoLensContainerCPUCores") private var selectedCores = 0
    @AppStorage("GoLensContainerMemoryMB") private var selectedMemoryMB = SandboxVMManager.defaultMemoryLimitMB
    @AppStorage("GoLensContainerRosetta2") private var rosettaEnabled = true
    @AppStorage("GoLensContainerNetworkMode") private var networkMode = "loopback"
    @AppStorage("GoLensContainerForwardPorts") private var forwardPorts = true

    @State private var confirmClearBuildCache = false
    @State private var confirmClearModuleCache = false
    @State private var isClearingBuildCache = false
    @State private var isClearingModuleCache = false
    @State private var hostToolchain: HostGoToolchainStatus?
    @State private var operationErrorTitle = "Execution Action Failed"
    @State private var operationError: String?

    private var totalHostCores: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    private var recommendedCores: Int {
        2
    }

    private var maxMemoryGB: Int {
        Int((ProcessInfo.processInfo.physicalMemory * 3 / 4) / (1024 * 1024 * 1024))
    }

    private var resourcesRequireRestart: Bool {
        guard vm.isRunning else { return false }
        let currentCores = selectedCores == 0 ? recommendedCores : selectedCores
        return vm.cpuCores != currentCores || vm.memoryLimitMB != selectedMemoryMB
    }

    private var buildCacheSizeText: String {
        if vm.buildCacheSizeBytes <= 0 {
            return "0 KB"
        }
        return UserMessage.byteCount(vm.buildCacheSizeBytes)
    }

    private var moduleCacheSizeText: String {
        if vm.moduleCacheSizeBytes <= 0 {
            return "0 KB"
        }
        return UserMessage.byteCount(vm.moduleCacheSizeBytes)
    }

    private var activeToolchainLabel: String {
        if vm.executionMode == .host {
            if let host = hostToolchain {
                return "Go \(host.version) · \(host.goroot.isEmpty ? host.goBinaryPath : host.goroot)"
            }
            return "Not Found on PATH"
        }
        return vm.linuxGoVersion.map { "Go \($0) · linux/arm64" } ?? "Not Found in the Linux Runtime"
    }

    private var drillDownValueLabel: String {
        if vm.executionMode == .host {
            return hostToolchain.map { "Go \($0.version)" } ?? "Configure"
        }
        return vm.linuxGoVersion.map { "Go \($0)" } ?? "Not Found"
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
                LinuxSandboxSettingsSection(workspacePath: workspace.activeWorkspacePath)

                SettingsSection(
                    "Go Toolchain",
                    footer: vm.executionMode == .host
                        ? "GoLens runs the active macOS Go installation and switches versions automatically when go.mod and GOTOOLCHAIN request it."
                        : "Every workspace in the Linux machine uses the Go toolchain of the GoLens Linux runtime."
                ) {
                    LabeledContent("Active Toolchain") {
                        SettingsValue(activeToolchainLabel)
                    }

                    SettingsDrillDownRow(
                        title: "Installed Go Versions",
                        symbol: "cube.box",
                        tint: .cyan,
                        value: drillDownValueLabel,
                        page: .goToolchains
                    )
                }

                if vm.executionMode == .linuxVM {
                    SettingsSection("Linux Machine", footer: "GoLens builds, tests and debugs your code in an isolated Linux virtual machine on Apple Silicon.") {
                        LabeledContent("Status") {
                            HStack(spacing: SettingsMetrics.rowSpacing) {
                                statusView
                                Spacer(minLength: SettingsMetrics.rowSpacing)
                                statusActionButton
                            }
                        }

                        if vm.isRunning {
                            LabeledContent("Connection") {
                                SettingsValue("Zero-TCP vsock streaming (CID 3)")
                            }

                            if case let .running(_, _, bootTime) = vm.state {
                                LabeledContent("Uptime") {
                                    SettingsValue(uptimeString(from: bootTime))
                                }
                            }
                        }

                        Picker("Pause When Inactive", selection: $pauseMinutes) {
                            Text("After 5 Minutes").tag(5)
                            Text("After 10 Minutes").tag(10)
                            Text("After 30 Minutes").tag(30)
                            Text("Never").tag(0)
                        }
                        .accessibilityLabel("Pause When Inactive")
                        .onChange(of: pauseMinutes) { _, newValue in
                            vm.pauseWhenInactive = SandboxVMManager.InactivePauseInterval(rawValue: newValue * 60) ?? .after10Minutes
                        }

                        Toggle("Fast Resume from Snapshot", isOn: $fastResume)
                            .accessibilityLabel("Fast Resume from Snapshot")
                            .onChange(of: fastResume) { _, newValue in
                                vm.fastResumeEnabled = newValue
                            }
                    }

                    SettingsSection("Resources", footer: "GoLens normally uses about 512 MB and grows toward the maximum only while the Go language server needs more memory.") {
                        Picker("CPU Cores", selection: $selectedCores) {
                            Text("Automatic (\(recommendedCores) of \(totalHostCores) Cores)").tag(0)
                            ForEach(stride(from: 2, through: totalHostCores, by: 2).map { $0 }, id: \.self) { cores in
                                Text("\(cores) Cores").tag(cores)
                            }
                        }
                        .accessibilityLabel("CPU Cores")
                        .accessibilityValue(selectedCores == 0 ? "Automatic (\(recommendedCores) cores)" : "\(selectedCores) cores")
                        .onChange(of: selectedCores) { _, newValue in
                            let c = newValue == 0 ? recommendedCores : newValue
                            if !vm.isRunning { vm.cpuCores = c }
                        }

                        Picker("Maximum Memory", selection: $selectedMemoryMB) {
                            Text("512 MB").tag(512)
                            Text("1 GB").tag(1024)
                            Text("2 GB (Default)").tag(2048)
                            Text("4 GB").tag(4096)
                            if maxMemoryGB >= 8 {
                                Text("8 GB").tag(8192)
                            }
                            if maxMemoryGB >= 16 {
                                Text("16 GB").tag(16384)
                            }
                        }
                        .accessibilityLabel("Maximum Memory")
                        .accessibilityValue("\(selectedMemoryMB) megabytes")
                        .onChange(of: selectedMemoryMB) { _, newValue in
                            if !vm.isRunning { vm.memoryLimitMB = newValue }
                        }

                        Toggle("Run x86_64 Binaries with Rosetta 2", isOn: $rosettaEnabled)
                            .accessibilityLabel("Run x86_64 Binaries with Rosetta 2")
                            .onChange(of: rosettaEnabled) { _, newValue in
                                vm.isRosettaEnabled = newValue
                            }

                        if rosettaEnabled && VZLinuxRosettaDirectoryShare.availability == .notInstalled {
                            SettingsNote("Rosetta 2 is required to run Linux x86_64 programs on Apple Silicon.") {
                                Button("Install Rosetta…") {
                                    performOperation("Could Not Install Rosetta 2") {
                                        try await SandboxVMManager.installRosetta()
                                    }
                                }
                                .accessibilityLabel("Install Rosetta 2")
                            }
                        }

                        if resourcesRequireRestart {
                            SettingsNote("New resource limits take effect the next time the Linux machine restarts.", systemImage: "info.circle") {
                                Button("Restart Now") {
                                    let c = selectedCores == 0 ? recommendedCores : selectedCores
                                    vm.cpuCores = c
                                    vm.memoryLimitMB = selectedMemoryMB
                                    performOperation("Could Not Restart Linux Machine") {
                                        try await vm.restart()
                                    }
                                }
                                .accessibilityLabel("Restart Linux machine now")
                            }
                        }
                    }

                    SettingsSection("Privacy & Network", footer: "With Loopback Only, go test can reach local servers started by the test but cannot connect to the internet. Gopilot test runs always use Loopback Only and a read-only workspace.") {
                        Picker("Network Access During Tests", selection: $networkMode) {
                            Text("Loopback Only (127.0.0.1)").tag("loopback")
                            Text("Allow Outbound Network").tag("outbound")
                        }
                        .accessibilityLabel("Network Access During Tests")
                        .onChange(of: networkMode) { _, newValue in
                            vm.networkMode = SandboxVMManager.NetworkMode(rawValue: newValue) ?? .loopbackOnly
                        }

                        Toggle("Forward Listening Ports to localhost", isOn: $forwardPorts)
                            .accessibilityLabel("Forward Listening Ports to localhost")
                            .onChange(of: forwardPorts) { _, newValue in
                                vm.forwardListeningPorts = newValue
                            }

                        LabeledContent("Host-Guest Communication") {
                            SettingsStatus("Zero-TCP vsock streaming (CID 3)", symbol: "lock.shield", tint: StatusTone.success.tint)
                        }

                        LabeledContent("DNS Resolution") {
                            SettingsValue(networkMode == "loopback" ? "Isolated (No Outbound DNS)" : "Host DNS Proxy (127.0.0.1)")
                        }
                    }

                    SettingsSection("Storage", footer: "Caches live inside GoLens’s sandbox container and are shared across workspaces.") {
                        LabeledContent("Build Cache (GOCACHE)") {
                            HStack(spacing: SettingsMetrics.rowSpacing) {
                                SettingsValue(buildCacheSizeText)
                                Button("Clear…") {
                                    confirmClearBuildCache = true
                                }
                                .disabled(vm.buildCacheSizeBytes <= 0 || isClearingBuildCache)
                                .accessibilityLabel("Clear Build Cache")
                            }
                        }

                        LabeledContent("Module Cache (GOMODCACHE)") {
                            HStack(spacing: SettingsMetrics.rowSpacing) {
                                SettingsValue(moduleCacheSizeText)
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: vm.moduleCacheDirectoryURL().path)
                                }
                                .accessibilityLabel("Show Module Cache in Finder")
                                Button("Clear…") {
                                    confirmClearModuleCache = true
                                }
                                .disabled(vm.moduleCacheSizeBytes <= 0 || isClearingModuleCache)
                                .accessibilityLabel("Clear Module Cache")
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Clear Build Cache?", isPresented: $confirmClearBuildCache, titleVisibility: .visible) {
            Button("Clear Build Cache", role: .destructive) {
                isClearingBuildCache = true
                performOperation("Could Not Clear Build Cache", always: { isClearingBuildCache = false }) {
                    try await vm.clearBuildCache()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next build will recompile packages as needed. The code intelligence index is kept, so completion keeps working.")
        }
        .confirmationDialog("Clear Module Cache?", isPresented: $confirmClearModuleCache, titleVisibility: .visible) {
            Button("Clear Module Cache", role: .destructive) {
                isClearingModuleCache = true
                performOperation("Could Not Clear Module Cache", always: { isClearingModuleCache = false }) {
                    try await vm.clearModuleCache()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next build will re-download modules as needed.")
        }
        .task(id: workspace.customGoBinaryPath) {
            vm.refreshLinuxGoVersion()
            vm.updateCacheSizesAsync()
            hostToolchain = await workspace.detectHostGoToolchain()
        }
    }

    private func performOperation(
        _ errorTitle: String,
        always: (@MainActor () -> Void)? = nil,
        _ work: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            defer { always?() }
            do {
                operationError = nil
                try await work()
            } catch {
                operationErrorTitle = errorTitle
                operationError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch vm.state {
        case let .running(kernel, arch, _):
            SettingsStatus("Running · \(kernel) \(arch)", tone: .success)
        case .paused:
            SettingsStatus("Paused · 0% CPU", symbol: "pause.circle.fill", tint: .secondary)
        case .starting, .restarting:
            SettingsStatus(busy: "Starting…")
        case .stopped:
            if vm.executionMode == .host {
                SettingsStatus("Not in use: no open project uses the sandbox.", tone: .inactive)
            } else {
                SettingsStatus("Stopped", tone: .inactive)
            }
        case let .failed(desc, _):
            SettingsStatus("Stopped · \(desc)", tone: .warning)
        }
    }

    @ViewBuilder
    private var statusActionButton: some View {
        switch vm.state {
        case .running:
            Button("Restart") {
                performOperation("Could Not Restart Linux Machine") {
                    try await vm.restart()
                }
            }
            .accessibilityLabel("Restart Linux machine")
        case .paused:
            Button("Resume") {
                performOperation("Could Not Resume Linux Machine") {
                    try await vm.resume()
                }
            }
            .accessibilityLabel("Resume Linux machine")
        case .starting, .restarting:
            Button("Starting…") {}
                .disabled(true)
                .accessibilityLabel("Starting Linux machine")
        case .stopped:
            if vm.executionMode == .linuxVM {
                Button("Start") {
                    performOperation("Could Not Start Linux Machine") {
                        try await vm.start()
                    }
                }
                .accessibilityLabel("Start Linux machine")
            }
        case .failed:
            Button("Repair Machine") {
                performOperation("Could Not Repair Linux Machine") {
                    try await vm.repair()
                }
            }
            .accessibilityLabel("Repair Linux machine")
        }
    }

    private func uptimeString(from bootTime: Date) -> String {
        let diff = max(0, Int(Date().timeIntervalSince(bootTime)))
        let hours = diff / 3600
        let minutes = (diff % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
