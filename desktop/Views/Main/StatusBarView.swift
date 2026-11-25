import SwiftUI

struct StatusBarView: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var secondaryColor: Color {
        ThemeColor.textSecondary
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: Spacing.comfortable) {
                if !workspace.activeWorkspacePath.isEmpty,
                   workspace.git.isRepository != false,
                   let operation = workspace.sourceControl.runningOperation {
                    GitOperationStatusItem(title: operation.progressTitle) { workspace.stopRemoteOperation() }
                }

                WorkspaceHealthItem(workspace: workspace)

                if !workspace.activeWorkspacePath.isEmpty {
                    BuildTargetStatusBarItem()
                }

                if workspace.showsDockerStatus {
                    DockerStatusBarItem(workspace: workspace)
                }

                Spacer()

                HStack(spacing: Spacing.standard) {
                    CursorPositionText(workspace: workspace)

                    if workspace.activeFilePath.isEmpty {
                        EmptyView()
                    } else if workspace.activeFileUsesTabs {
                        Text("Tabs")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(secondaryColor)
                            .help("Go files indent with tabs, as gofmt requires")
                    } else {
                        Menu {
                            Picker("Indentation", selection: $workspace.tabSize) {
                                Text("2 Spaces").tag(2)
                                Text("4 Spaces").tag(4)
                                Text("8 Spaces").tag(8)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text("Spaces: \(workspace.tabSize)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(secondaryColor)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Indentation (Editor menu)")
                        .accessibilityLabel("Indentation")
                        .accessibilityValue("\(workspace.tabSize) spaces")
                    }

                    if !workspace.activeFilePath.isEmpty {
                        Text("UTF-8")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(secondaryColor)
                            .help("Text encoding")

                        Text(workspace.activeLineEnding)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(secondaryColor)
                            .help("Line endings")
                    }

                    AISuggestionsStatusBarItem()

                    Divider()
                        .frame(height: 12)

                    Button(action: {
                        withAnimation(reduceMotion ? nil : Motion.standard) {
                            workspace.showConsole.toggle()
                        }
                    }) {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(workspace.showConsole ? ThemeColor.accent : secondaryColor)
                    }
                    .buttonStyle(.borderless)
                    .help(KeymapStore.shared.labeled(workspace.showConsole ? "Hide Console" : "Show Console", "view.console"))
                    .accessibilityLabel(workspace.showConsole ? "Hide Console" : "Show Console")
                }
            }
            .padding(.horizontal, Spacing.standard)
            .frame(height: 24)
        }
        .background(ThemeColor.panelSurface)
    }
}

private struct CursorPositionText: View {
    let workspace: WorkspaceState

    var body: some View {
        Text(workspace.displayCursorPosition)
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(ThemeColor.textSecondary)
            .frame(minWidth: workspace.displayCursorPosition.isEmpty ? 0 : 120, alignment: .trailing)
    }
}

@MainActor
func openAISuggestionsSettings() {
    UserDefaults.standard.set(SettingsPage.aiSuggestions.paneID, forKey: "GoLensSettingsPane")
    UserDefaults.standard.set(SettingsPage.aiSuggestions.rawValue, forKey: SettingsPage.pendingKey)
    if let appMenu = NSApp.mainMenu?.items.first?.submenu,
       let item = appMenu.items.first(where: { $0.keyEquivalent == "," }) {
        appMenu.performActionForItem(at: appMenu.index(of: item))
        return
    }
    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
}

private struct AISuggestionsStatusBarItem: View {
    @Bindable private var settings = AICompletionSettings.shared

    var body: some View {
        if settings.isEnabled, let pause = settings.pause {
            Menu {
                Toggle("Suggest Code While Typing", isOn: $settings.isEnabled)
                Text(settings.selectedModelName.map { "Model: \($0)" } ?? "No model chosen")
                Text("Paused: \(pause.reason)")
                Divider()
                Button("AI Suggestion Settings…") { openAISuggestionsSettings() }
            } label: {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: StatusTone.warning.symbol)
                        .font(.caption.weight(.medium))
                        .accessibilityHidden(true)
                    Text("Suggestions Paused")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(StatusTone.warning.tint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("AI Suggestions paused: \(pause.reason)")
            .accessibilityLabel("AI Suggestions")
            .accessibilityValue("Suggestions paused: \(pause.reason)")
        }
    }
}

struct StatusBarItemLabel<Trailing: View>: View {
    let symbol: String
    let title: String
    var horizontalPadding: CGFloat = Spacing.compact
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let secondaryColor = ThemeColor.textSecondary
        HStack(spacing: Spacing.compact) {
            Image(systemName: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(secondaryColor)
                .accessibilityHidden(true)

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(secondaryColor)
                .lineLimit(1)

            trailing()
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, Spacing.hairline)
        .contentShape(Rectangle())
    }
}

extension StatusBarItemLabel where Trailing == EmptyView {
    init(symbol: String, title: String, horizontalPadding: CGFloat = Spacing.compact) {
        self.init(symbol: symbol, title: title, horizontalPadding: horizontalPadding) {
            EmptyView()
        }
    }
}

private struct GitOperationStatusItem: View {
    let title: String
    let stop: () -> Void

    var body: some View {
        HStack(spacing: Spacing.compact) {
            ProgressView()
                .controlSize(.mini)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Button(action: stop) {
                Image(systemName: "stop.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Stop")
            .accessibilityLabel("Stop \(title.replacingOccurrences(of: "…", with: ""))")
        }
        .accessibilityElement(children: .contain)
    }
}
