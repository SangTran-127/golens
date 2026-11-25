import Foundation

public enum ProfileKind: String, Sendable, Equatable, Codable {
    case cpu
    case heapAlloc
    case heapInuse
    case block
    case mutex
}

public enum ProfileMetadataValue: Sendable, Equatable, Codable {
    case known(String)
    case unknown

    public var isKnown: Bool {
        if case .known = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .known(let value): return value
        case .unknown: return "unknown"
        }
    }
}

public enum MappingConfidence: String, Sendable, Equatable, Codable {
    case verified
    case unverified
    case mismatched
}

public struct ProfileRunMetadata: Sendable, Equatable, Codable {
    public var workload: ProfileMetadataValue
    public var config: ProfileMetadataValue
    public var sourceHash: ProfileMetadataValue
    public var build: ProfileMetadataValue

    public init(workload: ProfileMetadataValue = .unknown, config: ProfileMetadataValue = .unknown, sourceHash: ProfileMetadataValue = .unknown, build: ProfileMetadataValue = .unknown) {
        self.workload = workload
        self.config = config
        self.sourceHash = sourceHash
        self.build = build
    }

    public static let unknown = ProfileRunMetadata()

    public var isFullyKnown: Bool { workload.isKnown && config.isKnown && sourceHash.isKnown && build.isKnown }

    public var unknownFieldNames: [String] {
        var names: [String] = []
        if !workload.isKnown { names.append("workload") }
        if !config.isKnown { names.append("config") }
        if !sourceHash.isKnown { names.append("source hash") }
        if !build.isKnown { names.append("build") }
        return names
    }
}

public struct ProfileDetailPayload: Sendable, Equatable, Codable {
    public struct SampleTypeInfo: Sendable, Equatable, Codable {
        public let type: String
        public let unit: String
    }

    public struct Entry: Sendable, Equatable, Codable {
        public let function: String
        public let file: String
        public let line: Int
        public let flat: Int64
        public let cum: Int64
        public let children: [String]?
        public let callers: [String]?
        public let count: Int64?
    }

    public let contentSha256: String
    public let mode: String
    public let sampleType: String
    public let unit: String
    public let sampleTypes: [SampleTypeInfo]
    public let totalValue: Int64
    public let sampleCount: Int
    public let skippedSamples: Int
    public let durationNanos: Int64
    public let period: Int64
    public let truncated: Bool
    public let entriesBeforeCap: Int
    public let entryCap: Int
    public let entries: [Entry]
}

public struct ProfileTruncation: Sendable, Equatable, Codable {
    public let truncated: Bool
    public let entriesBeforeCap: Int
    public let entryCap: Int
    public let skippedSamples: Int
}

public struct ProfileFrame: Sendable, Equatable, Codable {
    public let id: String
    public let function: String
    public let file: String
    public let line: Int
    public let flat: Int64
    public let cum: Int64
    public let children: [String]
    public let callers: [String]
    public let count: Int64
}

public enum ProfileError: Error, Sendable, Equatable {
    case unsupportedSampleType(mode: String, sampleType: String)
    case missingContentHash
    case negativeValue(String)
}

public struct ProfileRecord: Sendable, Equatable, Codable {
    public let id: String
    public let contentSHA256: String
    public let kind: ProfileKind
    public let sampleType: String
    public let unit: String
    public let totalValue: Int64
    public let sampleCount: Int
    public let durationNanos: Int64?
    public let period: Int64?
    public let truncation: ProfileTruncation
    public let metadata: ProfileRunMetadata
    public let mapping: MappingConfidence
    public let capturedAt: Date
    public let frames: [ProfileFrame]

    public static func deriveID(contentSHA256: String, kind: ProfileKind, sampleType: String) -> String {
        "P-" + String(ContentHash.sha256Hex("\(contentSHA256)|\(kind.rawValue)|\(sampleType)").prefix(16))
    }

    public static func deriveFrameID(profileID: String, function: String, file: String, line: Int) -> String {
        "F-" + String(ContentHash.sha256Hex("\(profileID)|\(function)|\(file)|\(line)").prefix(16))
    }

    public static func kind(mode: String, sampleType: String) -> ProfileKind? {
        switch mode {
        case "cpu": return sampleType == "cpu" ? .cpu : nil
        case "block": return .block
        case "mutex": return .mutex
        case "memory":
            switch sampleType {
            case "alloc_space", "alloc_objects": return .heapAlloc
            case "inuse_space", "inuse_objects": return .heapInuse
            default: return nil
            }
        default: return nil
        }
    }

    public static func make(from payload: ProfileDetailPayload, metadata: ProfileRunMetadata = .unknown, mapping: MappingConfidence = .unverified, capturedAt: Date = Date()) throws -> ProfileRecord {
        guard !payload.contentSha256.isEmpty else { throw ProfileError.missingContentHash }
        guard let kind = kind(mode: payload.mode, sampleType: payload.sampleType) else {
            throw ProfileError.unsupportedSampleType(mode: payload.mode, sampleType: payload.sampleType)
        }
        guard payload.totalValue >= 0 else { throw ProfileError.negativeValue("totalValue") }
        let id = deriveID(contentSHA256: payload.contentSha256, kind: kind, sampleType: payload.sampleType)
        var frames: [ProfileFrame] = []
        for entry in payload.entries {
            guard entry.flat >= 0, entry.cum >= 0 else { throw ProfileError.negativeValue(entry.function) }
            frames.append(ProfileFrame(
                id: deriveFrameID(profileID: id, function: entry.function, file: entry.file, line: entry.line),
                function: entry.function,
                file: entry.file,
                line: entry.line,
                flat: entry.flat,
                cum: entry.cum,
                children: entry.children ?? [],
                callers: entry.callers ?? [],
                count: entry.count ?? 0
            ))
        }
        return ProfileRecord(
            id: id,
            contentSHA256: payload.contentSha256,
            kind: kind,
            sampleType: payload.sampleType,
            unit: payload.unit,
            totalValue: payload.totalValue,
            sampleCount: payload.sampleCount,
            durationNanos: payload.durationNanos > 0 ? payload.durationNanos : nil,
            period: payload.period > 0 ? payload.period : nil,
            truncation: ProfileTruncation(truncated: payload.truncated, entriesBeforeCap: payload.entriesBeforeCap, entryCap: payload.entryCap, skippedSamples: payload.skippedSamples),
            metadata: metadata,
            mapping: mapping,
            capturedAt: capturedAt,
            frames: frames
        )
    }

    public func frame(_ frameID: String) -> ProfileFrame? { frames.first { $0.id == frameID } }

    func strippingFrames() -> ProfileRecord {
        ProfileRecord(id: id, contentSHA256: contentSHA256, kind: kind, sampleType: sampleType, unit: unit, totalValue: totalValue, sampleCount: sampleCount, durationNanos: durationNanos, period: period, truncation: truncation, metadata: metadata, mapping: mapping, capturedAt: capturedAt, frames: [])
    }
}

public enum ProfileLookup: Sendable, Equatable {
    case found(ProfileRecord)
    case expired(ProfileRecord)
    case unknown
}

public enum ProfileRegistryError: Error, Sendable, Equatable {
    case unknownProfile(String)
    case expiredProfile(String)
}

public actor ProfileRegistry {
    private var records: [String: ProfileRecord] = [:]
    private var order: [String] = []
    private var expiredIDs: Set<String> = []
    private var attachments: [UUID: [String]] = [:]

    public init() {}

    public func add(_ record: ProfileRecord) -> ProfileRecord {
        if let existing = records[record.id] { return existing }
        records[record.id] = record
        order.append(record.id)
        return record
    }

    public func lookup(_ id: String) -> ProfileLookup {
        guard let record = records[id] else { return .unknown }
        return expiredIDs.contains(id) ? .expired(record.strippingFrames()) : .found(record)
    }

    public func list() -> [ProfileRecord] {
        order.compactMap { records[$0] }.map { expiredIDs.contains($0.id) ? $0.strippingFrames() : $0 }
    }

    public func expire(_ id: String) {
        guard records[id] != nil else { return }
        expiredIDs.insert(id)
    }

    public func attach(_ id: String, toConversation conversation: UUID) throws {
        guard records[id] != nil else { throw ProfileRegistryError.unknownProfile(id) }
        guard !expiredIDs.contains(id) else { throw ProfileRegistryError.expiredProfile(id) }
        var list = attachments[conversation] ?? []
        if !list.contains(id) { list.append(id) }
        attachments[conversation] = list
    }

    public func attachedProfileIDs(conversation: UUID) -> [String] {
        attachments[conversation] ?? []
    }

    public func latestAttachedProfileID(conversation: UUID) -> String? {
        attachments[conversation]?.last
    }
}
