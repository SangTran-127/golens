import AppKit
import SwiftUI

struct ConsoleLogView: NSViewRepresentable {
    @Environment(\.windowWorkspace) private var workspace
    let messages: [WorkspaceState.LogMessage]
    let normalColor: NSColor
    let background: NSColor
    var isDark: Bool = true
    @Binding var prettyMessageIDs: Set<UUID>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let textView = ConsoleTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        textView.setAccessibilityLabel("Console Output")
        textView.setAccessibilityIdentifier("GoLensConsoleLog")
        textView.delegate = context.coordinator
        textView.menuProvider = { [weak coordinator = context.coordinator] index in coordinator?.menu(forCharacterAt: index) }
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let appearanceName: NSAppearance.Name = highContrast
            ? (isDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (isDark ? .darkAqua : .aqua)
        let targetAppearance = NSAppearance(named: appearanceName)
        if scroll.appearance != targetAppearance {
            scroll.appearance = targetAppearance
        }
        scroll.backgroundColor = background
        (scroll.documentView as? NSTextView)?.backgroundColor = background
        context.coordinator.prettyBinding = $prettyMessageIDs
        context.coordinator.workspace = workspace
        context.coordinator.show(messages, normalColor: normalColor, pretty: prettyMessageIDs, in: scroll)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var workspace: WorkspaceState?
        var prettyBinding: Binding<Set<UUID>>?
        private var shown: [WorkspaceState.LogMessage] = []
        private var lengths: [Int] = []
        private var normalColor: NSColor?
        private var pretty: Set<UUID> = []

        private static let font = TechnicalTypography.codeCanvasNSFont(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        private static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 2
            return style
        }()

        func show(_ messages: [WorkspaceState.LogMessage], normalColor: NSColor, pretty: Set<UUID>, in scroll: NSScrollView) {
            guard let textView, let storage = textView.textStorage else { return }
            let followsOutput = isScrolledToBottom(scroll)
            if normalColor != self.normalColor || pretty != self.pretty {
                self.normalColor = normalColor
                self.pretty = pretty
                rebuild(messages, storage: storage)
            } else if let dropped = droppedPrefix(toReach: messages) {
                storage.beginEditing()
                if dropped > 0 {
                    storage.deleteCharacters(in: NSRange(location: 0, length: lengths.prefix(dropped).reduce(0, +)))
                    shown.removeFirst(dropped)
                    lengths.removeFirst(dropped)
                }
                append(messages[shown.count...], to: storage)
                storage.endEditing()
            } else {
                rebuild(messages, storage: storage)
            }
            if followsOutput {
                textView.scrollToEndOfDocument(nil)
            }
        }

        private func droppedPrefix(toReach messages: [WorkspaceState.LogMessage]) -> Int? {
            guard let first = messages.first else { return shown.isEmpty ? 0 : nil }
            guard !shown.isEmpty else { return 0 }
            guard let dropped = shown.firstIndex(where: { $0.id == first.id }) else { return nil }
            let kept = shown.count - dropped
            guard messages.count >= kept, messages[kept - 1].id == shown[shown.count - 1].id else { return nil }
            return dropped
        }

        private func rebuild(_ messages: [WorkspaceState.LogMessage], storage: NSTextStorage) {
            shown = []
            lengths = []
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            append(messages[...], to: storage)
            storage.endEditing()
        }

        private func append(_ messages: ArraySlice<WorkspaceState.LogMessage>, to storage: NSTextStorage) {
            guard !messages.isEmpty else { return }
            let chunk = NSMutableAttributedString()
            for message in messages {
                let line = render(message)
                chunk.append(line)
                shown.append(message)
                lengths.append(line.length)
            }
            storage.append(chunk)
        }

        private func render(_ message: WorkspaceState.LogMessage) -> NSAttributedString {
            let isPretty = pretty.contains(message.id)
            let text = isPretty ? message.formatPrettyJSON() : message.text
            let line = NSMutableAttributedString(string: text + "\n", attributes: [
                .font: Self.font,
                .foregroundColor: color(for: message.tone),
                .paragraphStyle: Self.paragraph,
            ])
            if !isPretty, let linked = message.linked {
                for run in linked.runs {
                    guard let url = run.link else { continue }
                    line.addAttribute(.link, value: url, range: NSRange(run.range, in: linked))
                }
            }
            return line
        }

        private func color(for tone: WorkspaceState.LogMessage.Tone) -> NSColor {
            switch tone {
            case .failure: .systemRed
            case .success: .systemGreen
            case .quiet: .secondaryLabelColor
            case .normal: normalColor ?? .labelColor
            }
        }

        private func isScrolledToBottom(_ scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return true }
            return scroll.contentView.bounds.maxY >= document.frame.maxY - 24
        }

        private func message(atCharacter index: Int) -> WorkspaceState.LogMessage? {
            var offset = 0
            for (i, length) in lengths.enumerated() {
                offset += length
                if index < offset { return shown[i] }
            }
            return shown.last
        }

        func menu(forCharacterAt index: Int) -> NSMenu {
            let menu = NSMenu()
            if let textView, textView.selectedRange().length > 0 {
                let copyItem = menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
                copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            }
            if let message = message(atCharacter: index) {
                menu.addItem(ActionMenuItem("Copy Line", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                })
                if message.hasStructuredJSONPayload {
                    let isPretty = pretty.contains(message.id)
                    menu.addItem(ActionMenuItem(isPretty ? "Show Original JSON" : "Format JSON", icon: "curlybraces") { [weak self] in
                        guard let binding = self?.prettyBinding else { return }
                        if isPretty { binding.wrappedValue.remove(message.id) } else { binding.wrappedValue.insert(message.id) }
                    })
                }
                if message.isGovulncheckPayload {
                    menu.addItem(ActionMenuItem("Open in Safety (Vulnerabilities)", icon: "checkmark.shield") { [weak self] in
                        self?.workspace?.openGovulncheckMessageInSafetyPanel(message.text)
                    })
                }
            }
            menu.addItem(.separator())
            let selectAllItem = menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
            selectAllItem.image = NSImage(systemSymbolName: "selection.pin.in.out", accessibilityDescription: nil)
            return menu
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            guard let workspace else { return false }
            return ConsoleLinks.open(url, in: workspace)
        }
    }
}

final class ConsoleTextView: NSTextView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        return menuProvider?(index) ?? super.menu(for: event)
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, icon: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let icon {
            image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
