import Foundation
import CryptoKit

public protocol FileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    func writeAtomically(_ data: Data, to url: URL) throws
    func append(_ data: Data, to url: URL) throws
    func createDirectory(_ url: URL) throws
    func remove(_ url: URL) throws
    func copy(from source: URL, to destination: URL) throws
    func contents(of directory: URL) throws -> [URL]
    func exists(_ url: URL) -> Bool
    func size(of url: URL) -> Int?
}

public struct LocalFileSystem: FileSystem {
    public init() {}

    public func read(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try createDirectory(directory)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            if Darwin.rename(temp.path, url.path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    public func append(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    public func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func copy(from source: URL, to destination: URL) throws {
        try createDirectory(destination.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: destination)
    }

    public func contents(of directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func size(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }
}

public enum StoreError: Error, Sendable, Equatable {
    case diskFull
    case writeFailed(String)
    case readFailed(String)
    case readOnly(String)
    case conversationReadOnly
    case notFound
    case notInTrash
    case undoWindowExpired
    case transcriptLimitReached
    case conversationLimitReached
    case invalidConfirmation
    case migrationFailed(backupPath: String?, reason: String)
    case unsupportedFutureVersion(Int)
    case corruptMetadata(String)
    case noteTooLarge
    case emptyNote
    case artifactTooLarge
    case hashMismatch
    case hashConflict

    static func mapping(_ error: Error) -> StoreError {
        if let store = error as? StoreError { return store }
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { return .diskFull }
        if let posix = error as? POSIXError, posix.code == .ENOSPC || posix.code == .EDQUOT { return .diskFull }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) || nsError.code == Int(EDQUOT) { return .diskFull }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == CocoaError.fileWriteOutOfSpace.rawValue { return .diskFull }
        return .writeFailed(error.localizedDescription)
    }
}

public enum ContentHash {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    public static func normalizedArgumentsHash(_ argumentsJSON: String) -> String {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else {
            return sha256Hex(argumentsJSON)
        }
        return sha256Hex(canonical)
    }
}

enum Coding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
