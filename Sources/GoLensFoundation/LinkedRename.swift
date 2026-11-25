import Foundation

public enum GoIdentifier {
    public static let keywords: Set<String> = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]

    public static func isPart(_ u: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(u) else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    public static func isValid(_ s: String) -> Bool {
        problem(with: s) == nil
    }

    public static func problem(with s: String) -> String? {
        guard let first = s.unicodeScalars.first else { return "Type a name for the symbol." }
        guard s.utf16.allSatisfy(isPart) else { return "Go names use only letters, digits and _." }
        if CharacterSet.decimalDigits.contains(first) { return "A Go name can’t start with a digit." }
        if keywords.contains(s) { return "‘\(s)’ is a Go keyword, so it can’t be a name." }
        if s == "_" { return "_ is the blank identifier, so nothing could refer to the symbol." }
        return nil
    }
}

public struct LinkedEdit: Equatable, Sendable {
    public var range: NSRange
    public var text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

public struct LinkedRename: Equatable, Sendable {
    public let original: String
    public private(set) var name: String
    public private(set) var ranges: [NSRange]
    public let primaryIndex: Int

    public init?(original: String, ranges candidates: [NSRange], primaryLocation: Int) {
        let length = (original as NSString).length
        guard length > 0 else { return nil }
        var kept: [NSRange] = []
        for range in Set(candidates.filter { $0.length == length && $0.location >= 0 }).sorted(by: { $0.location < $1.location })
        where kept.last.map({ NSMaxRange($0) <= range.location }) ?? true {
            kept.append(range)
        }
        guard let primary = kept.firstIndex(where: { $0.location <= primaryLocation && primaryLocation <= NSMaxRange($0) }) else { return nil }
        self.original = original
        self.name = original
        self.ranges = kept
        self.primaryIndex = primary
    }

    public var primaryRange: NSRange { ranges[primaryIndex] }
    public var changed: Bool { name != original }

    public func contains(_ selection: NSRange) -> Bool {
        let primary = primaryRange
        return selection.location >= primary.location && NSMaxRange(selection) <= NSMaxRange(primary)
    }

    public func accepts(_ edit: NSRange, replacement: String) -> Bool {
        contains(edit) && replacement.utf16.allSatisfy(GoIdentifier.isPart)
    }

    public mutating func apply(_ edit: NSRange, replacement: String) -> [LinkedEdit]? {
        guard accepts(edit, replacement: replacement) else { return nil }
        let primary = primaryRange
        let local = NSRange(location: edit.location - primary.location, length: edit.length)
        let renamed = (name as NSString).replacingCharacters(in: local, with: replacement)
        let edits = ranges.enumerated().map { index, range in
            index == primaryIndex ? LinkedEdit(range: edit, text: replacement) : LinkedEdit(range: range, text: renamed)
        }
        move(to: renamed)
        return edits.reversed()
    }

    public mutating func setAll(to text: String) -> [LinkedEdit] {
        let edits = ranges.reversed().map { LinkedEdit(range: $0, text: text) }
        move(to: text)
        return edits
    }

    public mutating func shift(byEditAt edit: NSRange, newLength: Int) -> Bool {
        let delta = newLength - edit.length
        var shifted: [NSRange] = []
        for range in ranges {
            if NSMaxRange(edit) <= range.location {
                shifted.append(NSRange(location: range.location + delta, length: range.length))
            } else if edit.location >= NSMaxRange(range) {
                shifted.append(range)
            } else {
                return false
            }
        }
        ranges = shifted
        return true
    }

    private mutating func move(to text: String) {
        let delta = (text as NSString).length - (name as NSString).length
        let length = (text as NSString).length
        ranges = ranges.enumerated().map { index, range in NSRange(location: range.location + index * delta, length: length) }
        name = text
    }
}
