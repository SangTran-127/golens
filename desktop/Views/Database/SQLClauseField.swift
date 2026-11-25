import AppKit
import SwiftUI

struct SQLClauseField: NSViewRepresentable {
    let label: String
    let placeholder: String
    @Binding var text: String
    let completionContext: (_ text: String, _ caretByte: Int) -> (request: DBCompleteRequest, prefixBytes: Int)?
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        field.controlSize = .small
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel(label)
        field.stringValue = text
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SQLClauseField
        private var items: [String] = []
        private var requestedText = ""
        private let key = UUID()

        init(_ parent: SQLClauseField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let editor = field.currentEditor() as? NSTextView else { return }
            parent.text = field.stringValue
            guard let event = NSApp.currentEvent, event.type == .keyDown,
                  let last = event.characters?.unicodeScalars.last,
                  CharacterSet.alphanumerics.contains(last) || last == "_" || last == "." else { return }
            let text = field.stringValue
            let caret = editor.selectedRange().location
            let caretByte = (text as NSString).substring(to: min(caret, (text as NSString).length)).utf8.count
            guard let context = parent.completionContext(text, caretByte) else { return }
            requestedText = text
            BackgroundFFI.shared.run(key, debounce: 0.05, work: {
                DatabaseCore.complete(context.request)?.items.map(\.insert) ?? []
            }, deliver: { [weak self, weak field] labels in
                guard let self, let field, field.stringValue == self.requestedText, let editor = field.currentEditor() as? NSTextView, !labels.isEmpty else { return }
                self.items = labels
                editor.complete(nil)
            })
        }

        func control(_ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange).lowercased()
            index.pointee = -1
            let matches = items.filter { partial.isEmpty || $0.lowercased().hasPrefix(partial) }
            return Array(matches.prefix(50))
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.complete(_:)) {
                let text = textView.string
                let caretByte = (text as NSString).substring(to: textView.selectedRange().location).utf8.count
                guard let context = parent.completionContext(text, caretByte) else { return false }
                requestedText = text
                BackgroundFFI.shared.run(key, work: {
                    DatabaseCore.complete(context.request)?.items.map(\.insert) ?? []
                }, deliver: { [weak self, weak textView] labels in
                    guard let self, let textView, textView.string == self.requestedText, !labels.isEmpty else { return }
                    self.items = labels
                    textView.complete(nil)
                })
                return true
            }
            return false
        }
    }
}
