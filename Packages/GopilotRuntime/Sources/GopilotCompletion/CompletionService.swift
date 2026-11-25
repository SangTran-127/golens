import Foundation

public enum CompletionOutcome: Sendable, Equatable {
    case suggestion(String, cached: Bool, latencySeconds: TimeInterval)
    case empty(latencySeconds: TimeInterval)
    case failed(CompletionFailure)
    case cancelled
}

public final class CompletionService: @unchecked Sendable {
    public let client: CompletionClient
    public let cache: CompletionCache
    private let lock = NSLock()
    private var nonStreamingScopes = Set<String>()

    public init(client: CompletionClient, cache: CompletionCache = CompletionCache()) {
        self.client = client
        self.cache = cache
    }

    public func cachedSuggestion(for context: CompletionContext, endpoint: CompletionEndpoint) -> String? {
        cache.lookup(scope: scope(endpoint, context), path: context.relativePath, prefix: context.prefix, suffix: context.suffix)
    }

    public func suggest(context: CompletionContext, endpoint: CompletionEndpoint, useCache: Bool = true) async -> CompletionOutcome {
        if useCache, let hit = cachedSuggestion(for: context, endpoint: endpoint) {
            return .suggestion(hit, cached: true, latencySeconds: 0)
        }
        var effective = endpoint
        if streamingUnsupported(for: endpoint) { effective.options.stream = false }
        do {
            let response: CompletionResponse
            do {
                response = try await complete(context: context, endpoint: effective)
            } catch CompletionFailure.server(let status) where status >= 500 && effective.options.stream && !Task.isCancelled {
                effective.options.stream = false
                response = try await complete(context: context, endpoint: effective)
                markStreamingUnsupported(for: endpoint)
            }
            if Task.isCancelled { return .cancelled }
            guard let text = CompletionPostProcessor.process(response.rawText, context: context) else {
                return .empty(latencySeconds: response.totalSeconds)
            }
            cache.store(text, scope: scope(endpoint, context), path: context.relativePath, prefix: context.prefix, suffix: context.suffix)
            return .suggestion(text, cached: false, latencySeconds: response.totalSeconds)
        } catch let failure as CompletionFailure {
            return Task.isCancelled ? .cancelled : .failed(failure)
        } catch {
            return .cancelled
        }
    }

    public func streamingUnsupported(for endpoint: CompletionEndpoint) -> Bool {
        lock.withLock { nonStreamingScopes.contains(endpoint.cacheScope) }
    }

    public func resetStreamingObservations() {
        lock.withLock { nonStreamingScopes.removeAll() }
    }

    private func markStreamingUnsupported(for endpoint: CompletionEndpoint) {
        _ = lock.withLock { nonStreamingScopes.insert(endpoint.cacheScope) }
    }

    private func complete(context: CompletionContext, endpoint: CompletionEndpoint) async throws -> CompletionResponse {
        try await client.complete(context: context, endpoint: endpoint) { partial in
            CompletionPostProcessor.isComplete(partial, context: context)
        }
    }

    private func scope(_ endpoint: CompletionEndpoint, _ context: CompletionContext) -> String {
        endpoint.cacheScope + (context.multiline ? "|multi" : "|single")
    }
}
