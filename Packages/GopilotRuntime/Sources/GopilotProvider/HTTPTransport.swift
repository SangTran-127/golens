import Foundation
import GopilotRuntime

public struct HTTPRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var sensitiveHeaderNames: Set<String>
    public var timeout: TimeInterval

    public init(
        url: URL,
        method: String = "POST",
        headers: [String: String] = [:],
        body: Data? = nil,
        sensitiveHeaderNames: Set<String> = ["authorization"],
        timeout: TimeInterval = 90
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        self.timeout = timeout
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var description: String {
        "\(method) \(url.absoluteString) headers=[\(headers.keys.sorted().joined(separator: ", "))] bodyBytes=\(body?.count ?? 0)"
    }

    public var debugDescription: String { description }
}

public struct HTTPResponseHead: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        var normalized: [String: String] = [:]
        for (key, value) in headers {
            normalized[key.lowercased()] = value
        }
        self.headers = normalized
    }
}

public struct HTTPResponse: Sendable {
    public let head: HTTPResponseHead
    public let body: AsyncThrowingStream<Data, Error>

    public init(head: HTTPResponseHead, body: AsyncThrowingStream<Data, Error>) {
        self.head = head
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum RedirectPolicy {
    public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        origin(of: lhs) == origin(of: rhs)
    }

    public static func sanitized(_ redirected: URLRequest, from previous: URL?, sensitiveHeaderNames: Set<String>) -> URLRequest {
        guard let previous, let target = redirected.url, sameOrigin(previous, target) else {
            return strippingSensitiveHeaders(redirected, names: sensitiveHeaderNames)
        }
        return redirected
    }

    private static func strippingSensitiveHeaders(_ request: URLRequest, names: Set<String>) -> URLRequest {
        var copy = request
        let blocked = names.union(["authorization"]).map { $0.lowercased() }
        for key in (copy.allHTTPHeaderFields ?? [:]).keys where blocked.contains(key.lowercased()) {
            copy.setValue(nil, forHTTPHeaderField: key)
        }
        return copy
    }

    private static func origin(of url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let sensitiveHeaderNames: Set<String>
    private let authorizeHost: HostAuthorizationCheck?
    private let lock = NSLock()
    private var blockedHost: String?

    init(sensitiveHeaderNames: Set<String>, authorizeHost: HostAuthorizationCheck?) {
        self.sensitiveHeaderNames = sensitiveHeaderNames
        self.authorizeHost = authorizeHost
    }

    var deniedHost: String? {
        lock.withLock { blockedHost }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let authorizeHost, let targetURL = request.url,
           !OutboundHostConsent.isLoopback(targetURL), !authorizeHost(targetURL) {
            let host = OutboundHostConsent.normalizedHost(for: targetURL) ?? targetURL.host ?? "provider"
            lock.withLock { blockedHost = host }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(RedirectPolicy.sanitized(request, from: task.currentRequest?.url, sensitiveHeaderNames: sensitiveHeaderNames))
    }
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let authorizeHost: HostAuthorizationCheck?

    public init(configuration: URLSessionConfiguration? = nil, authorizeHost: HostAuthorizationCheck? = nil) {
        let base = configuration ?? URLSessionConfiguration.ephemeral
        base.httpCookieStorage = nil
        base.urlCache = nil
        base.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: base)
        self.authorizeHost = authorizeHost
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if let authorizeHost, !OutboundHostConsent.isLoopback(request.url), !authorizeHost(request.url) {
            let host = OutboundHostConsent.normalizedHost(for: request.url) ?? request.url.host ?? "provider"
            throw ProviderError.consentRequired(host: host)
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let redirectGuard = RedirectGuard(sensitiveHeaderNames: request.sensitiveHeaderNames, authorizeHost: authorizeHost)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest, delegate: redirectGuard)
        } catch {
            if let deniedHost = redirectGuard.deniedHost {
                throw ProviderError.consentRequired(host: deniedHost)
            }
            throw error
        }
        if let deniedHost = redirectGuard.deniedHost {
            throw ProviderError.consentRequired(host: deniedHost)
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        let body = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var pending = Data()
                    for try await byte in bytes {
                        pending.append(byte)
                        if byte == 0x0A || pending.count >= 8192 {
                            continuation.yield(pending)
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                    if !pending.isEmpty {
                        continuation.yield(pending)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPResponse(head: HTTPResponseHead(status: http.statusCode, headers: headers), body: body)
    }
}
