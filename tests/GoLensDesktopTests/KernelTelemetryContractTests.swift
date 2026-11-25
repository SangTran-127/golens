import Foundation
import XCTest
import GoLensFoundation

final class KernelTelemetryContractTests: XCTestCase {
    private func decodeFixture(_ name: String = "kernel-telemetry-contract") throws -> KernelTelemetry {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("core/cmd/golens-vm-agent/kerneltelemetry/testdata/\(name).json")
        return try KernelTelemetry.decode(Data(contentsOf: url))
    }

    func testDecodesTheVMAgentReport() throws {
        let telemetry = try decodeFixture()
        XCTAssertEqual(telemetry.pid, 4242)
        XCTAssertEqual(telemetry.targetName, "server")
        XCTAssertEqual(telemetry.timestamp, Date(timeIntervalSince1970: 1_794_929_445))
        XCTAssertEqual(telemetry.openFDs.count, 6)
        XCTAssertEqual(telemetry.openFDs.limit, 1_048_576)
        let fd = try XCTUnwrap(telemetry.openFDs.entries.first)
        XCTAssertEqual(fd.fd, 0)
        XCTAssertEqual(fd.target, "/srv/app/data.db")
        let socket = try XCTUnwrap(telemetry.tcpSockets.last)
        XCTAssertEqual(socket.localAddress, "127.0.0.1")
        XCTAssertEqual(socket.localPort, 8080)
        XCTAssertEqual(socket.remoteAddress, "10.0.2.2")
        XCTAssertEqual(socket.remotePort, 50011)
        XCTAssertEqual(socket.inode, 41012)
        XCTAssertEqual(socket.rxQueue, 11)
        XCTAssertEqual(socket.txQueue, 22)
        let psi = try XCTUnwrap(telemetry.psi)
        let memory = psi.memory.somePressure
        XCTAssertEqual([memory.avg10, memory.avg60, memory.avg300], [1.5, 0.75, 0.2])
        XCTAssertEqual(memory.totalMicros, 123_456)
        XCTAssertEqual(psi.memory.fullPressure?.totalMicros, 9876)
        XCTAssertEqual(psi.cpu.somePressure.avg10, 12.5)
        XCTAssertNil(psi.cpu.fullPressure)
        XCTAssertEqual(psi.io.fullPressure?.avg10, 0)
    }

    func testDecodesAReportFromAKernelWithoutPressureStallInformation() throws {
        let telemetry = try decodeFixture("kernel-telemetry-contract-no-pressure")
        XCTAssertNil(telemetry.psi)
        XCTAssertEqual(telemetry.pid, 7)
        XCTAssertEqual(telemetry.targetName, "idle")
        XCTAssertEqual(telemetry.openFDs.limit, 1024)
        XCTAssertTrue(telemetry.openFDs.entries.isEmpty)
        XCTAssertTrue(telemetry.tcpSockets.isEmpty)
    }

    func testEveryKindAndStateOnBothSidesMatches() throws {
        let telemetry = try decodeFixture()
        XCTAssertEqual(telemetry.openFDs.entries.map(\.kind), FDEntry.FDKind.allCases)
        XCTAssertEqual(telemetry.tcpSockets.map(\.state), TCPSocketTelemetry.TCPState.allCases)
    }

    func testEndpointsBracketIPv6AndShowListenersAsWildcards() throws {
        func socket(_ json: String) throws -> TCPSocketTelemetry {
            try JSONDecoder().decode(TCPSocketTelemetry.self, from: Data(json.utf8))
        }
        let listener = try socket(#"{"localAddress":"::","localPort":8099,"remoteAddress":"::","remotePort":0,"state":"LISTEN","inode":1,"rxQueue":0,"txQueue":0}"#)
        XCTAssertEqual(listener.localEndpoint, "[::]:8099")
        XCTAssertEqual(listener.remoteEndpoint, "*:*")
        let client = try socket(#"{"localAddress":"127.0.0.1","localPort":42582,"remoteAddress":"127.0.0.1","remotePort":8099,"state":"ESTABLISHED","inode":2,"rxQueue":0,"txQueue":0}"#)
        XCTAssertEqual(client.localEndpoint, "127.0.0.1:42582")
        XCTAssertEqual(client.remoteEndpoint, "127.0.0.1:8099")
    }
}
