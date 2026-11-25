import Foundation

struct SnippetStop: Decodable {
    let index: Int
    let start: Int
    let length: Int
}

struct SnippetSession {
    struct Stop {
        let index: Int
        var range: NSRange
    }

    private(set) var stops: [Stop]
    private(set) var current = 0
    private(set) var finalCaret: Int?

    init?(base: Int, stops: [SnippetStop], final: Int) {
        guard !stops.isEmpty else { return nil }
        self.stops = stops.map { Stop(index: $0.index, range: NSRange(location: base + $0.start, length: $0.length)) }
        finalCaret = final >= 0 ? base + final : nil
    }

    var currentRange: NSRange { stops[current].range }

    var exitCaret: Int {
        finalCaret ?? NSMaxRange(stops[stops.count - 1].range)
    }

    mutating func apply(edit old: NSRange, newLength: Int) -> Bool {
        let delta = newLength - old.length
        let cur = stops[current].range
        let inCurrent = old.location >= cur.location && NSMaxRange(old) <= NSMaxRange(cur)
        var kept: [Stop] = []
        var newCurrent = current
        for (i, stop) in stops.enumerated() {
            var r = stop.range
            let encloses = r.location <= old.location && NSMaxRange(r) >= NSMaxRange(old)
            if i == current || (inCurrent && r.location <= cur.location && NSMaxRange(r) >= NSMaxRange(cur)) {
                if inCurrent || encloses {
                    r.length += delta
                } else if NSMaxRange(old) <= r.location {
                    r.location += delta
                } else if old.location < NSMaxRange(r) {
                    return false
                }
            } else if NSMaxRange(old) <= r.location {
                r.location += delta
            } else if old.location >= NSMaxRange(r) {
            } else if encloses {
                r.length += delta
            } else if inCurrent {
                if i < current { newCurrent -= 1 }
                continue
            } else {
                return false
            }
            kept.append(Stop(index: stop.index, range: r))
        }
        stops = kept
        current = newCurrent
        if let f = finalCaret, f >= NSMaxRange(old) {
            finalCaret = f + delta
        }
        return true
    }

    mutating func nest(_ inner: SnippetSession) -> Bool {
        let cur = currentRange
        guard inner.stops.allSatisfy({ $0.range.location >= cur.location && NSMaxRange($0.range) <= NSMaxRange(cur) }) else { return false }
        stops.insert(contentsOf: inner.stops, at: current + 1)
        current += 1
        return true
    }

    mutating func next() -> NSRange? {
        guard current + 1 < stops.count else { return nil }
        current += 1
        return stops[current].range
    }

    mutating func previous() -> NSRange? {
        guard current > 0 else { return nil }
        current -= 1
        return stops[current].range
    }
}
