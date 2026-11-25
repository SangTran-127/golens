import SwiftUI
import SwiftTerm

private typealias ANSI16Entry = SwiftTerm.Color

final class GoLensTerminalView: TerminalView {
    var coordinatorRef: GoLensTerminalCanvas.Coordinator?
    weak var hostWorkspace: WorkspaceState?
    var workspaceState: WorkspaceState { hostWorkspace ?? WorkspaceState.owning(window: window) }

    func applyThemeAppearance() {
        let theme = workspaceState.currentTheme
        let isDark = theme.resolvedIsDark
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let appearanceName: NSAppearance.Name = highContrast
            ? (isDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (isDark ? .darkAqua : .aqua)
        let targetAppearance = NSAppearance(named: appearanceName) ?? effectiveAppearance
        if appearance?.name != targetAppearance.name {
            appearance = targetAppearance
        }
        let ansiPalette = theme.terminalANSIColors(isDark: isDark).map { r, g, b in
            ANSI16Entry(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
        }
        targetAppearance.performAsCurrentDrawingAppearance {
            installColors(ansiPalette)
            let bg = theme.backgroundColor(isDark: isDark)
            nativeBackgroundColor = bg
            nativeForegroundColor = theme.textColor(isDark: isDark)
            caretColor = theme.insertionPointColor(isDark: isDark)
            layer?.backgroundColor = bg.cgColor
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        if event.modifierFlags.contains(.command), handleCommandClick(with: event) {
            return
        }
        super.mouseDown(with: event)
    }

    private func handleCommandClick(with event: NSEvent) -> Bool {
        let pt = convert(event.locationInWindow, from: nil)
        let dims = terminalDimensions
        guard dims.rows > 0, dims.cols > 0, bounds.height > 0, bounds.width > 0 else { return false }
        let clickedRow = max(0, min(dims.rows - 1, Int(((bounds.height - pt.y) / bounds.height) * CGFloat(dims.rows))))
        let clickedCol = max(0, min(dims.cols - 1, Int((pt.x / bounds.width) * CGFloat(dims.cols))))
        let startRow = max(0, clickedRow - 1)
        let endRow = min(dims.rows, clickedRow + 2)
        let rowTexts = visibleRowsText(startRow..<endRow)
        for text in rowTexts {
            let matches = ConsoleLinks.matches(in: text)
            guard !matches.isEmpty else { continue }
            let chosen = matches.first(where: { NSLocationInRange(clickedCol, $0.range) }) ?? matches.first!
            if ConsoleLinks.openLocation(
                path: chosen.path,
                line: chosen.line,
                column: chosen.column,
                in: workspaceState,
                preferredDirectory: coordinatorRef?.cwd
            ) {
                return true
            }
        }
        return false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeAppearance()
        guard window != nil, !isHidden, workspaceState.activePopup == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.isHidden, self.workspaceState.activePopup == nil else { return }
            window.makeFirstResponder(self)
        }
    }
}

struct GoLensTerminalCanvas: NSViewRepresentable {
    @Environment(\.windowWorkspace) private var workspace
    var cwd: String
    var terminalId: String
    var isVisible: Bool
    var fontSize: CGFloat

    func makeNSView(context: Context) -> TerminalView {
        let targetFont = TechnicalTypography.codeCanvasNSFont(size: fontSize)
        let workspace = self.workspace
        context.coordinator.workspace = workspace
        if let existing = workspace.terminalEngines[terminalId] {
            (existing as? GoLensTerminalView)?.hostWorkspace = workspace
            if existing.font != targetFont {
                existing.font = targetFont
            }
            (existing as? GoLensTerminalView)?.coordinatorRef = context.coordinator
            (existing as? GoLensTerminalView)?.applyThemeAppearance()
            existing.terminalDelegate = context.coordinator
            existing.isHidden = !isVisible
            if isVisible {
                DispatchQueue.main.async {
                    if workspace.activePopup == nil {
                        existing.window?.makeFirstResponder(existing)
                    }
                }
            }
            return existing
        }
        
        let terminalView = GoLensTerminalView(frame: .zero)
        terminalView.hostWorkspace = workspace
        terminalView.changeScrollback(WorkspaceState.terminalScrollbackLines)
        terminalView.coordinatorRef = context.coordinator
        terminalView.terminalDelegate = context.coordinator
        terminalView.font = targetFont
        
        terminalView.applyThemeAppearance()
        terminalView.isHidden = !isVisible
        
        workspace.terminalEngines[terminalId] = terminalView
        
        if let argv = TerminalCommands.argv(for: terminalId) {
            let argvJSON = jsonText(argv)
            terminalId.withCString { idStr in
                cwd.withCString { cstr in
                    argvJSON.withCString { StartTerminalCommand(idStr, cstr, $0) }
                }
            }
        } else {
            cwd.withCString { cstr in
                terminalId.withCString { idStr in
                    StartTerminal(idStr, cstr)
                }
            }
        }
        if let input = WorkspaceState.takePendingTerminalInput(terminalId) {
            terminalId.withCString { idStr in
                input.withCString { WriteTerminal(idStr, $0, Int32(input.utf8.count)) }
            }
        }
        if isVisible {
            DispatchQueue.main.async {
                if workspace.activePopup == nil {
                    terminalView.window?.makeFirstResponder(terminalView)
                }
            }
        }
        
        return terminalView
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        let targetFont = TechnicalTypography.codeCanvasNSFont(size: fontSize)
        if nsView.font != targetFont {
            nsView.font = targetFont
        }
        (nsView as? GoLensTerminalView)?.coordinatorRef = context.coordinator
        nsView.terminalDelegate = context.coordinator
        (nsView as? GoLensTerminalView)?.applyThemeAppearance()
        let wasHidden = nsView.isHidden
        nsView.isHidden = !isVisible
        if wasHidden && isVisible {
            let workspace = self.workspace
            DispatchQueue.main.async {
                if workspace.activePopup == nil {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }
    
    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalId: terminalId, cwd: cwd)
    }

    class Coordinator: NSObject, TerminalViewDelegate {
        var terminalId: String
        var cwd: String
        weak var workspace: WorkspaceState?
        
        init(terminalId: String, cwd: String) {
            self.terminalId = terminalId
            self.cwd = cwd
        }
        
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            terminalId.withCString { idStr in
                ResizeTerminal(idStr, Int32(newRows), Int32(newCols))
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            if let directory, !directory.isEmpty {
                cwd = directory
            }
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            let matches = ConsoleLinks.matches(in: link)
            if let first = matches.first, let workspace {
                _ = ConsoleLinks.openLocation(
                    path: first.path,
                    line: first.line,
                    column: first.column,
                    in: workspace,
                    preferredDirectory: cwd
                )
                return
            }
            if let url = URL(string: link), let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") {
                NSWorkspace.shared.open(url)
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            data.withUnsafeBytes { buf in
                terminalId.withCString { idStr in
                    WriteTerminal(idStr, buf.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(buf.count))
                }
            }
        }
        
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

enum TerminalCommands {
    private static var commands: [String: [String]] = [:]

    static func argv(for terminalId: String) -> [String]? {
        commands[terminalId]
    }

    static func register(_ argv: [String], for terminalId: String) {
        commands[terminalId] = argv
    }

    static func forget(_ terminalId: String) {
        commands[terminalId] = nil
    }
}

extension WorkspaceState {
    func openCommandTerminal(title: String, argv: [String]) {
        if terminalSessions.count >= Self.maxTerminalSessions, let lastId = terminalSessions.last?.id {
            closeTerminalSession(lastId)
        }
        let dir = activeWorkspacePath.isEmpty ? NSHomeDirectory() : activeWorkspacePath
        let session = TerminalSession(id: UUID().uuidString, title: title, cwd: dir)
        TerminalCommands.register(argv, for: session.id)
        terminalSessions.append(session)
        selectedTerminalId = session.id
        showConsole = true
        selectedConsoleTab = Self.terminalTab
    }

    func restartTerminal(_ session: TerminalSession) {
        guard let argv = TerminalCommands.argv(for: session.id),
              let index = terminalSessions.firstIndex(where: { $0.id == session.id }) else {
            restartTerminalSession(session.id)
            return
        }
        TerminalCommands.forget(session.id)
        if let engine = terminalEngines.removeValue(forKey: session.id) {
            engine.terminalDelegate = nil
            engine.removeFromSuperview()
        }
        let oldID = session.id
        DispatchQueue.global(qos: .utility).async { oldID.withCString { CloseTerminal($0) } }
        let next = TerminalSession(id: UUID().uuidString, title: session.title, cwd: session.cwd)
        TerminalCommands.register(argv, for: next.id)
        terminalSessions[index] = next
        selectedTerminalId = next.id
    }
}
