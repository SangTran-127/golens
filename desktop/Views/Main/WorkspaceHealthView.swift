import SwiftUI
import AppKit

struct WorkspaceHealthItem: View {
    @Bindable var workspace: WorkspaceState
    @State private var showDetails = false

    var body: some View {
        if let issue = workspace.workspaceIssue {
            let secondaryColor = ThemeColor.textSecondary
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: Spacing.compact) {
                    if issue.isInProgress {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: issue.symbol)
                            .foregroundStyle(issue.isWarning ? AnyShapeStyle(StatusTone.warning.tint) : AnyShapeStyle(secondaryColor))
                    }
                    Text(issue.shortTitle)
                        .foregroundStyle(secondaryColor)
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(issue.title)
            .accessibilityLabel(issue.title)
            .popover(isPresented: $showDetails, arrowEdge: .top) {
                WorkspaceIssueDetail(workspace: workspace, issue: issue)
            }
        }
    }
}

extension WorkspaceIssue {
    var shortTitle: String {
        switch self {
        case .goMissing: return "Go Not Found"
        case .goTooOld(let health): return "Go \(ToolchainHealthInfo.display(health.required)) Required"
        case .goplsMissing: return "gopls Not Installed"
        case .goplsOutdated: return "gopls Out of Date"
        case .goplsCrashed: return "gopls Stopped"
        case .goplsRestarting: return "Restarting gopls…"
        case .modulesOffline: return "Offline"
        case .noModule: return "No go.mod"
        case .starting: return "Starting gopls…"
        case .indexing: return "Indexing…"
        }
    }

    var title: String {
        switch self {
        case .goMissing: return "Go Isn’t Installed"
        case .goTooOld(let health): return "Go \(ToolchainHealthInfo.display(health.required)) Required"
        case .goplsMissing: return "Code Intelligence Is Off"
        case .goplsOutdated: return "gopls Is Out of Date"
        case .goplsCrashed: return "gopls Stopped Unexpectedly"
        case .goplsRestarting: return "Restarting gopls"
        case .modulesOffline: return "Can’t Download Modules"
        case .noModule: return "No Go Module"
        case .starting: return "Starting gopls"
        case .indexing: return "Indexing"
        }
    }

    var symbol: String {
        switch self {
        case .modulesOffline: return "wifi.exclamationmark"
        case .noModule: return "info.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }

    var isWarning: Bool {
        switch self {
        case .goMissing, .goTooOld, .goplsMissing, .goplsOutdated, .goplsCrashed: return true
        default: return false
        }
    }
}

private struct WorkspaceIssueDetail: View {
    @Bindable var workspace: WorkspaceState
    let issue: WorkspaceIssue
    @State private var moduleName = ""
    @State private var isWorking = false
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text(issue.title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            extraContent
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            actions
                .padding(.top, Spacing.standard)
        }
        .padding(Spacing.section)
        .frame(width: 320, alignment: .leading)
        .onAppear {
            moduleName = (workspace.activeWorkspacePath as NSString).lastPathComponent
        }
    }

    private var message: String {
        switch issue {
        case .goMissing:
            return "GoLens needs the Go toolchain to run, test and debug, and gopls needs it for code intelligence. Install Go, then check again."
        case .goTooOld(let h):
            let file = (h.requiredBy as NSString).lastPathComponent
            return "This module needs Go \(ToolchainHealthInfo.display(h.required)) (“\(h.directive)” in \(file)). With GOTOOLCHAIN=\(h.toolchain), Go runs version \(ToolchainHealthInfo.display(h.effective)) and won’t switch to the version the module needs, so Run, Test and Debug fail."
        case .goplsOutdated(let h):
            return "gopls was built with Go \(ToolchainHealthInfo.display(h.goplsGo)), but this module uses Go \(ToolchainHealthInfo.display(h.required)), so newer language features can show as errors and completion can be wrong. Update gopls to rebuild it with Go \(ToolchainHealthInfo.display(h.buildWith))."
        case .goplsMissing:
            return "gopls, the Go language server, isn’t installed, so completion, diagnostics and navigation are unavailable. Install it with this command in Terminal, then try again."
        case .goplsCrashed(_, let retryIn):
            return retryIn > 0
                ? "GoLens restarts it automatically in \(retryIn) s and reopens your files. You can also restart it now."
                : "GoLens restarts it automatically and reopens your files. You can also restart it now."
        case .goplsRestarting, .starting:
            return "Completion, diagnostics and navigation are available when it’s ready."
        case .indexing:
            return "gopls is loading this folder’s packages. Completion and navigation are available when it finishes."
        case .modulesOffline:
            return "GoLens couldn’t reach the module proxy, so imports from modules that aren’t downloaded yet don’t resolve. Modules already on this Mac still work. Check your connection, then try again."
        case .noModule:
            return "This folder has no go.mod, so packages and imports may not resolve. Create one to make it a Go module."
        }
    }

    @ViewBuilder
    private var extraContent: some View {
        switch issue {
        case .goplsMissing:
            commandText(WorkspaceState.goplsInstallCommand)
        case .goTooOld(let h):
            Text(Self.toolchainSourceNote(h.toolchainSource))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .goplsOutdated(let h):
            Text("gopls: \(h.goplsPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            commandText(WorkspaceState.goplsUpdateArguments(buildWith: h.buildWith).joined(separator: " "))
        case .goplsCrashed(let reason, _) where !reason.isEmpty:
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        case .indexing(let step) where !step.isEmpty:
            Text("gopls: \(step)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .modulesOffline(let error):
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
        case .noModule:
            TextField("Module Path", text: $moduleName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Module Path")
                .onSubmit(createModule)
        default:
            EmptyView()
        }
    }

    private func commandText(_ command: String) -> some View {
        Text(command)
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.standard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.contentSurface, in: RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.standard) {
                Spacer(minLength: 0)
                progress
                secondaryActions
                defaultAction
            }
            VStack(alignment: .trailing, spacing: Spacing.standard) {
                HStack(spacing: Spacing.standard) {
                    progress
                    defaultAction
                }
                HStack(spacing: Spacing.standard) {
                    secondaryActions
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .trailing, spacing: Spacing.standard) {
                HStack(spacing: Spacing.standard) {
                    progress
                    defaultAction
                }
                secondaryActions
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var progress: some View {
        if isWorking {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        switch issue {
        case .goMissing:
            checkAgainButton
        case .goplsMissing:
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(WorkspaceState.goplsInstallCommand, forType: .string)
            }
        case .goTooOld(let h):
            if Self.canAllowAutomaticToolchain(h) || h.toolchain == "local" {
                checkAgainButton
            }
            if Self.canAllowAutomaticToolchain(h) && h.toolchain == "local" {
                downloadGoButton
            }
        case .goplsOutdated(let h):
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(WorkspaceState.goplsUpdateArguments(buildWith: h.buildWith).joined(separator: " "), forType: .string)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var defaultAction: some View {
        switch issue {
        case .goMissing:
            downloadGoButton
                .keyboardShortcut(.defaultAction)
        case .goplsMissing:
            Button("Try Again") { workspace.restartLanguageServer() }
                .keyboardShortcut(.defaultAction)
        case .goTooOld(let h):
            if Self.canAllowAutomaticToolchain(h) {
                Button("Allow Automatic Toolchain") {
                    isWorking = true
                    Task {
                        actionError = await workspace.allowAutomaticToolchain()
                        isWorking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            } else if h.toolchain == "local" {
                downloadGoButton
                    .keyboardShortcut(.defaultAction)
            } else {
                checkAgainButton
                    .keyboardShortcut(.defaultAction)
            }
        case .goplsOutdated(let h):
            Button("Update gopls") { workspace.updateGopls(buildWith: h.buildWith) }
                .keyboardShortcut(.defaultAction)
        case .goplsCrashed:
            Button("Restart Now") { workspace.restartLanguageServer() }
                .keyboardShortcut(.defaultAction)
        case .modulesOffline:
            Button("Try Again") {
                isWorking = true
                Task {
                    actionError = await workspace.retryModuleDownload()
                    isWorking = false
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking)
        case .noModule:
            Button("Create go.mod", action: createModule)
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || moduleName.trimmingCharacters(in: .whitespaces).isEmpty)
        default:
            EmptyView()
        }
    }

    private var checkAgainButton: some View {
        Button("Check Again") { workspace.refreshWorkspaceHealth() }
    }

    private var downloadGoButton: some View {
        Button("Download Go…", action: openGoDownloads)
    }

    private static func canAllowAutomaticToolchain(_ health: ToolchainHealthInfo) -> Bool {
        health.toolchainSource == "goenv" || health.toolchainSource == "goroot"
    }

    private func openGoDownloads() {
        if let url = URL(string: "https://go.dev/dl/") { NSWorkspace.shared.open(url) }
    }

    private static func toolchainSourceNote(_ source: String) -> String {
        switch source {
        case "env": return "GOTOOLCHAIN is set in the environment GoLens was opened with. Remove it from your shell profile or launch settings, then reopen GoLens."
        case "goenv": return "GOTOOLCHAIN is set in Go’s settings file (go env -w). Allow Automatic Toolchain sets it to auto for every Go project on this Mac."
        case "goroot": return "GOTOOLCHAIN comes from this Go installation’s defaults (go.env in GOROOT). Allow Automatic Toolchain overrides it with auto for every Go project on this Mac."
        default: return "GOTOOLCHAIN keeps Go from switching versions."
        }
    }

    private func createModule() {
        let name = moduleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            actionError = await workspace.createGoModule(named: name)
            isWorking = false
        }
    }
}

struct RunFailureBanner: View {
    @Bindable var workspace: WorkspaceState
    let failure: RunFailure

    var body: some View {
        if case .oomKilled(let limit) = failure.kind {
            OOMKilledBannerView(workspace: workspace, memoryLimit: limit) {
                workspace.runFailure = nil
            }
        } else {
            InlineBanner(
                .status(failure.errorCount > 0 ? .failure : .warning),
                title: title,
                message: message,
                onClose: { workspace.runFailure = nil }
            ) {
                if let url = failure.firstErrorURL {
                    Button("Show First Error") {
                        _ = ConsoleLinks.open(url, in: workspace)
                    }
                }
                if case .remote(let issue) = failure.kind, !issue.fix.isEmpty, !issue.fixTitle.isEmpty {
                    Button(issue.fixTitle) {
                        workspace.performRemoteFix(issue)
                    }
                    .help(issue.command.isEmpty ? issue.fixTitle : issue.command)
                }
                if failure.kind == .toolchainMissing {
                    Button("Download Go…") {
                        if let url = URL(string: "https://go.dev/dl/") { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    private var title: String {
        switch failure.kind {
        case .build: return "Build Failed"
        case .exited: return "Program Exited with an Error"
        case .toolchainMissing: return "Go Isn’t Installed"
        case .command(let name): return name == "Build" ? "Build Failed" : "\(name) Failed"
        case .remote(let issue): return issue.title
        case .oomKilled: return "Process Killed by Linux OOM Killer"
        }
    }

    private var compilerErrors: String {
        failure.errorCount == 1 ? "1 error. Fix it" : "\(failure.errorCount) errors. Fix them"
    }

    private var message: String {
        switch failure.kind {
        case .build:
            return "The compiler reported \(compilerErrors), then \(KeymapStore.shared.labeled("run again", "product.run"))."
        case .exited:
            return "\(failure.detail.prefix(1).uppercased() + failure.detail.dropFirst()). The program’s output is below."
        case .toolchainMissing:
            return "GoLens runs your code with the Go toolchain. Install Go, then run again."
        case .command:
            guard failure.errorCount == 0 else {
                return "The compiler reported \(compilerErrors), then \(KeymapStore.shared.labeled("build again", "product.build"))."
            }
            return "\(failure.detail.prefix(1).uppercased() + failure.detail.dropFirst()). The command’s output is below."
        case .remote(let issue):
            return issue.message
        case .oomKilled(let limit):
            return "The program exceeded the Memory Limit of \(limit) and was terminated by the Linux kernel."
        }
    }
}
