import Foundation

enum TextBounds {
    static func truncate(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var used = 0
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            if used + width > maxBytes { break }
            used += width
            out.append(scalar)
        }
        return (String(out), true)
    }
}
