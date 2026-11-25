import Foundation

public struct LSPPosition: Sendable, Equatable {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

public struct LineColumn: Sendable, Equatable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct RangeConverter: Sendable {
    private let scalarUTF8: [Int]
    private let scalarUTF16: [Int]
    private let lineStarts: [Int]
    private let lineEnds: [Int]

    public var utf16Length: Int { scalarUTF16.last ?? 0 }
    public var utf8Length: Int { scalarUTF8.last ?? 0 }
    public var lineCount: Int { lineStarts.count }

    public init(_ text: String) {
        var utf8: [Int] = []
        var utf16: [Int] = []
        var starts: [Int] = [0]
        var ends: [Int] = []
        var byte = 0
        var unit = 0
        var previousWasCR = false

        for scalar in text.unicodeScalars {
            utf8.append(byte)
            utf16.append(unit)
            let width8 = String(scalar).utf8.count
            let width16 = scalar.value > 0xFFFF ? 2 : 1
            if scalar == "\n" {
                if previousWasCR {
                    starts[starts.count - 1] = unit + 1
                } else {
                    ends.append(unit)
                    starts.append(unit + 1)
                }
                previousWasCR = false
            } else if scalar == "\r" {
                ends.append(unit)
                starts.append(unit + 1)
                previousWasCR = true
            } else {
                previousWasCR = false
            }
            byte += width8
            unit += width16
        }
        utf8.append(byte)
        utf16.append(unit)
        ends.append(unit)

        scalarUTF8 = utf8
        scalarUTF16 = utf16
        lineStarts = starts
        lineEnds = ends
    }

    public func utf16Offset(utf8Offset: Int) -> Int? {
        guard let index = Self.search(scalarUTF8, utf8Offset) else { return nil }
        return scalarUTF16[index]
    }

    public func utf8Offset(utf16Offset: Int) -> Int? {
        guard let index = Self.search(scalarUTF16, utf16Offset) else { return nil }
        return scalarUTF8[index]
    }

    public func lspPosition(utf16Offset: Int) -> LSPPosition? {
        guard Self.search(scalarUTF16, utf16Offset) != nil else { return nil }
        let line = lineIndex(containing: utf16Offset)
        guard utf16Offset <= lineEnds[line] else { return nil }
        return LSPPosition(line: line, character: utf16Offset - lineStarts[line])
    }

    public func utf16Offset(position: LSPPosition) -> Int? {
        guard position.line >= 0, position.line < lineStarts.count, position.character >= 0 else { return nil }
        let start = lineStarts[position.line]
        guard position.character <= lineEnds[position.line] - start else { return nil }
        let offset = start + position.character
        guard Self.search(scalarUTF16, offset) != nil else { return nil }
        return offset
    }

    public func lineColumn(utf16Offset: Int) -> LineColumn? {
        guard let position = lspPosition(utf16Offset: utf16Offset) else { return nil }
        return LineColumn(line: position.line + 1, column: position.character + 1)
    }

    public func utf16Offset(lineColumn: LineColumn) -> Int? {
        utf16Offset(position: LSPPosition(line: lineColumn.line - 1, character: lineColumn.column - 1))
    }

    public func lineColumn(utf8Offset: Int) -> LineColumn? {
        utf16Offset(utf8Offset: utf8Offset).flatMap { lineColumn(utf16Offset: $0) }
    }

    public func utf8Offset(lineColumn: LineColumn) -> Int? {
        utf16Offset(lineColumn: lineColumn).flatMap { utf8Offset(utf16Offset: $0) }
    }

    private func lineIndex(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private static func search(_ sorted: [Int], _ value: Int) -> Int? {
        guard value >= 0, let last = sorted.last, value <= last else { return nil }
        var low = 0
        var high = sorted.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if sorted[mid] == value { return mid }
            if sorted[mid] < value { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }
}
