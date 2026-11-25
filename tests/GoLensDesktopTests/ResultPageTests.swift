import Foundation
import XCTest
import GoLensFoundation

final class ResultPageTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Column: Decodable {
            let kind: String
            let values: [String?]
            let truncated: [Bool]
        }
        let flags: UInt8
        let endOfResult: Bool
        let sortedView: Bool
        let firstRow: Int64
        let rowCount: Int
        let resultVersion: UInt32
        let byteLength: Int
        let columns: [Column]
    }

    private static var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("core/database/testdata/ffi")
    }

    private static func pageFixtures() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixtureDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("page-v1-") && $0.pathExtension == "bin" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testDecodesEveryGoldenPage() throws {
        let pages = try Self.pageFixtures()
        XCTAssertGreaterThanOrEqual(pages.count, 7)
        for binURL in pages {
            let name = binURL.lastPathComponent
            let expected = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: binURL.deletingPathExtension().appendingPathExtension("json")))
            let data = try Data(contentsOf: binURL)
            XCTAssertEqual(data.count, expected.byteLength, name)
            let page = try ResultPage.copying(data)
            XCTAssertEqual(page.layout.flags, expected.flags, name)
            XCTAssertEqual(page.isEndOfResult, expected.endOfResult, name)
            XCTAssertEqual(page.isSortedView, expected.sortedView, name)
            XCTAssertEqual(page.firstRow, expected.firstRow, name)
            XCTAssertEqual(page.rowCount, expected.rowCount, name)
            XCTAssertEqual(page.resultVersion, expected.resultVersion, name)
            XCTAssertEqual(page.columnCount, expected.columns.count, name)
            for (c, column) in expected.columns.enumerated() {
                XCTAssertEqual(page.kind(column: c).name, column.kind, "\(name) column \(c)")
                for r in 0..<expected.rowCount {
                    let value = column.values[r]
                    XCTAssertEqual(page.isNull(row: r, column: c), value == nil, "\(name) null \(r),\(c)")
                    XCTAssertEqual(page.string(row: r, column: c), value, "\(name) value \(r),\(c)")
                    XCTAssertEqual(page.isTruncated(row: r, column: c), column.truncated[r], "\(name) truncated \(r),\(c)")
                    XCTAssertEqual(page.displayByteCount(row: r, column: c), value?.utf8.count ?? 0, "\(name) bytes \(r),\(c)")
                }
            }
        }
    }

    func testOutOfRangeCellsAreNullWithoutReading() throws {
        let page = try ResultPage.copying(Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("page-v1-basic.bin")))
        XCTAssertNil(page.string(row: page.rowCount, column: 0))
        XCTAssertNil(page.string(row: 0, column: page.columnCount))
        XCTAssertNil(page.string(row: -1, column: 0))
        XCTAssertTrue(page.isNull(row: 99, column: 0))
    }

    func testRejectsEveryTruncatedOrCorruptedBuffer() throws {
        for binURL in try Self.pageFixtures() {
            let data = try Data(contentsOf: binURL)
            for cut in 0..<data.count {
                XCTAssertThrowsError(try ResultPage.copying(data.prefix(cut)), "\(binURL.lastPathComponent) cut at \(cut)")
            }
            var badMagic = data
            badMagic[0] = 0x58
            XCTAssertThrowsError(try ResultPage.copying(badMagic))
            var badVersion = data
            badVersion[4] = 2
            XCTAssertEqual((try? ResultPage.copying(badVersion)) == nil, true)
            var trailing = data
            trailing.append(contentsOf: [0, 0, 0, 0])
            XCTAssertThrowsError(try ResultPage.copying(trailing))
        }
    }

    func testReleasesAdoptedBufferExactlyOnce() throws {
        let data = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("page-v1-nulls.bin"))
        var released = 0
        do {
            let memory = UnsafeMutableRawPointer.allocate(byteCount: data.count, alignment: 8)
            data.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
            let page = try ResultPage.adopt(UnsafeRawPointer(memory), count: data.count) { released += 1; memory.deallocate() }
            XCTAssertEqual(page.rowCount, 9)
        }
        XCTAssertEqual(released, 1)
        let bad = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        bad.initializeMemory(as: UInt8.self, repeating: 0, count: 8)
        XCTAssertThrowsError(try ResultPage.adopt(UnsafeRawPointer(bad), count: 8) { released += 1; bad.deallocate() })
        XCTAssertEqual(released, 2)
    }
}
