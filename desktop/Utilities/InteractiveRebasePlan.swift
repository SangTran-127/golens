import Foundation

enum InteractiveRebaseAction: String, CaseIterable, Identifiable {
    case pick, reword, edit, squash, fixup, drop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pick: "Pick"
        case .reword: "Reword"
        case .edit: "Stop to Edit"
        case .squash: "Squash"
        case .fixup: "Fixup"
        case .drop: "Drop"
        }
    }

    var help: String {
        switch self {
        case .pick: "Keep the commit as it is"
        case .reword: "Keep the change and replace the commit message"
        case .edit: "Stop after this commit so you can change it, then choose Continue"
        case .squash: "Fold into the commit above and keep both messages"
        case .fixup: "Fold into the commit above and keep only its message"
        case .drop: "Remove the commit and its change"
        }
    }

    var symbol: String {
        switch self {
        case .pick: "checkmark.circle"
        case .reword: "pencil"
        case .edit: "pause.circle"
        case .squash: "arrow.up.and.down.and.arrow.left.and.right"
        case .fixup: "arrow.up.to.line"
        case .drop: "trash"
        }
    }
}

struct InteractiveRebaseStep: Identifiable, Equatable {
    let commit: GitHistoryCommit
    let originalMessage: String
    var action: InteractiveRebaseAction = .pick
    var message: String

    var id: String { commit.hash }

    init(commit: GitHistoryCommit, message: String) {
        self.commit = commit
        self.originalMessage = message
        self.message = message
    }

    var rewordsMessage: Bool {
        action == .reword && message.trimmingCharacters(in: .whitespacesAndNewlines) != originalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum InteractiveRebasePlan {
    static let todoFileName = "golens-rebase-todo"
    static let messageFilePrefix = "golens-rebase-message-"

    static func messageFileName(_ index: Int) -> String { messageFilePrefix + String(index) }

    static func problem(_ steps: [InteractiveRebaseStep], original: [String]) -> String? {
        if steps.isEmpty { return "There are no commits to rebase." }
        if let first = steps.first(where: { $0.action != .drop }), first.action == .squash || first.action == .fixup {
            return "“\(first.commit.subject)” has no earlier commit to fold into. Pick it, or move it below another commit."
        }
        if let empty = steps.first(where: { $0.action == .reword && $0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Write a message for “\(empty.commit.subject)”."
        }
        let unchanged = steps.map(\.commit.hash) == original && steps.allSatisfy { $0.action == .pick || ($0.action == .reword && !$0.rewordsMessage) }
        if unchanged { return "Change an action, a message or the order to rebase." }
        return nil
    }

    static func todo(_ steps: [InteractiveRebaseStep]) -> (todo: String, messages: [String: String]) {
        var lines: [String] = []
        var messages: [String: String] = [:]
        for (index, step) in steps.enumerated() {
            let subject = step.commit.subject.replacingOccurrences(of: "\n", with: " ")
            switch step.action {
            case .reword where step.rewordsMessage:
                lines.append("pick \(step.commit.hash) \(subject)")
                let name = messageFileName(index)
                messages[name] = step.message.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                lines.append("exec git commit --amend --only --allow-empty --no-verify --cleanup=strip -F \"$(git rev-parse --git-path \(name))\"")
            case .reword:
                lines.append("pick \(step.commit.hash) \(subject)")
            default:
                lines.append("\(step.action.rawValue) \(step.commit.hash) \(subject)")
            }
        }
        return (lines.joined(separator: "\n") + "\n", messages)
    }

    static let sequenceEditor = "cp \"$(git rev-parse --git-path \(todoFileName))\""
}
