import Foundation

public struct KernelTelemetry: Codable, Equatable, Sendable {
    public var pid: Int32
    public var targetName: String
    public var openFDs: OpenFDsTelemetry
    public var tcpSockets: [TCPSocketTelemetry]
    public var psi: PSITelemetry?
    public var timestamp: Date

    public static func decode(_ data: Data) throws -> KernelTelemetry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KernelTelemetry.self, from: data)
    }
}

public struct OpenFDsTelemetry: Codable, Equatable, Sendable {
    public var count: Int
    public var limit: Int
    public var entries: [FDEntry]
}

public struct FDEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { fd }
    public var fd: Int
    public var target: String
    public var kind: FDKind

    public enum FDKind: String, Codable, CaseIterable, Sendable {
        case file, socket, pipe, character, anonInode, other
    }
}

public struct TCPSocketTelemetry: Codable, Identifiable, Equatable, Sendable {
    public var id: String { "\(localAddress):\(localPort)-\(remoteAddress):\(remotePort)-\(inode)" }
    public var localAddress: String
    public var localPort: Int
    public var remoteAddress: String
    public var remotePort: Int
    public var state: TCPState
    public var inode: UInt64
    public var rxQueue: UInt64
    public var txQueue: UInt64

    public var localEndpoint: String { Self.endpoint(localAddress, localPort) }
    public var remoteEndpoint: String { remotePort == 0 ? "*:*" : Self.endpoint(remoteAddress, remotePort) }

    static func endpoint(_ address: String, _ port: Int) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    public enum TCPState: String, Codable, CaseIterable, Sendable {
        case established = "ESTABLISHED"
        case synSent = "SYN_SENT"
        case synRecv = "SYN_RECV"
        case finWait1 = "FIN_WAIT1"
        case finWait2 = "FIN_WAIT2"
        case timeWait = "TIME_WAIT"
        case close = "CLOSE"
        case closeWait = "CLOSE_WAIT"
        case lastAck = "LAST_ACK"
        case listen = "LISTEN"
        case closing = "CLOSING"
        case unknown = "UNKNOWN"
    }
}

public struct PSITelemetry: Codable, Equatable, Sendable {
    public var memory: PSIResource
    public var cpu: PSIResource
    public var io: PSIResource
}

public struct PSIResource: Codable, Equatable, Sendable {
    public var somePressure: PSIValues
    public var fullPressure: PSIValues?
}

public struct PSIValues: Codable, Equatable, Sendable {
    public var avg10: Double
    public var avg60: Double
    public var avg300: Double
    public var totalMicros: UInt64
}
