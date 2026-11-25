import SwiftUI
import AppKit

struct BreadcrumbStep: Identifiable, Equatable {
    var id: String {
        "\(isSymbol ? "s" : isDirectory ? "d" : "f")|\(fullPath)|\(line ?? -1)|\(col ?? -1)|\(name)"
    }
    let name: String
    let fullPath: String
    let isDirectory: Bool
    let isSymbol: Bool
    let line: Int?
    let col: Int?
}

struct BreadcrumbBarView: View {
    @Bindable var workspace: WorkspaceState
    var paneID: EditorPaneID = .primary
    var isFocused: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    private var pane: EditorPaneState {
        workspace.paneState(for: paneID)
    }

    private var paneFilePath: String {
        workspace.filePath(for: paneID)
    }

    private var itemForeground: Color {
        isFocused ? ThemeColor.textPrimary : Color.secondary
    }

    var body: some View {
        let steps = getSteps()
        let currentMode = workspace.editorMode(for: paneFilePath)
        let hasCommitDiff = workspace.git.activeCommitDiffContext != nil && paneFilePath == workspace.activeFilePath
        let hasDiff = !paneFilePath.isEmpty && (workspace.gitStatus(for: paneFilePath) != nil || hasCommitDiff || currentMode == .diff)
        let isInsideRepo = !paneFilePath.isEmpty && workspace.git.isRepository == true && (
            workspace.activeWorkspacePath.isEmpty || paneFilePath.hasPrefix(workspace.activeWorkspacePath + "/")
        )
        let showModeSwitcher = !paneFilePath.isEmpty && (isInsideRepo || hasDiff)

        HStack(spacing: Spacing.comfortable) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.compact) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .imageScale(.small)
                                .foregroundStyle(Color(nsColor: .secondaryLabelColor).opacity(0.6))
                        }

                        if step.isSymbol {
                            symbolMenu(step)
                        } else if step.isDirectory {
                            directoryMenu(step)
                        } else {
                            fileMenu(step)
                        }
                    }
                }
                .padding(.vertical, Spacing.compact)
                .padding(.horizontal, Spacing.row)
            }
            .clipped()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: Spacing.standard)

            if currentMode != .diff {
                documentContextControls
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

            if showModeSwitcher {
                let canOpenCode = FileManager.default.fileExists(atPath: paneFilePath) || workspace.documentSession(forPath: paneFilePath) != nil
                let modeHelp: String = if !canOpenCode {
                    "File does not exist in the working tree"
                } else if !hasDiff {
                    "File has no uncommitted changes"
                } else {
                    "Switch between Code and Git Diff"
                }
                HStack(spacing: Spacing.standard) {
                    if currentMode == .diff {
                        DiffControls(filePath: paneFilePath)
                    }
                    Picker("Editor Mode", selection: Binding(
                        get: { workspace.editorMode(for: paneFilePath) },
                        set: { newMode in
                            if newMode == .code {
                                guard canOpenCode else { return }
                                if paneFilePath == workspace.activeFilePath {
                                    workspace.clearCommitDiffContext()
                                }
                            } else if newMode == .diff {
                                guard hasDiff else { return }
                            }
                            workspace.setEditorMode(newMode, for: paneFilePath)
                        }
                    )) {
                        Text("Code")
                            .tag(WorkspaceState.EditorMode.code)
                            .selectionDisabled(!canOpenCode)
                        Text("Diff")
                            .tag(WorkspaceState.EditorMode.diff)
                            .selectionDisabled(!hasDiff)
                            .help(hasDiff ? "Show Git Diff" : "File has no uncommitted changes")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(currentMode == .diff && !canOpenCode)
                    .background(
                        EditorModeSegmentSync(
                            codeEnabled: canOpenCode,
                            diffEnabled: hasDiff,
                            diffHelp: hasDiff ? "Switch between Code and Git Diff" : "File has no uncommitted changes"
                        )
                    )
                    .accessibilityLabel("Editor Mode")
                    .help(modeHelp)
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .padding(.trailing, workspace.isSplitMode ? 0 : Spacing.standard)
            }
        }
        .frame(height: 26)
        .onChange(of: steps) { _, updated in
            if pane.breadcrumbSegments != updated {
                pane.breadcrumbSegments = updated
            }
        }
    }

    @ViewBuilder
    private var documentContextControls: some View {
        if paneID == .primary && workspace.isActiveFileScratch {
            Button(action: { workspace.runGoScratchFile() }) {
                Label("Run Scratch", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Run Go Scratchpad")
        } else if paneFilePath.hasSuffix(".md") || paneFilePath.hasSuffix(".markdown") {
            if !(workspace.isSplitMode && paneID == .secondary && paneFilePath == workspace.activeFilePath) {
                Picker("Markdown Mode", selection: Binding(
                    get: { workspace.markdownPreviewMode[paneFilePath] ?? false },
                    set: { workspace.markdownPreviewMode[paneFilePath] = $0 }
                )) {
                    Text("Source").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 116)
                .help("Switch between Markdown source and rendered preview")
            }
        } else if EcosystemDocumentTools.isHTTPFile(paneFilePath) {
            HTTPFileControlsView(workspace: workspace, path: paneFilePath)
        } else if EcosystemDocumentTools.isSQLFile(paneFilePath) {
            SQLConsoleControlsView(workspace: workspace, path: paneFilePath)
        } else if EcosystemDocumentTools.isJSONFile(paneFilePath) {
            Button(action: {
                workspace.focusPane(paneID)
                workspace.formatActiveDocument()
            }) {
                Label("Format", systemImage: "text.alignleft")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(KeymapStore.shared.labeled("Pretty-Print JSON", "editor.format"))
        } else if EcosystemDocumentTools.isYAMLFile(paneFilePath) {
            Button(action: {
                workspace.focusPane(paneID)
                workspace.formatActiveDocument()
            }) {
                Label("Format", systemImage: "text.alignleft")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(KeymapStore.shared.labeled("Normalize YAML Indentation", "editor.format"))
        } else if EcosystemDocumentTools.isEnvFile(paneFilePath) {
            HStack(spacing: Spacing.row) {
                Button(action: {
                    workspace.envSecretsMasked.toggle()
                    workspace.primaryTextView?.needsDisplay = true
                    workspace.secondaryTextView?.needsDisplay = true
                }) {
                    Label(
                        workspace.envSecretsMasked ? "Show Secrets" : "Mask Secrets",
                        systemImage: workspace.envSecretsMasked ? "eye" : "eye.slash"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(workspace.envSecretsMasked ? "Reveal Sensitive .env Values" : "Mask Sensitive .env Values")

                Button(action: { workspace.applyEnvFileToActiveRunConfig(envPath: paneFilePath) }) {
                    Label("Apply to Run Config", systemImage: "play.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Load .env Variables into Active Run Configuration")
            }
        }
    }

    private func directoryMenu(_ step: BreadcrumbStep) -> some View {
        Menu {
            BreadcrumbFolderMenuItems(path: step.fullPath, level: 0, paneID: paneID)
        } label: {
            HStack(spacing: Spacing.compact) {
                FileIconView(fileName: step.name, path: step.fullPath, isFolder: true, isSelected: false, size: 14, inMenuLabel: true)
                Text(step.name)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(itemForeground)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    private func jumpInCurrentPane(line: Int, col: Int) {
        workspace.focusPane(paneID)
        if let tv = workspace.editorTextView(for: paneID) ?? (workspace.activeTextView as? GoLensTextView) {
            tv.jumpTo(path: paneFilePath, line: line, col: col)
        } else if paneID == .secondary {
            workspace.openFileInSplit(paneFilePath, line: line, column: col)
        } else {
            workspace.jumpTo(filePath: paneFilePath, line: line, column: col)
        }
    }

    @ViewBuilder
    private func secondaryPaneTabSwitchSection() -> some View {
        if workspace.isSplitMode && paneID == .secondary {
            if let counterpart = workspace.resolveCounterpart(for: workspace.activeFilePath),
               FileManager.default.fileExists(atPath: counterpart.path) {
                Button {
                    workspace.isCounterpartSplitEnabled = false
                    workspace.secondaryFilePath = counterpart.path
                } label: {
                    Label("Counterpart: \((counterpart.path as NSString).lastPathComponent)", systemImage: "doc.on.doc")
                }
                Divider()
            }
            Section("Open Tabs") {
                ForEach(workspace.openFiles, id: \.self) { openPath in
                    Button {
                        workspace.isCounterpartSplitEnabled = false
                        workspace.secondaryFilePath = openPath
                    } label: {
                        HStack {
                            Text((openPath as NSString).lastPathComponent)
                            if openPath == paneFilePath {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private func fileMenuLabel(_ step: BreadcrumbStep) -> some View {
        HStack(spacing: Spacing.compact) {
            FileIconView(fileName: step.name, path: step.fullPath, isSelected: false, size: 14, inMenuLabel: true)
            Text(step.name)
                .font(.subheadline.monospaced())
                .foregroundStyle(itemForeground)
            if workspace.isSplitMode && workspace.editedFiles.contains(step.fullPath) {
                Circle()
                    .fill(ThemeColor.textSecondary)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Edited")
            }
        }
    }

    @ViewBuilder
    private func fileMenu(_ step: BreadcrumbStep) -> some View {
        let isGoFile = step.fullPath.hasSuffix(".go")
        let decls = isGoFile ? pane.goDeclarations : []
        let docSymbols = isGoFile ? [] : pane.documentSymbols
        if isGoFile {
            Menu {
                secondaryPaneTabSwitchSection()
                if decls.isEmpty {
                    Text("No Symbols")
                        .font(.subheadline)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                } else {
                    ForEach(decls, id: \.symbolName) { decl in
                        Button(action: {
                            jumpInCurrentPane(line: decl.line, col: decl.col)
                        }) {
                            Label {
                                Text(decl.symbolName)
                            } icon: {
                                SymbolIconView(kind: decl.kind, isSelected: false, size: 14, inMenuLabel: true)
                            }
                        }
                    }
                }
            } label: {
                fileMenuLabel(step)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
        } else if !docSymbols.isEmpty || (workspace.isSplitMode && paneID == .secondary) {
            Menu {
                secondaryPaneTabSwitchSection()
                ForEach(Array(docSymbols.enumerated()), id: \.offset) { _, sym in
                    Button(action: {
                        let line = sym.selectionRange.start.line + 1
                        let col = sym.selectionRange.start.character + 1
                        jumpInCurrentPane(line: line, col: col)
                    }) {
                        Label {
                            Text(sym.name)
                        } icon: {
                            SymbolIconView(lspKind: sym.kind, isSelected: false, size: 14, inMenuLabel: true)
                        }
                    }
                }
            } label: {
                fileMenuLabel(step)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
        } else {
            fileMenuLabel(step)
                .padding(.horizontal, Spacing.compact)
                .padding(.vertical, Spacing.hairline)
        }
    }

    private func symbolMenu(_ step: BreadcrumbStep) -> some View {
        let isGoFile = step.fullPath.hasSuffix(".go")
        let decls = pane.goDeclarations
        let docSymbols = pane.documentSymbols
        let activeKind = decls.first(where: { $0.symbolName == step.name })?.kind ?? (isGoFile ? (step.name.first?.isUppercase == true ? "struct" : "func") : "field")
        return Menu {
            if isGoFile {
                ForEach(decls, id: \.symbolName) { decl in
                    Button(action: {
                        jumpInCurrentPane(line: decl.line, col: decl.col)
                    }) {
                        Label {
                            Text(decl.symbolName)
                        } icon: {
                            SymbolIconView(kind: decl.kind, isSelected: false, size: 14, inMenuLabel: true)
                        }
                    }
                }
            } else {
                ForEach(Array(docSymbols.enumerated()), id: \.offset) { _, sym in
                    Button(action: {
                        let line = sym.selectionRange.start.line + 1
                        let col = sym.selectionRange.start.character + 1
                        jumpInCurrentPane(line: line, col: col)
                    }) {
                        Label {
                            Text(sym.name)
                        } icon: {
                            SymbolIconView(lspKind: sym.kind, isSelected: false, size: 14, inMenuLabel: true)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.compact) {
                SymbolIconView(kind: activeKind, isSelected: false, size: 14, inMenuLabel: true)
                Text(step.name)
                    .font(.subheadline.weight(.medium).monospaced())
                    .foregroundStyle(itemForeground)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    private func getSteps() -> [BreadcrumbStep] {
        guard !workspace.activeWorkspacePath.isEmpty,
              !paneFilePath.isEmpty else {
            return []
        }

        var steps: [BreadcrumbStep] = []

        let activeURL = URL(fileURLWithPath: paneFilePath)
        let rootURL = URL(fileURLWithPath: workspace.activeWorkspacePath)

        var components: [String] = []
        var parentURL = activeURL.deletingLastPathComponent()

        if paneFilePath.hasPrefix(workspace.activeWorkspacePath + "/") {
            while parentURL.path != rootURL.path && parentURL.path != "/" {
                components.insert(parentURL.lastPathComponent, at: 0)
                parentURL = parentURL.deletingLastPathComponent()
            }

            var cumulativePath = workspace.activeWorkspacePath
            for comp in components {
                cumulativePath = (cumulativePath as NSString).appendingPathComponent(comp)
                steps.append(BreadcrumbStep(
                    name: comp,
                    fullPath: cumulativePath,
                    isDirectory: true,
                    isSymbol: false,
                    line: nil,
                    col: nil
                ))
            }
        }

        steps.append(BreadcrumbStep(
            name: activeURL.lastPathComponent,
            fullPath: paneFilePath,
            isDirectory: false,
            isSymbol: false,
            line: nil,
            col: nil
        ))

        let paneLine = max(1, pane.cursorLine)

        if paneFilePath.hasSuffix(".go") {
            let sortedDecls = BreadcrumbSymbolCache.declarationsByLineDescending(pane.goDeclarations, for: paneID)
            let activeLine = (paneID == .primary && workspace.debug.activeLine > 0) ? workspace.debug.activeLine : paneLine
            var lo = 0, hi = sortedDecls.count
            while lo < hi {
                let mid = (lo + hi) >> 1
                if sortedDecls[mid].line > activeLine { lo = mid + 1 } else { hi = mid }
            }
            if lo < sortedDecls.count {
                let activeDecl = sortedDecls[lo]
                steps.append(BreadcrumbStep(
                    name: activeDecl.symbolName,
                    fullPath: paneFilePath,
                    isDirectory: false,
                    isSymbol: true,
                    line: activeDecl.line,
                    col: activeDecl.col
                ))
            }
        } else if EcosystemDocumentTools.isNonGoEcosystemFile(paneFilePath),
                  let session = workspace.documents[paneFilePath] {
            let trail = BreadcrumbSymbolCache.trail(for: session, cursorLine: paneLine)
            for item in trail {
                steps.append(BreadcrumbStep(
                    name: item.name,
                    fullPath: paneFilePath,
                    isDirectory: false,
                    isSymbol: true,
                    line: item.line,
                    col: item.col
                ))
            }
        }

        return steps
    }
}

private struct EditorModeSegmentSync: NSViewRepresentable {
    let codeEnabled: Bool
    let diffEnabled: Bool
    let diffHelp: String

    func makeNSView(context: Context) -> SegmentSyncAnchor {
        let view = SegmentSyncAnchor()
        view.apply(codeEnabled: codeEnabled, diffEnabled: diffEnabled, diffHelp: diffHelp)
        return view
    }

    func updateNSView(_ nsView: SegmentSyncAnchor, context: Context) {
        nsView.apply(codeEnabled: codeEnabled, diffEnabled: diffEnabled, diffHelp: diffHelp)
    }

    final class SegmentSyncAnchor: NSView {
        private var lastState: (Bool, Bool, String)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let (c, d, h) = lastState {
                sync(codeEnabled: c, diffEnabled: d, diffHelp: h)
            }
        }

        func apply(codeEnabled: Bool, diffEnabled: Bool, diffHelp: String) {
            lastState = (codeEnabled, diffEnabled, diffHelp)
            if !sync(codeEnabled: codeEnabled, diffEnabled: diffEnabled, diffHelp: diffHelp) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let (c, d, h) = self.lastState else { return }
                    _ = self.sync(codeEnabled: c, diffEnabled: d, diffHelp: h)
                }
            }
        }

        @discardableResult
        private func sync(codeEnabled: Bool, diffEnabled: Bool, diffHelp: String) -> Bool {
            var node: NSView? = superview
            var depth = 0
            while let current = node, depth < 5 {
                if let control = Self.findSegmentedControl(in: current), control.segmentCount == 2 {
                    control.setEnabled(codeEnabled, forSegment: 0)
                    control.setEnabled(diffEnabled, forSegment: 1)
                    control.setToolTip(diffHelp, forSegment: 1)
                    return true
                }
                node = current.superview
                depth += 1
            }
            return false
        }

        private static func findSegmentedControl(in root: NSView) -> NSSegmentedControl? {
            if let seg = root as? NSSegmentedControl {
                return seg
            }
            for sub in root.subviews {
                if let found = findSegmentedControl(in: sub) {
                    return found
                }
            }
            return nil
        }
    }
}

private enum BreadcrumbSymbolCache {
    private static var primaryDeclarations: (source: [WorkspaceState.GoDeclaration], sorted: [WorkspaceState.GoDeclaration])?
    private static var secondaryDeclarations: (source: [WorkspaceState.GoDeclaration], sorted: [WorkspaceState.GoDeclaration])?
    private final class SymbolEntry {
        weak var session: DocumentSession?
        let version: Int
        let symbols: [DocumentSymbol]
        init(session: DocumentSession, version: Int, symbols: [DocumentSymbol]) {
            self.session = session
            self.version = version
            self.symbols = symbols
        }
    }
    private static var symbols: [String: SymbolEntry] = [:]

    static func declarationsByLineDescending(_ decls: [WorkspaceState.GoDeclaration], for paneID: EditorPaneID) -> [WorkspaceState.GoDeclaration] {
        switch paneID {
        case .primary:
            if let cached = primaryDeclarations, cached.source.hasSameStorage(as: decls) { return cached.sorted }
            let sorted = decls.sorted { $0.line > $1.line }
            primaryDeclarations = (decls, sorted)
            return sorted
        case .secondary:
            if let cached = secondaryDeclarations, cached.source.hasSameStorage(as: decls) { return cached.sorted }
            let sorted = decls.sorted { $0.line > $1.line }
            secondaryDeclarations = (decls, sorted)
            return sorted
        }
    }

    static func trail(for session: DocumentSession, cursorLine: Int) -> [(name: String, line: Int, col: Int)] {
        let parsed: [DocumentSymbol]
        if let cached = symbols[session.path], cached.session === session, cached.version == session.version {
            parsed = cached.symbols
        } else {
            parsed = EcosystemDocumentTools.documentSymbols(forPath: session.path, text: session.storage.string)
            symbols[session.path] = SymbolEntry(session: session, version: session.version, symbols: parsed)
        }
        var trail: [(name: String, line: Int, col: Int)] = []
        collect(in: parsed, targetLine0: max(0, cursorLine - 1), into: &trail)
        return trail
    }

    private static func collect(in symbols: [DocumentSymbol], targetLine0: Int, into trail: inout [(name: String, line: Int, col: Int)]) {
        if let containing = symbols.last(where: { $0.range.start.line <= targetLine0 && targetLine0 <= $0.range.end.line }) {
            trail.append((containing.name, containing.selectionRange.start.line + 1, containing.selectionRange.start.character + 1))
            if let children = containing.children, !children.isEmpty {
                collect(in: children, targetLine0: targetLine0, into: &trail)
            }
            return
        }
        if trail.isEmpty, let preceding = symbols.last(where: { $0.range.start.line <= targetLine0 }) {
            trail.append((preceding.name, preceding.selectionRange.start.line + 1, preceding.selectionRange.start.character + 1))
        }
    }
}

private struct BreadcrumbFolderMenuItems: View {
    let path: String
    let level: Int
    var paneID: EditorPaneID = .primary
    @Environment(\.windowWorkspace) private var workspace

    var body: some View {
        let items = workspace.folderItemsForMenu(at: path)
        if items.isEmpty {
            Text("Empty Folder")
        } else {
            ForEach(items, id: \.fullPath) { item in
                if item.isDirectory {
                    if level < 2 {
                        Menu {
                            BreadcrumbFolderMenuItems(path: item.fullPath, level: level + 1, paneID: paneID)
                        } label: {
                            Label {
                                Text(item.name)
                            } icon: {
                                FileIconView(fileName: item.name, path: item.fullPath, isFolder: true, isSelected: false, size: 14)
                            }
                        }
                    }
                } else {
                    Button {
                        if workspace.isSplitMode && paneID == .secondary {
                            workspace.isCounterpartSplitEnabled = false
                            workspace.openFileInSplit(item.fullPath)
                        } else {
                            workspace.openFile(item.fullPath)
                        }
                    } label: {
                        Label {
                            Text(item.name)
                        } icon: {
                            FileIconView(fileName: item.name, path: item.fullPath, isSelected: false, size: 14)
                        }
                    }
                }
            }
        }
    }
}
