import Foundation

public struct TextPosition: Equatable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct UTF16LineTable: Equatable, Sendable {
    public let utf16Length: Int
    public let utf8ByteLength: Int
    public let lineEnding: String
    private let lineStartsUTF16: [Int]
    private let nonASCIIUTF16Positions: [Int]
    private let nonASCIIExtraBytePrefix: [Int]

    public var lineCount: Int {
        lineStartsUTF16.count
    }

    public static func extraUTF8Bytes(forUTF16CodeUnit unit: UInt16) -> Int {
        if unit < 0x80 { return 0 }
        if unit < 0x800 || (unit >= 0xD800 && unit <= 0xDFFF) { return 1 }
        return 2
    }

    public init(_ text: String) {
        let units = Array(text.utf16)
        self.utf16Length = units.count

        var detectedEnding = "LF"
        if let lfIdx = units.firstIndex(of: 0x0A), lfIdx > 0, units[lfIdx - 1] == 0x0D {
            detectedEnding = "CRLF"
        }
        self.lineEnding = detectedEnding

        var starts: [Int] = [0]
        var positions: [Int] = []
        var prefix: [Int] = [0]
        var runningExtra = 0

        for (index, unit) in units.enumerated() {
            if unit == 0x0A {
                starts.append(index + 1)
            }
            let extra = Self.extraUTF8Bytes(forUTF16CodeUnit: unit)
            if extra > 0 {
                positions.append(index)
                runningExtra += extra
                prefix.append(runningExtra)
            }
        }

        self.lineStartsUTF16 = starts
        self.nonASCIIUTF16Positions = positions
        self.nonASCIIExtraBytePrefix = prefix
        self.utf8ByteLength = units.count + runningExtra
    }

    public func lineStartUTF16Offset(forLine line: Int) -> Int? {
        guard line >= 1, line <= lineStartsUTF16.count else { return nil }
        return lineStartsUTF16[line - 1]
    }

    public func lineContentEndUTF16Offset(forLine line: Int) -> Int? {
        guard line >= 1, line <= lineStartsUTF16.count else { return nil }
        if line < lineStartsUTF16.count {
            return lineStartsUTF16[line] - 1
        }
        return utf16Length
    }

    public func utf16Offset(line: Int, column: Int) -> Int? {
        guard let start = lineStartUTF16Offset(forLine: line),
              let end = lineContentEndUTF16Offset(forLine: line) else {
            return nil
        }
        let clampedColumn = max(1, column)
        return min(start + (clampedColumn - 1), end)
    }

    public func position(atUTF16Offset offset: Int) -> TextPosition {
        let clamped = min(max(0, offset), utf16Length)
        let lineIdx = Self.upperBound(lineStartsUTF16, clamped) - 1
        let start = lineStartsUTF16[max(0, lineIdx)]
        return TextPosition(line: max(0, lineIdx) + 1, column: (clamped - start) + 1)
    }

    public func utf8Offset(forUTF16Offset utf16Offset: Int) -> Int {
        let clamped = min(max(0, utf16Offset), utf16Length)
        let idx = Self.lowerBound(nonASCIIUTF16Positions, clamped)
        return clamped + nonASCIIExtraBytePrefix[idx]
    }

    public func utf16Offset(forUTF8Offset utf8Offset: Int) -> Int {
        let clamped = min(max(0, utf8Offset), utf8ByteLength)
        var lo = 0
        var hi = nonASCIIUTF16Positions.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if nonASCIIUTF16Positions[mid] + nonASCIIExtraBytePrefix[mid] < clamped {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return min(max(0, clamped - nonASCIIExtraBytePrefix[lo]), utf16Length)
    }

    public func utf8Offset(line: Int, column: Int) -> Int? {
        guard let u16 = utf16Offset(line: line, column: column) else { return nil }
        return utf8Offset(forUTF16Offset: u16)
    }

    public func position(atUTF8Offset utf8Offset: Int) -> TextPosition {
        position(atUTF16Offset: utf16Offset(forUTF8Offset: utf8Offset))
    }

    private static func lowerBound(_ array: [Int], _ value: Int) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if array[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func upperBound(_ array: [Int], _ value: Int) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if array[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

public enum MessageFormatting {
    public static func previewFailed(_ subject: String) -> String {
        "Couldn’t generate the \(subject) preview. Check that the file builds, then try again."
    }

    public static func readFailed(_ subject: String) -> String {
        "Couldn’t read the \(subject) in this file. Check that it builds, then try again."
    }

    public static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    public static func humanized(_ identifier: String) -> String {
        guard identifier.contains("_"), !identifier.contains(" ") else { return identifier }
        let words = identifier.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
