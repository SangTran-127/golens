import Foundation
import SwiftUI

extension WorkspaceState {
    struct LogMessage: Identifiable {
        enum Tone { case normal, failure, success, quiet }

        let id = UUID()
        let text: String
        var linked: AttributedString? = nil
        var isStderr = false
        let tone: Tone
        let hasStructuredJSONPayload: Bool

        init(text: String, linked: AttributedString? = nil, isStderr: Bool = false) {
            self.text = text
            self.linked = linked
            self.isStderr = isStderr
            self.tone = Self.tone(of: text)
            self.hasStructuredJSONPayload = Self.hasJSONPayload(text)
        }

        private static func hasJSONPayload(_ text: String) -> Bool {
            guard text.utf8.count > 80 else { return false }
            guard let openBrace = text.firstIndex(of: "{"),
                  let closeBrace = text.lastIndex(of: "}"),
                  openBrace < closeBrace else {
                return false
            }
            return text[openBrace...closeBrace].contains("\":")
        }

        private static func tone(of text: String) -> Tone {
            let lower = text.lowercased()
            if text.range(of: #"\.go:\d+(:\d+)?: "#, options: .regularExpression) != nil ||
                text.hasPrefix("panic:") ||
                text.hasPrefix("fatal error:") ||
                text.hasPrefix("FAIL\t") ||
                text.contains("--- FAIL:") ||
                lower.hasPrefix("process exited with error") ||
                lower.hasPrefix("exit status ") ||
                lower.hasPrefix("tests failed:") ||
                lower.hasPrefix("debug start failed:") ||
                lower.hasPrefix("build failed") ||
                lower.contains("error:") ||
                lower.hasPrefix("error ") ||
                lower.contains("failed:") {
                return .failure
            }
            if text == "Process exited successfully." ||
                lower.hasPrefix("tests passed:") ||
                text == "PASS" ||
                text.hasPrefix("PASS\t") ||
                text.contains("--- PASS:") {
                return .success
            }
            if ((text.hasPrefix("Running ") || text.hasPrefix("Debugging ") || text.hasPrefix("Building ") || text.hasPrefix("Testing ")) && text.hasSuffix("…")) ||
                text == "Process stopped." ||
                text == "Testing stopped." ||
                text.hasPrefix("Debugger finished with the exit code") ||
                text.hasPrefix("No main package in ") {
                return .quiet
            }
            return .normal
        }

        var isGovulncheckPayload: Bool {
            if text.hasPrefix("Run govulncheck:") || text.hasPrefix("govulncheck:") {
                return true
            }
            return hasStructuredJSONPayload && (
                text.contains("\"Entries\"") ||
                text.contains("\"osv\"") ||
                text.contains("\"GO-")
            )
        }

        func formatPrettyJSON() -> String {
            guard let openBrace = text.firstIndex(of: "{"),
                  let closeBrace = text.lastIndex(of: "}"),
                  openBrace < closeBrace else {
                return text
            }
            let prefix = String(text[..<openBrace]).trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonSlice = String(text[openBrace...closeBrace])
            if let data = jsonSlice.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let prettyStr = String(data: prettyData, encoding: .utf8) {
                return prefix.isEmpty ? prettyStr : "\(prefix)\n\(prettyStr)"
            }
            let lines = jsonSlice.components(separatedBy: .newlines)
            var formattedChunks: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let data = trimmed.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                   let prettyStr = String(data: prettyData, encoding: .utf8) {
                    formattedChunks.append(prettyStr)
                } else {
                    formattedChunks.append(trimmed)
                }
            }
            if !formattedChunks.isEmpty {
                let combined = formattedChunks.joined(separator: "\n")
                return prefix.isEmpty ? combined : "\(prefix)\n\(combined)"
            }
            return text
        }
    }

    enum BuildStatus: Equatable {
        case succeeded
        case failed(String)
        case testsSucceeded
        case testsFailed(String)
    }

    struct FinishedActivity: Equatable {
        let title: String
        let failed: Bool
        let date: Date
    }

    enum Navigator: Int, CaseIterable {
        case files, git, search, issues, tests

        var title: String {
            switch self {
            case .files: "Files"
            case .git: "Source Control"
            case .search: "Search"
            case .issues: "Issues"
            case .tests: "Tests"
            }
        }

        var symbol: String {
            switch self {
            case .files: "folder"
            case .git: "arrow.triangle.branch"
            case .search: "magnifyingglass"
            case .issues: "exclamationmark.triangle"
            case .tests: "checkmark.diamond"
            }
        }
    }

    enum Popup { case recentFiles, goToSymbol, workspaceSymbol, openQuickly, commandPalette, references, hierarchy, surroundWith, queryHistory }

    struct CoreEdits: Decodable {
        let version: Int
        let edits: [LSPTextEdit]
    }

    struct ModuleNotesReply: Decodable {
        struct Note: Decodable {
            let path: String
            let line: Int
            let deprecated: String?
            let retracted: [String]?
        }
        let notes: [Note]
        let error: String?
    }

    struct GoDeclaration: Decodable {
        let line: Int
        let col: Int
        let symbolName: String
        let kind: String
        var isInterface: Bool { kind == "interface" }

        private enum CodingKeys: String, CodingKey { case line, col, kind, symbolName = "name" }
    }

    enum EditorMode: String, Codable {
        case code
        case diff
        case readOnly
    }
}

func goLogCallback(msg: UnsafePointer<CChar>?, stream: Int32) {
    guard let msg = msg else { return }
    let text = String(cString: msg)
    let target = WorkspaceState.coreEventTarget(.output)
    if stream == 3 {
        target.appendDiagnosticLog(text)
    } else {
        let isStderr = stream == 2
        if target.consumeSuppressedRunnerLog(text, isStderr: isStderr) {
            return
        }
        target.appendLog(text, isStderr: isStderr)
    }
}

func goDiagCallback(path: UnsafePointer<CChar>?, payload: UnsafePointer<CChar>?) {
    guard let path = path, let payload = payload else { return }
    let pathStr = String(cString: path)
    let body = String(cString: payload)
    if let target = WorkspaceState.workspaceOwningPath(pathStr) {
        target.updateDiagnostics(path: pathStr, payload: body)
        return
    }
    DispatchQueue.main.async {
        WorkspaceState.workspaceHoldingDocument(pathStr)?.updateDiagnostics(path: pathStr, payload: body)
    }
}

func goLSPResponseCallback(payload: UnsafePointer<CChar>?) {
    guard let payload = payload else { return }
    let jsonStr = String(cString: payload)
    Task {
        await LSPClient.shared.handleIncomingResponse(jsonString: jsonStr)
    }
}

func registerGoCallbacks() {
    let logCb: @convention(c) (UnsafePointer<CChar>?, Int32) -> Void = goLogCallback
    RegisterCallback(logCb)

    let diagCb: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = goDiagCallback
    RegisterDiagnosticsCallback(diagCb)

    let termCb: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Void = goTerminalCallback
    RegisterTerminalCallback(termCb)

    let lspCb: @convention(c) (UnsafePointer<CChar>?) -> Void = goLSPResponseCallback
    RegisterLSPResponseCallback(lspCb)

    let debugCb: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = goDebugEventCallback
    RegisterDebugEventCallback(debugCb)

    let applyCb: @convention(c) (Int64, UnsafePointer<CChar>?) -> Void = goApplyEditCallback
    RegisterApplyEditCallback(applyCb)

    let testCb: @convention(c) (UnsafePointer<CChar>?) -> Void = goTestEventCallback
    RegisterTestEventCallback(testCb)

    let searchCb: @convention(c) (UnsafePointer<CChar>?) -> Void = goSearchCallback
    RegisterSearchCallback(searchCb)

    let statusCb: @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void = goStatusEventCallback
    RegisterStatusEventCallback(statusCb)
}

func goSearchCallback(payload: UnsafePointer<CChar>?) {
    guard let payload else { return }
    WorkspaceState.coreEventTarget(.search).receiveSearchBatch(String(cString: payload))
}

func goTestEventCallback(payload: UnsafePointer<CChar>?) {
    guard let payload else { return }
    let text = String(cString: payload)
    for target in WorkspaceState.testEventTargets(text) {
        target.receiveTestEvent(text)
    }
}

func goDebugEventCallback(event: UnsafePointer<CChar>?, body: UnsafePointer<CChar>?) {
    guard let event = event else { return }
    let eventName = String(cString: event)
    let bodyStr = body.flatMap { String(cString: $0) } ?? ""
    WorkspaceState.coreEventTarget(.debug).handleDebugEvent(name: eventName, jsonStr: bodyStr)
}

func goTerminalCallback(termId: UnsafePointer<CChar>?, data: UnsafePointer<CChar>?, length: Int32) {
    guard let termId, let data, length > 0 else { return }
    let idStr = String(cString: termId)
    let bytes = [UInt8](UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: UInt8.self), count: Int(length)))
    DispatchQueue.main.async {
        let target = MainActor.assumeIsolated {
            WorkspaceSessionRegistry.shared.workspace(owningTerminalID: idStr) ?? WorkspaceState.shared
        }
        target.terminalEngines[idStr]?.feed(byteArray: bytes[...])
    }
}

let measureEnabled = ProcessInfo.processInfo.environment["GOLENS_MEASURE"] != nil

func measureLog(_ message: @autoclosure () -> String) {
    if measureEnabled {
        FileHandle.standardError.write(Data("[measure] \(message())\n".utf8))
    }
}

let measureProcessStart: Date = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
    let start = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
}()

nonisolated(unsafe) private var measuredStartupPhases = Set<String>()

func measureStartupOnce(_ phase: String) {
    guard measureEnabled, measuredStartupPhases.insert(phase).inserted else { return }
    measureStartup(phase)
}

func measureStartup(_ phase: String) {
    guard measureEnabled else { return }
    let ms = Date().timeIntervalSince(measureProcessStart) * 1000
    measureLog("startup \(phase) \(String(format: "%.1f", ms)) ms since process start")
}
