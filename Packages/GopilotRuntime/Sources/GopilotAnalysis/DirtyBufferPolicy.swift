import Foundation

public struct BufferDiskState: Sendable, Equatable {
    public let path: String
    public let diskContentHash: String
    public let bufferContentHash: String
    public let documentVersion: Int

    public init(path: String, diskContentHash: String, bufferContentHash: String, documentVersion: Int) {
        self.path = path
        self.diskContentHash = diskContentHash
        self.bufferContentHash = bufferContentHash
        self.documentVersion = documentVersion
    }

    public var isDirty: Bool { diskContentHash != bufferContentHash }
}

public enum DirtyBufferDecision: Sendable, Equatable {
    case runSavedVersion
    case saveSelectedAndRun(paths: [String])
    case cancel
}

public enum DirtyBufferOutcome: Sendable, Equatable {
    case proceed(DiskRevision)
    case needsDecision(dirtyPaths: [String])
    case saveThenRerunGate(pathsToSave: [String])
    case cancelled
}

public struct DiskRevision: Sendable, Equatable {
    public let fingerprint: String
    public let runsSavedVersion: Bool
    public let dirtyPathsNotIncluded: [String]
}

public enum DirtyBufferPolicy {
    public static func diskFingerprint(_ buffers: [BufferDiskState]) -> String {
        ContentHash.combined(Dictionary(uniqueKeysWithValues: buffers.map { ($0.path, $0.diskContentHash) }))
    }

    public static func evaluate(buffers: [BufferDiskState], decision: DirtyBufferDecision?) -> DirtyBufferOutcome {
        let dirty = buffers.filter(\.isDirty).map(\.path).sorted()
        let fingerprint = diskFingerprint(buffers)
        if dirty.isEmpty {
            return .proceed(DiskRevision(fingerprint: fingerprint, runsSavedVersion: false, dirtyPathsNotIncluded: []))
        }
        guard let decision else { return .needsDecision(dirtyPaths: dirty) }
        switch decision {
        case .cancel:
            return .cancelled
        case .runSavedVersion:
            return .proceed(DiskRevision(fingerprint: fingerprint, runsSavedVersion: true, dirtyPathsNotIncluded: dirty))
        case .saveSelectedAndRun(let paths):
            let selected = Set(paths).intersection(dirty).sorted()
            if selected.isEmpty { return .needsDecision(dirtyPaths: dirty) }
            return .saveThenRerunGate(pathsToSave: selected)
        }
    }
}
