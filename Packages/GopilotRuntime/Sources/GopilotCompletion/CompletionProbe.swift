import Foundation
import GopilotProvider

public enum CompletionProbeResult: Sendable, Equatable {
    case fimHonored(latencySeconds: TimeInterval, promptTokensWithSuffix: Int, promptTokensWithoutSuffix: Int)
    case fimSuffixIgnored(latencySeconds: TimeInterval)
    case fimUnconfirmed(latencySeconds: TimeInterval)
    case fimNotSupported
    case fimTemplateWorks(latencySeconds: TimeInterval)
    case chatWorks(latencySeconds: TimeInterval)
    case empty(latencySeconds: TimeInterval)
    case failed(CompletionFailure)
}

public struct CompletionProbeReport: Sendable, Equatable {
    public var result: CompletionProbeResult
    public var usedNativeContent: Bool
    public var streamingFailed: Bool

    public init(result: CompletionProbeResult, usedNativeContent: Bool = false, streamingFailed: Bool = false) {
        self.result = result
        self.usedNativeContent = usedNativeContent
        self.streamingFailed = streamingFailed
    }
}

public struct CompletionProbe: Sendable {
    public static let prefix = "package main\n\nfunc add(a, b int) int {\n\treturn "
    public static let suffixMarker = "multiplyAllTheThings"
    public static let suffix = "\n}\n\nfunc multiplyAllTheThings(values []int) int {\n\tproduct := 1\n\tfor _, v := range values {\n\t\tproduct *= v\n\t}\n\treturn product\n}\n"
    public static let promptTokenMargin = 5
    public static let timeoutSeconds: TimeInterval = 15

    private let client: CompletionClient

    public init(transport: HTTPTransport, userAgent: String, timeoutSeconds: TimeInterval = CompletionProbe.timeoutSeconds) {
        client = CompletionClient(transport: transport, userAgent: userAgent, timeoutSeconds: timeoutSeconds)
    }

    public static func context(withSuffix: Bool) -> CompletionContext {
        CompletionContext(relativePath: "probe.go", prefix: prefix, suffix: withSuffix ? suffix : "", multiline: false)
    }

    func streamingFails(endpoint: CompletionEndpoint) async -> Bool {
        var streaming = endpoint
        streaming.options.stream = true
        do {
            _ = try await client.complete(context: Self.context(withSuffix: true), endpoint: streaming)
            return false
        } catch CompletionFailure.server {
            return true
        } catch {
            return false
        }
    }

    public func run(endpoint: CompletionEndpoint) async -> CompletionProbeReport {
        var probeEndpoint = endpoint
        probeEndpoint.options.stream = false
        let withSuffix = Self.context(withSuffix: true)
        let first: CompletionResponse
        do {
            first = try await client.complete(context: withSuffix, endpoint: probeEndpoint)
        } catch CompletionFailure.endpointNotFound where endpoint.options.dialect == .fillInTheMiddle {
            return CompletionProbeReport(result: .fimNotSupported)
        } catch let failure as CompletionFailure {
            return CompletionProbeReport(result: .failed(failure))
        } catch {
            return CompletionProbeReport(result: .failed(.offline))
        }
        let native = first.usedNativeContent
        let latency = first.totalSeconds
        let processed = CompletionPostProcessor.process(first.rawText, context: withSuffix)
        func report(_ result: CompletionProbeResult) -> CompletionProbeReport {
            CompletionProbeReport(result: result, usedNativeContent: native)
        }
        guard endpoint.options.dialect == .fillInTheMiddle else {
            return report(processed == nil ? .empty(latencySeconds: latency) : .chatWorks(latencySeconds: latency))
        }
        if first.rawText.contains(Self.suffixMarker) {
            return report(.fimSuffixIgnored(latencySeconds: latency))
        }
        if endpoint.options.fimTemplate.isRawTemplate {
            guard processed != nil else { return report(.empty(latencySeconds: latency)) }
            var result = report(.fimTemplateWorks(latencySeconds: latency))
            if endpoint.options.stream {
                result.streamingFailed = await streamingFails(endpoint: endpoint)
            }
            return result
        }
        guard let withTokens = first.promptTokens else {
            return report(processed == nil ? .empty(latencySeconds: latency) : .fimUnconfirmed(latencySeconds: latency))
        }
        let second: CompletionResponse
        do {
            second = try await client.complete(context: Self.context(withSuffix: false), endpoint: probeEndpoint)
        } catch let failure as CompletionFailure {
            return report(.failed(failure))
        } catch {
            return report(.failed(.offline))
        }
        guard let withoutTokens = second.promptTokens else {
            return report(.fimUnconfirmed(latencySeconds: latency))
        }
        if withTokens >= withoutTokens + Self.promptTokenMargin {
            return report(processed == nil ? .empty(latencySeconds: latency)
                : .fimHonored(latencySeconds: latency, promptTokensWithSuffix: withTokens, promptTokensWithoutSuffix: withoutTokens))
        }
        return report(.fimSuffixIgnored(latencySeconds: latency))
    }
}
