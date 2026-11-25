import AppKit
import UniformTypeIdentifiers

struct GoroutineVisibility: Equatable {
    struct Entry: Equatable {
        let group: GoroutineGroup
        let threadIds: [Int]
    }

    let entries: [Entry]
    let shown: Int
    let total: Int
    let hiddenSystem: Int
    let keptActive: Bool

    init(groups: [GoroutineGroup], query: String, showsSystem: Bool, active: Int?) {
        var entries: [Entry] = []
        var shown = 0, total = 0, hiddenSystem = 0
        var keptActive = false
        for group in groups {
            total += group.count
            let holdsActive = active.map { group.threadIds.contains($0) } ?? false
            if group.isSystem && !showsSystem {
                hiddenSystem += group.count
                if !holdsActive { continue }
            }
            var ids = group.isSystem && !showsSystem ? [] : group.threadIds(matching: query)
            if holdsActive, let active, !ids.contains(active) {
                ids.insert(active, at: 0)
                keptActive = true
            }
            guard !ids.isEmpty else { continue }
            shown += ids.count
            entries.append(Entry(group: group, threadIds: ids))
        }
        self.entries = entries
        self.shown = shown
        self.total = total
        self.hiddenSystem = hiddenSystem
        self.keptActive = keptActive
    }
}

extension WorkspaceState {
    var goroutineVisibility: GoroutineVisibility {
        GoroutineVisibility(groups: debug.goroutineGroups, query: debug.goroutineFilter,
                            showsSystem: debug.showsSystemGoroutines, active: debug.activeThreadId.map(Int.init))
    }

    func copyGoroutineDump() {
        withGoroutineDump(title: "Copy Goroutine Dump") { dump in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(dump, forType: .string)
        }
    }

    func saveGoroutineDump() {
        withGoroutineDump(title: "Save Goroutine Dump") { [weak self] dump in
            let panel = NSSavePanel()
            panel.title = "Save Goroutine Dump"
            panel.nameFieldStringValue = "Goroutine Dump.txt"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try dump.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self?.presentCommandFeedback("Couldn’t save the goroutine dump. \(Self.formatCommandReason(error.localizedDescription, fallback: "Choose another folder and try again."))",
                                             title: "Save Goroutine Dump", tone: .failure)
            }
        }
    }

    private func withGoroutineDump(title: String, then use: @escaping (String) -> Void) {
        guard debug.isDebugMode else {
            presentCommandFeedback("Start debugging and pause the program to take a goroutine dump.", title: title)
            return
        }
        guard debug.isPaused else {
            presentCommandFeedback("The program is running. Pause it or wait for a breakpoint, then take the goroutine dump.", title: title)
            return
        }
        let root = URL(fileURLWithPath: activeWorkspacePath).resolvingSymlinksInPath().path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: String? = root.withCString { r in
                guard let c = DebugGoroutineDump(r) else { return nil }
                defer { FreeGoCString(c) }
                return String(cString: c)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let result, !result.hasPrefix("Error:") else {
                    let detail = result.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
                    self.presentCommandFeedback(Self.formatCommandReason(detail, fallback: "The debugger didn’t return the goroutines."),
                                                title: title, tone: .failure)
                    return
                }
                use(result)
            }
        }
    }
}
