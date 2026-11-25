import SwiftUI

struct RunConfigurationsModal: View {
    @Bindable var workspace: WorkspaceState
    @Bindable private var vm = SandboxVMManager.shared
    @Environment(\.dismiss) var dismiss

    @State private var selectedConfigId: UUID?
    @State private var editingConfig: RunConfiguration?
    @State private var originalConfigurations: [RunConfiguration] = []
    @State private var originalActiveId: UUID?

    @State private var name: String = ""
    @State private var envVars: String = ""
    @State private var envFilePath: String = ""
    @State private var buildFlags: String = ""
    @State private var args: String = ""
    @State private var workingDirectory: String = "."
    @State private var discoveredMainDirs: [String] = ["."]
    @State private var discoveredEnvFiles: [String] = []
    @State private var kind: RunConfiguration.Kind = .go
    @State private var dockerfile: String = "Dockerfile"
    @State private var targetStage: String = ""
    @State private var imageTag: String = ""
    @State private var ports: String = ""
    @State private var dockerRunArgs: String = ""
    @State private var discoveredDockerfiles: [String] = []
    @State private var targetKind: RunTarget.Kind = .local
    @State private var architecture: TargetArchitecture = .arm64
    @State private var composeFile: String = ""
    @State private var service: String = ""
    @State private var host: String = ""
    @State private var sshPort: String = ""
    @State private var remoteWorkDir: String = ""
    @State private var debugPort: String = ""
    @State private var discoveredComposeFiles: [String] = []
    @State private var memoryLimit: MemoryLimit = .unlimited
    @State private var cpuQuota: CPUQuota = .unlimited
    @State private var highlightMemoryLimit: Bool = false
    @State private var hostToolchain: HostGoToolchainStatus?
    @State private var operationError: String?

    private var localDestinationTitle: String {
        vm.executionMode == .linuxVM ? "Linux Micro-VM (This Mac)" : "My Mac (Host Toolchain)"
    }

    private var localDestinationSymbol: String {
        vm.executionMode == .linuxVM ? "cpu" : "desktopcomputer"
    }

    var body: some View {
        ListDetailSheet(
            selection: $selectedConfigId,
            listTitle: "Configurations",
            addTitle: "Add Configuration",
            removeTitle: "Delete Configuration",
            showsDetail: editingConfig != nil,
            onAdd: addConfiguration,
            onRemove: delete,
            onCancel: cancel,
            onDone: { dismiss() }
        ) {
            ForEach(workspace.runConfigurations) { config in
                configurationRow(config)
                    .tag(config.id)
                    .contextMenu {
                        Button("Set as Active", systemImage: "checkmark.circle") {
                            workspace.activeRunConfigId = config.id
                            workspace.saveRunConfigurations()
                        }
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(config) }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(config.id) }
                    }
            }
        } sidebarAccessory: {
            if discoveredMainDirs.count > 1 {
                ListDetailBarButton(
                    title: "Add a Configuration for Each Main Package",
                    symbol: "wand.and.stars",
                    action: autoCreateConfigsFromMainPackages
                )
            }
        } detail: {
            configurationForm
        } emptyDetail: {
            emptyDetail
        } banner: {
            if let errorMessage = operationError {
                InlineBanner(
                    .status(.failure),
                    title: "Could Not Install Rosetta 2",
                    message: errorMessage,
                    onClose: { operationError = nil }
                )
            }
        }
        .sheetFrame(.runConfigurations)
        .onChange(of: selectedConfigId) { _, newVal in
            if let id = newVal, let config = workspace.runConfigurations.first(where: { $0.id == id }) {
                loadConfig(config)
            } else {
                editingConfig = nil
            }
        }
        .onAppear(perform: prepare)
        .task(id: workspace.customGoBinaryPath) {
            hostToolchain = await workspace.detectHostGoToolchain()
        }
    }

    private func rowSymbol(for config: RunConfiguration) -> String {
        if config.kind == .docker { return "shippingbox" }
        if config.runTarget.kind == .local { return localDestinationSymbol }
        return config.runTarget.symbol
    }

    private func rowSubtitle(for config: RunConfiguration) -> String {
        if config.kind == .docker { return "Docker Image" }
        if config.runTarget.kind == .local { return localDestinationTitle }
        return config.runTarget.title
    }

    private func configurationRow(_ config: RunConfiguration) -> some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: rowSymbol(for: config))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(config.name)
                    .lineLimit(1)
                Text(rowSubtitle(for: config))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if workspace.activeRunConfigId == config.id {
                Image(systemName: "checkmark.circle.fill")
                    .rowTint(Color(nsColor: .controlAccentColor))
                    .help("Active Configuration")
                    .accessibilityLabel("Active")
            }
        }
        .padding(.vertical, Spacing.hairline)
        .accessibilityElement(children: .combine)
    }

    private var configurationForm: some View {
        Form {
            generalSection
            if kind == .go {
                destinationSection
                if targetKind != .local {
                    connectionSection
                } else if vm.executionMode == .linuxVM {
                    resourceLimitsSection
                }
                executionSection
            } else {
                dockerSection
            }
            envFileSection
            envVarsSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var emptyDetail: some View {
        if workspace.runConfigurations.isEmpty {
            ContentUnavailableView {
                Label("No Run Configurations", systemImage: "play.rectangle")
            } description: {
                Text("Run uses “go run .” in the project folder. Add a configuration to set build flags, arguments or environment.")
            } actions: {
                Button("Add Configuration", action: addConfiguration)
            }
        } else {
            ContentUnavailableView("No Configuration Selected", systemImage: "sidebar.left", description: Text("Select a configuration in the sidebar."))
        }
    }

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $name, prompt: Text("Configuration name"))
                .onChange(of: name) { saveCurrentChanges() }

            Picker("Kind", selection: $kind) {
                Text("Go").tag(RunConfiguration.Kind.go)
                Text("Docker").tag(RunConfiguration.Kind.docker)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .onChange(of: kind) { saveCurrentChanges() }

            if kind == .go {
                LabeledContent("Package") {
                    HStack(spacing: Spacing.standard) {
                        TextField("Package", text: $workingDirectory, prompt: Text("Project root"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .onChange(of: workingDirectory) { saveCurrentChanges() }
                        if !discoveredMainDirs.isEmpty {
                            Menu {
                                ForEach(discoveredMainDirs, id: \.self) { dir in
                                    Button(dir == "." ? "Project Root" : dir) {
                                        workingDirectory = dir
                                        if name == "New Configuration" || name == "Unnamed" {
                                            name = dir == "." ? (workspace.activeWorkspacePath as NSString).lastPathComponent : (dir as NSString).lastPathComponent
                                        }
                                        saveCurrentChanges()
                                    }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Choose a Main Package")
                            .accessibilityLabel("Choose a Main Package")
                        }
                    }
                }
            }
        }
    }

    private var composeServices: [String] {
        var list = workspace.runTargets.compose.services
        if !service.isEmpty && !list.contains(service) { list.insert(service, at: 0) }
        return list
    }

    private var composeFileChoices: [String] {
        var list = discoveredComposeFiles
        if !composeFile.isEmpty && !list.contains(composeFile) { list.insert(composeFile, at: 0) }
        return list
    }

    private var destinationFooter: String {
        switch targetKind {
        case .local:
            if vm.executionMode == .linuxVM && architecture == .amd64 {
                return "Run and Test build for linux/amd64 and run under Rosetta 2 inside the Linux Micro-VM. Debug always builds for linux/arm64."
            }
            return vm.executionMode == .linuxVM
                ? "Runs inside the isolated Linux Micro-VM with instant VirtioFS workspace synchronization and automatic port forwarding."
                : "Runs directly on My Mac (Host Toolchain) using your local Go installation with zero virtual machine overhead."
        case .compose:
            return "Run, Test and Debug build for Linux on this Mac, copy the program into the running service and run it there. With CGO_ENABLED=1 the build runs inside the service. Debugging uses the debugger port directly when the service publishes it on 127.0.0.1; otherwise it goes through docker compose exec."
        case .ssh:
            return "Host accepts user@host or a Host alias from ~/.ssh/config; an empty Port uses the alias’s port or 22. Run, Test and Debug build for Linux on this Mac, copy the program to the host over SSH and run it there, signing in with your SSH keys. With CGO_ENABLED=1 the build runs on the host."
        }
    }

    private var destinationSection: some View {
        Section {
            Picker("Run On", selection: $targetKind) {
                Label(localDestinationTitle, systemImage: localDestinationSymbol).tag(RunTarget.Kind.local)
                Label("Docker Compose Service", systemImage: "square.stack.3d.up").tag(RunTarget.Kind.compose)
                Label("SSH Host", systemImage: "server.rack").tag(RunTarget.Kind.ssh)
            }
            .pickerStyle(.menu)
            .onChange(of: targetKind) {
                if targetKind == .compose {
                    if composeFile.isEmpty, let first = discoveredComposeFiles.first { composeFile = first }
                    workspace.loadComposeServices(file: composeFile)
                    if service.isEmpty, let first = workspace.runTargets.compose.services.first { service = first }
                }
                saveCurrentChanges()
            }

            switch targetKind {
            case .local:
                localTargetFields
            case .compose:
                composeFields
            case .ssh:
                sshFields
            }

            if targetKind != .local {
                TextField("Debugger Port", text: $debugPort, prompt: Text(String(RunTarget.defaultDebugPort)))
                    .onChange(of: debugPort) { saveCurrentChanges() }
            }
        } header: {
            Text("Destination")
        } footer: {
            footerText(destinationFooter)
        }
    }

    private var resourceLimitsSection: some View {
        Section {
            Picker("Memory Limit", selection: $memoryLimit) {
                ForEach(MemoryLimit.allCases) { opt in
                    Text(opt.title).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: memoryLimit) {
                highlightMemoryLimit = false
                saveCurrentChanges()
            }
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .stroke(StatusTone.warning.tint, lineWidth: highlightMemoryLimit ? 2 : 0)
            )

            Picker("CPU Quota", selection: $cpuQuota) {
                ForEach(CPUQuota.allCases) { opt in
                    Text(opt.title).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: cpuQuota) { saveCurrentChanges() }
        } header: {
            Text("Resource Limits")
        } footer: {
            footerText("Simulates production container resource limits inside the Linux Micro-VM using cgroups v2. If the memory limit is exceeded, the Linux OOM Killer terminates the process.")
        }
    }

    @ViewBuilder
    private var localTargetFields: some View {
        Picker("Architecture", selection: $architecture) {
            Text(TargetArchitecture.arm64.title).tag(TargetArchitecture.arm64)
            Text(TargetArchitecture.amd64.title).tag(TargetArchitecture.amd64)
        }
        .pickerStyle(.segmented)
        .onChange(of: architecture) { saveCurrentChanges() }

        if vm.executionMode == .linuxVM && architecture == .amd64 && SandboxVMManager.rosettaAvailability != .installed {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                Label("Rosetta 2 is required to run Linux amd64 binaries on Apple Silicon.", systemImage: StatusTone.warning.symbol)
                    .font(.subheadline)
                    .foregroundStyle(StatusTone.warning.tint)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Install Rosetta…") {
                    Task { @MainActor in
                        do {
                            operationError = nil
                            try await SandboxVMManager.installRosetta()
                        } catch {
                            operationError = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.vertical, Spacing.compact)
        }
    }

    @ViewBuilder
    private var composeFields: some View {
        if composeFileChoices.isEmpty {
            Label("This project has no compose.yaml or docker-compose.yml.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Picker("Compose File", selection: $composeFile) {
                ForEach(composeFileChoices, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: composeFile) {
                workspace.loadComposeServices(file: composeFile, force: true)
                saveCurrentChanges()
            }
            LabeledContent("Service") {
                HStack(spacing: Spacing.standard) {
                    Picker("Service", selection: $service) {
                        if service.isEmpty { Text("Choose a Service").tag("") }
                        ForEach(composeServices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .onChange(of: service) { saveCurrentChanges() }
                    if workspace.runTargets.isLoadingServices {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            workspace.loadComposeServices(file: composeFile, force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Reload Services from the Compose File")
                        .accessibilityLabel("Reload Services")
                    }
                }
            }
            if let error = workspace.runTargets.compose.error {
                Text(error)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        TextField("Working Directory", text: $remoteWorkDir, prompt: Text("Service default"))
            .onChange(of: remoteWorkDir) { saveCurrentChanges() }
    }

    @ViewBuilder
    private var sshFields: some View {
        TextField("Host", text: $host, prompt: Text("user@host or alias"))
            .onChange(of: host) { saveCurrentChanges() }
        TextField("Port", text: $sshPort, prompt: Text("22 or from ~/.ssh/config"))
            .onChange(of: sshPort) { saveCurrentChanges() }
        TextField("Working Directory", text: $remoteWorkDir, prompt: Text("Home folder"))
            .onChange(of: remoteWorkDir) { saveCurrentChanges() }
    }

    @ViewBuilder
    private var connectionSection: some View {
        if let config = editingConfig {
            let state = workspace.runTargets
            let checking = state.checking.contains(config.id)
            Section("Connection") {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.section) {
                    connectionStatus(config: config, state: state, checking: checking)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Check Connection") {
                        workspace.checkRunTarget(config)
                    }
                    .buttonStyle(.bordered)
                    .fixedSize()
                    .disabled(checking)
                }
                if !checking, let issue = state.checkResults[config.id]?.issue,
                   !issue.fix.isEmpty, issue.fix != "editDestination", issue.fix != "retry" {
                    HStack {
                        Spacer()
                        Button(issue.fixTitle) {
                            if issue.fix == "openTerminal" { dismiss() }
                            workspace.performRemoteFix(issue)
                        }
                        .buttonStyle(.bordered)
                        .help(issue.command.isEmpty ? issue.fixTitle : issue.command)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectionStatus(config: RunConfiguration, state: RunTargetState, checking: Bool) -> some View {
        if checking {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                ProgressView().controlSize(.small)
                Text("Checking \(config.target.title)…")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } else if let result = state.checkResults[config.id] {
            if let issue = result.issue {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Label {
                        Text(issue.title)
                            .fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: StatusTone.warning.symbol)
                            .foregroundStyle(StatusTone.warning.tint)
                    }
                    Text(issue.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
            } else {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Label {
                        Text("Connected")
                            .fontWeight(.semibold)
                    } icon: {
                        Image(systemName: StatusTone.success.symbol)
                            .foregroundStyle(StatusTone.success.tint)
                    }
                    Text(result.probe.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text("Not checked yet")
                .foregroundStyle(.secondary)
        }
    }

    private var executionSection: some View {
        Section("Execution") {
            TextField("Build Flags", text: $buildFlags, prompt: Text("-race"))
                .onChange(of: buildFlags) { saveCurrentChanges() }
            TextField("Arguments", text: $args, prompt: Text("Optional"))
                .onChange(of: args) { saveCurrentChanges() }
        }
    }

    private var envFileSection: some View {
        Section {
            LabeledContent("Env File") {
                HStack(spacing: Spacing.standard) {
                    TextField("Env File", text: $envFilePath, prompt: Text(".env or .env.local"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onChange(of: envFilePath) { saveCurrentChanges() }
                    Menu {
                        Button("None", systemImage: "slash.circle") {
                            envFilePath = ""
                            saveCurrentChanges()
                        }
                        if !discoveredEnvFiles.isEmpty {
                            Divider()
                            ForEach(discoveredEnvFiles, id: \.self) { file in
                                Button(file, systemImage: "doc.text") {
                                    envFilePath = file
                                    saveCurrentChanges()
                                }
                            }
                        }
                        Divider()
                        Button("Browse…", systemImage: "folder") {
                            browseEnvFile()
                        }
                    } label: {
                        Image(systemName: "doc")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose an Env File")
                    .accessibilityLabel("Choose an Env File")
                }
            }
        } header: {
            Text("Environment")
        } footer: {
            footerText("Optional. Variables in this file load before Run, Test and Debug.")
        }
    }

    private var envVarsSection: some View {
        Section {
            TextEditor(text: $envVars)
                .font(.callout.monospaced())
                .frame(minHeight: 88)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Environment Variables")
                .onChange(of: envVars) { saveCurrentChanges() }

            let isVM = vm.executionMode == .linuxVM
            DisclosureGroup(isVM ? "Linux Micro-VM (This Mac) Default Environment" : "My Mac (Host Toolchain) Default Environment") {
                VStack(alignment: .leading, spacing: Spacing.row) {
                    Group {
                        defaultEnvRow(key: "GOOS", value: isVM ? "linux" : "darwin")
                        defaultEnvRow(key: "GOARCH", value: architecture.rawValue)
                        if isVM {
                            defaultEnvRow(key: "GOCACHE", value: "/cache/gobuild")
                            defaultEnvRow(key: "GOMODCACHE", value: "/cache/gomod")
                            defaultEnvRow(key: "GOROOT", value: "/usr/local/go")
                            defaultEnvRow(key: "PATH", value: "/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin")
                        } else if let host = hostToolchain, !host.goroot.isEmpty {
                            defaultEnvRow(key: "GOROOT", value: host.goroot)
                        }
                    }
                    Button("Insert Defaults into Editor") {
                        insertDefaultEnvVars()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, Spacing.compact)
                }
                .padding(.vertical, Spacing.compact)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } header: {
            Text("Environment Variables")
        } footer: {
            footerText(
                kind == .go && targetKind == .local
                    ? "One KEY=VALUE per line. Merged into the \(localDestinationTitle) environment and overrides values from the env file."
                    : "One KEY=VALUE per line. These override values from the env file."
            )
        }
    }

    private func defaultEnvRow(key: String, value: String) -> some View {
        HStack {
            Text(key)
                .font(.subheadline.monospaced())
                .foregroundStyle(Color(nsColor: .labelColor))
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        }
    }

    private func insertDefaultEnvVars() {
        let isVM = SandboxVMManager.shared.executionMode == .linuxVM
        var defaults = [
            "GOOS=\(isVM ? "linux" : "darwin")",
            "GOARCH=\(architecture.rawValue)"
        ]
        if isVM {
            defaults.append("GOCACHE=/cache/gobuild")
            defaults.append("GOMODCACHE=/cache/gomod")
        }
        var existing = envVars.trimmingCharacters(in: .whitespacesAndNewlines)
        for d in defaults {
            let key = d.components(separatedBy: "=").first ?? ""
            if !existing.contains("\(key)=") {
                if !existing.isEmpty { existing += "\n" }
                existing += d
            }
        }
        envVars = existing
        saveCurrentChanges()
    }

    @ViewBuilder
    private var dockerSection: some View {
        Section {
            LabeledContent("Dockerfile") {
                HStack(spacing: Spacing.standard) {
                    TextField("Dockerfile", text: $dockerfile, prompt: Text("Dockerfile"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .onChange(of: dockerfile) { saveCurrentChanges() }
                    Menu {
                        ForEach(discoveredDockerfiles, id: \.self) { file in
                            Button(file, systemImage: "shippingbox") {
                                dockerfile = file
                                saveCurrentChanges()
                            }
                        }
                        if !discoveredDockerfiles.isEmpty { Divider() }
                        Button("Generate Dockerfile for Go Project…", systemImage: "sparkles") {
                            dismiss()
                            DispatchQueue.main.async { workspace.presentGenerateDockerfile() }
                        }
                    } label: {
                        Image(systemName: "doc")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose a Dockerfile")
                    .accessibilityLabel("Choose a Dockerfile")
                }
            }
            TextField("Target Stage", text: $targetStage, prompt: Text("Final stage"))
                .onChange(of: targetStage) { saveCurrentChanges() }
            TextField("Image Tag", text: $imageTag, prompt: Text(DockerCommandLine.imageTag(folder: (workspace.activeWorkspacePath as NSString).lastPathComponent, stage: targetStage)))
                .onChange(of: imageTag) { saveCurrentChanges() }
            TextField("Ports", text: $ports, prompt: Text("8080:8080"))
                .onChange(of: ports) { saveCurrentChanges() }
            TextField("Run Options", text: $dockerRunArgs, prompt: Text("--network host"))
                .onChange(of: dockerRunArgs) { saveCurrentChanges() }
            TextField("Arguments", text: $args, prompt: Text("Optional"))
                .onChange(of: args) { saveCurrentChanges() }
        } header: {
            Text("Docker")
        } footer: {
            dockerFooter
        }
    }

    @ViewBuilder
    private var dockerFooter: some View {
        if let config = editingConfig {
            switch workspace.dockerRunPlan(for: config) {
            case .success(let plan):
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    footerText("Run builds the image, then runs it with these commands:")
                    Text(DockerCommandLine.line(plan.buildArgv) + "\n" + DockerCommandLine.line(plan.runArgv))
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Commands for Run")
                }
            case .failure(let error):
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func prepare() {
        originalConfigurations = workspace.runConfigurations
        originalActiveId = workspace.activeRunConfigId
        discoveredMainDirs = workspace.discoverMainPackageDirectories()
        discoveredEnvFiles = workspace.discoverWorkspaceEnvFiles()
        discoveredDockerfiles = workspace.allWorkspaceRelativeFilePaths().filter { EcosystemDocumentTools.isDockerfile($0) }.sorted()
        discoveredComposeFiles = workspace.discoverComposeFiles()
        workspace.loadComposeServices()
        if let activeId = workspace.activeRunConfigId {
            selectedConfigId = activeId
        } else {
            selectedConfigId = workspace.runConfigurations.first?.id
        }
        if let requested = workspace.runTargets.requestedKind {
            workspace.runTargets.requestedKind = nil
            if let id = selectedConfigId, let config = workspace.runConfigurations.first(where: { $0.id == id }), config.kind == .go {
                loadConfig(config)
                targetKind = requested
                saveCurrentChanges()
            } else {
                let config = RunConfiguration(name: "SSH Host", envVars: [:], buildFlags: "", args: "", workingDirectory: "", envFilePath: discoveredEnvFiles.first ?? "", target: RunTarget(kind: requested))
                workspace.updateRunConfiguration(config)
                selectedConfigId = config.id
                loadConfig(config)
            }
        }
        if workspace.focusMemoryLimitOnOpen {
            workspace.focusMemoryLimitOnOpen = false
            highlightMemoryLimit = true
        }
    }

    private func cancel() {
        workspace.runConfigurations = originalConfigurations
        workspace.activeRunConfigId = originalActiveId
        workspace.saveRunConfigurations()
        dismiss()
    }

    private func addConfiguration() {
        let newConfig = RunConfiguration(
            id: UUID(),
            name: "New Configuration",
            envVars: [:],
            buildFlags: "",
            args: "",
            workingDirectory: ".",
            envFilePath: discoveredEnvFiles.first ?? ""
        )
        workspace.updateRunConfiguration(newConfig)
        selectedConfigId = newConfig.id
        loadConfig(newConfig)
    }

    private func duplicate(_ config: RunConfiguration) {
        var copy = config
        copy.id = UUID()
        copy.name = config.name + " Copy"
        workspace.updateRunConfiguration(copy)
        selectedConfigId = copy.id
    }

    private func delete(_ id: UUID) {
        let ids = workspace.runConfigurations.map(\.id)
        let index = ids.firstIndex(of: id) ?? 0
        workspace.deleteRunConfiguration(id: id)
        let remaining = workspace.runConfigurations
        selectedConfigId = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    private func loadConfig(_ config: RunConfiguration) {
        editingConfig = config
        name = config.name
        buildFlags = config.buildFlags
        args = config.args
        workingDirectory = config.workingDirectory
        envFilePath = config.envFilePath
        kind = config.kind
        dockerfile = config.dockerfile
        targetStage = config.targetStage
        imageTag = config.imageTag
        ports = config.ports
        dockerRunArgs = config.dockerRunArgs
        targetKind = config.target.kind
        composeFile = config.target.composeFile
        service = config.target.service
        host = config.target.host
        sshPort = config.target.port == RunTarget.defaultSSHPort ? "" : String(config.target.port)
        remoteWorkDir = config.target.workDir
        debugPort = config.target.debugPort == RunTarget.defaultDebugPort ? "" : String(config.target.debugPort)
        architecture = config.architecture
        memoryLimit = config.memoryLimit
        cpuQuota = config.cpuQuota
        envVars = config.envVars.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
    }

    private func saveCurrentChanges() {
        guard let editingConfig = editingConfig else { return }
        var updatedEnv: [String: String] = [:]
        
        let lines = envVars.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    updatedEnv[key] = val
                }
            }
        }
        
        let newConfig = RunConfiguration(
            id: editingConfig.id,
            name: name.isEmpty ? "Unnamed" : name,
            envVars: updatedEnv,
            buildFlags: buildFlags,
            args: args,
            workingDirectory: workingDirectory,
            envFilePath: envFilePath.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            dockerfile: dockerfile.trimmingCharacters(in: .whitespacesAndNewlines),
            targetStage: targetStage.trimmingCharacters(in: .whitespacesAndNewlines),
            imageTag: imageTag.trimmingCharacters(in: .whitespacesAndNewlines),
            ports: ports,
            dockerRunArgs: dockerRunArgs,
            target: RunTarget(
                kind: targetKind,
                composeFile: composeFile.trimmingCharacters(in: .whitespacesAndNewlines),
                service: service,
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(sshPort.trimmingCharacters(in: .whitespaces)) ?? RunTarget.defaultSSHPort,
                workDir: remoteWorkDir.trimmingCharacters(in: .whitespacesAndNewlines),
                debugPort: Int(debugPort.trimmingCharacters(in: .whitespaces)) ?? RunTarget.defaultDebugPort
            ),
            architecture: architecture,
            memoryLimit: memoryLimit,
            cpuQuota: cpuQuota
        )
        
        self.editingConfig = newConfig
        workspace.updateRunConfiguration(newConfig)
    }

    private func autoCreateConfigsFromMainPackages() {
        let defaultEnv = discoveredEnvFiles.first ?? ""
        for dir in discoveredMainDirs {
            if workspace.runConfigurations.contains(where: { $0.workingDirectory == dir }) { continue }
            let cfgName = dir == "." ? (workspace.activeWorkspacePath as NSString).lastPathComponent : (dir as NSString).lastPathComponent
            let cfg = RunConfiguration(
                id: UUID(),
                name: cfgName.isEmpty ? dir : cfgName,
                envVars: [:],
                buildFlags: "",
                args: "",
                workingDirectory: dir,
                envFilePath: defaultEnv
            )
            workspace.updateRunConfiguration(cfg)
        }
        if selectedConfigId == nil, let first = workspace.runConfigurations.first {
            selectedConfigId = first.id
            loadConfig(first)
        }
    }

    private func browseEnvFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if !workspace.activeWorkspacePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: workspace.activeWorkspacePath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            let full = url.path
            if !workspace.activeWorkspacePath.isEmpty && full.hasPrefix(workspace.activeWorkspacePath + "/") {
                envFilePath = String(full.dropFirst(workspace.activeWorkspacePath.count + 1))
            } else {
                envFilePath = full
            }
            saveCurrentChanges()
        }
    }
}
