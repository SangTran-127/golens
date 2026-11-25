import Foundation

enum MermaidDiagramModel {
    case graph(MermaidGraphDiagram)
    case sequence(MermaidSequenceDiagram)

    var kindTitle: String {
        switch self {
        case .graph(let g): return g.kindBadge
        case .sequence: return "Sequence"
        }
    }
}

enum MermaidGraphDirection {
    case topDown
    case bottomUp
    case leftRight
    case rightLeft

    var isHorizontal: Bool {
        self == .leftRight || self == .rightLeft
    }
}

enum MermaidNodeShape {
    case rect
    case rounded
    case stadium
    case diamond
    case cylinder
    case circle
    case startEnd
}

enum MermaidEdgeStyle {
    case solid
    case dashed
    case thick
}

struct MermaidNode: Identifiable {
    let id: String
    var label: String
    var details: [String] = []
    var shape: MermaidNodeShape
    var subgraphTitle: String? = nil
}

struct MermaidEdge: Identifiable {
    let id: String
    let from: String
    let to: String
    let label: String
    let style: MermaidEdgeStyle
    let hasArrow: Bool
}

struct MermaidGraphDiagram {
    let kindBadge: String
    let direction: MermaidGraphDirection
    let nodes: [MermaidNode]
    let edges: [MermaidEdge]
}

struct MermaidParticipant: Identifiable {
    let id: String
    let label: String
    let isActor: Bool
}

enum MermaidSequenceStep: Identifiable {
    case message(id: String, from: String, to: String, text: String, isDashed: Bool)
    case note(id: String, participants: [String], text: String)

    var id: String {
        switch self {
        case .message(let id, _, _, _, _),
             .note(let id, _, _):
            return id
        }
    }
}

struct MermaidSequenceDiagram {
    let participants: [MermaidParticipant]
    let steps: [MermaidSequenceStep]
}

enum MermaidParser {
    static func parse(_ source: String) -> MermaidDiagramModel {
        let rawLines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }

        guard let header = rawLines.first else {
            return .graph(MermaidGraphDiagram(kindBadge: "Flowchart", direction: .topDown, nodes: [], edges: []))
        }

        let lowerHeader = header.lowercased()
        if lowerHeader.hasPrefix("sequencediagram") {
            return .sequence(parseSequence(Array(rawLines.dropFirst())))
        } else if lowerHeader.hasPrefix("statediagram") {
            return .graph(parseStateOrFlowGraph(Array(rawLines.dropFirst()), kindBadge: "State", defaultDirection: .topDown))
        } else if lowerHeader.hasPrefix("classdiagram") {
            return .graph(parseClassOrERGraph(Array(rawLines.dropFirst()), kindBadge: "Class", isER: false))
        } else if lowerHeader.hasPrefix("erdiagram") {
            return .graph(parseClassOrERGraph(Array(rawLines.dropFirst()), kindBadge: "ER", isER: true))
        } else if lowerHeader.hasPrefix("flowchart") || lowerHeader.hasPrefix("graph") {
            let dir = parseDirection(from: header)
            return .graph(parseStateOrFlowGraph(Array(rawLines.dropFirst()), kindBadge: "Flowchart", defaultDirection: dir))
        } else {
            return .graph(parseStateOrFlowGraph(rawLines, kindBadge: "Diagram", defaultDirection: .topDown))
        }
    }

    private static func parseDirection(from header: String) -> MermaidGraphDirection {
        let tokens = header.uppercased().split(separator: " ")
        guard tokens.count >= 2 else { return .topDown }
        switch tokens[1] {
        case "LR": return .leftRight
        case "RL": return .rightLeft
        case "BT": return .bottomUp
        default: return .topDown
        }
    }

    private static func parseSequence(_ lines: [String]) -> MermaidSequenceDiagram {
        var participants: [MermaidParticipant] = []
        var participantMap: [String: Int] = [:]
        var steps: [MermaidSequenceStep] = []
        var stepCounter = 0

        func ensureParticipant(id: String, label: String? = nil, isActor: Bool = false) {
            let cleanID = id.trimmingCharacters(in: .whitespaces)
            guard !cleanID.isEmpty else { return }
            if let existingIdx = participantMap[cleanID] {
                if let newLabel = label, !newLabel.isEmpty {
                    participants[existingIdx] = MermaidParticipant(
                        id: cleanID,
                        label: newLabel,
                        isActor: participants[existingIdx].isActor || isActor
                    )
                }
            } else {
                participantMap[cleanID] = participants.count
                participants.append(
                    MermaidParticipant(
                        id: cleanID,
                        label: cleanQuotes(label ?? cleanID),
                        isActor: isActor
                    )
                )
            }
        }

        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("participant ") || lower.hasPrefix("actor ") {
                let isActor = lower.hasPrefix("actor ")
                let rest = String(line.dropFirst(isActor ? 6 : 12)).trimmingCharacters(in: .whitespaces)
                if let asRange = rest.range(of: " as ", options: .caseInsensitive) {
                    let id = String(rest[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let label = String(rest[asRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    ensureParticipant(id: id, label: cleanQuotes(label), isActor: isActor)
                } else {
                    ensureParticipant(id: rest, label: cleanQuotes(rest), isActor: isActor)
                }
                continue
            }

            if lower.hasPrefix("note ") {
                if let colonIdx = line.firstIndex(of: ":") {
                    let headerPart = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let noteText = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    var targetIDs: [String] = []
                    for prefix in ["note over ", "note right of ", "note left of "] {
                        if headerPart.lowercased().hasPrefix(prefix) {
                            let rawTargets = String(headerPart.dropFirst(prefix.count))
                            targetIDs = rawTargets.split(separator: ",").map {
                                $0.trimmingCharacters(in: .whitespaces)
                            }
                            break
                        }
                    }
                    for tid in targetIDs {
                        ensureParticipant(id: tid)
                    }
                    stepCounter += 1
                    steps.append(.note(id: "seq-note-\(stepCounter)", participants: targetIDs, text: noteText))
                }
                continue
            }

            if let msg = parseSequenceMessage(line) {
                ensureParticipant(id: msg.from)
                ensureParticipant(id: msg.to)
                stepCounter += 1
                steps.append(
                    .message(
                        id: "seq-msg-\(stepCounter)",
                        from: msg.from,
                        to: msg.to,
                        text: msg.text,
                        isDashed: msg.isDashed
                    )
                )
            }
        }

        return MermaidSequenceDiagram(participants: participants, steps: steps)
    }

    private static func parseSequenceMessage(_ line: String) -> (from: String, to: String, text: String, isDashed: Bool)? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let leftPart = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let msgText = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

        let arrows = ["-->>", "->>", "-->", "->", "--x", "-x", "--)", "-)"]
        for arrow in arrows {
            if let range = leftPart.range(of: arrow) {
                let rawFrom = String(leftPart[..<range.lowerBound])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " +-"))
                let rawTo = String(leftPart[range.upperBound...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " +-"))
                guard !rawFrom.isEmpty && !rawTo.isEmpty else { continue }
                return (rawFrom, rawTo, msgText, arrow.hasPrefix("--"))
            }
        }
        return nil
    }

    private static func parseStateOrFlowGraph(
        _ lines: [String],
        kindBadge: String,
        defaultDirection: MermaidGraphDirection
    ) -> MermaidGraphDiagram {
        var direction = defaultDirection
        var nodes: [MermaidNode] = []
        var nodeIndexMap: [String: Int] = [:]
        var edges: [MermaidEdge] = []
        var edgeCounter = 0
        var activeSubgraph: String? = nil

        func upsertNode(_ parsed: MermaidNode) {
            if let idx = nodeIndexMap[parsed.id] {
                if parsed.label != parsed.id || nodes[idx].label == nodes[idx].id {
                    nodes[idx].label = parsed.label
                }
                if parsed.shape != .rect {
                    nodes[idx].shape = parsed.shape
                }
                if nodes[idx].subgraphTitle == nil {
                    nodes[idx].subgraphTitle = activeSubgraph
                }
                for detail in parsed.details where !nodes[idx].details.contains(detail) {
                    nodes[idx].details.append(detail)
                }
            } else {
                var newNode = parsed
                if newNode.subgraphTitle == nil {
                    newNode.subgraphTitle = activeSubgraph
                }
                nodeIndexMap[newNode.id] = nodes.count
                nodes.append(newNode)
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()

            if lower.hasPrefix("direction ") {
                direction = parseDirection(from: line)
                continue
            }
            if lower.hasPrefix("classdef ") || lower.hasPrefix("class ") || lower.hasPrefix("style ") || lower.hasPrefix("linkstyle ") || lower.hasPrefix("click ") {
                continue
            }
            if lower.hasPrefix("subgraph ") {
                let rest = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                if let openB = rest.firstIndex(of: "["), let closeB = rest.lastIndex(of: "]"), openB < closeB {
                    activeSubgraph = cleanQuotes(String(rest[rest.index(after: openB)..<closeB]))
                } else {
                    activeSubgraph = cleanQuotes(rest)
                }
                continue
            }
            if lower == "end" || lower == "}" {
                activeSubgraph = nil
                continue
            }

            if lower.hasPrefix("state ") {
                let rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if let asRange = rest.range(of: " as ", options: .caseInsensitive) {
                    let rawLabel = cleanQuotes(String(rest[..<asRange.lowerBound]))
                    let rawID = String(rest[asRange.upperBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: " {"))
                    upsertNode(MermaidNode(id: rawID, label: rawLabel, shape: .rounded))
                    continue
                }
            }

            if let parsedChain = parseFlowOrStateEdgeLine(line) {
                for (lhsRaw, rhsRaw, edgeLabel, edgeStyle, hasArrow) in parsedChain {
                    let lhsNode = parseNodeToken(lhsRaw)
                    let rhsNode = parseNodeToken(rhsRaw)
                    upsertNode(lhsNode)
                    upsertNode(rhsNode)
                    edgeCounter += 1
                    edges.append(
                        MermaidEdge(
                            id: "edge-\(edgeCounter)",
                            from: lhsNode.id,
                            to: rhsNode.id,
                            label: edgeLabel,
                            style: edgeStyle,
                            hasArrow: hasArrow
                        )
                    )
                }
                continue
            }

            if let colonIdx = line.firstIndex(of: ":"), !line.contains("-->") {
                let lhs = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let rhs = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !lhs.isEmpty && !rhs.isEmpty && !lhs.contains(" ") {
                    upsertNode(MermaidNode(id: lhs, label: lhs, details: [rhs], shape: .rounded))
                    continue
                }
            }

            let standalone = parseNodeToken(line)
            if !standalone.id.isEmpty && !standalone.id.contains(" ") {
                upsertNode(standalone)
            }
        }

        return MermaidGraphDiagram(kindBadge: kindBadge, direction: direction, nodes: nodes, edges: edges)
    }

    private static func parseFlowOrStateEdgeLine(
        _ line: String
    ) -> [(from: String, to: String, label: String, style: MermaidEdgeStyle, hasArrow: Bool)]? {
        var workingLine = line
        var trailingStateLabel = ""

        if workingLine.contains("-->"),
           let colonIdx = workingLine.firstIndex(of: ":"),
           let arrowRange = workingLine.range(of: "-->"),
           colonIdx > arrowRange.upperBound {
            trailingStateLabel = String(workingLine[workingLine.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            workingLine = String(workingLine[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        }

        workingLine = normalizeInlineLabeledArrows(workingLine)

        let operators: [(token: String, style: MermaidEdgeStyle, hasArrow: Bool)] = [
            ("-.->", .dashed, true),
            ("==>", .thick, true),
            ("-->", .solid, true),
            ("---", .solid, false)
        ]

        guard operators.contains(where: { workingLine.contains($0.token) }) else {
            return nil
        }

        var results: [(from: String, to: String, label: String, style: MermaidEdgeStyle, hasArrow: Bool)] = []
        var remainder = workingLine

        while let nextOp = findEarliestOperator(in: remainder, operators: operators) {
            let lhs = String(remainder[..<nextOp.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            var afterOp = String(remainder[nextOp.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            var edgeLabel = trailingStateLabel

            if afterOp.hasPrefix("|"),
               let closingPipe = afterOp.dropFirst().firstIndex(of: "|") {
                edgeLabel = cleanQuotes(String(afterOp[afterOp.index(after: afterOp.startIndex)..<closingPipe]))
                afterOp = String(afterOp[afterOp.index(after: closingPipe)...]).trimmingCharacters(in: .whitespaces)
            }

            if let subsequentOp = findEarliestOperator(in: afterOp, operators: operators) {
                let midNode = String(afterOp[..<subsequentOp.range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !lhs.isEmpty && !midNode.isEmpty {
                    results.append((lhs, midNode, edgeLabel, nextOp.style, nextOp.hasArrow))
                }
                remainder = afterOp
            } else {
                if !lhs.isEmpty && !afterOp.isEmpty {
                    results.append((lhs, afterOp, edgeLabel, nextOp.style, nextOp.hasArrow))
                }
                break
            }
        }

        return results.isEmpty ? nil : results
    }

    private static func normalizeInlineLabeledArrows(_ input: String) -> String {
        var s = input
        let patterns: [(String, String)] = [
            (#"--\s+([^->|][^->]*?)\s+-->"#, "-->|$1|"),
            (#"-\.\s+([^.>|][^.>]*?)\s+\.->"#, "-.->|$1|"),
            (#"==\s+([^=>|][^=>]*?)\s+==>"#, "==>|$1|")
        ]
        for (pattern, template) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: template)
            }
        }
        return s
    }

    private static func findEarliestOperator(
        in text: String,
        operators: [(token: String, style: MermaidEdgeStyle, hasArrow: Bool)]
    ) -> (range: Range<String.Index>, style: MermaidEdgeStyle, hasArrow: Bool)? {
        var best: (range: Range<String.Index>, style: MermaidEdgeStyle, hasArrow: Bool)? = nil
        var bracketDepth = 0
        var quoteChar: Character? = nil

        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            if let q = quoteChar {
                if ch == q { quoteChar = nil }
                idx = text.index(after: idx)
                continue
            }
            if ch == "\"" || ch == "'" {
                quoteChar = ch
                idx = text.index(after: idx)
                continue
            }
            if ch == "[" || ch == "(" || ch == "{" {
                bracketDepth += 1
            } else if ch == "]" || ch == ")" || ch == "}" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if bracketDepth == 0 {
                let tail = text[idx...]
                for op in operators where tail.hasPrefix(op.token) {
                    let endIdx = text.index(idx, offsetBy: op.token.count)
                    best = (idx..<endIdx, op.style, op.hasArrow)
                    return best
                }
            }
            idx = text.index(after: idx)
        }
        return best
    }

    private static func parseNodeToken(_ rawToken: String) -> MermaidNode {
        var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasSuffix(";") {
            token.removeLast()
        }
        if let styleSep = token.range(of: ":::") {
            token = String(token[..<styleSep.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        if token == "[*]" {
            return MermaidNode(id: "__start_end__", label: "●", shape: .startEnd)
        }

        let delimiters: [(open: String, close: String, shape: MermaidNodeShape)] = [
            ("([", "])", .stadium),
            ("[(", ")]", .cylinder),
            ("(((", ")))", .circle),
            ("((", "))", .circle),
            ("{{", "}}", .diamond),
            ("[[", "]]", .rect),
            ("[", "]", .rect),
            ("(", ")", .rounded),
            ("{", "}", .diamond)
        ]

        for delim in delimiters {
            if let openRange = token.range(of: delim.open),
               token.hasSuffix(delim.close) {
                let rawID = String(token[..<openRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let labelStart = openRange.upperBound
                let labelEnd = token.index(token.endIndex, offsetBy: -delim.close.count)
                if !rawID.isEmpty && labelStart <= labelEnd {
                    let rawLabel = cleanQuotes(String(token[labelStart..<labelEnd]))
                    return MermaidNode(id: rawID, label: rawLabel.isEmpty ? rawID : rawLabel, shape: delim.shape)
                }
            }
        }

        let clean = cleanQuotes(token)
        return MermaidNode(id: clean, label: clean, shape: .rounded)
    }

    private static func parseClassOrERGraph(
        _ lines: [String],
        kindBadge: String,
        isER: Bool
    ) -> MermaidGraphDiagram {
        var nodes: [MermaidNode] = []
        var nodeMap: [String: Int] = [:]
        var edges: [MermaidEdge] = []
        var edgeCounter = 0
        var activeBlockEntity: String? = nil

        func ensureEntity(_ rawID: String, detail: String? = nil) -> String {
            let id = cleanQuotes(rawID.trimmingCharacters(in: CharacterSet(charactersIn: " {};")))
            guard !id.isEmpty else { return "" }
            if let idx = nodeMap[id] {
                if let d = detail, !d.isEmpty, !nodes[idx].details.contains(d) {
                    nodes[idx].details.append(d)
                }
            } else {
                nodeMap[id] = nodes.count
                nodes.append(
                    MermaidNode(
                        id: id,
                        label: id,
                        details: detail.map { [$0] } ?? [],
                        shape: .rect
                    )
                )
            }
            return id
        }

        let relTokens = [
            "<|--", "--|>", "*--", "--*", "o--", "--o", "<..", "..>",
            "..|>", "<|..", "-->", "<--", "..", "--",
            "||--o{", "}o--||", "||--|{", "}|--||", "||--||", "}o--o{"
        ]

        for line in lines {
            if line == "}" {
                activeBlockEntity = nil
                continue
            }

            if let currentEntity = activeBlockEntity {
                let member = line.trimmingCharacters(in: .whitespaces)
                if !member.isEmpty && !member.hasPrefix("{") {
                    _ = ensureEntity(currentEntity, detail: member)
                }
                continue
            }

            if line.hasSuffix("{") {
                var header = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                if header.lowercased().hasPrefix("class ") {
                    header = String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
                activeBlockEntity = ensureEntity(header)
                continue
            }

            var matchedRelation = false
            for rel in relTokens {
                if let relRange = line.range(of: rel) {
                    let leftRaw = String(line[..<relRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    var rightPart = String(line[relRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    var relLabel = ""
                    if let colonIdx = rightPart.firstIndex(of: ":") {
                        relLabel = cleanQuotes(String(rightPart[rightPart.index(after: colonIdx)...]))
                        rightPart = String(rightPart[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    }
                    let fromID = ensureEntity(leftRaw)
                    let toID = ensureEntity(rightPart)
                    if !fromID.isEmpty && !toID.isEmpty {
                        edgeCounter += 1
                        edges.append(
                            MermaidEdge(
                                id: "rel-\(edgeCounter)",
                                from: fromID,
                                to: toID,
                                label: relLabel,
                                style: rel.contains("..") ? .dashed : .solid,
                                hasArrow: true
                            )
                        )
                        matchedRelation = true
                        break
                    }
                }
            }
            if matchedRelation { continue }

            if !isER, let colonIdx = line.firstIndex(of: ":") {
                let clsName = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let member = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                if !clsName.isEmpty && !clsName.contains(" ") && !member.isEmpty {
                    _ = ensureEntity(clsName, detail: member)
                    continue
                }
            }

            if line.lowercased().hasPrefix("class ") {
                let rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                _ = ensureEntity(rest)
            }
        }

        return MermaidGraphDiagram(kindBadge: kindBadge, direction: .topDown, nodes: nodes, edges: edges)
    }

    private static func cleanQuotes(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            if s.count >= 2 {
                s = String(s.dropFirst().dropLast())
            }
        }
        return s.replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
    }
}
