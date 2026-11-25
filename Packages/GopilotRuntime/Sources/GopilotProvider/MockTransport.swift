import Foundation

public enum MockBodyStep: Sendable {
    case chunk(Data)
    case delay(TimeInterval)
    case disconnect
    case hang
}

public enum MockHeadBehavior: Sendable {
    case respond
    case fail(URLError.Code)
    case hang
}

public struct MockResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var steps: [MockBodyStep]
    public var headBehavior: MockHeadBehavior

    public init(
        status: Int = 200,
        headers: [String: String] = [:],
        steps: [MockBodyStep] = [],
        headBehavior: MockHeadBehavior = .respond
    ) {
        self.status = status
        self.headers = headers
        self.steps = steps
        self.headBehavior = headBehavior
    }

    public static func sse(_ text: String, status: Int = 200, splitting chunkSize: Int? = nil, then tail: [MockBodyStep] = []) -> MockResponse {
        let bytes = Array(text.utf8)
        var steps: [MockBodyStep] = []
        if let chunkSize, chunkSize > 0 {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunkSize, bytes.count)
                steps.append(.chunk(Data(bytes[offset..<end])))
                offset = end
            }
        } else {
            steps.append(.chunk(Data(bytes)))
        }
        return MockResponse(status: status, headers: ["Content-Type": "text/event-stream"], steps: steps + tail)
    }

    public static func sse(chunks: [Data], status: Int = 200, then tail: [MockBodyStep] = []) -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": "text/event-stream"], steps: chunks.map { .chunk($0) } + tail)
    }

    public static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> MockResponse {
        var merged = headers
        merged["Content-Type"] = merged["Content-Type"] ?? "application/json"
        return MockResponse(status: status, headers: merged, steps: [.chunk(Data(text.utf8))])
    }

    public static func html(_ text: String = "<html><body>Bad gateway</body></html>", status: Int = 200) -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], steps: [.chunk(Data(text.utf8))])
    }

    public static func connectionFailure(_ code: URLError.Code = .notConnectedToInternet) -> MockResponse {
        MockResponse(headBehavior: .fail(code))
    }
}

public final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [MockResponse]
    private var recorded: [HTTPRequest] = []
    private var cancelled = 0

    public init(_ responses: [MockResponse]) {
        remaining = responses
    }

    public var requests: [HTTPRequest] {
        lock.withLock { recorded }
    }

    public var requestCount: Int {
        lock.withLock { recorded.count }
    }

    public var cancellationCount: Int {
        lock.withLock { cancelled }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response: MockResponse? = lock.withLock {
            recorded.append(request)
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }
        guard let response else {
            throw URLError(.notConnectedToInternet)
        }
        switch response.headBehavior {
        case .fail(let code):
            throw URLError(code)
        case .hang:
            do {
                try await Task.sleep(nanoseconds: SystemProviderClock.nanoseconds(3600))
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }
        case .respond:
            break
        }
        let steps = response.steps
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    for step in steps {
                        try Task.checkCancellation()
                        switch step {
                        case .chunk(let data):
                            continuation.yield(data)
                        case .delay(let seconds):
                            try await Task.sleep(nanoseconds: SystemProviderClock.nanoseconds(seconds))
                        case .disconnect:
                            throw URLError(.networkConnectionLost)
                        case .hang:
                            try await Task.sleep(nanoseconds: SystemProviderClock.nanoseconds(3600))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    self?.lock.withLock { self?.cancelled += 1 }
                }
                task.cancel()
            }
        }
        return HTTPResponse(head: HTTPResponseHead(status: response.status, headers: response.headers), body: body)
    }
}
