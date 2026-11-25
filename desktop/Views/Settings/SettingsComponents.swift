import AppKit
import SwiftUI

enum SettingsMetrics {
    static let contentInset: CGFloat = 20
    static let rowSpacing = Spacing.standard
    static let compactSpacing = Spacing.compact
    static let fieldWidth: CGFloat = 320
    static let tileSize: CGFloat = 20
    static let tableMinHeight: CGFloat = 240
    static let tableReservedHeight: CGFloat = 288
}

struct SettingsForm<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        Form {
            content()
        }
        .formStyle(.grouped)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    let content: () -> Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        Section {
            content()
        } header: {
            if let title { Text(title) }
        } footer: {
            if let footer { SettingsFooter(footer) }
        }
    }
}

struct SettingsFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsNote<Action: View>: View {
    let text: String
    let systemImage: String?
    let action: () -> Action

    init(_ text: String, systemImage: String? = nil, @ViewBuilder action: @escaping () -> Action) {
        self.text = text
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        HStack(spacing: SettingsMetrics.rowSpacing) {
            Group {
                if let systemImage {
                    Label(text, systemImage: systemImage)
                } else {
                    Text(text)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
    }
}

extension SettingsNote where Action == EmptyView {
    init(_ text: String, systemImage: String? = nil) {
        self.init(text, systemImage: systemImage) { EmptyView() }
    }
}

struct SettingsExplanation<Details: View>: View {
    let paragraphs: [String]
    let detailsTitle: String
    @Binding var isPresented: Bool
    let details: () -> Details

    init(_ paragraphs: [String], detailsTitle: String, isPresented: Binding<Bool>, @ViewBuilder details: @escaping () -> Details) {
        self.paragraphs = paragraphs
        self.detailsTitle = detailsTitle
        self._isPresented = isPresented
        self.details = details
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            ForEach(paragraphs, id: \.self) { paragraph in
                SettingsNote(paragraph)
            }
            Button(detailsTitle) { isPresented = true }
                .buttonStyle(.link)
                .popover(isPresented: $isPresented, arrowEdge: .bottom, content: details)
        }
    }
}

struct SettingsFieldRow<Field: View, Help: View>: View {
    let title: String
    let field: () -> Field
    let help: () -> Help

    init(_ title: String, @ViewBuilder field: @escaping () -> Field, @ViewBuilder help: @escaping () -> Help) {
        self.title = title
        self.field = field
        self.help = help
    }

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .leading, spacing: SettingsMetrics.compactSpacing) {
                field()
                help()
            }
            .frame(width: SettingsMetrics.fieldWidth, alignment: .leading)
        }
    }
}

extension SettingsFieldRow where Help == EmptyView {
    init(_ title: String, @ViewBuilder field: @escaping () -> Field) {
        self.init(title, field: field) { EmptyView() }
    }
}

struct SettingsFieldHelp: View {
    let text: String
    let systemImage: String?

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func settingsTextField() -> some View {
        labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.leading)
    }
}

struct SettingsValue: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

struct SettingsStatus: View {
    typealias Tone = StatusTone

    let text: String
    let detail: String?
    let symbol: String?
    let tint: Color
    let isBusy: Bool

    init(_ text: String, detail: String? = nil, symbol: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        self.isBusy = false
    }

    init(_ text: String, detail: String? = nil, tone: Tone) {
        self.init(text, detail: detail, symbol: tone.symbol, tint: tone.tint)
    }

    init(busy text: String) {
        self.text = text
        self.detail = nil
        self.symbol = nil
        self.tint = .secondary
        self.isBusy = true
    }

    private var isEmphasized: Bool {
        !isBusy && symbol != nil && tint != .secondary
    }

    var body: some View {
        HStack(alignment: detail == nil ? .center : .firstTextBaseline, spacing: Spacing.row) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(text)
                    .foregroundStyle(isEmphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SettingsBadge: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.row)
            .padding(.vertical, Spacing.hairline)
            .background(.quaternary, in: Capsule())
    }
}

struct SettingsItemRow<Icon: View, Badges: View, Accessory: View>: View {
    let title: String
    let subtitle: String?
    let icon: () -> Icon
    let badges: () -> Badges
    let accessory: () -> Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder badges: @escaping () -> Badges,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.badges = badges
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: SettingsMetrics.rowSpacing) {
            icon()
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.row) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    badges()
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: SettingsMetrics.rowSpacing)
            accessory()
        }
    }
}

extension SettingsItemRow where Icon == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder badges: @escaping () -> Badges,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.init(title, subtitle: subtitle, icon: { EmptyView() }, badges: badges, accessory: accessory)
    }
}

struct SettingsDrillDownRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let page: SettingsPage
    @Environment(\.openSettingsPage) private var openPage

    var body: some View {
        Button {
            openPage(page)
        } label: {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                Image(systemName: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                    .frame(width: SettingsMetrics.tileSize, height: SettingsMetrics.tileSize)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: SettingsMetrics.rowSpacing)
                SettingsValue(value)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint("Shows \(title) settings")
    }
}

struct SettingsActionRow<Leading: View, Trailing: View>: View {
    let leading: () -> Leading
    let trailing: () -> Trailing

    init(@ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: SettingsMetrics.rowSpacing) {
            leading()
            Spacer(minLength: SettingsMetrics.rowSpacing)
            trailing()
        }
    }
}

extension SettingsActionRow where Leading == EmptyView {
    init(@ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

struct SettingsTablePane<Header: View, Search: View, TableContent: View, Actions: View>: View {
    let header: () -> Header
    let search: () -> Search
    let table: () -> TableContent
    let actions: () -> Actions
    @State private var headerHeight: CGFloat = 128

    init(
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder search: @escaping () -> Search,
        @ViewBuilder table: @escaping () -> TableContent,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.header = header
        self.search = search
        self.table = table
        self.actions = actions
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                SettingsForm(content: header)
                    .scrollDisabled(true)
                    .background(SettingsFormHeightReader(height: $headerHeight))
                    .frame(height: headerHeight)
                VStack(spacing: SettingsMetrics.rowSpacing) {
                    search()
                    table()
                        .frame(minHeight: SettingsMetrics.tableMinHeight, maxHeight: .infinity)
                    actions()
                }
                .padding([.horizontal, .bottom], SettingsMetrics.contentInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
    }
}

private struct SettingsFormHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.height = $height
        nsView.measureSoon()
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            measureSoon()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            measureSoon()
        }

        override func layout() {
            super.layout()
            coordinator?.measure(from: self)
        }

        func measureSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.coordinator?.measure(from: self)
            }
        }
    }

    final class Coordinator {
        var height: Binding<CGFloat>
        private weak var observedDoc: NSView?
        private var observer: NSObjectProtocol?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func measure(from probe: NSView) {
            guard probe.window != nil,
                  let root = probe.superview,
                  let scrollView = Self.findFormScrollView(in: root, matching: probe),
                  let doc = scrollView.documentView else { return }
            if observedDoc !== doc {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observedDoc = doc
                doc.postsFrameChangedNotifications = true
                observer = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: doc,
                    queue: .main
                ) { [weak self, weak doc] _ in
                    guard let self, let doc else { return }
                    self.publish(doc: doc)
                }
            }
            publish(doc: doc)
        }

        private func publish(doc: NSView) {
            let subMaxY = doc.subviews.map { $0.frame.maxY }.max() ?? 0
            let natural = subMaxY > 40 ? (subMaxY + 8) : doc.frame.height
            let clamped = min(max(ceil(natural), 96), 280)
            if abs(height.wrappedValue - clamped) > 1 {
                height.wrappedValue = clamped
            }
        }

        private static func findFormScrollView(in root: NSView, matching probe: NSView) -> NSScrollView? {
            let probeRect = probe.convert(probe.bounds, to: nil)
            var candidates: [NSScrollView] = []
            collectScrollViews(in: root, into: &candidates)
            return candidates.first { sv in
                guard !(sv.documentView is NSTableView) else { return false }
                let svRect = sv.convert(sv.bounds, to: nil)
                return svRect.intersects(probeRect.insetBy(dx: -4, dy: -4))
            }
        }

        private static func collectScrollViews(in view: NSView, into result: inout [NSScrollView]) {
            if let sv = view as? NSScrollView {
                result.append(sv)
            }
            for sub in view.subviews {
                collectScrollViews(in: sub, into: &result)
            }
        }
    }
}

struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = UserFocusedSearchField()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            if text.wrappedValue != sender.stringValue { text.wrappedValue = sender.stringValue }
        }
    }

    final class UserFocusedSearchField: NSSearchField {
        private var accessibilityRequestedFocus = false

        override func becomeFirstResponder() -> Bool {
            let requested = accessibilityRequestedFocus || currentEditor() != nil || isFocusEvent(NSApp.currentEvent)
            accessibilityRequestedFocus = false
            return requested && super.becomeFirstResponder()
        }

        override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
            if accessibilityFocused { accessibilityRequestedFocus = true }
            super.setAccessibilityFocused(accessibilityFocused)
        }

        override func accessibilityPerformPress() -> Bool {
            accessibilityRequestedFocus = true
            return window?.makeFirstResponder(self) ?? false
        }

        private func isFocusEvent(_ event: NSEvent?) -> Bool {
            guard let event, event.window === window else { return false }
            switch event.type {
            case .keyDown:
                return event.keyCode == 48
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                return bounds.contains(convert(event.locationInWindow, from: nil))
            default:
                return false
            }
        }
    }
}
