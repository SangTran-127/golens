import Foundation
import Observation

struct HTTPHeaderDTO: Decodable, Hashable {
    let name: String
    let value: String
}

struct HTTPFileRequestDTO: Decodable, Hashable {
    let index: Int
    let name: String
    let title: String
    let method: String
    let url: String
    let line: Int
    let startLine: Int
    let endLine: Int
    let isGRPC: Bool?
    let handlerLine: Int?
}

struct HTTPEnvironmentIssueDTO: Decodable, Hashable {
    let file: String
    let message: String
}

struct HTTPEnvironmentsDTO: Decodable, Hashable {
    let names: [String]
    let publicFile: String?
    let privateFile: String?
    let issues: [HTTPEnvironmentIssueDTO]

    static let empty = HTTPEnvironmentsDTO(names: [], publicFile: nil, privateFile: nil, issues: [])
}

struct HTTPFileOutlineDTO: Decodable, Hashable {
    let requests: [HTTPFileRequestDTO]
    let environments: HTTPEnvironmentsDTO

    static let empty = HTTPFileOutlineDTO(requests: [], environments: .empty)
}

struct HTTPResolvedRequestDTO: Decodable, Hashable {
    let index: Int
    let name: String
    let title: String
    let line: Int
    let method: String
    let url: String
    let headers: [HTTPHeaderDTO]
    let body: String
    let isGRPC: Bool
    let handler: String?
    let handlerLine: Int?
    let handlerName: String?
}

struct HTTPTimingDTO: Decodable, Hashable {
    let dnsMs: Int64
    let connectMs: Int64
    let tlsMs: Int64
    let firstByteMs: Int64
    let totalMs: Int64
}

struct HTTPResponseDTO: Decodable, Hashable {
    let status: Int
    let statusText: String
    let `protocol`: String
    let headers: [HTTPHeaderDTO]
    let body: String
    let prettyBody: String?
    let contentType: String
    let isJSON: Bool
    let size: Int
    let truncated: Bool
    let timing: HTTPTimingDTO

    var isGRPC: Bool { `protocol` == "gRPC" }

    var isSuccess: Bool {
        isGRPC ? status == 0 : (200..<300).contains(status)
    }

    var statusLabel: String {
        if isGRPC { return statusText }
        return statusText.isEmpty ? "\(status)" : "\(status) \(statusText)"
    }

    var displayBody: String {
        if let prettyBody, !prettyBody.isEmpty { return prettyBody }
        return body
    }
}

struct HTTPRunErrorDTO: Decodable, Hashable {
    let kind: String
    let message: String
    let detail: String?
    let variables: [String]?
    let file: String?
}

struct HTTPRunResultDTO: Decodable {
    let runId: String
    let request: HTTPResolvedRequestDTO?
    let response: HTTPResponseDTO?
    let error: HTTPRunErrorDTO?
}

struct HTTPAssertionResult: Hashable {
    let message: String
    let passed: Bool
}

struct HTTPTestResult: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let passed: Bool
    let message: String
    let assertions: [HTTPAssertionResult]
}

struct HTTPScriptOutcome {
    var globals: [String: String]
    var tests: [HTTPTestResult] = []
    var logs: [String] = []
    var error: String?
    var errorLine: Int?
}

struct HTTPRunEntry: Identifiable, Equatable {
    static func == (lhs: HTTPRunEntry, rhs: HTTPRunEntry) -> Bool {
        lhs.id == rhs.id && lhs.isRunning == rhs.isRunning && lhs.finishedAt == rhs.finishedAt
    }

    let id: UUID
    let runID: String
    let path: String
    let requestKey: String
    let requestIndex: Int
    let title: String
    let method: String
    let rawURL: String
    let environment: String?
    let startedAt: Date
    var finishedAt: Date?
    var isRunning: Bool
    var request: HTTPResolvedRequestDTO?
    var response: HTTPResponseDTO?
    var error: HTTPRunErrorDTO?
    var tests: [HTTPTestResult] = []
    var logs: [String] = []
    var scriptError: String?
    var scriptErrorLine: Int?
    var handlerLine: Int?

    var failedTests: Int { tests.filter { !$0.passed }.count }

    var isSuccess: Bool {
        guard !isRunning, error == nil, scriptError == nil, let response else { return false }
        return response.isSuccess && failedTests == 0
    }

    var isFailure: Bool {
        guard !isRunning else { return false }
        if error != nil || scriptError != nil || failedTests > 0 { return true }
        if let response { return !response.isSuccess && (response.isGRPC || response.status >= 400) }
        return false
    }

    var summary: String {
        if isRunning { return "Running…" }
        if let error {
            switch error.kind {
            case "unresolved": return "Missing variable"
            case "cancelled": return "Stopped"
            case "timeout": return "Timed out"
            case "network": return "Could not connect"
            case "file": return "File not found"
            default: return "Failed"
            }
        }
        guard let response else { return "Failed" }
        var parts = [response.statusLabel, HTTPFormat.duration(response.timing.totalMs)]
        if scriptError != nil {
            parts.append("handler error")
        } else if !tests.isEmpty {
            let failed = failedTests
            if failed == 0 {
                parts.append(tests.count == 1 ? "1 test passed" : "\(tests.count) tests passed")
            } else {
                parts.append("\(failed) of \(tests.count) tests failed")
            }
        }
        return parts.joined(separator: " · ")
    }
}

enum HTTPFormat {
    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 { return String(format: "%.1f KB", Double(count) / 1024) }
        return String(format: "%.2f MB", Double(count) / (1024 * 1024))
    }

    static func duration(_ ms: Int64) -> String {
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.2f s", Double(ms) / 1000)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

@Observable
final class HTTPClientState {
    static let historyLimitPerRequest = 20
    static let environmentDefaultsKey = "GoLensHTTPEnvironmentByFile"

    var outlines: [String: HTTPFileOutlineDTO] = [:]
    var globals: [String: String] = [:]
    var entries: [HTTPRunEntry] = []
    var selectedEntryID: UUID?
    var runningRunIDs: [String: String] = [:]
    var runAllPaths: Set<String> = []
    var selectedEnvironments: [String: String] = (UserDefaults.standard.dictionary(forKey: HTTPClientState.environmentDefaultsKey) as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(selectedEnvironments, forKey: Self.environmentDefaultsKey) }
    }

    var selectedEntry: HTTPRunEntry? {
        guard let selectedEntryID else { return entries.first }
        return entries.first { $0.id == selectedEntryID } ?? entries.first
    }

    var hasHistory: Bool { !entries.isEmpty }

    static func requestKey(path: String, request: HTTPFileRequestDTO) -> String {
        let id = request.name.isEmpty ? "\(request.method) \(request.url)" : request.name
        return path + "#" + id
    }

    func latestEntry(forKey key: String) -> HTTPRunEntry? {
        entries.first { $0.requestKey == key }
    }

    func history(forKey key: String) -> [HTTPRunEntry] {
        entries.filter { $0.requestKey == key }
    }

    func environment(for path: String) -> String? {
        guard let name = selectedEnvironments[path], !name.isEmpty else { return nil }
        if let outline = outlines[path], !outline.environments.names.contains(name) { return nil }
        return name
    }

    func insert(_ entry: HTTPRunEntry) {
        entries.insert(entry, at: 0)
        var seen = 0
        entries.removeAll { candidate in
            guard candidate.requestKey == entry.requestKey else { return false }
            seen += 1
            return seen > Self.historyLimitPerRequest
        }
        selectedEntryID = entry.id
    }

    func update(_ id: UUID, _ change: (inout HTTPRunEntry) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[idx]
        change(&entry)
        entries[idx] = entry
    }

    func clearHistory() {
        entries.removeAll { !$0.isRunning }
        selectedEntryID = entries.first?.id
    }
}
