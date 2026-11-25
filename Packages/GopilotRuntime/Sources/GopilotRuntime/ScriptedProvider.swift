import Foundation

public enum ScriptStep: Sendable {
    case event(ProviderEvent)
    case delay(Duration)
    case fail(ProviderError)
    case hang
}

public final class ScriptedProvider: ProviderAdapter {
    private let state: ScriptState

    public init(responses: [[ScriptStep]]) {
        state = ScriptState(responses: responses)
    }

    public func recordedRequests() async -> [ProviderRequest] {
        await state.requests
    }

    public func stream(_ request: ProviderRequest) -> AsyncThrowingStream<ProviderEvent, Error> {
        let state = self.state
        return AsyncThrowingStream { continuation in
            let task = Task {
                guard let script = await state.next(for: request) else {
                    continuation.finish(throwing: ProviderError.malformedResponse("Script exhausted."))
                    return
                }
                do {
                    for step in script {
                        try Task.checkCancellation()
                        switch step {
                        case .event(let event):
                            continuation.yield(event)
                        case .delay(let duration):
                            try await Task.sleep(for: duration)
                        case .fail(let error):
                            throw error
                        case .hang:
                            try await Task.sleep(for: .seconds(3600))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ScriptState {
    private var remaining: [[ScriptStep]]
    private(set) var requests: [ProviderRequest] = []

    init(responses: [[ScriptStep]]) {
        remaining = responses
    }

    func next(for request: ProviderRequest) -> [ScriptStep]? {
        requests.append(request)
        return remaining.isEmpty ? nil : remaining.removeFirst()
    }
}
