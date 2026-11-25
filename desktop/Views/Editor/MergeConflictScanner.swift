import Foundation

struct MergeConflictRegion: Equatable {
    let startLine: Int
    let baseLine: Int?
    let separatorLine: Int
    let endLine: Int
    let range: NSRange
    let currentRange: NSRange
    let baseRange: NSRange?
    let incomingRange: NSRange
    let currentLabel: String
    let incomingLabel: String
    let endsWithLineBreak: Bool

    func role(forLine line: Int) -> MergeConflictLineRole? {
        guard line >= startLine, line <= endLine else { return nil }
        if line == startLine { return .currentMarker }
        if line == endLine { return .incomingMarker }
        if line == separatorLine { return .separator }
        if let baseLine {
            if line == baseLine { return .baseMarker }
            if line > baseLine { return line < separatorLine ? .base : .incoming }
            return .current
        }
        return line < separatorLine ? .current : .incoming
    }
}

enum MergeConflictLineRole {
    case currentMarker, current, baseMarker, base, separator, incoming, incomingMarker
}

enum MergeConflictResolution {
    case left, right, leftThenRight, rightThenLeft

    var actionName: String {
        switch self {
        case .left: return "Choose Left"
        case .right: return "Choose Right"
        case .leftThenRight: return "Choose Left Then Right"
        case .rightThenLeft: return "Choose Right Then Left"
        }
    }

    var lensTitle: String {
        switch self {
        case .left: return "Choose Left"
        case .right: return "Choose Right"
        case .leftThenRight: return "Left Then Right"
        case .rightThenLeft: return "Right Then Left"
        }
    }

    func tooltip(currentLabel: String, incomingLabel: String, isRebase: Bool = false) -> String {
        let current = currentLabel.isEmpty ? "HEAD" : currentLabel
        let incoming = incomingLabel.isEmpty ? "" : " (\(incomingLabel))"
        if isRebase {
            switch self {
            case .left: return "Keep the upstream version (\(current))"
            case .right: return "Keep your commit\(incoming)"
            case .leftThenRight: return "Keep both versions, the upstream one first and your commit after it"
            case .rightThenLeft: return "Keep both versions, your commit first and the upstream one after it"
            }
        }
        switch self {
        case .left: return "Keep your version (\(current))"
        case .right: return "Keep the incoming version\(incoming)"
        case .leftThenRight: return "Keep both versions, yours first and the incoming one after it"
        case .rightThenLeft: return "Keep both versions, the incoming one first and yours after it"
        }
    }
}

enum MergeConflictScanner {
    private enum Marker { case start, base, separator, end }

    static func scan(_ text: NSString) -> [MergeConflictRegion] {
        let length = text.length
        guard length >= 7 else { return [] }
        let chunkSize = 8192
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var bufferStart = -chunkSize
        func char(_ index: Int) -> unichar {
            if index < bufferStart || index >= bufferStart + chunkSize {
                bufferStart = index
                let count = min(chunkSize, length - index)
                buffer.withUnsafeMutableBufferPointer { ptr in
                    text.getCharacters(ptr.baseAddress!, range: NSRange(location: index, length: count))
                }
            }
            return buffer[index - bufferStart]
        }

        var regions: [MergeConflictRegion] = []
        var start: (line: Int, location: Int, contentStart: Int, label: String)?
        var base: (line: Int, location: Int, contentStart: Int)?
        var separator: (line: Int, location: Int, contentStart: Int)?

        var lineNumber = 1
        var lineStart = 0
        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length {
                let c = char(lineEnd)
                if c == 0x0A || c == 0x0D { break }
                lineEnd += 1
            }
            var next = lineEnd
            if next < length {
                if char(next) == 0x0D, next + 1 < length, char(next + 1) == 0x0A { next += 2 } else { next += 1 }
            }

            if lineEnd - lineStart >= 7, let marker = marker(at: lineStart, lineEnd: lineEnd, char: char) {
                switch marker {
                case .start:
                    let label = lineEnd - lineStart > 8 ? text.substring(with: NSRange(location: lineStart + 8, length: lineEnd - lineStart - 8)) : ""
                    start = (lineNumber, lineStart, next, label)
                    base = nil
                    separator = nil
                case .base:
                    if start != nil, separator == nil, base == nil {
                        base = (lineNumber, lineStart, next)
                    }
                case .separator:
                    if start != nil, separator == nil {
                        separator = (lineNumber, lineStart, next)
                    }
                case .end:
                    if let s = start, let sep = separator {
                        let label = lineEnd - lineStart > 8 ? text.substring(with: NSRange(location: lineStart + 8, length: lineEnd - lineStart - 8)) : ""
                        let currentEnd = base?.location ?? sep.location
                        regions.append(MergeConflictRegion(
                            startLine: s.line,
                            baseLine: base?.line,
                            separatorLine: sep.line,
                            endLine: lineNumber,
                            range: NSRange(location: s.location, length: next - s.location),
                            currentRange: NSRange(location: s.contentStart, length: currentEnd - s.contentStart),
                            baseRange: base.map { NSRange(location: $0.contentStart, length: sep.location - $0.contentStart) },
                            incomingRange: NSRange(location: sep.contentStart, length: lineStart - sep.contentStart),
                            currentLabel: s.label.trimmingCharacters(in: .whitespaces),
                            incomingLabel: label.trimmingCharacters(in: .whitespaces),
                            endsWithLineBreak: next > lineEnd
                        ))
                    }
                    start = nil
                    base = nil
                    separator = nil
                }
            }

            lineNumber += 1
            lineStart = next
        }
        return regions
    }

    private static func marker(at lineStart: Int, lineEnd: Int, char: (Int) -> unichar) -> Marker? {
        let first = char(lineStart)
        let marker: Marker
        switch first {
        case 0x3C: marker = .start
        case 0x7C: marker = .base
        case 0x3D: marker = .separator
        case 0x3E: marker = .end
        default: return nil
        }
        for i in 1..<7 where char(lineStart + i) != first { return nil }
        let rest = lineEnd - lineStart - 7
        if marker == .separator { return rest == 0 ? marker : nil }
        if rest == 0 { return marker }
        return char(lineStart + 7) == 0x20 ? marker : nil
    }

    static func regionIndex(containingLine line: Int, in regions: [MergeConflictRegion]) -> Int? {
        var low = 0
        var high = regions.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let region = regions[mid]
            if line < region.startLine {
                high = mid - 1
            } else if line > region.endLine {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    static func role(forLine line: Int, in regions: [MergeConflictRegion]) -> MergeConflictLineRole? {
        guard let index = regionIndex(containingLine: line, in: regions) else { return nil }
        return regions[index].role(forLine: line)
    }

    static func replacement(for region: MergeConflictRegion, resolution: MergeConflictResolution, in text: NSString) -> String {
        let current = text.substring(with: region.currentRange)
        let incoming = text.substring(with: region.incomingRange)
        var result: String
        switch resolution {
        case .left: result = current
        case .right: result = incoming
        case .leftThenRight: result = current + incoming
        case .rightThenLeft: result = incoming + current
        }
        if !region.endsWithLineBreak, let last = result.last, last.isNewline {
            result.removeLast()
        }
        return result
    }

    static func neighborIndex(fromLine line: Int, forward: Bool, in regions: [MergeConflictRegion]) -> Int? {
        guard !regions.isEmpty else { return nil }
        if forward {
            return regions.firstIndex(where: { $0.startLine > line }) ?? 0
        }
        return regions.lastIndex(where: { $0.endLine < line }) ?? regions.count - 1
    }
}
