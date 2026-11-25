import AppKit
import Foundation

extension WorkspaceState {
    private var breakpointsStorageKey: String {
        "GoLensBreakpoints.\(activeWorkspacePath)"
    }

    func loadBreakpointsForWorkspace() {
        debug.breakpoints = [:]
        debug.breakpointSpecs = [:]
        debug.functionBreakpoints = []
        debug.functionBreakpointProblems = [:]
        debug.storedBreakpointLines = [:]
        guard !activeWorkspacePath.isEmpty,
              let data = UserDefaults.standard.data(forKey: breakpointsStorageKey),
              let stored = try? JSONDecoder().decode(PersistedBreakpoints.self, from: data) else { return }
        for item in stored.lines where item.line >= 1 && FileManager.default.fileExists(atPath: item.path) {
            debug.storedBreakpointLines[item.path, default: []].append(item)
        }
        for path in debug.storedBreakpointLines.keys {
            applyStoredBreakpointLines(for: path)
        }
        debug.functionBreakpoints = stored.functions.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func applyStoredBreakpointLines(for path: String) {
        let items = debug.storedBreakpointLines[path] ?? []
        debug.breakpoints[path] = items.isEmpty ? nil : Set(items.map(\.line))
        var specs: [Int: BreakpointSpec] = [:]
        for item in items {
            let spec = BreakpointSpec(condition: item.condition, hitCondition: item.hitCondition, logMessage: item.logMessage, isEnabled: item.isEnabled)
            if !spec.isPlain { specs[item.line] = spec }
        }
        debug.breakpointSpecs[path] = specs.isEmpty ? nil : specs
    }

    func restoreSavedBreakpointLines(for path: String) {
        guard debug.breakpoints[path] != nil || debug.storedBreakpointLines[path] != nil else { return }
        applyStoredBreakpointLines(for: path)
        syncBreakpoints(for: path)
        (activeTextView as? GoLensTextView)?.redrawGutter()
    }

    func saveBreakpointsForWorkspace() {
        guard !activeWorkspacePath.isEmpty else { return }
        var stored = PersistedBreakpoints()
        var byPath: [String: [PersistedBreakpoints.Line]] = [:]
        for path in Set(debug.breakpoints.keys).union(debug.storedBreakpointLines.keys).sorted() {
            if documents[path]?.isEdited == true {
                if let kept = debug.storedBreakpointLines[path] { byPath[path] = kept }
                continue
            }
            let lines = (debug.breakpoints[path] ?? []).sorted().map { line -> PersistedBreakpoints.Line in
                let spec = debug.spec(path, line)
                return .init(path: path, line: line, condition: spec.condition, hitCondition: spec.hitCondition,
                             logMessage: spec.logMessage, isEnabled: spec.isEnabled)
            }
            if !lines.isEmpty { byPath[path] = lines }
        }
        debug.storedBreakpointLines = byPath
        stored.lines = byPath.keys.sorted().flatMap { byPath[$0] ?? [] }
        stored.functions = debug.functionBreakpoints
        if stored.lines.isEmpty && stored.functions.isEmpty {
            UserDefaults.standard.removeObject(forKey: breakpointsStorageKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: breakpointsStorageKey)
        }
    }

    func breakpointLinesDidMove(in path: String, to specs: [Int: BreakpointSpec]) {
        let moved = Set(specs.keys)
        guard moved != debug.breakpoints[path] else { return }
        debug.breakpoints[path] = moved.isEmpty ? nil : moved
        let kept = specs.filter { !$0.value.isPlain }
        debug.breakpointSpecs[path] = kept.isEmpty ? nil : kept
        syncBreakpoints(for: path)
    }

    func isBreakpointEnabled(_ ref: BreakpointRef) -> Bool {
        switch ref {
        case let .line(path, line):
            return debug.spec(path, line).isEnabled
        case let .function(name):
            return debug.functionBreakpoints.first { $0.name == name }?.isEnabled ?? false
        }
    }

    func setBreakpoint(_ ref: BreakpointRef, enabled: Bool) {
        switch ref {
        case let .line(path, line):
            guard debug.breakpoints[path]?.contains(line) == true else { return }
            var spec = debug.spec(path, line)
            spec.isEnabled = enabled
            debug.breakpointSpecs[path, default: [:]][line] = spec.isPlain ? nil : spec
            syncBreakpoints(for: path)
            activeTextView?.needsDisplay = true
            (activeTextView as? GoLensTextView)?.redrawGutter()
        case let .function(name):
            guard let index = debug.functionBreakpoints.firstIndex(where: { $0.name == name }) else { return }
            debug.functionBreakpoints[index].isEnabled = enabled
            syncFunctionBreakpoints()
        }
        saveBreakpointsForWorkspace()
    }

    func deleteBreakpoint(_ ref: BreakpointRef) {
        switch ref {
        case let .line(path, line):
            guard debug.breakpoints[path]?.contains(line) == true else { return }
            toggleBreakpoint(forLine: line, in: path)
            (activeTextView as? GoLensTextView)?.redrawGutter()
        case let .function(name):
            debug.functionBreakpoints.removeAll { $0.name == name }
            debug.functionBreakpointProblems[name] = nil
            syncFunctionBreakpoints()
            saveBreakpointsForWorkspace()
        }
    }

    static func normalizedFunctionName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func functionBreakpointInputProblem(_ raw: String) -> String? {
        let name = Self.normalizedFunctionName(raw)
        if name.isEmpty { return "Enter a function name, such as main.handler or (*Server).Serve." }
        if name.contains(where: \.isWhitespace) { return "A function name has no spaces. Use a form such as main.handler or (*Server).Serve." }
        if debug.functionBreakpoints.contains(where: { $0.name == name }) { return "This function already has a breakpoint." }
        return nil
    }

    func addFunctionBreakpoint(_ raw: String) {
        guard functionBreakpointInputProblem(raw) == nil else { return }
        debug.functionBreakpoints.append(FunctionBreakpointItem(name: Self.normalizedFunctionName(raw)))
        saveBreakpointsForWorkspace()
        syncFunctionBreakpoints()
    }

    func presentAddFunctionBreakpoint() {
        guard !activeWorkspacePath.isEmpty else {
            presentCommandFeedback("Open a project to add a function breakpoint.", title: "Add Function Breakpoint")
            return
        }
        showAddFunctionBreakpointSheet = true
    }

    func showBreakpointsNavigator() {
        selectedIssuesNavigatorSubtab = .breakpoints
        showNavigator(.issues)
    }

    static func functionBreakpointProblem(_ message: String?, name: String) -> String {
        let raw = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("not found") || raw.contains("could not find") {
            return "The program has no function named “\(name)”. Check the package and name, such as main.handler or (*Server).Serve."
        }
        return formatCommandReason(raw, fallback: "The debugger couldn’t set this breakpoint.")
    }

    func syncFunctionBreakpoints() {
        guard debug.isDebugMode else {
            debug.functionBreakpointProblems = [:]
            return
        }
        let json = debug.functionBreakpointsJSON()
        let names = debug.functionBreakpoints.filter(\.isEnabled).map(\.name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.sendFunctionBreakpoints(json)
            DispatchQueue.main.async { self?.applyFunctionBreakpointResult(result, names: names) }
        }
    }

    nonisolated static func sendFunctionBreakpoints(_ json: String) -> String? {
        json.withCString { j in
            guard let c = DebugSetFunctionBreakpoints(j) else { return nil }
            defer { FreeGoCString(c) }
            return String(cString: c)
        }
    }

    func applyFunctionBreakpointResult(_ result: String?, names: [String]) {
        var problems: [String: String] = [:]
        if let result, result.hasPrefix("Error:") {
            let detail = String(result.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            let message = detail.contains("support")
                ? "This debug session can’t stop at functions. Use a line breakpoint instead."
                : Self.formatCommandReason(detail, fallback: "The debugger couldn’t set function breakpoints.")
            for name in names { problems[name] = message }
        } else if let result, let data = result.data(using: .utf8),
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for (index, name) in names.enumerated() where index < list.count && list[index]["verified"] as? Bool != true {
                problems[name] = Self.functionBreakpointProblem(list[index]["message"] as? String, name: name)
            }
        }
        debug.functionBreakpointProblems = problems
        for (name, message) in problems {
            appendLog("Function breakpoint \(name) not set: \(message)")
        }
    }
}
