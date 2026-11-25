import SwiftUI

struct ConsoleHeaderView: View {
    @Bindable var workspace: WorkspaceState
    @Binding var selectedTab: Int

    var body: some View {
        HStack(spacing: Spacing.standard) {
            Picker("Panel", selection: $selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tabLabel(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            if selectedTab == WorkspaceState.terminalTab {
                Divider()
                    .frame(height: 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.compact) {
                        ForEach(workspace.terminalSessions) { session in
                            TerminalTabButton(session: session)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Button(action: newTerminalSession) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(workspace.terminalSessions.count >= WorkspaceState.maxTerminalSessions)
                .help("New Terminal Session")
                .accessibilityLabel("New Terminal Session")
            } else if selectedTab == WorkspaceState.consoleTab && hasRunSessionPills {
                Divider()
                    .frame(height: 14)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.compact) {
                        ForEach(workspace.runSessions) { session in
                            runSessionTabItem(session)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }

            HStack(spacing: Spacing.standard) {
                if workspace.debug.isDebugMode {
                    HStack(spacing: Spacing.compact) {
                        if workspace.isDebuggerPaused {
                            Button(action: {
                                workspace.debugContinue()
                            }) {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(KeymapStore.shared.labeled("Continue", "debug.continue"))
                            .accessibilityLabel("Continue")
                        } else {
                            Button(action: {
                                workspace.debugPause()
                            }) {
                                Image(systemName: "pause.fill")
                            }
                            .buttonStyle(.borderless)
                            .help(KeymapStore.shared.labeled("Pause", "debug.pause"))
                            .accessibilityLabel("Pause")
                        }
                        
                        Button(action: {
                            workspace.debugStepOver()
                        }) {
                            Image(systemName: "arrow.turn.down.right")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!workspace.isDebuggerPaused)
                        .help(KeymapStore.shared.labeled("Step Over", "debug.stepOver"))
                        .accessibilityLabel("Step Over")
                        
                        Button(action: {
                            workspace.debugStepInto()
                        }) {
                            Image(systemName: "arrow.down.to.line")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!workspace.isDebuggerPaused)
                        .help(KeymapStore.shared.labeled("Step Into", "debug.stepInto"))
                        .accessibilityLabel("Step Into")
                        
                        Button(action: {
                            workspace.debugStepOut()
                        }) {
                            Image(systemName: "arrow.up.to.line")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!workspace.isDebuggerPaused)
                        .help(KeymapStore.shared.labeled("Step Out", "debug.stepOut"))
                        .accessibilityLabel("Step Out")
                        
                        Button(action: {
                            workspace.debugStop()
                        }) {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(KeymapStore.shared.labeled("Stop Debugging", "product.stop"))
                        .accessibilityLabel("Stop Debugging")
                    }
                    .padding(.horizontal, Spacing.standard)
                    .padding(.vertical, Spacing.compact)
                    .background(ThemeColor.wellFill)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
                }

                if selectedTab == WorkspaceState.requestsTab {
                    Button(action: {
                        workspace.http.clearHistory()
                    }) {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    .buttonStyle(.borderless)
                    .disabled(!workspace.http.entries.contains { !$0.isRunning })
                    .help("Clear Request History")
                    .accessibilityLabel("Clear Request History")
                }

                if selectedTab == WorkspaceState.databaseTab {
                    databaseActions
                }

                if selectedTab == WorkspaceState.servicesTab {
                    ServicesHeaderControls(workspace: workspace)
                }

                if selectedTab == WorkspaceState.consoleTab {
                    PanelFilterBar(
                        placeholder: "Filter console…",
                        text: $workspace.consoleFilterText,
                        leadingSymbol: "line.3.horizontal.decrease.circle",
                        accessibilityTitle: "Filter Console Output"
                    )
                    .frame(width: 172)

                    Button(action: {
                        workspace.clearConsoleOutput()
                    }) {
                        Image(systemName: "trash")
                            .font(.subheadline)
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                    .buttonStyle(.borderless)
                    .disabled(workspace.consoleOutput.isEmpty)
                    .help("Clear Console")
                    .accessibilityLabel("Clear Console")
                }
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .frame(height: 28)
        .background(ThemeColor.panelSurface)
        .onAppear {
            if !availableTabs.contains(selectedTab) { selectedTab = WorkspaceState.consoleTab }
        }
        .onChange(of: workspace.debug.isDebugMode) {
            if !availableTabs.contains(selectedTab) { selectedTab = WorkspaceState.consoleTab }
        }
        .onChange(of: workspace.hasSafetyData) {
            if !availableTabs.contains(selectedTab) { selectedTab = WorkspaceState.consoleTab }
        }
        .onChange(of: workspace.activeFilePath) {
            if !availableTabs.contains(selectedTab) { selectedTab = WorkspaceState.consoleTab }
        }
    }

    @ViewBuilder
    private var databaseActions: some View {
        let database = workspace.databaseUI
        if database.uiIsRunningAny {
            Button(action: { database.uiStopRunning() }) {
                Image(systemName: "stop.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .buttonStyle(.borderless)
            .help(KeymapStore.shared.labeled("Stop Statement", DatabaseCommandID.stopStatement))
            .accessibilityLabel("Stop Statement")
        }
        if let result = database.uiSelectedResult {
            Button(action: { database.uiCloseResult(id: result.id) }) {
                Image(systemName: "xmark")
                    .font(.subheadline)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
            .buttonStyle(.borderless)
            .help("Close Result")
            .accessibilityLabel("Close Result")
        }
    }

    private var hasRunSessionPills: Bool {
        workspace.runSessions.count > 1 || workspace.runSessions.contains(where: { $0.key.hasPrefix("docker:") || $0.key.hasPrefix("make:") })
    }

    private func runSessionTabItem(_ session: RunSession) -> some View {
        let isSelected = workspace.selectedRunSessionId == session.id
        let isDark = workspace.currentTheme.resolvedIsDark
        return HStack(spacing: Spacing.row) {
            Button {
                workspace.selectRunSession(session.id)
            } label: {
                HStack(spacing: Spacing.row) {
                    Circle()
                        .fill(session.isRunning ? StatusTone.success.tint : ChromeColor.textSecondary)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(session.title)
                        .font(.subheadline.weight(isSelected ? .medium : .regular))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Switch to \(session.title) in \((session.dir as NSString).lastPathComponent)")

            if isSelected {
                Button {
                    workspace.copyRunCommand(session)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy Command")
                .accessibilityLabel("Copy Command")
            }

            if session.isRunning {
                Button {
                    workspace.stopRunSession(session.id)
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption.weight(.medium))
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Stop \(session.title)")
                .accessibilityLabel("Stop \(session.title)")
            } else {
                Button {
                    workspace.closeRunSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close \(session.title)")
                .accessibilityLabel("Close \(session.title)")
            }
        }
        .padding(.horizontal, Spacing.standard)
        .padding(.vertical, Spacing.compact)
        .contextMenu {
            Button("Copy Command", systemImage: "doc.on.doc") { workspace.copyRunCommand(session) }
        }
        .background(workspace.tabBackgroundColor(isActive: isSelected, isDark: isDark))
        .foregroundStyle(workspace.tabTextColor(isActive: isSelected, isDark: isDark))
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                    .strokeBorder(ChromeColor.separator.opacity(0.45), lineWidth: Stroke.hairline)
            }
        }
    }

    private var availableTabs: [Int] {
        var tabs = workspace.debug.isDebugMode
            ? [WorkspaceState.debuggerTab, WorkspaceState.consoleTab, WorkspaceState.terminalTab, WorkspaceState.profilerTab]
            : [WorkspaceState.consoleTab, WorkspaceState.terminalTab, WorkspaceState.profilerTab]
        if workspace.hasSafetyData || !workspace.safetyFindings.isEmpty || workspace.isSafetyAuditRunning {
            tabs.append(WorkspaceState.safetyTab)
        }
        if workspace.isActiveFileHTTP || workspace.http.hasHistory || selectedTab == WorkspaceState.requestsTab {
            tabs.append(WorkspaceState.requestsTab)
        }
        let database = workspace.databaseUI
        if !database.uiDataSources.isEmpty,
           EcosystemDocumentTools.isSQLFile(workspace.activeFilePath) || !database.uiResults.isEmpty || database.uiIsRunningAny || selectedTab == WorkspaceState.databaseTab {
            tabs.append(WorkspaceState.databaseTab)
        }
        if selectedTab == WorkspaceState.servicesTab || ServicesStore.shared.isRelevant(for: workspace) {
            tabs.append(WorkspaceState.servicesTab)
        }
        return tabs
    }

    private func tabLabel(_ index: Int) -> String {
        switch index {
        case WorkspaceState.debuggerTab: return "Debugger"
        case WorkspaceState.terminalTab: return "Terminal"
        case WorkspaceState.profilerTab: return "Profiler"
        case WorkspaceState.safetyTab: return "Safety"
        case WorkspaceState.requestsTab: return "Requests"
        case WorkspaceState.databaseTab: return "Database"
        case WorkspaceState.servicesTab: return "Services"
        default: return "Console"
        }
    }

    private func newTerminalSession() {
        let newSession = TerminalSession(id: UUID().uuidString, title: "zsh")
        workspace.terminalSessions.append(newSession)
        workspace.selectedTerminalId = newSession.id
    }
}
