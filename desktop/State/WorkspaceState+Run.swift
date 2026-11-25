import Foundation
import SwiftUI

extension WorkspaceState {
    
    private var runConfigFilePath: String {
        return (activeWorkspacePath as NSString).appendingPathComponent(".golens/run.json")
    }
    
    func loadRunConfigurations() {
        guard !activeWorkspacePath.isEmpty else { return }
        
        let path = runConfigFilePath
        var configs: [RunConfiguration] = []
        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                configs = try JSONDecoder().decode([RunConfiguration].self, from: data)
            } catch {
                appendLog("Failed to load run configurations: \(error.localizedDescription)")
                let keptPath = path + ".unreadable"
                try? FileManager.default.removeItem(atPath: keptPath)
                let kept = (try? FileManager.default.moveItem(atPath: path, toPath: keptPath)) != nil
                let reason = Self.failureReason(error)
                DispatchQueue.main.async { [weak self] in
                    self?.presentFailure(
                        "Couldn’t Read Run Configurations",
                        kept
                            ? "\(reason) GoLens kept the file as run.json.unreadable in the project’s .golens folder and starts with no run configurations, so nothing is overwritten."
                            : "\(reason) GoLens starts with no run configurations for now. Fix or remove .golens/run.json before you add new ones, or they will replace it.",
                        revealing: kept ? keptPath : path
                    )
                }
            }
        }
        runConfigurations = configs
        activeRunConfigId = configs.first?.id
    }
    
    func saveRunConfigurations() {
        guard !activeWorkspacePath.isEmpty else { return }
        
        let path = runConfigFilePath
        let dirPath = (path as NSString).deletingLastPathComponent
        let fileManager = FileManager.default
        
        do {
            if !fileManager.fileExists(atPath: dirPath) {
                try fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
            }
            
            let data = try JSONEncoder().encode(self.runConfigurations)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            execution.runConfigurationSaveFailed = false
        } catch {
            appendLog("Failed to save run configurations: \(error.localizedDescription)")
            guard !execution.runConfigurationSaveFailed else { return }
            execution.runConfigurationSaveFailed = true
            presentFailure(
                "Couldn’t Save Run Configurations",
                "\(Self.failureReason(error)) Your changes apply until you close the project. Check that you can write to the .golens folder in the project, then try again.",
                recovery: ("Try Again", { [weak self] in
                    self?.execution.runConfigurationSaveFailed = false
                    self?.saveRunConfigurations()
                }),
                revealing: path
            )
        }
    }
    
    func updateRunConfiguration(_ config: RunConfiguration) {
        if let index = runConfigurations.firstIndex(where: { $0.id == config.id }) {
            runConfigurations[index] = config
        } else {
            runConfigurations.append(config)
        }
        saveRunConfigurations()
    }
    
    func deleteRunConfiguration(id: UUID) {
        runConfigurations.removeAll(where: { $0.id == id })
        if activeRunConfigId == id {
            activeRunConfigId = runConfigurations.first?.id
        }
        saveRunConfigurations()
    }
    
    var activeRunConfigurationName: String {
        activeRunConfiguration?.name ?? "Default"
    }

    var activeRunConfiguration: RunConfiguration? {
        if let id = activeRunConfigId {
            return runConfigurations.first(where: { $0.id == id })
        }
        return runConfigurations.first
    }

    func resolvedEnvVars(for config: RunConfiguration) -> [String: String] {
        var merged: [String: String] = [:]
        let rawPath = config.envFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawPath.isEmpty {
            let fullPath = rawPath.hasPrefix("/")
                ? rawPath
                : (activeWorkspacePath as NSString).appendingPathComponent(rawPath)
            if let handle = FileHandle(forReadingAtPath: fullPath) {
                let data = (try? handle.read(upToCount: 65_536)) ?? Data()
                try? handle.close()
                if let text = String(data: data, encoding: .utf8) {
                    for rawLine in text.components(separatedBy: .newlines) {
                        var line = rawLine.trimmingCharacters(in: .whitespaces)
                        if line.isEmpty || line.hasPrefix("#") { continue }
                        if line.hasPrefix("export ") {
                            line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                        }
                        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        guard parts.count == 2 else { continue }
                        let key = parts[0].trimmingCharacters(in: .whitespaces)
                        guard !key.isEmpty else { continue }
                        var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
                           (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                            value = String(value.dropFirst().dropLast())
                        }
                        merged[key] = value
                    }
                }
            }
        }
        for (k, v) in config.envVars {
            merged[k] = v
        }
        return merged
    }

    func discoverWorkspaceEnvFiles() -> [String] {
        guard !activeWorkspacePath.isEmpty else { return [] }
        var found = Set<String>()
        let fm = FileManager.default
        if let rootEntries = try? fm.contentsOfDirectory(atPath: activeWorkspacePath) {
            for entry in rootEntries where entry == ".env" || entry.hasPrefix(".env.") {
                found.insert(entry)
            }
        }
        for rel in allWorkspaceRelativeFilePaths() {
            let base = (rel as NSString).lastPathComponent
            if base == ".env" || base.hasPrefix(".env.") || base.hasSuffix(".env") {
                found.insert(rel)
            }
        }
        return found.sorted()
    }

    func discoverMainPackageDirectories() -> [String] {
        guard !activeWorkspacePath.isEmpty else { return ["."] }
        var mainDirs = Set<String>()
        var checkedDirs = Set<String>()
        let candidates = allWorkspaceRelativeFilePaths().filter {
            $0.hasSuffix(".go") && !$0.hasSuffix("_test.go")
        }
        var filesRead = 0
        for rel in candidates {
            let dir = (rel as NSString).deletingLastPathComponent
            let normDir = dir.isEmpty ? "." : dir
            if mainDirs.contains(normDir) { continue }
            if filesRead >= 120 && checkedDirs.contains(normDir) { continue }
            checkedDirs.insert(normDir)
            let fullPath = (activeWorkspacePath as NSString).appendingPathComponent(rel)
            if let doc = documents[fullPath] {
                if hasMainPackageClause(in: doc.storage.string as NSString) {
                    mainDirs.insert(normDir)
                }
                continue
            }
            guard let handle = FileHandle(forReadingAtPath: fullPath) else { continue }
            let data = (try? handle.read(upToCount: 4096)) ?? Data()
            try? handle.close()
            filesRead += 1
            if let text = String(data: data, encoding: .utf8),
               hasMainPackageClause(in: text as NSString) {
                mainDirs.insert(normDir)
            }
        }
        if mainDirs.isEmpty { mainDirs.insert(".") }
        return mainDirs.sorted { a, b in
            if a == "." { return true }
            if b == "." { return false }
            return a < b
        }
    }

    func openTerminal(atDirectory dir: String) {
        let targetDir: String
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            targetDir = isDir.boolValue ? dir : (dir as NSString).deletingLastPathComponent
        } else {
            targetDir = activeWorkspacePath
        }
        let folderName = (targetDir as NSString).lastPathComponent
        let title = folderName.isEmpty ? "zsh" : folderName
        if terminalSessions.count >= Self.maxTerminalSessions, let lastId = terminalSessions.last?.id {
            closeTerminalSession(lastId)
        }
        let newSession = TerminalSession(id: UUID().uuidString, title: title, cwd: targetDir)
        terminalSessions.append(newSession)
        selectedTerminalId = newSession.id
        showConsole = true
        selectedConsoleTab = Self.terminalTab
    }
}
