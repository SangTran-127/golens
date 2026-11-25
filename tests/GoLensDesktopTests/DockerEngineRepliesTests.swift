import Foundation
import XCTest
import GoLensFoundation

final class DockerEngineRepliesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testNetworkListDecodesItemsAndRemovability() throws {
        let reply = try decode(DockerListResult<DockerNetworkSummary>.self, """
        {"kind":"network","items":[
          {"id":"n1","name":"bridge","driver":"bridge","scope":"local","builtIn":true,"containers":[],"created":"2026-11-16T08:00:00Z"},
          {"id":"n2","name":"svcdemo_default","driver":"bridge","scope":"local","builtIn":false,"containers":["svcdemo-api-1"]},
          {"id":"n3","name":"scratch","driver":"bridge","scope":"local","builtIn":false,"created":1763280000}
        ]}
        """)
        XCTAssertEqual(reply.kind, "network")
        XCTAssertEqual(reply.items.map(\.name), ["bridge", "svcdemo_default", "scratch"])
        XCTAssertEqual(reply.items.map(\.isRemovable), [false, false, true])
        XCTAssertEqual(reply.items[0].created, "2026-11-16T08:00:00Z")
        XCTAssertEqual(reply.items[1].containers, ["svcdemo-api-1"])
        XCTAssertFalse(reply.items[2].created.isEmpty)
        XCTAssertEqual(reply.error, "")
    }

    func testNetworkListAndRemoveCarryErrors() throws {
        let list = try decode(DockerListResult<DockerNetworkSummary>.self, #"{"kind":"network","error":"The engine isn’t running."}"#)
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertEqual(list.error, "The engine isn’t running.")
        let refused = try decode(DockerActionResult.self, #"{"ok":false,"error":"“bridge” is built in, so it can’t be removed."}"#)
        XCTAssertFalse(refused.ok)
        XCTAssertFalse(refused.error.isEmpty)
        XCTAssertTrue(try decode(DockerActionResult.self, #"{"ok":true}"#).ok)
    }

    func testDiskUsageKeepsKnownKindsAndSumsSelection() throws {
        let usage = try decode(DockerDiskUsage.self, """
        {"categories":[
          {"kind":"containers","count":2,"bytes":1000},
          {"kind":"images","count":3,"bytes":500000000},
          {"kind":"volumes","count":1,"bytes":900000000},
          {"kind":"networks","count":4,"bytes":0},
          {"kind":"buildCache","count":7,"bytes":100},
          {"kind":"plugins","count":9,"bytes":9}
        ]}
        """)
        XCTAssertEqual(usage.categories.count, 5)
        XCTAssertEqual(usage.category(.images).count, 3)
        XCTAssertEqual(usage.category(.volumes).bytes, 900_000_000)
        XCTAssertEqual(usage.reclaimableBytes([.containers, .images, .buildCache]), 500_001_100)
        XCTAssertEqual(usage.reclaimableBytes([]), 0)
        let missing = try decode(DockerDiskUsage.self, #"{"categories":[]}"#)
        XCTAssertEqual(missing.category(.networks).count, 0)
        XCTAssertEqual(try decode(DockerDiskUsage.self, #"{"error":"boom"}"#).error, "boom")
    }

    func testVolumesAreTheOnlyKindUncheckedByDefault() {
        XCTAssertEqual(DockerPruneKind.allCases.filter { !$0.isCheckedByDefault }, [.volumes])
        XCTAssertEqual(DockerPruneKind.allCases.map(\.rawValue), ["containers", "images", "volumes", "networks", "buildCache"])
    }

    func testPruneOptionsEncodeTheContractShape() throws {
        let plain = try JSONSerialization.jsonObject(with: Data(DockerPruneOptions(kind: .images).json.utf8)) as? [String: Any]
        XCTAssertEqual(plain?["kind"] as? String, "images")
        XCTAssertNil(plain?["label"])
        let labelled = try JSONSerialization.jsonObject(with: Data(DockerPruneOptions(kind: .buildCache, label: "golens.smoke=1").json.utf8)) as? [String: Any]
        XCTAssertEqual(labelled?["kind"] as? String, "buildCache")
        XCTAssertEqual(labelled?["label"] as? String, "golens.smoke=1")
    }

    func testPruneResultAcceptsCountOrList() throws {
        let counted = try decode(DockerPruneResult.self, #"{"kind":"images","removed":3,"bytes":1400000000}"#)
        XCTAssertEqual(counted.removed, 3)
        XCTAssertEqual(counted.bytes, 1_400_000_000)
        let listed = try decode(DockerPruneResult.self, #"{"kind":"volumes","removed":["a","b"],"bytes":10}"#)
        XCTAssertEqual(listed.removed, 2)
        let failed = try decode(DockerPruneResult.self, #"{"kind":"buildCache","error":"The engine stopped."}"#)
        XCTAssertEqual(failed.removed, 0)
        XCTAssertEqual(failed.error, "The engine stopped.")
    }

    func testStatsEventDecodes() throws {
        let sample = try decode(DockerStatsSample.self, #"{"stream":7,"id":"a1a1","cpuPercent":3.2,"memoryBytes":44040192,"memoryLimitBytes":8267825152,"closed":false}"#)
        XCTAssertEqual(sample.stream, 7)
        XCTAssertEqual(sample.id, "a1a1")
        XCTAssertEqual(sample.cpuPercent, 3.2, accuracy: 0.0001)
        XCTAssertEqual(sample.memoryLimitBytes, 8_267_825_152)
        XCTAssertTrue(sample.hasReading)
        let closed = try decode(DockerStatsSample.self, #"{"stream":7,"id":"a1a1","closed":true,"error":"The container stopped."}"#)
        XCTAssertTrue(closed.closed)
        XCTAssertFalse(closed.hasReading)
    }

    func testContextListMarksCurrentAndRemoteTransports() throws {
        let list = try decode(DockerContextList.self, """
        {"current":"orbstack","contexts":[
          {"name":"default","description":"Current DOCKER_HOST based configuration","endpoint":"unix:///var/run/docker.sock","transport":"unix","current":false},
          {"name":"orbstack","description":"OrbStack","endpoint":"unix:///Users/me/.orbstack/run/docker.sock","transport":"unix","current":true},
          {"name":"build-box","endpoint":"ssh://me@build-box","transport":"ssh"},
          {"name":"tls-box","endpoint":"tcp://10.0.0.2:2376","transport":"tls"}
        ]}
        """)
        XCTAssertEqual(list.current, "orbstack")
        XCTAssertEqual(list.currentContext?.description, "OrbStack")
        XCTAssertEqual(list.contexts.map(\.isRemote), [false, false, true, true])
        let inferred = try decode(DockerContextList.self, #"{"contexts":[{"name":"a"},{"name":"b","current":true}]}"#)
        XCTAssertEqual(inferred.current, "b")
        XCTAssertEqual(try decode(DockerContextList.self, #"{"error":"No contexts."}"#).error, "No contexts.")
    }
}
