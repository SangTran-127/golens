import AppKit
import Foundation

@Observable
final class ToolSetupStatus {
    static let shared = ToolSetupStatus()

    enum Tool: String, CaseIterable, Identifiable {
        case go, gopls, git, dlv

        var id: String { rawValue }

        var title: String {
            switch self {
            case .go: "Go"
            case .gopls: "gopls"
            case .git: "Git"
            case .dlv: "Delve"
            }
        }

        var purpose: String {
            switch self {
            case .go: "Build, run and test"
            case .gopls: "Completion and diagnostics"
            case .git: "Source control"
            case .dlv: "Debugging"
            }
        }

        var installPackage: String? {
            switch self {
            case .gopls: "golang.org/x/tools/gopls@latest"
            case .dlv: "github.com/go-delve/delve/cmd/dlv@latest"
            case .go, .git: nil
            }
        }
    }

    private(set) var paths: [Tool: String] = [:]
    private(set) var hasChecked = false
    private(set) var isChecking = false
    private(set) var installing: Tool?
    var installFailure: String?

    var missing: [Tool] {
        hasChecked ? Tool.allCases.filter { paths[$0] == nil } : []
    }

    func check() {
        guard !isChecking else { return }
        isChecking = true
        DispatchQueue.global(qos: .utility).async {
            var found: [Tool: String] = [:]
            for tool in Tool.allCases {
                if let path = WorkspaceState.findTool(tool.rawValue) {
                    found[tool] = path
                }
            }
            if found[.git] == "/usr/bin/git", !Self.developerToolsInstalled() {
                found[.git] = nil
            }
            for name in (ProcessInfo.processInfo.environment["GOLENS_DEV_MISSING_TOOLS"] ?? "").split(separator: ",") {
                if let tool = Tool(rawValue: String(name)) { found[tool] = nil }
            }
            DispatchQueue.main.async {
                self.paths = found
                self.hasChecked = true
                self.isChecking = false
            }
        }
    }

    func install(_ tool: Tool) {
        switch tool {
        case .go:
            if let url = URL(string: "https://go.dev/dl/") { NSWorkspace.shared.open(url) }
        case .git:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            process.arguments = ["--install"]
            try? process.run()
        case .gopls, .dlv:
            guard installing == nil, let go = paths[.go], let package = tool.installPackage else { return }
            installing = tool
            installFailure = nil
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: go)
                process.arguments = ["install", package]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                var message: String?
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        message = "go install \(package) failed. \(text.split(separator: "\n").suffix(3).joined(separator: " "))"
                    }
                } catch {
                    message = "GoLens couldn’t run go install: \(error.localizedDescription)"
                }
                DispatchQueue.main.async {
                    self.installing = nil
                    self.installFailure = message
                    self.check()
                }
            }
        }
    }

    private static func developerToolsInstalled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
