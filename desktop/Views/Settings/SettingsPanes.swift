import GoLensFoundation
import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var workspace = WorkspaceState.shared
    @AppStorage(WorkspaceState.diagnosticLogsKey) private var diagnosticLogs = false
    @AppStorage(FileIconPalette.coloredKey) private var coloredFileIcons = true
    @AppStorage(ThemeManager.mascotCostumeKey) private var mascotCostume = "default"
    @Bindable private var updater = AppUpdater.shared

    private var updatesFooter: String {
        updater.isAvailable
            ? "GoLens looks for a new release once a day and asks before installing it."
            : "This build was not installed from a GoLens release, so it cannot update itself."
    }

    var body: some View {
        SettingsForm {
            SettingsSection("Appearance", footer: "Colored file icons are tinted by family: Go, containers and deployment, data formats, and web files.") {
                Picker("Theme", selection: $workspace.selectedThemeId) {
                    ForEach(ThemeManager.shared.themes) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .accessibilityLabel("Theme")

                Picker("Gopher Mascot", selection: $mascotCostume) {
                    Text("Classic Go").tag("default")
                    Text("Halloween").tag("halloween")
                    Text("Noel").tag("noel")
                    Text("Lunar New Year").tag("tet")
                    Text("Hacker").tag("hacker")
                }
                .accessibilityLabel("Gopher Mascot")
                .onAppear {
                    if mascotCostume == "auto" {
                        mascotCostume = "default"
                    }
                }
                .onChange(of: mascotCostume) { _, newValue in
                    ThemeManager.shared.applyAppIcon(themeId: workspace.selectedThemeId, costume: newValue)
                }

                Toggle("Colored File Icons", isOn: $coloredFileIcons)
                    .accessibilityLabel("Colored File Icons")
            }

            SettingsSection("Console", footer: "Adds GoLens, gopls and Delve messages and the exact go commands to the console for troubleshooting; Console.app always has them.") {
                Toggle("Show Diagnostic Messages in Console", isOn: $diagnosticLogs)
                    .accessibilityLabel("Show Diagnostic Messages in Console")
            }

            SettingsSection("Updates", footer: updatesFooter) {
                Toggle("Check for Updates Automatically", isOn: $updater.automaticallyChecksForUpdates)
                    .disabled(!updater.isAvailable)
                    .accessibilityLabel("Check for Updates Automatically")
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.isAvailable)
            }
        }
    }
}

struct EditingSettingsPane: View {
    @Bindable var workspace = WorkspaceState.shared
    @Bindable private var aiSuggestions = AICompletionSettings.shared

    private var liveTemplatesValue: String {
        let enabled = LiveTemplateStore.shared.templates.filter(\.isEnabled).count
        return "\(enabled) of \(LiveTemplateStore.shared.templates.count) On"
    }

    private var aiSuggestionsValue: String {
        guard aiSuggestions.isEnabled else { return "Off" }
        return aiSuggestions.selectedModelName ?? "No Model"
    }

    private var inlayHintsValue: String {
        guard workspace.showInlayHints else { return "Off" }
        let kinds = CodeCheck.all.filter { $0.group == .inlayHint }
        return "\(kinds.filter(CodeCheck.isOn).count) of \(kinds.count)"
    }

    private var completionFooter: String {
        workspace.completionAcceptKey == .tab
            ? "Tab inserts the selected completion; Return always starts a new line."
            : "Return inserts the selected completion; Tab always indents."
    }

    var body: some View {
        SettingsForm {
            SettingsSection("Text", footer: "Go files always indent with tabs, as gofmt requires.") {
                LabeledContent("Font Size") {
                    Stepper(value: $workspace.editorFontSize, in: 6...72, step: 1) {
                        Text("\(Int(workspace.editorFontSize)) pt")
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Font Size")
                    .accessibilityValue("\(Int(workspace.editorFontSize)) points")
                }

                Picker("Indent Width", selection: $workspace.defaultTabSize) {
                    Text("2 Spaces").tag(2)
                    Text("4 Spaces").tag(4)
                    Text("8 Spaces").tag(8)
                }
                .accessibilityLabel("Indent Width")
            }

            SettingsSection("Completion", footer: completionFooter) {
                Picker("Accept Completions With", selection: $workspace.completionAcceptKey) {
                    Text("Tab").tag(CompletionAcceptKey.tab)
                    Text("Return").tag(CompletionAcceptKey.returnKey)
                }
                .accessibilityLabel("Accept Completions With")
                SettingsDrillDownRow(title: "AI Suggestions", symbol: "sparkles", tint: .purple, value: aiSuggestionsValue, page: .aiSuggestions)
                SettingsDrillDownRow(title: "Live Templates", symbol: "text.badge.plus", tint: .teal, value: liveTemplatesValue, page: .liveTemplates)
            }

            SettingsSection("Display", footer: "Automatic uses the right-hand lens column on wide external displays and switches to inline end-of-line annotations on 13-inch MacBooks or split panes. Usage and implementation counts come from gopls; turn them off in large projects if completion slows down.") {
                SettingsDrillDownRow(title: "Inlay Hints", symbol: "text.word.spacing", tint: .indigo, value: inlayHintsValue, page: .inlayHints)
                Picker("Code Lenses", selection: $workspace.opticalLensDisplayMode) {
                    ForEach(OpticalLensDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .accessibilityLabel("Code Lenses")
                Toggle("Show Usage Counts", isOn: $workspace.showUsageCounts)
                    .accessibilityLabel("Show Usage Counts")
                Toggle("Show Minimap", isOn: $workspace.showMinimap)
                    .accessibilityLabel("Show Minimap")
                Toggle("Wrap Lines", isOn: $workspace.wordWrapEnabled)
                    .accessibilityLabel("Wrap Lines")
            }

            SettingsSection("Tabs", footer: "Single-clicking a file in the Files navigator opens it in one reusable tab; double-clicking or editing keeps it open.") {
                Toggle("Preview Tab on Single-Click", isOn: $workspace.enablePreviewTab)
                    .accessibilityLabel("Preview Tab on Single-Click")
            }

            SettingsSection("Saving", footer: "Go files are formatted with gofmt and goimports through gopls; auto-save also runs before running and testing.") {
                Toggle("Format on Save", isOn: $workspace.formatOnSave)
                    .accessibilityLabel("Format on Save")
                Toggle("Organize Imports on Save", isOn: $workspace.organizeImportsOnSave)
                    .accessibilityLabel("Organize Imports on Save")
                Toggle("Auto-Save When Switching Apps", isOn: $workspace.autoSaveOnFocusLoss)
                    .accessibilityLabel("Auto-Save When Switching Apps")
            }
        }
    }
}

struct InlayHintsSettingsPage: View {
    @Bindable var workspace = WorkspaceState.shared

    var body: some View {
        SettingsForm {
            SettingsSection(footer: "Dimmed types and parameter names from gopls inside Go code. View ▸ Inlay Hints turns them all on or off.") {
                Toggle("Show Inlay Hints", isOn: $workspace.showInlayHints)
                    .accessibilityLabel("Show Inlay Hints")
            }

            SettingsSection("Kinds") {
                CodeCheckToggles(group: .inlayHint)
                    .disabled(!workspace.showInlayHints)
            }
        }
    }
}

struct CodeChecksSettingsPane: View {
    @Bindable var workspace = WorkspaceState.shared
    @AppStorage(WorkspaceState.golangciLintOnSaveKey) private var golangciLintOnSave = true
    @AppStorage(WorkspaceState.safetyAnalyzersEnabledKey) private var safetyAnalyzersOnSave = true
    @State private var safetyCategoryRevision = 0

    var body: some View {
        SettingsForm {
            SettingsSection("Go Safety Analyzers", footer: "Fast AST checks run in the background when opening or saving Go files and appear inline with Quick Fixes.") {
                Toggle("Run Go Safety Analyzers", isOn: $safetyAnalyzersOnSave)
                    .accessibilityLabel("Run Go Safety Analyzers")
                    .onChange(of: safetyAnalyzersOnSave) { _, isOn in
                        if isOn {
                            workspace.rerunSafetyAnalyzersForOpenFiles()
                        } else {
                            workspace.clearSafetyDiagnostics()
                        }
                    }

                ForEach(SafetyAnalyzerCategory.all) { category in
                    Toggle(isOn: Binding(
                        get: {
                            _ = safetyCategoryRevision
                            return WorkspaceState.isSafetyCategoryEnabled(category.id)
                        },
                        set: { isOn in
                            WorkspaceState.setSafetyCategoryEnabled(category.id, isOn)
                            safetyCategoryRevision += 1
                            workspace.rerunSafetyAnalyzersForOpenFiles()
                        }
                    )) {
                        Text(category.title)
                        Text(category.subtitle)
                    }
                    .disabled(!safetyAnalyzersOnSave)
                    .accessibilityLabel(category.title)
                    .accessibilityHint(category.subtitle)
                }
            }

            SettingsSection("Correctness") {
                CodeCheckToggles(group: .correctness)
            }

            SettingsSection("Style") {
                CodeCheckToggles(group: .style)
            }

            SettingsSection("Performance", footer: "These checks run in gopls and appear as warnings in the editor and the Issues navigator.") {
                CodeCheckToggles(group: .performance)
            }

            SettingsSection("Linter", footer: "Lints the saved file’s package when golangci-lint is installed and the workspace has a .golangci configuration file.") {
                Toggle("Run golangci-lint on Save", isOn: $golangciLintOnSave)
                    .accessibilityLabel("Run golangci-lint on Save")
                    .onChange(of: golangciLintOnSave) { _, isOn in
                        if !isOn { workspace.clearLintDiagnostics() }
                    }
            }
        }
    }
}

private struct SafetyAnalyzerCategory: Identifiable {
    let id: String
    let title: String
    let subtitle: String

    static let all: [SafetyAnalyzerCategory] = [
        SafetyAnalyzerCategory(
            id: "concurrency",
            title: "Concurrency & Context",
            subtitle: "Missing context cancel calls, unstopped tickers and lock misuse."
        ),
        SafetyAnalyzerCategory(
            id: "resourceSafety",
            title: "Resource & Network Safety",
            subtitle: "Unclosed HTTP response bodies, missing client timeouts and leaked handles."
        ),
        SafetyAnalyzerCategory(
            id: "errorHandling",
            title: "Error Wrapping & Chains",
            subtitle: "fmt.Errorf error verbs and sentinel comparisons."
        ),
        SafetyAnalyzerCategory(
            id: "security",
            title: "Security & Sensitive Data",
            subtitle: "Sensitive struct fields exposed to JSON, weak hashes and SQL concatenation."
        ),
        SafetyAnalyzerCategory(
            id: "modernization",
            title: "Go Modernization",
            subtitle: "Legacy interface{} aliases and pre-allocation opportunities."
        ),
    ]
}

private struct CodeCheckToggles: View {
    let group: CodeCheck.Group

    var body: some View {
        ForEach(CodeCheck.all.filter { $0.group == group }) { check in
            Toggle(isOn: Binding(get: { CodeCheck.isOn(check) }, set: { CodeCheck.set(check, $0) })) {
                Text(check.title)
                Text(check.detail)
            }
            .accessibilityLabel(check.title)
            .accessibilityHint(check.detail)
        }
    }
}

struct CodeCheck: Identifiable {
    enum Group {
        case correctness, style, performance, inlayHint
    }

    let id: String
    let title: String
    let detail: String
    let group: Group
    let isHint: Bool
    let defaultOn: Bool

    static let all: [CodeCheck] = [
        CodeCheck(id: "ignoredError", title: "Dropped Errors", detail: "Marks calls whose error result is ignored.", group: .correctness, isHint: true, defaultOn: true),
        CodeCheck(id: "SA4006", title: "Values Never Read", detail: "Assignments overwritten before use.", group: .correctness, isHint: false, defaultOn: true),
        CodeCheck(id: "SA1000", title: "Invalid Regular Expressions", detail: "regexp patterns that fail to compile.", group: .correctness, isHint: false, defaultOn: true),
        CodeCheck(id: "ST1005", title: "Error String Style", detail: "Error strings that are capitalized or end with punctuation.", group: .style, isHint: false, defaultOn: true),
        CodeCheck(id: "shadow", title: "Shadowed Variables", detail: "Declarations that hide an outer variable.", group: .correctness, isHint: false, defaultOn: false),
        CodeCheck(id: "ST1003", title: "Identifier Naming", detail: "Names that don’t follow Go conventions.", group: .style, isHint: false, defaultOn: false),
        CodeCheck(id: "ST1016", title: "Receiver Names", detail: "Methods of one type with different receiver names.", group: .style, isHint: false, defaultOn: false),
        CodeCheck(id: "fieldalignment", title: "Struct Padding", detail: "Structs that use less memory with reordered fields.", group: .performance, isHint: false, defaultOn: false),
        CodeCheck(id: "escape", title: "Escape Analysis (Heap Allocations)", detail: "Shows inline compiler hints when variables escape to the heap.", group: .performance, isHint: true, defaultOn: false),
        CodeCheck(id: "assignVariableTypes", title: "Variable Types", detail: "The type after each variable declared with :=.", group: .inlayHint, isHint: true, defaultOn: true),
        CodeCheck(id: "rangeVariableTypes", title: "Range Variable Types", detail: "The key and value types in for … range loops.", group: .inlayHint, isHint: true, defaultOn: true),
        CodeCheck(id: "parameterNames", title: "Parameter Names", detail: "The parameter name before each argument in a call.", group: .inlayHint, isHint: true, defaultOn: true),
    ]

    private static func store(_ hint: Bool) -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: hint ? "GoLensCodeHints" : "GoLensCodeChecks") as? [String: Bool] ?? [:]
    }

    static func isOn(_ check: CodeCheck) -> Bool {
        store(check.isHint)[check.id] ?? check.defaultOn
    }

    static func set(_ check: CodeCheck, _ on: Bool) {
        var d = store(check.isHint)
        d[check.id] = on
        UserDefaults.standard.set(d, forKey: check.isHint ? "GoLensCodeHints" : "GoLensCodeChecks")
        apply()
    }

    static func apply() {
        var analyses: [String: Bool] = [:]
        var hints: [String: Bool] = [:]
        for c in all {
            if c.isHint { hints[c.id] = isOn(c) } else { analyses[c.id] = isOn(c) }
        }
        jsonText(["analyses": analyses, "hints": hints]).withCString { SetGoplsOptions($0) }
    }
}
