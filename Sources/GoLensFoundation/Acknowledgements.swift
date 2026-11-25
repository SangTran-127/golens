import Foundation

public struct AcknowledgementSection: Decodable, Equatable, Identifiable, Sendable {
    public let title: String
    public let appliesTo: [String]
    public let text: String

    public var id: String { title }

    public init(title: String, appliesTo: [String], text: String) {
        self.title = title
        self.appliesTo = appliesTo
        self.text = text
    }
}

public enum Acknowledgements {
    public static let componentsTitle = "Components"

    public static func decode(_ data: Data) -> [AcknowledgementSection] {
        (try? JSONDecoder().decode([AcknowledgementSection].self, from: data)) ?? []
    }

    public static func componentCount(in sections: [AcknowledgementSection]) -> Int {
        sections.first { $0.title == componentsTitle }?.text.split(separator: "\n").count ?? 0
    }

    public static func runtimeSections(fromNotices text: String, prefix: String) -> [AcknowledgementSection] {
        let lines = text.components(separatedBy: "\n")
        let isRule: (String) -> Bool = { $0.count >= 20 && $0.allSatisfy { $0 == "=" } }
        var sections: [AcknowledgementSection] = []
        var title: String?
        var body: [String] = []
        func flush() {
            guard let title else { return }
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = "\(prefix): \(title)"
            sections.append(AcknowledgementSection(title: name, appliesTo: [name], text: text))
        }
        var index = 0
        while index < lines.count {
            if isRule(lines[index]), index + 2 < lines.count, isRule(lines[index + 2]) {
                flush()
                title = lines[index + 1].trimmingCharacters(in: .whitespaces)
                body = []
                index += 3
                continue
            }
            if title != nil { body.append(lines[index]) }
            index += 1
        }
        flush()
        return sections
    }

    public static func filter(_ sections: [AcknowledgementSection], query: String) -> [AcknowledgementSection] {
        let shown = sections.filter { $0.title != componentsTitle }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return shown }
        return shown.filter { section in
            section.title.localizedCaseInsensitiveContains(needle)
                || section.appliesTo.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }
}
