import Foundation

struct DAPSource: Codable, Equatable {
    let name: String?
    let path: String?
}

struct DAPStackFrame: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
    let source: DAPSource?
    let line: Int
    let column: Int
}

struct DAPThread: Codable, Identifiable, Equatable {
    let id: Int
    let name: String
}

struct DAPScope: Codable, Identifiable, Equatable {
    var id: Int { variablesReference }
    let name: String
    let variablesReference: Int
}

struct DAPVariable: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let value: String
    let type: String?
    let variablesReference: Int
    
    enum CodingKeys: String, CodingKey {
        case name, value, type, variablesReference
    }
}

struct BreakpointSpec: Equatable {
    var condition = ""
    var hitCondition = ""
    var logMessage = ""
    var isEnabled = true

    var isPlain: Bool { condition.isEmpty && hitCondition.isEmpty && logMessage.isEmpty && isEnabled }
    var isLogpoint: Bool { !logMessage.isEmpty }
    var hasCondition: Bool { !condition.isEmpty || !hitCondition.isEmpty }
}

struct FunctionBreakpointItem: Codable, Identifiable, Equatable, Hashable {
    var name: String
    var isEnabled = true

    var id: String { name }
}

struct PersistedBreakpoints: Codable, Equatable {
    struct Line: Codable, Equatable {
        var path: String
        var line: Int
        var condition = ""
        var hitCondition = ""
        var logMessage = ""
        var isEnabled = true
    }

    var lines: [Line] = []
    var functions: [FunctionBreakpointItem] = []
}

enum BreakpointRef: Hashable {
    case line(path: String, line: Int)
    case function(name: String)
}

struct GoroutineGroup: Codable, Identifiable, Equatable {
    var id: String { threadIds.map(String.init).joined(separator: ",") }
    let count: Int
    let top: String
    let location: String
    let frames: [String]
    var frameLocations: [String]? = nil
    let threadIds: [Int]
    let names: [String]
    var labels: [String]? = nil
    var system: Bool? = nil

    var isSystem: Bool { system ?? false }

    func label(for threadId: Int) -> String {
        guard let labels, let index = threadIds.firstIndex(of: threadId), index < labels.count else { return "" }
        return labels[index]
    }

    func threadIds(matching query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return threadIds }
        let stackText = ([top, location] + frames + (frameLocations ?? [])).joined(separator: "\n").lowercased()
        if stackText.contains(needle) { return threadIds }
        return threadIds.filter { "\($0)" == needle || "#\($0)" == needle || label(for: $0).lowercased().contains(needle) }
    }
}

struct WatchEvaluationResult: Codable, Equatable {
    let value: String
    let type: String
    let variablesReference: Int
    let error: String?
}
