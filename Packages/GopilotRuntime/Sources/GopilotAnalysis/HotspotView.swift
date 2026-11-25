import Foundation

public enum HotspotOrdering: String, Sendable, Equatable {
    case flat
    case cumulative
}

public enum IncompleteReason: Sendable, Equatable {
    case truncatedEntries(before: Int, cap: Int)
    case skippedSamples(Int)
    case emptyProfile
    case inconsistentValues(String)

    public var description: String {
        switch self {
        case .truncatedEntries(let before, let cap): return "only the top \(cap) of \(before) functions were retained"
        case .skippedSamples(let count): return "\(count) samples had no resolvable frames or value"
        case .emptyProfile: return "profile has no usable samples"
        case .inconsistentValues(let detail): return "inconsistent values: \(detail)"
        }
    }
}

public struct HotspotRow: Sendable, Equatable {
    public let frameID: String
    public let function: String
    public let file: String
    public let line: Int
    public let flat: Int64
    public let cum: Int64
    public let flatShare: Double?
    public let cumShare: Double?
    public let isRecursive: Bool
}

public enum HotspotError: Error, Sendable, Equatable {
    case profileUnknown
    case profileExpired(String)
    case incompatibleMeasures(String, String)
    case unknownFrame(String)
}

public struct HotspotView: Sendable, Equatable {
    public static let maxLimit = 50

    public let profileID: String
    public let kind: ProfileKind
    public let sampleType: String
    public let unit: String
    public let denominator: Int64
    public let totalSampleCount: Int
    public let ordering: HotspotOrdering
    public let rows: [HotspotRow]
    public let totalRowCount: Int
    public let offset: Int
    public let incompleteReasons: [IncompleteReason]

    public var incomplete: Bool { !incompleteReasons.isEmpty }
    public var measureKey: String { "\(kind.rawValue)/\(sampleType)/\(unit)" }

    public static func make(lookup: ProfileLookup, ordering: HotspotOrdering = .flat, offset: Int = 0, limit: Int = 20) throws -> HotspotView {
        switch lookup {
        case .unknown: throw HotspotError.profileUnknown
        case .expired(let record): throw HotspotError.profileExpired(record.id)
        case .found(let record): return make(record: record, ordering: ordering, offset: offset, limit: limit)
        }
    }

    public static func make(record: ProfileRecord, ordering: HotspotOrdering = .flat, offset: Int = 0, limit: Int = 20) -> HotspotView {
        let recursive = ProfileGraph(record: record).recursiveFunctions
        let denominator = record.totalValue
        func share(_ value: Int64) -> Double? { denominator > 0 ? Double(value) / Double(denominator) : nil }
        let sorted = record.frames.sorted { lhs, rhs in
            let l = ordering == .flat ? (lhs.flat, lhs.cum) : (lhs.cum, lhs.flat)
            let r = ordering == .flat ? (rhs.flat, rhs.cum) : (rhs.cum, rhs.flat)
            if l.0 != r.0 { return l.0 > r.0 }
            if l.1 != r.1 { return l.1 > r.1 }
            return lhs.function < rhs.function
        }
        let start = Swift.max(0, Swift.min(offset, sorted.count))
        let end = Swift.min(sorted.count, start + Swift.max(1, Swift.min(limit, maxLimit)))
        let rows = sorted[start..<end].map { frame in
            HotspotRow(frameID: frame.id, function: frame.function, file: frame.file, line: frame.line, flat: frame.flat, cum: frame.cum, flatShare: share(frame.flat), cumShare: share(frame.cum), isRecursive: recursive.contains(frame.function))
        }
        return HotspotView(
            profileID: record.id,
            kind: record.kind,
            sampleType: record.sampleType,
            unit: record.unit,
            denominator: denominator,
            totalSampleCount: record.sampleCount,
            ordering: ordering,
            rows: Array(rows),
            totalRowCount: sorted.count,
            offset: start,
            incompleteReasons: completeness(of: record)
        )
    }

    public static func ensureSameMeasure(_ a: HotspotView, _ b: HotspotView) throws {
        guard a.measureKey == b.measureKey else { throw HotspotError.incompatibleMeasures(a.measureKey, b.measureKey) }
    }

    static func completeness(of record: ProfileRecord) -> [IncompleteReason] {
        var reasons: [IncompleteReason] = []
        if record.truncation.truncated {
            reasons.append(.truncatedEntries(before: record.truncation.entriesBeforeCap, cap: record.truncation.entryCap))
        }
        if record.truncation.skippedSamples > 0 {
            reasons.append(.skippedSamples(record.truncation.skippedSamples))
        }
        if record.totalValue <= 0 || record.frames.isEmpty {
            reasons.append(.emptyProfile)
            return reasons
        }
        var problems: [String] = []
        for frame in record.frames {
            if frame.flat > frame.cum { problems.append("\(frame.function): flat exceeds cumulative") }
            if frame.cum > record.totalValue { problems.append("\(frame.function): cumulative exceeds total") }
        }
        if !record.truncation.truncated {
            let flatSum = record.frames.reduce(Int64(0)) { $0 + $1.flat }
            if flatSum != record.totalValue { problems.append("flat values sum to \(flatSum) but total is \(record.totalValue)") }
        }
        if !problems.isEmpty { reasons.append(.inconsistentValues(problems.prefix(3).joined(separator: "; "))) }
        return reasons
    }
}

public enum CumulativeCombination: Sendable, Equatable {
    case additive(value: Int64, share: Double?, incomplete: Bool)
    case notAdditive(reason: String)
}

struct ProfileGraph {
    let byFunction: [String: ProfileFrame]
    let reachable: [String: Set<String>]

    init(record: ProfileRecord) {
        var map: [String: ProfileFrame] = [:]
        for frame in record.frames { map[frame.function] = frame }
        byFunction = map
        var closure: [String: Set<String>] = [:]
        for frame in record.frames {
            var seen = Set<String>()
            var stack = frame.children
            while let next = stack.popLast() {
                guard seen.insert(next).inserted, let child = map[next] else { continue }
                stack.append(contentsOf: child.children)
            }
            closure[frame.function] = seen
        }
        reachable = closure
    }

    var recursiveFunctions: Set<String> {
        Set(reachable.filter { $0.value.contains($0.key) }.keys)
    }

    func related(_ a: String, _ b: String) -> Bool {
        (reachable[a]?.contains(b) ?? false) || (reachable[b]?.contains(a) ?? false)
    }
}

extension ProfileRecord {
    public func combinedCumulative(frameIDs: [String]) throws -> CumulativeCombination {
        var selected: [ProfileFrame] = []
        for id in frameIDs {
            guard let frame = frame(id) else { throw HotspotError.unknownFrame(id) }
            if !selected.contains(where: { $0.id == frame.id }) { selected.append(frame) }
        }
        let graph = ProfileGraph(record: self)
        for (index, a) in selected.enumerated() {
            for b in selected[(index + 1)...] where graph.related(a.function, b.function) {
                return .notAdditive(reason: "\(a.function) and \(b.function) are ancestor and descendant, so their cumulative values overlap")
            }
        }
        let value = selected.reduce(Int64(0)) { $0 + $1.cum }
        let share: Double? = totalValue > 0 ? Double(value) / Double(totalValue) : nil
        let incomplete = !HotspotView.completeness(of: self).isEmpty
        return .additive(value: value, share: share, incomplete: incomplete)
    }
}
