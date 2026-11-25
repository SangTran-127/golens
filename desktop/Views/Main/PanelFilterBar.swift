import AppKit
import SwiftUI

struct PanelFilterBar<Accessory: View>: View {
    let placeholder: String
    @Binding var text: String
    var leadingSymbol: String = "magnifyingglass"
    var accessibilityTitle: String? = nil
    var focusTrigger: Int = 0
    var onSubmit: (() -> Void)? = nil
    var onMoveSelection: ((Int) -> Void)? = nil
    var onEscapeWhenEmpty: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    @State private var localFocusRequest: Int = 0

    init(
        placeholder: String,
        text: Binding<String>,
        leadingSymbol: String = "magnifyingglass",
        accessibilityTitle: String? = nil,
        focusTrigger: Int = 0,
        onSubmit: (() -> Void)? = nil,
        onMoveSelection: ((Int) -> Void)? = nil,
        onEscapeWhenEmpty: (() -> Void)? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.placeholder = placeholder
        self._text = text
        self.leadingSymbol = leadingSymbol
        self.accessibilityTitle = accessibilityTitle
        self.focusTrigger = focusTrigger
        self.onSubmit = onSubmit
        self.onMoveSelection = onMoveSelection
        self.onEscapeWhenEmpty = onEscapeWhenEmpty
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: Spacing.row) {
            Image(systemName: leadingSymbol)
                .font(.subheadline)
                .foregroundStyle(ChromeColor.textSecondary)
                .accessibilityHidden(true)

            FilterTextInputBridge(
                placeholder: placeholder,
                text: $text,
                accessibilityTitle: accessibilityTitle ?? placeholder,
                focusTrigger: focusTrigger &+ localFocusRequest,
                onSubmit: onSubmit,
                onMoveSelection: onMoveSelection,
                onEscapeWhenEmpty: onEscapeWhenEmpty
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            accessory()

            if !text.isEmpty {
                Button {
                    text = ""
                    localFocusRequest &+= 1
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(ChromeColor.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear Filter")
                .accessibilityLabel("Clear Filter")
            }
        }
        .padding(.horizontal, Spacing.standard)
        .frame(height: 26)
        .wellBackground(cornerRadius: CornerRadius.control)
    }
}

extension PanelFilterBar where Accessory == EmptyView {
    init(
        placeholder: String,
        text: Binding<String>,
        leadingSymbol: String = "magnifyingglass",
        accessibilityTitle: String? = nil,
        focusTrigger: Int = 0,
        onSubmit: (() -> Void)? = nil,
        onMoveSelection: ((Int) -> Void)? = nil,
        onEscapeWhenEmpty: (() -> Void)? = nil
    ) {
        self.init(
            placeholder: placeholder,
            text: text,
            leadingSymbol: leadingSymbol,
            accessibilityTitle: accessibilityTitle,
            focusTrigger: focusTrigger,
            onSubmit: onSubmit,
            onMoveSelection: onMoveSelection,
            onEscapeWhenEmpty: onEscapeWhenEmpty
        ) {
            EmptyView()
        }
    }
}

private struct FilterTextInputBridge: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let accessibilityTitle: String
    let focusTrigger: Int
    let onSubmit: (() -> Void)?
    let onMoveSelection: ((Int) -> Void)?
    let onEscapeWhenEmpty: (() -> Void)?

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterTextInputBridge
        var lastFocusTrigger: Int = 0
        var isUpdatingProgrammatically = false

        init(_ parent: FilterTextInputBridge) {
            self.parent = parent
            self.lastFocusTrigger = parent.focusTrigger
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isUpdatingProgrammatically,
                  let textField = obj.object as? NSTextField else { return }
            if parent.text != textField.stringValue {
                parent.text = textField.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if !parent.text.isEmpty {
                    isUpdatingProgrammatically = true
                    control.stringValue = ""
                    isUpdatingProgrammatically = false
                    parent.text = ""
                    return true
                }
                if let onEscape = parent.onEscapeWhenEmpty {
                    onEscape()
                }
                if let editor = WorkspaceState.owning(window: control.window).activeTextView, editor.window === control.window {
                    control.window?.makeFirstResponder(editor)
                } else {
                    control.window?.makeFirstResponder(nil)
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)), let onMove = parent.onMoveSelection {
                onMove(-1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)), let onMove = parent.onMoveSelection {
                onMove(1)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)), let onSubmit = parent.onSubmit {
                onSubmit()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .subheadline)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.stringValue = text
        field.setAccessibilityLabel(accessibilityTitle)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.accessibilityLabel() != accessibilityTitle {
            nsView.setAccessibilityLabel(accessibilityTitle)
        }
        if nsView.stringValue != text {
            context.coordinator.isUpdatingProgrammatically = true
            nsView.stringValue = text
            context.coordinator.isUpdatingProgrammatically = false
        }
        if context.coordinator.lastFocusTrigger != focusTrigger {
            context.coordinator.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}
