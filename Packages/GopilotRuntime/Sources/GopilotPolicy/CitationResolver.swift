import Foundation

public enum UnverifiedReason: String, Sendable, Equatable {
    case unknown
    case expired
}

public enum CitationSegment: Sendable, Equatable {
    case text(String)
    case citation(Evidence)
    case unverifiedCitation(token: String, reason: UnverifiedReason)
}

public struct CitationResolver: Sendable {
    private static let pattern = try! NSRegularExpression(pattern: #"\[E([0-9]{1,9})\]"#)

    public init() {}

    public func resolve(_ text: String, workspaceID: UUID, store: EvidenceStore) async -> [CitationSegment] {
        let source = text as NSString
        let matches = Self.pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        var segments: [CitationSegment] = []
        var cursor = 0

        func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            if case .text(let previous)? = segments.last {
                segments[segments.count - 1] = .text(previous + value)
            } else {
                segments.append(.text(value))
            }
        }

        for match in matches {
            if match.range.location > cursor {
                appendText(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            let token = source.substring(with: match.range)
            let id = String(token.dropFirst().dropLast())
            switch await store.lookup(id: id, workspaceID: workspaceID) {
            case .found(let evidence):
                segments.append(.citation(evidence))
            case .expired:
                segments.append(.unverifiedCitation(token: token, reason: .expired))
            case .unknown:
                segments.append(.unverifiedCitation(token: token, reason: .unknown))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            appendText(source.substring(from: cursor))
        }
        return segments
    }
}
