import Foundation

enum LSPRequestPriority: Sendable {
    case navigation
    case interactive
    case background
}

enum LSPRequestKind: String, CaseIterable, Sendable {
    case hover
    case quickDocumentation
    case definition
    case references
    case implementation
    case typeDefinition
    case hierarchyPrepare
    case hierarchyExpand
    case documentHighlight
    case inlayHint
    case documentSymbol
    case workspaceSymbol
    case codeAction
    case usageLens
    case rename

    var priority: LSPRequestPriority {
        switch self {
        case .quickDocumentation, .definition, .references, .implementation, .typeDefinition, .hierarchyPrepare, .hierarchyExpand, .rename:
            return .navigation
        case .usageLens:
            return .background
        case .hover, .documentHighlight, .inlayHint, .documentSymbol, .workspaceSymbol, .codeAction:
            return .interactive
        }
    }
}

enum UsageCountSource: Equatable, Sendable {
    case index
    case refreshingIndex
    case waitForIndex
    case references

    init(indexState: String?) {
        switch indexState {
        case "ready": self = .index
        case "refreshing": self = .refreshingIndex
        case "building": self = .waitForIndex
        default: self = .references
        }
    }

    var answersFromIndex: Bool {
        self == .index || self == .refreshingIndex
    }

    var retriesLater: Bool {
        self == .waitForIndex || self == .refreshingIndex
    }

    func needsReferences(isEntryPoint: Bool) -> Bool {
        self == .references && !isEntryPoint
    }

    static func needsImplementation(kind: String, hasIndexedLens: Bool) -> Bool {
        kind != "func" && !hasIndexedLens
    }
}

struct LSPServerConditions: Equatable, Sendable {
    var isRemote: Bool
    var isLoading: Bool

    static let localReady = LSPServerConditions(isRemote: false, isLoading: false)
}

enum LSPTimeoutPolicy {
    struct Budget: Equatable {
        let local: Double
        let remote: Double
        let loading: Double
    }

    static func budget(for kind: LSPRequestKind) -> Budget {
        switch kind {
        case .hover: return Budget(local: 2.5, remote: 5, loading: 5)
        case .quickDocumentation: return Budget(local: 5, remote: 10, loading: 20)
        case .definition: return Budget(local: 10, remote: 20, loading: 45)
        case .references: return Budget(local: 15, remote: 30, loading: 60)
        case .implementation: return Budget(local: 15, remote: 30, loading: 60)
        case .typeDefinition: return Budget(local: 10, remote: 20, loading: 45)
        case .hierarchyPrepare: return Budget(local: 10, remote: 20, loading: 45)
        case .hierarchyExpand: return Budget(local: 15, remote: 30, loading: 60)
        case .documentHighlight: return Budget(local: 1, remote: 3, loading: 3)
        case .inlayHint: return Budget(local: 1, remote: 3, loading: 3)
        case .documentSymbol: return Budget(local: 5, remote: 10, loading: 20)
        case .workspaceSymbol: return Budget(local: 3, remote: 8, loading: 15)
        case .codeAction: return Budget(local: 2, remote: 5, loading: 10)
        case .usageLens: return Budget(local: 5, remote: 15, loading: 15)
        case .rename: return Budget(local: 10, remote: 20, loading: 45)
        }
    }

    static func seconds(for kind: LSPRequestKind, under conditions: LSPServerConditions) -> Double {
        let budget = budget(for: kind)
        let settled = conditions.isRemote ? budget.remote : budget.local
        return conditions.isLoading ? max(settled, budget.loading) : settled
    }

    static func timeout(for kind: LSPRequestKind, under conditions: LSPServerConditions) -> Duration {
        .milliseconds(Int64((seconds(for: kind, under: conditions) * 1000).rounded()))
    }

    static func codeLensConcurrency(under conditions: LSPServerConditions) -> Int {
        conditions.isRemote ? 1 : 6
    }

    static let maxBackgroundWaitWhileLoading: Double = 60
    static let reservedForegroundSlots = 16
    static let backgroundQuietAfterEdit: Double = 1.5
    static let codeLensRecomputeAfterEdit: Double = 3

    static func backgroundMayRun(secondsSinceEdit: Double?) -> Bool {
        guard let secondsSinceEdit else { return true }
        return secondsSinceEdit >= backgroundQuietAfterEdit
    }

    static func codeLensRetryDelay(afterFailedRounds rounds: Int, resumeDelay: Double, maxRounds: Int) -> Double {
        resumeDelay * pow(2, Double(min(max(rounds, 1), maxRounds + 1) - 1))
    }
}

enum LSPRequestFailure: Error, Equatable, Sendable, LocalizedError {
    case timedOut(seconds: Double, whileLoading: Bool)
    case serverNotRunning
    case serverError(code: Int, message: String)
    case contentModified
    case cancelled
    case preempted
    case overloaded
    case invalidResponse

    static let requestCancelledCode = -32800
    static let contentModifiedCode = -32801

    static func fromResponseError(code: Int, message: String) -> LSPRequestFailure {
        switch code {
        case requestCancelledCode: return .cancelled
        case contentModifiedCode: return .contentModified
        default: return .serverError(code: code, message: message)
        }
    }

    var isSilent: Bool {
        self == .cancelled || self == .preempted
    }

    var meansNoResult: Bool {
        guard case .serverError(_, let message) = self else { return false }
        return !Self.isRetryableServerMessage(message)
    }

    static func isRetryableServerMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["metadata", "no views", "not loaded", "still loading", "context canceled", "context deadline"].contains { lowered.contains($0) }
    }

    var explanation: String {
        switch self {
        case .timedOut(let seconds, let whileLoading):
            if whileLoading {
                return "gopls is still loading the project. Try again in a moment."
            }
            return "gopls didn’t answer within \(Int(seconds.rounded())) seconds."
        case .serverNotRunning:
            return "The language server isn’t running."
        case .serverError(_, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "gopls reported an error." : "gopls reported an error: \(trimmed)"
        case .contentModified:
            return "The file changed while gopls was answering."
        case .cancelled, .preempted:
            return "The request was cancelled."
        case .overloaded:
            return "Too many language server requests are waiting."
        case .invalidResponse:
            return "gopls sent an answer GoLens couldn’t read."
        }
    }

    var errorDescription: String? {
        switch self {
        case .timedOut, .cancelled, .preempted: return "cancelled"
        case .serverNotRunning: return "Language server is not running"
        case .serverError(_, let message): return message
        case .contentModified: return "content modified"
        case .overloaded: return "Too many pending language server requests"
        case .invalidResponse: return "Invalid language server response"
        }
    }
}

enum LSPFileURI {
    private static let unescapedBytes: Set<UInt8> = {
        var set = Set<UInt8>()
        for c in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(c) }
        for c in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(c) }
        for c in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(c) }
        for c in "-_.~$&+,/:;=@".utf8 { set.insert(c) }
        return set
    }()

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    static func uri(forPath path: String) -> String {
        var bytes: [UInt8] = Array("file://".utf8)
        for byte in path.precomposedStringWithCanonicalMapping.utf8 {
            if unescapedBytes.contains(byte) {
                bytes.append(byte)
            } else {
                bytes.append(UInt8(ascii: "%"))
                bytes.append(hexDigits[Int(byte >> 4)])
                bytes.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func path(fromURI uri: String) -> String {
        guard uri.lowercased().hasPrefix("file:") else { return uri }
        var rest = Substring(uri.dropFirst(5))
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            if !rest.hasPrefix("/") {
                if let slash = rest.firstIndex(of: "/") {
                    rest = rest[slash...]
                } else {
                    rest = ""
                }
            }
        }
        if let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            rest = rest[..<end]
        }
        let raw = String(rest)
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.precomposedStringWithCanonicalMapping
    }
}
