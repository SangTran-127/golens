import Foundation
import GopilotPolicy

enum GopilotLSPReply {
    case result(Any?)
    case unavailable(String)
    case timeout
}

enum GopilotLSP {
    static func request(_ method: String, params: [String: Any], key: String, timeout: Duration = .seconds(5)) async -> GopilotLSPReply {
        do {
            let data = try await LSPClient.shared.sendRequest(method: method, params: params, supersedeKey: "gopilot." + key, timeout: timeout)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unavailable("The language server sent an unreadable answer.") }
            return .result(json["result"])
        } catch is CancellationError {
            return .timeout
        } catch {
            let message = (error as NSError).localizedDescription
            if message == "cancelled" { return .timeout }
            if message.contains("not running") { return .unavailable("The language server is not running.") }
            return .unavailable("The language server could not answer: \(message)")
        }
    }

    static func position(_ position: SymbolPosition, access: GopilotWorkspaceAccess) -> [String: Any] {
        [
            "textDocument": ["uri": lspURI(forPath: access.absolute(position.path))],
            "position": ["line": position.line, "character": position.character]
        ]
    }

    static func range(_ value: Any?) -> SourceRange? {
        guard let dict = value as? [String: Any],
              let start = dict["start"] as? [String: Any], let end = dict["end"] as? [String: Any],
              let sl = start["line"] as? Int, let sc = start["character"] as? Int,
              let el = end["line"] as? Int, let ec = end["character"] as? Int else { return nil }
        return SourceRange(startLine: sl, startCharacter: sc, endLine: el, endCharacter: ec)
    }

    static func location(from value: Any?, access: GopilotWorkspaceAccess) -> CodeLocation? {
        guard let dict = value as? [String: Any] else { return nil }
        let uri = (dict["uri"] as? String) ?? (dict["targetUri"] as? String)
        let rangeValue = dict["range"] ?? dict["targetSelectionRange"] ?? dict["targetRange"]
        guard let uri, let range = range(rangeValue), let relative = access.relative(lspPath(fromURI: uri)) else { return nil }
        return CodeLocation(path: relative, range: range)
    }

    static func locations(from result: Any?, access: GopilotWorkspaceAccess) -> (items: [CodeLocation], droppedOutsideWorkspace: Int) {
        let raw: [Any]
        if let array = result as? [Any] { raw = array } else if let single = result as? [String: Any] { raw = [single] } else { raw = [] }
        var items: [CodeLocation] = []
        var dropped = 0
        for entry in raw {
            if let location = location(from: entry, access: access) { items.append(location) } else { dropped += 1 }
        }
        return (items, dropped)
    }

    static func kindName(_ kind: Int) -> String {
        switch kind {
        case 2: "module"
        case 3: "namespace"
        case 4: "package"
        case 5: "class"
        case 6: "method"
        case 7: "property"
        case 8: "field"
        case 9: "constructor"
        case 10: "enum"
        case 11: "interface"
        case 12: "function"
        case 13: "variable"
        case 14: "constant"
        case 23: "struct"
        case 26: "type parameter"
        default: "symbol"
        }
    }

    static func symbolInfo(from item: [String: Any], access: GopilotWorkspaceAccess) -> SymbolInfo? {
        guard let name = item["name"] as? String, let uri = item["uri"] as? String,
              let range = range(item["selectionRange"] ?? item["range"]),
              let relative = access.relative(lspPath(fromURI: uri)) else { return nil }
        return SymbolInfo(name: name, kind: kindName(item["kind"] as? Int ?? 0), container: item["detail"] as? String, location: CodeLocation(path: relative, range: range))
    }

    static func page<Item: Sendable>(_ items: [Item], cursor: String?, limit: Int) -> BackendPage<Item> {
        let offset = Int(cursor ?? "") ?? 0
        let slice = Array(items.dropFirst(offset).prefix(limit))
        let next = offset + slice.count < items.count ? String(offset + slice.count) : nil
        return BackendPage(items: slice, nextCursor: next, isTruncated: next != nil)
    }
}

struct GopilotSymbolBackend: SymbolBackend {
    let access: GopilotWorkspaceAccess

    func documentSymbols(in path: ResolvedPath, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<SymbolInfo>> {
        let reply = await GopilotLSP.request("textDocument/documentSymbol", params: ["textDocument": ["uri": lspURI(forPath: access.absolute(path))]], key: "documentSymbol")
        switch reply {
        case .timeout: return .timeout
        case .unavailable(let message): return .unavailable(message)
        case .result(let value):
            guard let array = value as? [[String: Any]], !array.isEmpty else { return .empty }
            var flat: [SymbolInfo] = []
            func walk(_ nodes: [[String: Any]], container: String?) {
                for node in nodes {
                    guard let name = node["name"] as? String else { continue }
                    let rangeValue = node["selectionRange"] ?? node["range"] ?? (node["location"] as? [String: Any])?["range"]
                    guard let range = GopilotLSP.range(rangeValue) else { continue }
                    flat.append(SymbolInfo(name: name, kind: GopilotLSP.kindName(node["kind"] as? Int ?? 0), container: container ?? (node["containerName"] as? String), location: CodeLocation(path: path.relativePath, range: range)))
                    if let children = node["children"] as? [[String: Any]] { walk(children, container: name) }
                }
            }
            walk(array, container: nil)
            return flat.isEmpty ? .empty : .found(GopilotLSP.page(flat, cursor: cursor, limit: limit))
        }
    }

    func findSymbols(query: String, limit: Int) async -> BackendOutcome<BackendPage<SymbolInfo>> {
        let reply = await GopilotLSP.request("workspace/symbol", params: ["query": query], key: "workspaceSymbol", timeout: .seconds(5))
        switch reply {
        case .timeout: return .timeout
        case .unavailable(let message): return .unavailable(message)
        case .result(let value):
            guard let array = value as? [[String: Any]] else { return .empty }
            let symbols: [SymbolInfo] = array.compactMap { item in
                guard let name = item["name"] as? String, let location = GopilotLSP.location(from: item["location"], access: access) else { return nil }
                return SymbolInfo(name: name, kind: GopilotLSP.kindName(item["kind"] as? Int ?? 0), container: item["containerName"] as? String, location: location)
            }
            return symbols.isEmpty ? .empty : .found(GopilotLSP.page(symbols, cursor: nil, limit: limit))
        }
    }

    func resolveSymbol(at position: SymbolPosition, relation: SymbolRelation) async -> BackendOutcome<ResolvedLocations> {
        let method: String
        switch relation {
        case .definition: method = "textDocument/definition"
        case .type: method = "textDocument/typeDefinition"
        case .implementation: method = "textDocument/implementation"
        }
        let reply = await GopilotLSP.request(method, params: GopilotLSP.position(position, access: access), key: "resolve")
        switch reply {
        case .timeout: return .timeout
        case .unavailable(let message): return .unavailable(message)
        case .result(let value):
            let parsed = GopilotLSP.locations(from: value, access: access)
            if parsed.items.isEmpty && parsed.droppedOutsideWorkspace == 0 { return .empty }
            return .found(ResolvedLocations(locations: parsed.items, isComplete: parsed.droppedOutsideWorkspace == 0))
        }
    }

    func findReferences(at position: SymbolPosition, cursor: String?, limit: Int) async -> BackendOutcome<BackendPage<CodeLocation>> {
        var params = GopilotLSP.position(position, access: access)
        params["context"] = ["includeDeclaration": false]
        let reply = await GopilotLSP.request("textDocument/references", params: params, key: "references", timeout: .seconds(8))
        switch reply {
        case .timeout: return .timeout
        case .unavailable(let message): return .unavailable(message)
        case .result(let value):
            let parsed = GopilotLSP.locations(from: value, access: access)
            if parsed.items.isEmpty && parsed.droppedOutsideWorkspace == 0 { return .empty }
            return .found(GopilotLSP.page(parsed.items, cursor: cursor, limit: limit))
        }
    }

    func callHierarchy(at position: SymbolPosition, direction: CallDirection, limit: Int) async -> BackendOutcome<BackendPage<CallEdge>> {
        let prepare = await GopilotLSP.request("textDocument/prepareCallHierarchy", params: GopilotLSP.position(position, access: access), key: "prepareCallHierarchy")
        let item: [String: Any]
        switch prepare {
        case .timeout: return .timeout
        case .unavailable(let message): return .unavailable(message)
        case .result(let value):
            guard let first = (value as? [[String: Any]])?.first else { return .empty }
            item = first
        }
        let method = direction == .incoming ? "callHierarchy/incomingCalls" : "callHierarchy/outgoingCalls"
        let reply = await GopilotLSP.request(method, params: ["item": item], key: "callHierarchy", timeout: .seconds(8))
        switch reply {
        case .timeout: return .timeout
        case .unavailable(let message): return .unavailable(message)
        case .result(let value):
            guard let array = value as? [[String: Any]], !array.isEmpty else { return .empty }
            var edges: [CallEdge] = []
            for entry in array {
                let otherKey = direction == .incoming ? "from" : "to"
                guard let other = entry[otherKey] as? [String: Any], let symbol = GopilotLSP.symbolInfo(from: other, access: access) else { continue }
                let siteFile = direction == .incoming ? symbol.location.path : position.path.relativePath
                let sites: [CodeLocation] = ((entry["fromRanges"] as? [Any]) ?? []).compactMap { raw in
                    GopilotLSP.range(raw).map { CodeLocation(path: siteFile, range: $0) }
                }
                edges.append(CallEdge(symbol: symbol, callSites: sites, isDynamic: false))
            }
            return edges.isEmpty ? .empty : .found(GopilotLSP.page(edges, cursor: nil, limit: limit))
        }
    }
}

struct GopilotDocumentationBackend: DocumentationBackend {
    let access: GopilotWorkspaceAccess

    func documentation(for query: DocumentationQuery) async -> BackendOutcome<DocumentationInfo> {
        guard case .position(let position) = query else {
            return .unavailable("Package documentation lookup by name is not available. Ask for a symbol position in the source instead.")
        }
        let reply = await GopilotLSP.request("textDocument/hover", params: GopilotLSP.position(position, access: access), key: "hover", timeout: .seconds(4))
        switch reply {
        case .timeout: return .timeout
        case .unavailable(let message): return .unavailable(message)
        case .result(let value):
            guard let dict = value as? [String: Any], let markdown = Self.markdown(from: dict["contents"]), !markdown.isEmpty else { return .empty }
            let parts = Self.split(markdown)
            return .found(DocumentationInfo(signature: parts.signature, documentation: parts.documentation, moduleVersion: nil, provenance: "gopls hover on the current buffer"))
        }
    }

    static func markdown(from contents: Any?) -> String? {
        if let text = contents as? String { return text }
        if let dict = contents as? [String: Any] { return dict["value"] as? String }
        if let array = contents as? [Any] {
            return array.compactMap { markdown(from: $0) }.joined(separator: "\n\n")
        }
        return nil
    }

    static func split(_ markdown: String) -> (signature: String, documentation: String) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var signature: [Substring] = []
        var rest: [Substring] = []
        var inFence = false
        var fenceDone = false
        for line in lines {
            if line.hasPrefix("```") {
                if inFence { fenceDone = true }
                inFence.toggle()
                continue
            }
            if inFence && !fenceDone { signature.append(line) } else { rest.append(line) }
        }
        return (signature.joined(separator: "\n"), rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
