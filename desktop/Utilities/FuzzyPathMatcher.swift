import Foundation

enum FuzzyPathMatcher {
    struct Candidate {
        let path: String
        let bytes: [UInt8]
        let original: [UInt8]
        let nameStart: Int

        init(_ path: String) {
            self.path = path
            original = Array(path.utf8)
            bytes = original.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
            nameStart = (original.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
        }
    }

    static func query(_ text: String) -> [UInt8] {
        Array(text.lowercased().utf8).filter { $0 != UInt8(ascii: " ") }
    }

    static func score(_ q: [UInt8], _ c: Candidate) -> Int? {
        guard !q.isEmpty else { return 0 }
        var qi = q.count - 1, pi = c.bytes.count - 1
        var score = 0, lastMatch = Int.max, firstMatch = 0
        while qi >= 0 && pi >= 0 {
            if c.bytes[pi] == q[qi] {
                score += 16
                if lastMatch == pi + 1 { score += 24 }
                if isWordStart(c, pi) { score += 20 }
                if pi >= c.nameStart { score += 8 }
                lastMatch = pi
                firstMatch = pi
                qi -= 1
            } else if lastMatch != Int.max {
                score -= 1
            }
            pi -= 1
        }
        guard qi < 0 else { return nil }
        let name = c.bytes[c.nameStart...]
        if name.starts(with: q) { score += name.count == q.count ? 500 : 300 }
        else if firstMatch >= c.nameStart { score += 200 }
        return score - c.bytes.count / 8
    }

    private static func isWordStart(_ c: Candidate, _ i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = c.original[i - 1], cur = c.original[i]
        if prev == UInt8(ascii: "/") || prev == UInt8(ascii: "_") || prev == UInt8(ascii: "-") || prev == UInt8(ascii: ".") { return true }
        return prev >= 97 && prev <= 122 && cur >= 65 && cur <= 90
    }

    static func rank(_ text: String, _ candidates: [Candidate], limit: Int) -> [String] {
        let q = query(text)
        var scored: [(Int, Candidate)] = []
        for c in candidates {
            if let s = score(q, c) { scored.append((s, c)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.bytes.count < $1.1.bytes.count }
        return scored.prefix(limit).map(\.1.path)
    }
}
