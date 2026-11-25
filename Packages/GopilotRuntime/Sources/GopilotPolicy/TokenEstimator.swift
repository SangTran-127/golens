import Foundation
import GopilotRuntime

public struct TokenEstimate: Sendable, Equatable {
    public static let label = "Estimated"

    public let value: Int
    public var label: String { Self.label }
}

public enum TokenEstimator {
    public static let perMessageOverhead = 4

    public static func estimate(_ text: String) -> TokenEstimate {
        var total = 0.0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                switch scalar.value {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: total += 0.34
                case 0x09, 0x0A, 0x0D, 0x20: total += 0.2
                default: total += 0.7
                }
            } else if scalar.value > 0xFFFF {
                total += 3.0
            } else {
                total += 1.3
            }
        }
        return TokenEstimate(value: Int(total.rounded(.up)))
    }

    public static func estimate(_ message: ModelMessage) -> TokenEstimate {
        var total = perMessageOverhead + estimate(message.content).value
        for call in message.toolCalls {
            total += estimate(call.name).value + estimate(call.argumentsJSON).value + perMessageOverhead
        }
        return TokenEstimate(value: total)
    }

    public static func estimate(_ messages: [ModelMessage]) -> TokenEstimate {
        TokenEstimate(value: messages.reduce(0) { $0 + estimate($1).value })
    }
}
