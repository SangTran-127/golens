import Foundation
import Observation

struct LiveTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var abbreviation: String
    var description: String
    var body: String
    var isEnabled = true
    var builtInID: String? = nil

    var isBuiltIn: Bool { builtInID != nil }
    var usesSelection: Bool { body.contains("$TM_SELECTED_TEXT") || body.contains("${TM_SELECTED_TEXT}") }
}

@Observable
final class LiveTemplateStore {
    static let shared = LiveTemplateStore()
    static let storageKey = "GoLensLiveTemplates"
    static let rowBase = -1000

    static let builtIns: [LiveTemplate] = [
        LiveTemplate(abbreviation: "forr", description: "Range loop over a slice or map",
                     body: "for ${1:_}, ${2:v} := range ${3:items} {\n\t$0\n}", builtInID: "forr"),
        LiveTemplate(abbreviation: "errw", description: "Return the error wrapped with context",
                     body: "if err != nil {\n\treturn ${1:}fmt.Errorf(\"${2:context}: %w\", err)\n}\n$0", builtInID: "errw"),
        LiveTemplate(abbreviation: "tfn", description: "Table-driven test",
                     body: "func Test${1:Name}(t *testing.T) {\n\ttests := []struct {\n\t\tname string\n\t\t$2\n\t}{\n\t\t{name: \"${3:case}\"},\n\t}\n\tfor _, tt := range tests {\n\t\tt.Run(tt.name, func(t *testing.T) {\n\t\t\t$0\n\t\t})\n\t}\n}",
                     builtInID: "tfn"),
        LiveTemplate(abbreviation: "prl", description: "Log a value with its name",
                     body: "log.Printf(\"${1:$TM_SELECTED_TEXT} = %v\\n\", ${2:$TM_SELECTED_TEXT})$0", builtInID: "prl"),
    ]

    private(set) var templates: [LiveTemplate] = []
    @ObservationIgnored private var enabled: [LiveTemplate] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        templates = Self.load(from: defaults)
        enabled = templates.filter(\.isEnabled)
    }

    static func load(from defaults: UserDefaults) -> [LiveTemplate] {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([LiveTemplate].self, from: data) else { return builtIns }
        let present = Set(stored.compactMap(\.builtInID))
        return stored + builtIns.filter { !present.contains($0.builtInID ?? "") }
    }

    private func commit(_ updated: [LiveTemplate]) {
        templates = updated
        enabled = updated.filter(\.isEnabled)
        if let data = try? JSONEncoder().encode(updated) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    func matching(prefix: String) -> [(row: Int, template: LiveTemplate)] {
        guard !prefix.isEmpty else { return [] }
        var result: [(Int, LiveTemplate)] = []
        for template in enabled where template.abbreviation.hasPrefix(prefix) {
            if let index = templates.firstIndex(where: { $0.id == template.id }) {
                result.append((Self.rowBase - index, template))
            }
        }
        return result
    }

    func template(forRow row: Int) -> LiveTemplate? {
        let index = Self.rowBase - row
        guard row <= Self.rowBase, templates.indices.contains(index) else { return nil }
        return templates[index]
    }

    var surroundTemplates: [LiveTemplate] { enabled.filter(\.usesSelection) }

    func problem(abbreviation raw: String, excluding id: UUID?) -> String? {
        let abbreviation = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if abbreviation.isEmpty { return "Enter an abbreviation, such as forr." }
        if abbreviation.contains(where: { $0.isWhitespace }) { return "An abbreviation has no spaces." }
        if templates.contains(where: { $0.abbreviation == abbreviation && $0.id != id }) {
            return "Another template already uses “\(abbreviation)”."
        }
        return nil
    }

    func save(_ template: LiveTemplate) {
        var updated = templates
        var cleaned = template
        cleaned.abbreviation = template.abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.body = Self.straightQuotes(template.body)
        if let index = updated.firstIndex(where: { $0.id == template.id }) {
            updated[index] = cleaned
        } else {
            updated.append(cleaned)
        }
        commit(updated)
    }

    static func straightQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }

    func setEnabled(_ isEnabled: Bool, for id: UUID) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        var updated = templates
        updated[index].isEnabled = isEnabled
        commit(updated)
    }

    func duplicate(_ template: LiveTemplate) -> LiveTemplate {
        var abbreviation = template.abbreviation + "2"
        var n = 2
        while templates.contains(where: { $0.abbreviation == abbreviation }) {
            n += 1
            abbreviation = template.abbreviation + "\(n)"
        }
        let copy = LiveTemplate(abbreviation: abbreviation, description: template.description, body: template.body, isEnabled: template.isEnabled)
        commit(templates + [copy])
        return copy
    }

    func delete(_ id: UUID) {
        commit(templates.filter { $0.id != id || $0.isBuiltIn })
    }

    func restoreDefaults() {
        let custom = templates.filter { !$0.isBuiltIn }
        commit(Self.builtIns + custom)
    }
}
