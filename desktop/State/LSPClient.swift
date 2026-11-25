import Foundation
import os

public struct LSPPosition: Codable, Hashable {
    public let line: Int
    public let character: Int
}

public struct LSPRange: Codable, Hashable {
    public let start: LSPPosition
    public let end: LSPPosition
}

public struct LSPLocation: Codable {
    public let uri: String
    public let range: LSPRange
    
    public var path: String {
        lspPath(fromURI: uri)
    }
}

public struct LSPTextEdit: Codable {
    public let range: LSPRange
    public let newText: String
}

public struct LSPVersionedDocument: Codable {
    public let uri: String
}

public struct LSPDocumentChange: Codable {
    public let textDocument: LSPVersionedDocument
    public let edits: [LSPTextEdit]
}

public struct WorkspaceEdit: Codable {
    public let changes: [String: [LSPTextEdit]]?
    public var documentChanges: [LSPDocumentChange]? = nil

    public var editsByPath: [(String, [LSPTextEdit])] {
        var out: [(String, [LSPTextEdit])] = (changes ?? [:]).map { (lspPath(fromURI: $0.key), $0.value) }
        for change in documentChanges ?? [] {
            out.append((lspPath(fromURI: change.textDocument.uri), change.edits))
        }
        return out
    }
}

public func lspURI(forPath path: String) -> String {
    LSPFileURI.uri(forPath: path)
}

public func lspPath(fromURI uri: String) -> String {
    LSPFileURI.path(fromURI: uri)
}

public struct CodeAction: Codable, Identifiable {
    public let title: String
    public let kind: String?
    public let edit: WorkspaceEdit?
    
    public var id: String {
        return "\(title)-\(kind ?? "")"
    }
}

public struct InlayHint: Codable, Identifiable {
    public let position: LSPPosition
    public let label: String
    public let kind: Int?
    
    public var id: String {
        return "\(position.line):\(position.character):\(label)"
    }
}

public struct DocumentSymbol: Codable, Identifiable {
    public let name: String
    public let detail: String?
    public let kind: Int
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let children: [DocumentSymbol]?
    
    public var id: String {
        return "\(name)-\(range.start.line)-\(range.start.character)"
    }
}

public struct WorkspaceSymbolInfo: Codable {
    public let name: String
    public let kind: Int
    public let location: LSPLocation
    public let containerName: String?
}

public struct LSPDocumentHighlight: Decodable {
    public let range: LSPRange
    public let kind: Int?
}

public enum DefinitionResult: Codable {
    case location(LSPLocation)
    case locations([LSPLocation])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let loc = try? container.decode(LSPLocation.self) {
            self = .location(loc)
        } else if let locs = try? container.decode([LSPLocation].self) {
            self = .locations(locs)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid definition result format")
        }
    }
    
    public var locations: [LSPLocation] {
        switch self {
        case .location(let loc):
            return [loc]
        case .locations(let locs):
            return locs
        }
    }
}

final class LSPServerConditionsStore: @unchecked Sendable {
    static let shared = LSPServerConditionsStore()
    private let lock = OSAllocatedUnfairLock(initialState: LSPServerConditions.localReady)

    var current: LSPServerConditions { lock.withLock { $0 } }

    var timeoutScale: Double {
        UserDefaults.standard.bool(forKey: "GoLensDebugForceLSPTimeouts") ? 0 : 1
    }

    func update(_ conditions: LSPServerConditions) {
        lock.withLock { $0 = conditions }
    }
}

final class LSPEditorActivity: @unchecked Sendable {
    static let shared = LSPEditorActivity()

    private struct State {
        var lastEdit: ContinuousClock.Instant?
        var backgroundInFlight = 0
        var preemptPending = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var secondsSinceEdit: Double? {
        guard let last = lock.withLock({ $0.lastEdit }) else { return nil }
        let elapsed = last.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    func noteEdit() {
        let preempt = lock.withLock { state -> Bool in
            state.lastEdit = .now
            guard state.backgroundInFlight > 0, !state.preemptPending else { return false }
            state.preemptPending = true
            return true
        }
        if preempt {
            Task { @LSPClientActor in LSPClient.shared.yieldBackgroundToTyping() }
        }
    }

    func setBackgroundInFlight(_ count: Int) {
        lock.withLock { $0.backgroundInFlight = count }
    }

    func preemptHandled() {
        lock.withLock { $0.preemptPending = false }
    }
}

@globalActor
public actor LSPClientActor {
    public static let shared = LSPClientActor()
}

@LSPClientActor
public class LSPClient {
    public static let shared = LSPClient()
    
    static let firstRequestID: Int64 = 1 << 32
    static let maxPendingRequests = 64

    private var requestIdCounter = LSPClient.firstRequestID
    private var pendingRequests: [Int64: CheckedContinuation<Data, Error>] = [:]
    private var timeoutTasks: [Int64: Task<Void, Never>] = [:]
    private var backgroundRequests: Set<Int64> = []
    private var navigationRequestsInFlight = 0
    private var supersede: [String: Int64] = [:]

    private init() {}

    public func handleIncomingResponse(jsonString: String) {
        let data = Data(jsonString.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let idVal = json["id"] else { return }
        let id: Int64
        if let num = idVal as? NSNumber {
            id = num.int64Value
        } else if let str = idVal as? String, let num = Int64(str) {
            id = num
        } else {
            return
        }
        guard let continuation = takePending(id) else { return }
        if let errorObj = json["error"] as? [String: Any] {
            let message = errorObj["message"] as? String ?? "Language server error"
            let code = (errorObj["code"] as? NSNumber)?.intValue ?? -1
            continuation.resume(throwing: LSPRequestFailure.fromResponseError(code: code, message: message))
        } else {
            continuation.resume(returning: data)
        }
    }

    private func takePending(_ id: Int64) -> CheckedContinuation<Data, Error>? {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if backgroundRequests.remove(id) != nil {
            LSPEditorActivity.shared.setBackgroundInFlight(backgroundRequests.count)
        }
        return pendingRequests.removeValue(forKey: id)
    }

    private func fail(_ id: Int64, _ failure: LSPRequestFailure) {
        takePending(id)?.resume(throwing: failure)
    }

    private func cancel(_ id: Int64, _ failure: LSPRequestFailure = .cancelled) {
        guard pendingRequests[id] != nil else { return }
        CancelLSPRequest(id)
        fail(id, failure)
    }

    private func preemptBackgroundRequests() {
        for id in backgroundRequests {
            cancel(id, .preempted)
        }
    }

    func yieldBackgroundToTyping() {
        LSPEditorActivity.shared.preemptHandled()
        preemptBackgroundRequests()
    }

    private func waitForForegroundToSettle() async throws {
        let started = ContinuousClock.now
        while true {
            if Task.isCancelled { throw LSPRequestFailure.cancelled }
            let conditions = LSPServerConditionsStore.shared.current
            let waitingForLoad = conditions.isRemote && conditions.isLoading
                && started.duration(to: .now) < .seconds(LSPTimeoutPolicy.maxBackgroundWaitWhileLoading)
            let typing = !LSPTimeoutPolicy.backgroundMayRun(secondsSinceEdit: LSPEditorActivity.shared.secondsSinceEdit)
            if navigationRequestsInFlight == 0 && !waitingForLoad && !typing { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                throw LSPRequestFailure.cancelled
            }
        }
    }

    func sendRequest(method: String, params: [String: Any], kind: LSPRequestKind, supersedeKey: String? = nil) async throws -> Data {
        let store = LSPServerConditionsStore.shared
        let timeout = LSPTimeoutPolicy.timeout(for: kind, under: store.current) * store.timeoutScale
        return try await sendRequest(method: method, params: params, supersedeKey: supersedeKey, timeout: timeout, priority: kind.priority)
    }

    func sendRequest(method: String, params: [String: Any], supersedeKey: String? = nil, timeout: Duration = .seconds(5), priority: LSPRequestPriority = .interactive) async throws -> Data {
        if priority == .background {
            try await waitForForegroundToSettle()
            guard pendingRequests.count < Self.maxPendingRequests - LSPTimeoutPolicy.reservedForegroundSlots else {
                throw LSPRequestFailure.overloaded
            }
        }
        if priority == .navigation {
            navigationRequestsInFlight += 1
            preemptBackgroundRequests()
        }
        defer {
            if priority == .navigation { navigationRequestsInFlight -= 1 }
        }
        let id = requestIdCounter
        requestIdCounter += 1
        if let key = supersedeKey {
            if let previous = supersede[key] { cancel(previous) }
            supersede[key] = id
        }
        defer {
            if let key = supersedeKey, supersede[key] == id { supersede.removeValue(forKey: key) }
        }
        guard pendingRequests.count < Self.maxPendingRequests else {
            throw LSPRequestFailure.overloaded
        }
        let requestDict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let requestData = try? JSONSerialization.data(withJSONObject: requestDict, options: [.withoutEscapingSlashes]),
              let requestStr = String(data: requestData, encoding: .utf8) else {
            throw LSPRequestFailure.invalidResponse
        }
        let whileLoading = LSPServerConditionsStore.shared.current.isLoading
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequests[id] = continuation
                if priority == .background {
                    backgroundRequests.insert(id)
                    LSPEditorActivity.shared.setBackgroundInFlight(backgroundRequests.count)
                }
                timeoutTasks[id] = Task { @LSPClientActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.cancel(id, .timedOut(seconds: seconds, whileLoading: whileLoading))
                }
                if Task.isCancelled {
                    fail(id, .cancelled)
                    return
                }
                let queued = requestStr.withCString { SendLSPMessage($0) } == 1
                if !queued {
                    fail(id, .serverNotRunning)
                }
            }
        } onCancel: {
            Task { @LSPClientActor in LSPClient.shared.cancel(id) }
        }
    }

    private func resultValue(method: String, params: [String: Any], kind: LSPRequestKind, supersedeKey: String? = nil) async -> Result<Any?, LSPRequestFailure> {
        do {
            let data = try await sendRequest(method: method, params: params, kind: kind, supersedeKey: supersedeKey)
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return .failure(.invalidResponse)
            }
            let value = json["result"]
            return .success(value is NSNull ? nil : value)
        } catch let failure as LSPRequestFailure {
            if failure.meansNoResult { return .success(nil) }
            if !failure.isSilent { measureLog("\(method) failed: \(failure.explanation)") }
            return .failure(failure)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.invalidResponse)
        }
    }

    private func locationsResult(method: String, params: [String: Any], kind: LSPRequestKind, supersedeKey: String? = nil) async -> Result<[LSPLocation], LSPRequestFailure> {
        let reply = await resultValue(method: method, params: params, kind: kind, supersedeKey: supersedeKey)
        return reply.flatMap { value in
            guard let value else { return .success([]) }
            guard value is [Any] || value is [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                  let decoded = try? JSONDecoder().decode(DefinitionResult.self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(decoded.locations)
        }
    }

    private static func positionParams(line: Int, col: Int, path: String) -> [String: Any] {
        [
            "textDocument": ["uri": lspURI(forPath: path)],
            "position": ["line": line - 1, "character": col - 1]
        ]
    }

    private func documentParams(_ path: String) -> [String: Any] {
        ["uri": lspURI(forPath: path)]
    }

    public nonisolated static func notifyWatchedFilesChanged(_ paths: [String], changeType: Int = 2) {
        guard !paths.isEmpty else { return }
        for path in paths { InvalidateWorkspaceSymbolFile(path) }
        let changes: [[String: Any]] = paths.map { ["uri": lspURI(forPath: $0), "type": changeType] }
        let msg: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "workspace/didChangeWatchedFiles",
            "params": ["changes": changes]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return }
        _ = str.withCString { SendLSPMessage($0) }
    }

    func requestHover(atLine line: Int, col: Int, inPath path: String, kind: LSPRequestKind = .hover) async -> String? {
        let reply = await resultValue(method: "textDocument/hover", params: Self.positionParams(line: line, col: col, path: path), kind: kind, supersedeKey: "hover")
        guard case .success(let value) = reply, let result = value as? [String: Any] else { return nil }
        return extractMarkdown(from: result)
    }

    func definitionResult(atLine line: Int, col: Int, inPath path: String) async -> Result<[LSPLocation], LSPRequestFailure> {
        await locationsResult(method: "textDocument/definition", params: Self.positionParams(line: line, col: col, path: path), kind: .definition)
    }

    public func requestDefinition(atLine line: Int, col: Int, inPath path: String) async -> [LSPLocation] {
        (try? await definitionResult(atLine: line, col: col, inPath: path).get()) ?? []
    }
    
    private func extractMarkdown(from hoverResult: [String: Any]) -> String? {
        guard let contents = hoverResult["contents"] else { return nil }
        
        if let str = contents as? String {
            return str
        }
        
        if let dict = contents as? [String: Any], let value = dict["value"] as? String {
            return value
        }
        
        if let arr = contents as? [[String: Any]] {
            var parts: [String] = []
            for item in arr {
                if let val = item["value"] as? String {
                    parts.append(val)
                }
            }
            return parts.joined(separator: "\n\n")
        }
        
        if let arr = contents as? [Any] {
            var parts: [String] = []
            for item in arr {
                if let str = item as? String {
                    parts.append(str)
                } else if let dict = item as? [String: Any], let val = dict["value"] as? String {
                    parts.append(val)
                }
            }
            return parts.joined(separator: "\n\n")
        }
        
        return nil
    }
    
    func referencesResult(atLine line: Int, col: Int, inPath path: String, kind: LSPRequestKind = .references) async -> Result<[LSPLocation], LSPRequestFailure> {
        var params = Self.positionParams(line: line, col: col, path: path)
        params["context"] = ["includeDeclaration": false]
        return await locationsResult(method: "textDocument/references", params: params, kind: kind)
    }

    public func requestReferences(atLine line: Int, col: Int, inPath path: String) async -> [LSPLocation]? {
        try? await referencesResult(atLine: line, col: col, inPath: path).get()
    }

    func implementationResult(atLine line: Int, col: Int, inPath path: String, kind: LSPRequestKind = .implementation) async -> Result<[LSPLocation], LSPRequestFailure> {
        await locationsResult(method: "textDocument/implementation", params: Self.positionParams(line: line, col: col, path: path), kind: kind)
    }

    func typeDefinitionResult(atLine line: Int, col: Int, inPath path: String) async -> Result<[LSPLocation], LSPRequestFailure> {
        await locationsResult(method: "textDocument/typeDefinition", params: Self.positionParams(line: line, col: col, path: path), kind: .typeDefinition)
    }

    public func requestImplementation(atLine line: Int, col: Int, inPath path: String) async -> [LSPLocation] {
        (try? await implementationResult(atLine: line, col: col, inPath: path).get()) ?? []
    }

    public func requestTypeDefinition(atLine line: Int, col: Int, inPath path: String) async -> [LSPLocation] {
        (try? await typeDefinitionResult(atLine: line, col: col, inPath: path).get()) ?? []
    }

    private func parseRange(_ dict: [String: Any]?) -> LSPRange? {
        guard let dict,
              let startDict = dict["start"] as? [String: Any],
              let endDict = dict["end"] as? [String: Any],
              let sl = startDict["line"] as? Int,
              let sc = startDict["character"] as? Int,
              let el = endDict["line"] as? Int,
              let ec = endDict["character"] as? Int else { return nil }
        return LSPRange(
            start: LSPPosition(line: sl, character: sc),
            end: LSPPosition(line: el, character: ec)
        )
    }

    private func parseHierarchyItem(_ dict: [String: Any], overrideSelectionRange: LSPRange? = nil) -> HierarchyItem? {
        guard let name = dict["name"] as? String,
              let kind = dict["kind"] as? Int,
              let uri = dict["uri"] as? String,
              let range = parseRange(dict["range"] as? [String: Any]),
              let selRange = parseRange(dict["selectionRange"] as? [String: Any]) else { return nil }
        let rawData = (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data()
        let rawJSON = String(data: rawData, encoding: .utf8) ?? "{}"
        return HierarchyItem(
            name: name,
            detail: dict["detail"] as? String,
            kind: kind,
            uri: uri,
            range: range,
            selectionRange: overrideSelectionRange ?? selRange,
            rawJSON: rawJSON
        )
    }

    private func locationsToHierarchyItems(_ locations: [LSPLocation]) -> [HierarchyItem] {
        var lineCache: [String: [String]] = [:]
        var items: [HierarchyItem] = []
        for loc in locations.prefix(WorkspaceState.maxHierarchyItems) {
            let path = loc.path
            let lines: [String]
            if let cached = lineCache[path] {
                lines = cached
            } else {
                let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                let split = text.components(separatedBy: .newlines)
                lineCache[path] = split
                lines = split
            }
            let lineIdx = loc.range.start.line
            let lineText = (lineIdx >= 0 && lineIdx < lines.count) ? lines[lineIdx] : ""
            let name = Self.extractSymbolName(from: lineText, utf16Col: loc.range.start.character) ?? (path as NSString).lastPathComponent
            let kind: Int
            if lineText.contains("interface") {
                kind = 11
            } else if lineText.contains("struct") {
                kind = 23
            } else if lineText.trimmingCharacters(in: .whitespaces).hasPrefix("func ") {
                kind = 6
            } else {
                kind = 5
            }
            let detail = (path as NSString).lastPathComponent
            let rangeDict: [String: Any] = [
                "start": ["line": loc.range.start.line, "character": loc.range.start.character],
                "end": ["line": loc.range.end.line, "character": loc.range.end.character]
            ]
            let rawDict: [String: Any] = [
                "name": name,
                "detail": detail,
                "kind": kind,
                "uri": loc.uri,
                "range": rangeDict,
                "selectionRange": rangeDict
            ]
            let rawData = (try? JSONSerialization.data(withJSONObject: rawDict, options: [])) ?? Data()
            let rawJSON = String(data: rawData, encoding: .utf8) ?? "{}"
            items.append(HierarchyItem(
                name: name,
                detail: detail,
                kind: kind,
                uri: loc.uri,
                range: loc.range,
                selectionRange: loc.range,
                rawJSON: rawJSON
            ))
        }
        return items
    }

    private static func extractSymbolName(from lineText: String, utf16Col: Int) -> String? {
        let ns = lineText as NSString
        guard ns.length > 0 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let clamped = max(0, min(utf16Col, ns.length - 1))
        var start = clamped
        while start > 0 {
            let sub = ns.substring(with: NSRange(location: start - 1, length: 1))
            guard let scalar = sub.unicodeScalars.first, allowed.contains(scalar) else { break }
            start -= 1
        }
        var end = clamped
        while end < ns.length {
            let sub = ns.substring(with: NSRange(location: end, length: 1))
            guard let scalar = sub.unicodeScalars.first, allowed.contains(scalar) else { break }
            end += 1
        }
        if end > start {
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
        return nil
    }

    private func hierarchyItemsResult(method: String, params: [String: Any], kind: LSPRequestKind, supersedeKey: String, transform: ([String: Any]) -> HierarchyItem?) async -> Result<[HierarchyItem], LSPRequestFailure> {
        let reply = await resultValue(method: method, params: params, kind: kind, supersedeKey: supersedeKey)
        return reply.flatMap { value in
            guard let value else { return .success([]) }
            guard let list = value as? [[String: Any]] else { return .failure(.invalidResponse) }
            var items: [HierarchyItem] = []
            for element in list {
                guard let item = transform(element) else { continue }
                items.append(item)
                if items.count >= WorkspaceState.maxHierarchyItems { break }
            }
            return .success(items)
        }
    }

    private func rawItemParams(_ item: HierarchyItem) -> [String: Any]? {
        guard let rawData = item.rawJSON.data(using: .utf8),
              let rawItemDict = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              !rawItemDict.isEmpty else { return nil }
        return ["item": rawItemDict]
    }

    func prepareCallHierarchy(atLine line: Int, col: Int, inPath path: String) async -> Result<[HierarchyItem], LSPRequestFailure> {
        await hierarchyItemsResult(method: "textDocument/prepareCallHierarchy", params: Self.positionParams(line: line, col: col, path: path), kind: .hierarchyPrepare, supersedeKey: "prepareCallHierarchy") { parseHierarchyItem($0) }
    }

    func incomingCalls(for item: HierarchyItem) async -> Result<[HierarchyItem], LSPRequestFailure> {
        guard let params = rawItemParams(item) else { return .success([]) }
        return await hierarchyItemsResult(method: "callHierarchy/incomingCalls", params: params, kind: .hierarchyExpand, supersedeKey: "hierarchyCalls") { element in
            guard let fromDict = element["from"] as? [String: Any] else { return nil }
            let fromRanges = (element["fromRanges"] as? [[String: Any]])?.compactMap { parseRange($0) } ?? []
            return parseHierarchyItem(fromDict, overrideSelectionRange: fromRanges.first)
        }
    }

    func outgoingCalls(for item: HierarchyItem) async -> Result<[HierarchyItem], LSPRequestFailure> {
        guard let params = rawItemParams(item) else { return .success([]) }
        return await hierarchyItemsResult(method: "callHierarchy/outgoingCalls", params: params, kind: .hierarchyExpand, supersedeKey: "hierarchyCalls") { element in
            guard let toDict = element["to"] as? [String: Any] else { return nil }
            return parseHierarchyItem(toDict)
        }
    }

    func prepareTypeHierarchy(atLine line: Int, col: Int, inPath path: String) async -> Result<[HierarchyItem], LSPRequestFailure> {
        let prepared = await hierarchyItemsResult(method: "textDocument/prepareTypeHierarchy", params: Self.positionParams(line: line, col: col, path: path), kind: .hierarchyPrepare, supersedeKey: "prepareTypeHierarchy") { parseHierarchyItem($0) }
        switch prepared {
        case .failure(let failure):
            return .failure(failure)
        case .success(let items) where !items.isEmpty:
            return .success(items)
        case .success:
            break
        }
        switch await definitionResult(atLine: line, col: col, inPath: path) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let defs) where !defs.isEmpty:
            return .success(locationsToHierarchyItems(defs))
        case .success:
            let fallbackPos = LSPPosition(line: max(0, line - 1), character: max(0, col - 1))
            let fallbackLoc = LSPLocation(uri: lspURI(forPath: path), range: LSPRange(start: fallbackPos, end: fallbackPos))
            return .success(locationsToHierarchyItems([fallbackLoc]))
        }
    }

    func supertypes(for item: HierarchyItem) async -> Result<[HierarchyItem], LSPRequestFailure> {
        await typeHierarchyRelatives(method: "typeHierarchy/supertypes", for: item)
    }

    func subtypes(for item: HierarchyItem) async -> Result<[HierarchyItem], LSPRequestFailure> {
        await typeHierarchyRelatives(method: "typeHierarchy/subtypes", for: item)
    }

    private func typeHierarchyRelatives(method: String, for item: HierarchyItem) async -> Result<[HierarchyItem], LSPRequestFailure> {
        if let params = rawItemParams(item) {
            let reply = await hierarchyItemsResult(method: method, params: params, kind: .hierarchyExpand, supersedeKey: "typeHierarchy") { parseHierarchyItem($0) }
            switch reply {
            case .failure(let failure):
                return .failure(failure)
            case .success(let items) where !items.isEmpty:
                return .success(items)
            case .success:
                break
            }
        }
        let line = item.selectionRange.start.line + 1
        let col = item.selectionRange.start.character + 1
        var impls = await implementationResult(atLine: line, col: col, inPath: item.filePath, kind: .hierarchyExpand)
        if case .success(let found) = impls, found.isEmpty, item.selectionRange.start.line > 0 {
            impls = await implementationResult(atLine: item.selectionRange.start.line, col: max(1, item.selectionRange.start.character), inPath: item.filePath, kind: .hierarchyExpand)
        }
        return impls.map { locationsToHierarchyItems($0) }
    }

    public func requestDocumentHighlight(atLine line: Int, col: Int, inPath path: String) async -> [LSPDocumentHighlight] {
        let reply = await resultValue(method: "textDocument/documentHighlight", params: Self.positionParams(line: line, col: col, path: path), kind: .documentHighlight, supersedeKey: "documentHighlight")
        guard case .success(let value) = reply, let result = value as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: result) else { return [] }
        return (try? JSONDecoder().decode([LSPDocumentHighlight].self, from: data)) ?? []
    }

    func prepareRenameResult(atLine line: Int, col: Int, inPath path: String) async -> Result<LSPRange?, LSPRequestFailure> {
        do {
            let data = try await sendRequest(method: "textDocument/prepareRename", params: Self.positionParams(line: line, col: col, path: path), kind: .rename, supersedeKey: "rename")
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return .failure(.invalidResponse) }
            guard let result = json["result"] as? [String: Any] else { return .success(nil) }
            return .success(parseRange(result["range"] as? [String: Any]) ?? parseRange(result))
        } catch let failure as LSPRequestFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidResponse)
        }
    }

    func renameOccurrences(atLine line: Int, col: Int, inPath path: String) async -> [LSPRange] {
        let reply = await resultValue(method: "textDocument/documentHighlight", params: Self.positionParams(line: line, col: col, path: path), kind: .rename)
        guard case .success(let value) = reply, let result = value as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: result) else { return [] }
        return ((try? JSONDecoder().decode([LSPDocumentHighlight].self, from: data)) ?? []).map(\.range)
    }

    public func requestWorkspaceSymbols(_ query: String) async -> [WorkspaceSymbolInfo] {
        let reply = await resultValue(method: "workspace/symbol", params: ["query": query], kind: .workspaceSymbol, supersedeKey: "workspaceSymbol")
        guard case .success(let value) = reply, let result = value as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: result) else { return [] }
        return (try? JSONDecoder().decode([WorkspaceSymbolInfo].self, from: data)) ?? []
    }

    func documentSymbolsResult(inPath path: String) async -> Result<[DocumentSymbol], LSPRequestFailure> {
        let reply = await resultValue(method: "textDocument/documentSymbol", params: ["textDocument": documentParams(path)], kind: .documentSymbol, supersedeKey: "documentSymbol")
        return reply.flatMap { value in
            guard let value else { return .success([]) }
            guard let result = value as? [[String: Any]],
                  let data = try? JSONSerialization.data(withJSONObject: result, options: []),
                  let symbols = try? JSONDecoder().decode([DocumentSymbol].self, from: data) else {
                return .failure(.invalidResponse)
            }
            return .success(symbols)
        }
    }

    public func requestDocumentSymbol(inPath path: String) async -> [DocumentSymbol] {
        (try? await documentSymbolsResult(inPath: path).get()) ?? []
    }
    
    public func requestCodeActions(range: LSPRange, inPath path: String, diagnostics: [[String: Any]] = []) async -> [CodeAction] {
        let uri = lspURI(forPath: path)
        let params: [String: Any] = [
            "textDocument": [
                "uri": uri
            ],
            "range": [
                "start": ["line": range.start.line, "character": range.start.character],
                "end": ["line": range.end.line, "character": range.end.character]
            ],
            "context": [
                "diagnostics": diagnostics
            ]
        ]
        
        do {
            let data = try await sendRequest(method: "textDocument/codeAction", params: params, kind: .codeAction, supersedeKey: "codeAction")
            guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  let result = json["result"] as? [[String: Any]] else { return [] }
            
            var actions: [CodeAction] = []
            for item in result {
                guard let title = item["title"] as? String else { continue }
                var edit: WorkspaceEdit? = nil
                if let editDict = item["edit"], let editData = try? JSONSerialization.data(withJSONObject: editDict) {
                    edit = try? JSONDecoder().decode(WorkspaceEdit.self, from: editData)
                }
                actions.append(CodeAction(title: title, kind: item["kind"] as? String, edit: edit))
            }
            return actions
        } catch {
            print("LSPClient: codeAction request failed: \(error.localizedDescription)")
        }
        
        return []
    }
    
    public func requestInlayHints(range: LSPRange, inPath path: String) async -> [InlayHint]? {
        let params: [String: Any] = [
            "textDocument": documentParams(path),
            "range": [
                "start": ["line": range.start.line, "character": range.start.character],
                "end": ["line": range.end.line, "character": range.end.character]
            ]
        ]
        let reply = await resultValue(method: "textDocument/inlayHint", params: params, kind: .inlayHint, supersedeKey: "inlayHint:" + path)
        guard case .success(let value) = reply else { return nil }
        guard let result = value as? [[String: Any]] else { return [] }
        var hints: [InlayHint] = []
        for item in result {
            guard let positionDict = item["position"] as? [String: Int],
                  let line = positionDict["line"],
                  let character = positionDict["character"] else { continue }
            let label: String
            if let labelString = item["label"] as? String {
                label = labelString
            } else if let labelParts = item["label"] as? [[String: Any]] {
                label = labelParts.compactMap { $0["value"] as? String }.joined()
            } else {
                label = ""
            }
            hints.append(InlayHint(position: LSPPosition(line: line, character: character), label: label, kind: item["kind"] as? Int))
        }
        return hints
    }
}
