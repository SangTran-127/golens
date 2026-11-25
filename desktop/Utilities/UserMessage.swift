import Foundation
import GoLensFoundation

enum UserMessage {
    static let technicalLocale = Locale(identifier: "en_US")

    static func duration(_ seconds: Double) -> String {
        TestDurationFormatter.format(seconds: seconds)
    }

    static func byteCount(_ bytes: Int64, style: ByteCountFormatStyle.Style = .file) -> String {
        ByteCountFormatStyle(style: style, spellsOutZero: false, locale: technicalLocale).format(bytes)
    }

    static func integer(_ value: Int) -> String {
        value.formatted(.number.locale(technicalLocale))
    }

    static func rawIdentifier<T: BinaryInteger>(_ value: T) -> String {
        String(value)
    }

    static func previewFailed(_ subject: String) -> String {
        "Couldn’t generate the \(subject) preview. Check that the file builds, then try again."
    }

    static func readFailed(_ subject: String) -> String {
        "Couldn’t read the \(subject) in this file. Check that it builds, then try again."
    }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    static func quantity(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(integer(value)) \(value == 1 ? singular : plural ?? singular + "s")"
    }

    static func humanized(_ identifier: String) -> String {
        guard identifier.contains("_"), !identifier.contains(" ") else { return identifier }
        let words = identifier.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
