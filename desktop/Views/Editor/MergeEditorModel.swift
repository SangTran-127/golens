import Foundation

enum MergeEditorChoice: Equatable {
    case left, right, leftThenRight, rightThenLeft, edited

    var resolution: MergeConflictResolution? {
        switch self {
        case .left: .left
        case .right: .right
        case .leftThenRight: .leftThenRight
        case .rightThenLeft: .rightThenLeft
        case .edited: nil
        }
    }

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .leftThenRight: "Left Then Right"
        case .rightThenLeft: "Right Then Left"
        case .edited: "Edited"
        }
    }
}

struct MergeEditorConflict: Identifiable, Equatable {
    let id: Int
    let region: MergeConflictRegion
    let current: String
    let base: String?
    let incoming: String
    var choice: MergeEditorChoice?
    var result: String?

    var isResolved: Bool { result != nil }
}

enum MergeEditorSegment: Identifiable, Equatable {
    case common(index: Int, text: String)
    case conflict(Int)

    var id: String {
        switch self {
        case .common(let index, _): "common-\(index)"
        case .conflict(let index): "conflict-\(index)"
        }
    }
}

struct MergeEditorDocument: Equatable {
    let original: String
    let segments: [MergeEditorSegment]
    var conflicts: [MergeEditorConflict]

    init(text: String) {
        original = text
        let ns = text as NSString
        let regions = MergeConflictScanner.scan(ns)
        var segments: [MergeEditorSegment] = []
        var conflicts: [MergeEditorConflict] = []
        var cursor = 0
        for (index, region) in regions.enumerated() {
            if region.range.location > cursor {
                segments.append(.common(index: segments.count, text: ns.substring(with: NSRange(location: cursor, length: region.range.location - cursor))))
            }
            conflicts.append(MergeEditorConflict(
                id: index,
                region: region,
                current: ns.substring(with: region.currentRange),
                base: region.baseRange.map { ns.substring(with: $0) },
                incoming: ns.substring(with: region.incomingRange)
            ))
            segments.append(.conflict(index))
            cursor = NSMaxRange(region.range)
        }
        if cursor < ns.length {
            segments.append(.common(index: segments.count, text: ns.substring(from: cursor)))
        }
        self.segments = segments
        self.conflicts = conflicts
    }

    var resolvedCount: Int { conflicts.filter(\.isResolved).count }
    var isFullyResolved: Bool { !conflicts.isEmpty && resolvedCount == conflicts.count }
    var hasChoices: Bool { resolvedCount > 0 }

    mutating func choose(_ choice: MergeEditorChoice, for index: Int) {
        guard conflicts.indices.contains(index), let resolution = choice.resolution else { return }
        conflicts[index].choice = choice
        conflicts[index].result = MergeConflictScanner.replacement(for: conflicts[index].region, resolution: resolution, in: original as NSString)
    }

    mutating func chooseAll(_ choice: MergeEditorChoice) {
        for index in conflicts.indices { choose(choice, for: index) }
    }

    mutating func edit(_ text: String, for index: Int) {
        guard conflicts.indices.contains(index) else { return }
        let region = conflicts[index].region
        var stored = text
        if region.endsWithLineBreak, !stored.isEmpty, stored.last?.isNewline != true { stored += "\n" }
        conflicts[index].choice = .edited
        conflicts[index].result = stored
    }

    mutating func reset(_ index: Int) {
        guard conflicts.indices.contains(index) else { return }
        conflicts[index].choice = nil
        conflicts[index].result = nil
    }

    func displayText(for index: Int) -> String {
        guard let result = conflicts[index].result else { return "" }
        return result.hasSuffix("\n") ? String(result.dropLast()) : result
    }

    var replacements: [(range: NSRange, text: String)] {
        conflicts.compactMap { conflict in conflict.result.map { (conflict.region.range, $0) } }
    }

    var mergedText: String {
        var output = ""
        let ns = original as NSString
        for segment in segments {
            switch segment {
            case .common(_, let text):
                output += text
            case .conflict(let index):
                let conflict = conflicts[index]
                output += conflict.result ?? ns.substring(with: conflict.region.range)
            }
        }
        return output
    }
}
