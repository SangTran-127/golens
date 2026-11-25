import Foundation

public enum ResultPageError: Error, Equatable {
    case tooShort
    case badMagic
    case unsupportedVersion(UInt8)
    case columnOutOfBounds(Int)
    case badOffsets(Int)
    case trailingBytes
}

public enum ResultCellKind: UInt8, CaseIterable, Sendable {
    case unknown = 0
    case text
    case int
    case float
    case decimal
    case bool
    case dateTime
    case json
    case binary
    case uuid

    public init(name: String) {
        switch name {
        case "text": self = .text
        case "int": self = .int
        case "float": self = .float
        case "decimal": self = .decimal
        case "bool": self = .bool
        case "datetime": self = .dateTime
        case "json": self = .json
        case "binary": self = .binary
        case "uuid": self = .uuid
        default: self = .unknown
        }
    }

    public var name: String {
        switch self {
        case .unknown: "unknown"
        case .text: "text"
        case .int: "int"
        case .float: "float"
        case .decimal: "decimal"
        case .bool: "bool"
        case .dateTime: "datetime"
        case .json: "json"
        case .binary: "binary"
        case .uuid: "uuid"
        }
    }

    public var isNumeric: Bool {
        self == .int || self == .float || self == .decimal
    }
}

public struct ResultPageLayout: Sendable {
    public struct Column: Sendable {
        public let kind: ResultCellKind
        let nulls: Int
        let truncated: Int
        let offsets: Int
        let data: Int
        let dataLength: Int
    }

    public static let headerSize = 24
    public static let flagEndOfResult: UInt8 = 1
    public static let flagSortedView: UInt8 = 2

    public let flags: UInt8
    public let firstRow: Int64
    public let rowCount: Int
    public let resultVersion: UInt32
    public let columns: [Column]

    public var isEndOfResult: Bool { flags & Self.flagEndOfResult != 0 }
    public var isSortedView: Bool { flags & Self.flagSortedView != 0 }

    private static func pad4(_ n: Int) -> Int { (n + 3) & ~3 }

    public init(_ bytes: UnsafeRawBufferPointer) throws {
        let length = bytes.count
        guard length >= Self.headerSize, let base = bytes.baseAddress else { throw ResultPageError.tooShort }
        guard base.load(as: UInt8.self) == 0x47, base.load(fromByteOffset: 1, as: UInt8.self) == 0x4C,
              base.load(fromByteOffset: 2, as: UInt8.self) == 0x52, base.load(fromByteOffset: 3, as: UInt8.self) == 0x50 else {
            throw ResultPageError.badMagic
        }
        let version = base.load(fromByteOffset: 4, as: UInt8.self)
        guard version == 1 else { throw ResultPageError.unsupportedVersion(version) }
        flags = base.load(fromByteOffset: 5, as: UInt8.self)
        let columnCount = Int(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: 6, as: UInt16.self)))
        firstRow = Int64(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: Int64.self))
        let rows = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt32.self)))
        resultVersion = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
        guard rows <= length else { throw ResultPageError.columnOutOfBounds(0) }
        rowCount = rows
        let bitmap = Self.pad4((rows + 7) / 8)
        var at = Self.headerSize
        var parsed: [Column] = []
        parsed.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            let head = 4 + 2 * bitmap + 4 * (rows + 1)
            guard at + head <= length else { throw ResultPageError.columnOutOfBounds(index) }
            let kind = ResultCellKind(rawValue: base.load(fromByteOffset: at, as: UInt8.self)) ?? .unknown
            let offsets = at + 4 + 2 * bitmap
            let first = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offsets, as: UInt32.self))
            let dataLength = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offsets + 4 * rows, as: UInt32.self)))
            let data = at + head
            guard first == 0, data + dataLength <= length else { throw ResultPageError.badOffsets(index) }
            parsed.append(Column(kind: kind, nulls: at + 4, truncated: at + 4 + bitmap, offsets: offsets, data: data, dataLength: dataLength))
            at = data + Self.pad4(dataLength)
        }
        guard at == length else { throw ResultPageError.trailingBytes }
        columns = parsed
    }
}

public final class ResultPage: @unchecked Sendable {
    public let layout: ResultPageLayout
    private let base: UnsafeRawPointer
    private let length: Int
    private let release: () -> Void

    public static func adopt(_ pointer: UnsafeRawPointer, count: Int, release: @escaping () -> Void) throws -> ResultPage {
        do {
            let layout = try ResultPageLayout(UnsafeRawBufferPointer(start: pointer, count: count))
            return ResultPage(layout: layout, base: pointer, length: count, release: release)
        } catch {
            release()
            throw error
        }
    }

    public static func copying(_ data: Data) throws -> ResultPage {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 8)
        data.withUnsafeBytes { source in
            if let src = source.baseAddress { memory.copyMemory(from: src, byteCount: data.count) }
        }
        return try adopt(UnsafeRawPointer(memory), count: data.count) { memory.deallocate() }
    }

    private init(layout: ResultPageLayout, base: UnsafeRawPointer, length: Int, release: @escaping () -> Void) {
        self.layout = layout
        self.base = base
        self.length = length
        self.release = release
    }

    deinit { release() }

    public var byteCount: Int { length }
    public var firstRow: Int64 { layout.firstRow }
    public var rowCount: Int { layout.rowCount }
    public var columnCount: Int { layout.columns.count }
    public var resultVersion: UInt32 { layout.resultVersion }
    public var isEndOfResult: Bool { layout.isEndOfResult }
    public var isSortedView: Bool { layout.isSortedView }

    public func kind(column: Int) -> ResultCellKind {
        layout.columns.indices.contains(column) ? layout.columns[column].kind : .unknown
    }

    private func bit(_ start: Int, _ row: Int) -> Bool {
        base.load(fromByteOffset: start + row >> 3, as: UInt8.self) & (1 << UInt8(row & 7)) != 0
    }

    private func valid(_ row: Int, _ column: Int) -> Bool {
        row >= 0 && row < layout.rowCount && layout.columns.indices.contains(column)
    }

    public func isNull(row: Int, column: Int) -> Bool {
        guard valid(row, column) else { return true }
        return bit(layout.columns[column].nulls, row)
    }

    public func isTruncated(row: Int, column: Int) -> Bool {
        guard valid(row, column) else { return false }
        return bit(layout.columns[column].truncated, row)
    }

    public func utf8(row: Int, column: Int) -> UnsafeRawBufferPointer? {
        guard valid(row, column) else { return nil }
        let col = layout.columns[column]
        guard !bit(col.nulls, row) else { return nil }
        let start = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: col.offsets + 4 * row, as: UInt32.self)))
        let end = Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: col.offsets + 4 * (row + 1), as: UInt32.self)))
        guard start <= end, end <= col.dataLength else { return nil }
        return UnsafeRawBufferPointer(start: base + col.data + start, count: end - start)
    }

    public func displayByteCount(row: Int, column: Int) -> Int {
        utf8(row: row, column: column)?.count ?? 0
    }

    public func string(row: Int, column: Int) -> String? {
        guard let bytes = utf8(row: row, column: column) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
