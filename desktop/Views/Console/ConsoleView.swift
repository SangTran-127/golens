import SwiftUI

struct ConsoleView: View {
    @Bindable var workspace: WorkspaceState
    @Binding var selectedTab: Int

    @State private var terminalInput = ""
    @FocusState private var isTerminalFocused: Bool

    var body: some View {
        Group {
            if selectedTab == WorkspaceState.terminalTab {
                TerminalPane(workspace: workspace, terminalInput: $terminalInput, isTerminalFocused: $isTerminalFocused, isVisible: true)
            } else if selectedTab == WorkspaceState.debuggerTab {
                DebuggerView()
            } else if selectedTab == WorkspaceState.profilerTab {
                ProfilerView()
            } else if selectedTab == WorkspaceState.requestsTab {
                HTTPResponsesView()
            } else if selectedTab == WorkspaceState.databaseTab {
                DatabasePanelView()
            } else if selectedTab == WorkspaceState.servicesTab {
                ServicesPanelView()
            } else if selectedTab == WorkspaceState.safetyTab {
                SafetyView(
                    findings: workspace.safetyFindings,
                    summary: workspace.safetySummary,
                    isRunning: workspace.isSafetyAuditRunning,
                    onRunAudit: { workspace.runSafetyAudit() },
                    onClear: { workspace.clearSafetyFindings() },
                    onSelectFinding: { finding in
                        guard !finding.file.isEmpty else { return }
                        workspace.jumpToLocation(path: finding.file, line: max(1, finding.line), column: max(1, finding.col))
                    }
                )
            } else {
                LogPane(workspace: workspace, selectedTab: selectedTab)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(ThemeColor.contentSurface)
    }
}

private struct TerminalPane: View {
    @Bindable var workspace: WorkspaceState
    @Binding var terminalInput: String
    @FocusState.Binding var isTerminalFocused: Bool
    var isVisible: Bool

    var body: some View {
        terminalContent
            .onAppear {
                focusActiveTerminal()
            }
            .onChange(of: workspace.selectedTerminalId) { _, _ in
                focusActiveTerminal()
            }
    }

    private func focusActiveTerminal() {
        guard let activeId = workspace.selectedTerminalId,
              let termView = workspace.terminalEngines[activeId],
              workspace.activePopup == nil else { return }
        DispatchQueue.main.async {
            termView.window?.makeFirstResponder(termView)
        }
    }
    
    private var terminalContent: some View {
        Group {
            if let activeId = workspace.selectedTerminalId, let session = workspace.terminalSessions.first(where: { $0.id == activeId }) {
                VStack(spacing: 0) {
                    GoLensTerminalCanvas(
                        cwd: session.cwd ?? workspace.activeWorkspacePath,
                        terminalId: session.id,
                        isVisible: isVisible,
                        fontSize: workspace.editorFontSize
                    )
                        .id(session.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, Spacing.standard)
                        .padding(.vertical, Spacing.compact)
                        .background(ThemeColor.editorSurface)
                    if let code = session.exitCode {
                        terminalExitBar(session: session, code: code)
                    }
                }
            } else {
                UnifiedEmptyState.empty(
                    symbol: "terminal",
                    badge: "terminal",
                    title: "No Terminal",
                    message: "Open a new shell to run commands in this folder.",
                    actionTitle: "New Terminal",
                    action: newSession
                )
            }
        }
    }

    private func terminalExitBar(session: TerminalSession, code: Int32) -> some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(code == 0 ? "The shell exited." : "The shell exited with code \(code).")
                .font(.subheadline)
            Text("Start a new shell to keep working here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Restart Shell") { workspace.restartTerminal(session) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            if workspace.terminalSessions.count > 1 {
                Button("Close") { workspace.closeTerminalSession(session.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .background(
            ThemeColor.panelSurface
        )
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private func newSession() {
        let newSession = TerminalSession(id: UUID().uuidString, title: "zsh")
        workspace.terminalSessions.append(newSession)
        workspace.selectedTerminalId = newSession.id
    }
}

struct TerminalTabButton: View, Equatable {
    static func == (lhs: TerminalTabButton, rhs: TerminalTabButton) -> Bool {
        lhs.session.id == rhs.session.id &&
        lhs.session.title == rhs.session.title &&
        lhs.isEditing == rhs.isEditing &&
        lhs.editedTitle == rhs.editedTitle &&
        lhs.workspace.selectedTerminalId == rhs.workspace.selectedTerminalId &&
        lhs.workspace.selectedThemeId == rhs.workspace.selectedThemeId &&
        lhs.workspace.systemAppearanceIsDark == rhs.workspace.systemAppearanceIsDark
    }
    
    @Environment(\.windowWorkspace) private var workspace
    let session: TerminalSession
    
    @State private var isEditing = false
    @State private var editedTitle = ""
    @FocusState private var isFieldFocused: Bool
    
    var body: some View {
        let isDark = workspace.currentTheme.resolvedIsDark
        let isSelected = workspace.selectedTerminalId == session.id
        HStack(spacing: Spacing.compact) {
            Button(action: {
                if !isEditing {
                    if isSelected, (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                        beginEditing()
                    } else {
                        workspace.selectedTerminalId = session.id
                    }
                }
            }) {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "terminal")
                        .font(.caption)
                
                    if isEditing {
                        TextField("", text: $editedTitle, onCommit: {
                            finishEditing()
                        })
                        .focused($isFieldFocused)
                        .textFieldStyle(.plain)
                        .font(.subheadline.monospaced())
                        .frame(width: 60)
                        .onChange(of: isFieldFocused) { _, focused in
                            if !focused { finishEditing() }
                        }
                    } else {
                        Text(session.title)
                            .font(.subheadline.weight(isSelected ? .medium : .regular).monospaced())
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Switch to \(session.title)")
            .accessibilityAction(named: "Rename Tab") {
                beginEditing()
            }
            .contextMenu {
                Button("Rename Tab", systemImage: "pencil") {
                    beginEditing()
                }
            }

            if workspace.terminalSessions.count > 1 {
                Button(action: {
                    workspace.closeTerminalSession(session.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Terminal Session")
                .help("Close Terminal Session")
            }
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.compact)
        .background(workspace.tabBackgroundColor(isActive: isSelected, isDark: isDark))
        .foregroundStyle(workspace.tabTextColor(isActive: isSelected, isDark: isDark))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: Stroke.hairline)
            }
        }
    }
    
    private func beginEditing() {
        editedTitle = session.title
        isEditing = true
        isFieldFocused = true
    }

    private func finishEditing() {
        isEditing = false
        if !editedTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            if let idx = workspace.terminalSessions.firstIndex(where: { $0.id == session.id }) {
                workspace.terminalSessions[idx].title = editedTitle
            }
        }
    }
}

private struct LogPane: View {
    @Bindable var workspace: WorkspaceState
    let selectedTab: Int
    @State private var stdinInput = ""
    @State private var prettyPrintedMessageIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            if let failure = workspace.runFailure {
                RunFailureBanner(workspace: workspace, failure: failure)
            }
            if workspace.consoleOutput.isEmpty && workspace.runFailure == nil && !workspace.isRunning {
                UnifiedEmptyState.empty(
                    symbol: "terminal",
                    badge: "terminal",
                    title: "No Output Yet",
                    message: "Run, build, or test your Go project to see output here.",
                    actionTitle: KeymapStore.shared.labeled("Run", "product.run"),
                    action: { workspace.runProject() }
                )
                .background(ThemeColor.editorSurface)
            } else if !workspace.consoleOutput.isEmpty && filteredMessages.isEmpty {
                UnifiedEmptyState.filteredEmpty(itemNoun: "Log Lines") {
                    workspace.consoleFilterText = ""
                }
                .background(ThemeColor.editorSurface)
            } else {
                log
            }
            if workspace.isRunning && !workspace.isTestRunning && !workspace.debug.isDebugMode && workspace.activeGoCommand == nil {
                Divider()
                stdinBar
            }
        }
    }

    private var stdinBar: some View {
        HStack(spacing: Spacing.standard) {
            Text("›")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Standard input…", text: $stdinInput)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .accessibilityLabel("Standard input")
                .onSubmit {
                    workspace.sendProgramStdin(stdinInput + "\n")
                    stdinInput = ""
                }
            Button("EOF") {
                workspace.sendProgramEOF()
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium).monospaced())
            .foregroundStyle(.secondary)
            .help("Close standard input")
            .accessibilityLabel("Send End of File")
        }
        .padding(.horizontal, Spacing.inset)
        .frame(height: 26)
        .background(ThemeColor.panelSurface)
    }

    private var filteredMessages: [WorkspaceState.LogMessage] {
        let query = workspace.consoleFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspace.consoleOutput }
        return workspace.consoleOutput.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var log: some View {
        ConsoleLogView(
            messages: filteredMessages,
            normalColor: CodeSurfaceTheme.nsTextPrimary,
            background: CodeSurfaceTheme.nsBackground,
            isDark: CodeSurfaceTheme.isDark,
            prettyMessageIDs: $prettyPrintedMessageIDs
        )
    }
}
