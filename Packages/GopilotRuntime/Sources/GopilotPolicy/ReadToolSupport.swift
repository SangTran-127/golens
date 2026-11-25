import Foundation
import GopilotRuntime

public struct ReadToolContext: Sendable {
    public let workspaceID: UUID
    public let snapshot: @Sendable () async -> SourceSnapshot
    public let scope: @Sendable () async -> TurnReadScope
    public let pathPolicy: PathPolicy
    public let evidence: EvidenceStore
    public let filter: SecretFilter
    public let backends: ReadBackends

    public init(
        workspaceID: UUID,
        snapshot: @escaping @Sendable () async -> SourceSnapshot,
        scope: @escaping @Sendable () async -> TurnReadScope = { .unrestricted },
        pathPolicy: PathPolicy,
        evidence: EvidenceStore,
        filter: SecretFilter = SecretFilter(),
        backends: ReadBackends
    ) {
        self.workspaceID = workspaceID
        self.snapshot = snapshot
        self.scope = scope
        self.pathPolicy = pathPolicy
        self.evidence = evidence
        self.filter = filter
        self.backends = backends
    }
}

struct Rendered {
    var fields: [String: Any]
    var refs: [SourceRef] = []
    var kind: EvidenceKind
    var truncated = false
    var nextCursor: String?
}

enum Resolution<Value> {
    case value(Value)
    case reply(ToolResultEnvelope)
}

enum RenderResult {
    case ok(Rendered)
    case fail(ToolErrorCode, String)
}

struct ReadTool: GopilotTool {
    let schema: ToolSchema
    let handler: @Sendable (String, [String: JSONValue]) async -> ToolResultEnvelope

    func execute(callID: String, argumentsJSON: String) async throws -> ToolResultEnvelope {
        let args = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        return await handler(callID, args)
    }
}

struct ReadToolKit: Sendable {
    static let previewLimit = 300
    static let generatedSuffixes = [".pb.go", "_generated.go", "_gen.go", ".gen.go"]

    let context: ReadToolContext

    func redact(_ text: String) -> String {
        context.filter.redact(text).text
    }

    func clip(_ text: String, _ limit: Int = ReadToolKit.previewLimit) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "..."
    }

    func makeTool(name: String, description: String, parameters: String, handler: @escaping @Sendable (String, [String: JSONValue]) async -> ToolResultEnvelope) -> ReadTool {
        ReadTool(schema: ToolSchema(name: name, description: description, parametersJSON: parameters), handler: handler)
    }

    func isVisible(path: String, dependencyRootID: String?) -> Bool {
        if let dependencyRootID, !context.pathPolicy.isApproved(dependencyRootID: dependencyRootID) { return false }
        return context.pathPolicy.lexicalExclusion(relativePath: path) == nil
    }

    func looksGenerated(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("zz_generated") || Self.generatedSuffixes.contains { name.hasSuffix($0) }
    }

    func envelope(callID: String, outcome: String, code: ToolErrorCode?, retryable: Bool, snapshotID: String?, fields: [String: Any] = [:], evidenceIDs: [String] = [], truncated: Bool = false, nextCursor: String? = nil) -> ToolResultEnvelope {
        var object = fields
        object["outcome"] = outcome
        object["truncated"] = truncated
        return ToolResultEnvelope(
            callID: callID,
            status: code == nil ? .ok : .error,
            data: JSONOutput.string(object),
            evidenceIDs: evidenceIDs,
            sourceSnapshotID: snapshotID,
            truncated: truncated,
            nextCursor: nextCursor,
            errorCode: code,
            retryable: retryable
        )
    }

    func failure(callID: String, code: ToolErrorCode, message: String, retryable: Bool = false) -> ToolResultEnvelope {
        envelope(callID: callID, outcome: "error", code: code, retryable: retryable, snapshotID: nil, fields: ["message": message])
    }

    func denial(callID: String, _ reason: PathDenial) -> ToolResultEnvelope {
        switch reason {
        case .notFound:
            return failure(callID: callID, code: .notFound, message: "No such file or directory in the allowed roots.")
        case .empty, .tooLong:
            return failure(callID: callID, code: .invalidArguments, message: "The path is empty or too long.")
        case .previewRequired:
            return failure(callID: callID, code: .denied, message: "The user must preview this file before it can be attached.")
        case .absolutePath, .traversal:
            return failure(callID: callID, code: .denied, message: "Use a path relative to the project root, without a leading slash or '..', for example service.go or internal/api/handler.go. The project root itself is the empty string.")
        case .nulCharacter, .outsideAllowedRoots, .dependencyRootNotApproved, .excluded:
            return failure(callID: callID, code: .denied, message: "Access to this path is not allowed.")
        }
    }

    func resolvePath(_ args: [String: JSONValue], callID: String, allowsRoot: Bool = false, scope: TurnReadScope? = nil) -> Resolution<ResolvedPath> {
        let path = args["relativePath"]?.stringValue ?? ""
        let root = args["dependencyRootID"]?.stringValue
        switch context.pathPolicy.evaluate(relativePath: path, dependencyRootID: root, allowsRoot: allowsRoot) {
        case .allowed(let resolved):
            if let scope, !scope.allowsFile(relativePath: resolved.relativePath, dependencyRootID: resolved.dependencyRootID) {
                return .reply(failure(callID: callID, code: .denied, message: "Project context is off. Access is restricted to the attached files for this turn."))
            }
            return .value(resolved)
        case .denied(let reason):
            return .reply(denial(callID: callID, reason))
        }
    }

    func position(_ args: [String: JSONValue], callID: String, scope: TurnReadScope? = nil) -> Resolution<SymbolPosition> {
        switch resolvePath(args, callID: callID, scope: scope) {
        case .reply(let envelope):
            return .reply(envelope)
        case .value(let path):
            guard let line = args["line"]?.intValue, let column = args["column"]?.intValue, line >= 1, column >= 1 else {
                return .reply(failure(callID: callID, code: .invalidArguments, message: "line and column are required and are 1-based."))
            }
            if let scope, !scope.allowsPosition(relativePath: path.relativePath, dependencyRootID: path.dependencyRootID, lineZeroBased: line - 1) {
                return .reply(failure(callID: callID, code: .denied, message: "Project context is off. The requested line is outside the attached source ranges for this turn."))
            }
            return .value(SymbolPosition(path: path, line: line - 1, character: column - 1))
        }
    }

    func ref(for location: CodeLocation) -> SourceRef {
        SourceRef(workspaceID: context.workspaceID, dependencyRootID: location.dependencyRootID, path: location.path, range: location.range, documentVersion: location.documentVersion)
    }

    func locationJSON(_ location: CodeLocation) -> [String: Any] {
        var object: [String: Any] = [
            "path": location.path,
            "startLine": location.range.startLine + 1,
            "startColumn": location.range.startCharacter + 1,
            "endLine": location.range.endLine + 1,
            "endColumn": location.range.endCharacter + 1,
            "isDynamic": location.isDynamic
        ]
        if let root = location.dependencyRootID { object["dependencyRootID"] = root }
        if let preview = location.preview { object["preview"] = redact(clip(preview)) }
        return object
    }

    func symbolJSON(_ symbol: SymbolInfo) -> [String: Any] {
        var object: [String: Any] = ["name": symbol.name, "kind": symbol.kind, "location": locationJSON(symbol.location)]
        if let container = symbol.container { object["container"] = container }
        return object
    }

    func run<V: Sendable>(callID: String, toolName: String, backendAvailable: Bool, call: @Sendable () async -> BackendOutcome<V>, render: (V, SourceSnapshot) -> RenderResult) async -> ToolResultEnvelope {
        guard backendAvailable else {
            return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: false, snapshotID: nil, fields: ["reason": "\(toolName) has no backend in this host."])
        }
        let before = await context.snapshot()
        let outcome = await call()
        let after = await context.snapshot()
        if before.id != after.id {
            return envelope(callID: callID, outcome: "stale", code: .staleContext, retryable: true, snapshotID: after.id, fields: ["message": "The source snapshot changed while \(toolName) was running. The result was discarded; call it again."])
        }

        switch outcome {
        case .empty:
            return envelope(callID: callID, outcome: "empty", code: nil, retryable: false, snapshotID: before.id, fields: ["message": "The query completed and returned no results.", "complete": true])
        case .unavailable(let reason):
            return envelope(callID: callID, outcome: "unavailable", code: .unavailable, retryable: true, snapshotID: before.id, fields: ["reason": redact(clip(reason, 200))])
        case .timeout:
            return envelope(callID: callID, outcome: "timeout", code: .timeout, retryable: true, snapshotID: before.id, fields: ["message": "The backend did not answer in time. This does not mean there are no results."])
        case .found(let value):
            switch render(value, before) {
            case .fail(let code, let message):
                return envelope(callID: callID, outcome: "error", code: code, retryable: code == .staleContext, snapshotID: before.id, fields: ["message": message])
            case .ok(let rendered):
                let provisional = envelope(callID: callID, outcome: "found", code: nil, retryable: false, snapshotID: before.id, fields: rendered.fields, truncated: rendered.truncated, nextCursor: rendered.nextCursor)
                let stored = await context.evidence.add(EvidenceDraft(
                    workspaceID: context.workspaceID,
                    producerID: "\(toolName):\(callID)",
                    kind: rendered.kind,
                    sourceRefs: rendered.refs,
                    snapshotID: before.id,
                    content: provisional.data,
                    isTruncated: rendered.truncated
                ))
                var fields = rendered.fields
                fields["evidenceID"] = stored.id
                return envelope(callID: callID, outcome: "found", code: nil, retryable: false, snapshotID: before.id, fields: fields, evidenceIDs: [stored.id], truncated: rendered.truncated, nextCursor: rendered.nextCursor)
            }
        }
    }
}
