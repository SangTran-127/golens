import SwiftUI
import AppKit
import GoLensFoundation

struct MarkdownPreviewView: View {
    let filePath: String
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = MarkdownPreviewModel()
    @State private var undoFocusTrigger: Int = 0

    private var refreshKey: MarkdownPreviewModel.RefreshKey {
        MarkdownPreviewModel.RefreshKey(
            path: filePath,
            isEdited: workspace.editedFiles.contains(filePath),
            isLoaded: workspace.loadedDocuments.contains(filePath),
            session: workspace.documents[filePath].map(ObjectIdentifier.init)
        )
    }

    private var baseDirectory: String {
        (filePath as NSString).deletingLastPathComponent
    }

    var body: some View {
        let isDark = workspace.currentTheme.resolvedIsDark
        let snapshot = model.snapshot.flatMap { $0.path == filePath ? $0 : nil }
        let parsedDocument = snapshot?.document ?? MarkdownParsedDocument(blocks: [], headings: [])
        let lineCount = snapshot?.lineCount ?? 1
        let wordCount = snapshot?.wordCount ?? 0

        let primaryText = ThemeColor.textPrimary
        let secondaryText = ThemeColor.textSecondary

        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                previewHeaderBar(
                    headings: parsedDocument.headings,
                    lineCount: lineCount,
                    wordCount: wordCount,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    scrollProxy: scrollProxy
                )

                Divider()

                ScrollView(.vertical, showsIndicators: true) {
                    if snapshot == nil {
                        Color.clear
                    } else if parsedDocument.blocks.isEmpty {
                        emptyMarkdownState(secondaryText: secondaryText)
                    } else {
                        LazyVStack(alignment: .leading, spacing: Spacing.section) {
                            ForEach(parsedDocument.blocks) { block in
                                MarkdownBlockRendererView(
                                    block: block,
                                    filePath: filePath,
                                    baseDirectory: baseDirectory,
                                    isDark: isDark,
                                    primaryText: primaryText,
                                    secondaryText: secondaryText,
                                    workspace: workspace,
                                    onSelectAnchor: { anchorSlug in
                                        scrollToHeadingSlug(anchorSlug, headings: parsedDocument.headings, proxy: scrollProxy)
                                    },
                                    onToggleTaskLine: { lineIndex in
                                        toggleTaskItem(atLineIndex: lineIndex)
                                    }
                                )
                                .id(block.id)
                            }
                        }
                        .padding(.horizontal, Spacing.content)
                        .padding(.vertical, Spacing.content)
                        .frame(maxWidth: 920, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .background(ThemeColor.contentSurface)
            }
            .background(ThemeColor.contentSurface)
            .environment(\.openURL, OpenURLAction { url in
                handleMarkdownURL(url, headings: parsedDocument.headings, scrollProxy: scrollProxy)
                return .handled
            })
        }
        .background(
            MarkdownUndoResponderBridge(filePath: filePath, focusTrigger: undoFocusTrigger)
                .frame(width: 0, height: 0)
        )
        .onAppear {
            if workspace.documents[filePath] == nil, FileManager.default.fileExists(atPath: filePath) {
                workspace.loadDocument(filePath)
            }
            model.refresh(path: filePath, session: workspace.documents[filePath], debounce: false, workspace: workspace)
        }
        .onChange(of: refreshKey) {
            model.refresh(path: filePath, session: workspace.documents[filePath], debounce: false, workspace: workspace)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { note in
            if let session = workspace.documents[filePath], note.object as AnyObject? === session.undoManager {
                model.refresh(path: filePath, session: session, debounce: false, workspace: workspace)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { note in
            if let session = workspace.documents[filePath], note.object as AnyObject? === session.undoManager {
                model.refresh(path: filePath, session: session, debounce: false, workspace: workspace)
            }
        }
    }

    @ViewBuilder
    private func previewHeaderBar(
        headings: [MarkdownHeadingOutlineItem],
        lineCount: Int,
        wordCount: Int,
        primaryText: Color,
        secondaryText: Color,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        HStack(spacing: Spacing.inset) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "doc.richtext")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(primaryText)
            }

            Divider()
                .frame(height: 14)

            Menu {
                if headings.isEmpty {
                    Text("No Headings in Document")
                } else {
                    ForEach(headings) { item in
                        Button {
                            withAnimation(reduceMotion ? nil : Motion.quick) {
                                scrollProxy.scrollTo(item.blockID, anchor: .top)
                            }
                        } label: {
                            let indent = String(repeating: "  ", count: max(0, item.level - 1))
                            Text("\(indent)H\(item.level) · \(item.title)")
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "list.bullet.indent")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(headings.first?.title ?? "Document Outline (\(headings.count))")
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(secondaryText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("Document Outline")
            .help("Jump to heading section in Markdown document")

            Spacer()

            Text("\(lineCount) lines • \(wordCount) words")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(secondaryText)
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.hairline)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                )

            Button {
                workspace.markdownPreviewMode[filePath] = false
            } label: {
                HStack(spacing: Spacing.compact) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("Edit Source")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(primaryText)
                .padding(.horizontal, Spacing.standard)
                .padding(.vertical, Spacing.hairline)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: Stroke.standard)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Source")
            .help("Switch to Markdown source editor")
        }
        .padding(.horizontal, Spacing.comfortable)
        .frame(height: 28)
        .background(ThemeColor.panelSurface)
    }

    @ViewBuilder
    private func emptyMarkdownState(secondaryText: Color) -> some View {
        VStack(spacing: Spacing.inset) {
            Image(systemName: "doc.text")
                .font(.title2)
                .foregroundStyle(secondaryText)
                .accessibilityHidden(true)
            Text("This Markdown document is empty.")
                .font(.callout)
                .foregroundStyle(secondaryText)
            Button("Edit Source") {
                workspace.markdownPreviewMode[filePath] = false
            }
            .buttonStyle(.link)
            .help("Switch to source editor to start writing Markdown")
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func scrollToHeadingSlug(
        _ slug: String,
        headings: [MarkdownHeadingOutlineItem],
        proxy: ScrollViewProxy
    ) {
        let normalized = GFMParser.slugify(slug.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        if let match = headings.first(where: { $0.slug == normalized || $0.blockID == slug }) {
            withAnimation(reduceMotion ? nil : Motion.quick) {
                proxy.scrollTo(match.blockID, anchor: .top)
            }
        }
    }

    private func handleMarkdownURL(
        _ url: URL,
        headings: [MarkdownHeadingOutlineItem],
        scrollProxy: ScrollViewProxy
    ) {
        let target: String
        if url.scheme == "golens-md-link",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let rawTarget = comps.queryItems?.first(where: { $0.name == "target" })?.value {
            target = rawTarget
        } else {
            target = url.absoluteString
        }

        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("#") {
            scrollToHeadingSlug(trimmed, headings: headings, proxy: scrollProxy)
            return
        }

        if trimmed.lowercased().hasPrefix("http://")
            || trimmed.lowercased().hasPrefix("https://")
            || trimmed.lowercased().hasPrefix("mailto:") {
            if let externalURL = URL(string: trimmed) {
                NSWorkspace.shared.open(externalURL)
            }
            return
        }

        var pathPart = trimmed
        var lineFragment: Int? = nil

        if pathPart.hasPrefix("file://"), let fileURL = URL(string: pathPart) {
            pathPart = fileURL.path
            if let frag = fileURL.fragment {
                lineFragment = Self.parseLineFragment(frag)
            }
        } else if let hashIndex = pathPart.firstIndex(of: "#") {
            let frag = String(pathPart[pathPart.index(after: hashIndex)...])
            pathPart = String(pathPart[..<hashIndex])
            lineFragment = Self.parseLineFragment(frag)
        }

        let decodedPath = pathPart.removingPercentEncoding ?? pathPart
        let resolvedURL: URL
        if decodedPath.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: decodedPath).standardized
        } else {
            resolvedURL = URL(fileURLWithPath: baseDirectory)
                .appendingPathComponent(decodedPath)
                .standardized
        }

        let resolvedPath = resolvedURL.path
        if FileManager.default.fileExists(atPath: resolvedPath) {
            if let line = lineFragment {
                workspace.jumpTo(filePath: resolvedPath, line: line, column: 1)
            } else {
                workspace.openFile(resolvedPath)
            }
        } else if let fallbackURL = URL(string: trimmed), fallbackURL.scheme != nil {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    private static func parseLineFragment(_ fragment: String) -> Int? {
        let upper = fragment.uppercased()
        let digits: String
        if upper.hasPrefix("L") {
            digits = String(upper.dropFirst().prefix(while: { $0.isNumber }))
        } else {
            digits = String(upper.prefix(while: { $0.isNumber }))
        }
        return Int(digits)
    }

    private func toggleTaskItem(atLineIndex lineIndex: Int) {
        if workspace.documents[filePath] == nil, FileManager.default.fileExists(atPath: filePath) {
            workspace.loadDocument(filePath)
        }
        guard let session = workspace.documents[filePath],
              let edit = MarkdownTaskToggle.edit(in: session.storage.string, atZeroBasedLine: lineIndex) else {
            return
        }
        workspace.applyRanges([(edit.range, edit.replacement)], in: session, actionName: "Toggle Task")
        if let textView = workspace.textView(showing: session), let window = textView.window {
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        } else {
            undoFocusTrigger &+= 1
        }
        model.refresh(path: filePath, session: session, debounce: false, workspace: workspace)
    }
}

private struct MarkdownUndoResponderBridge: NSViewRepresentable {
    let filePath: String
    let focusTrigger: Int

    func makeNSView(context: Context) -> UndoBridgeNSView {
        let view = UndoBridgeNSView()
        view.filePath = filePath
        return view
    }

    func updateNSView(_ nsView: UndoBridgeNSView, context: Context) {
        nsView.filePath = filePath
        if nsView.lastFocusTrigger != focusTrigger {
            nsView.lastFocusTrigger = focusTrigger
            if focusTrigger > 0, let window = nsView.window {
                window.makeFirstResponder(nsView)
            }
        }
    }

    final class UndoBridgeNSView: NSView {
        var filePath: String = ""
        var lastFocusTrigger: Int = 0

        override var acceptsFirstResponder: Bool { true }

        override var undoManager: UndoManager? {
            WorkspaceState.owning(window: window).documents[filePath]?.undoManager ?? super.undoManager
        }
    }
}

struct MarkdownPreviewSnapshot {
    let path: String
    let document: MarkdownParsedDocument
    let lineCount: Int
    let wordCount: Int

    init(path: String, text: String) {
        self.path = path
        document = GFMParser.parseDocument(text)
        var lines = 1
        var words = 0
        var inWord = false
        for character in text {
            if character.isWhitespace || character.isNewline {
                inWord = false
                for scalar in character.unicodeScalars {
                    switch scalar.value {
                    case 0x0A...0x0D, 0x85, 0x2028, 0x2029: lines += 1
                    default: break
                    }
                }
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        lineCount = lines
        wordCount = words
    }
}

@MainActor
@Observable
final class MarkdownPreviewModel {
    struct RefreshKey: Equatable {
        let path: String
        let isEdited: Bool
        let isLoaded: Bool
        let session: ObjectIdentifier?
    }

    private(set) var snapshot: MarkdownPreviewSnapshot?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private weak var observedStorage: NSTextStorage?
    @ObservationIgnored private weak var builtSession: DocumentSession?
    @ObservationIgnored private var builtVersion = -1
    @ObservationIgnored private var path = ""
    @ObservationIgnored private weak var workspace: WorkspaceState?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        work?.cancel()
    }

    func refresh(path: String, session: DocumentSession?, debounce: Bool, workspace: WorkspaceState) {
        self.workspace = workspace
        self.path = path
        observe(session)
        work?.cancel()
        work = nil
        if let session {
            if debounce {
                work = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    guard !Task.isCancelled, let self, let session = self.builtSessionCandidate(path) else { return }
                    if self.isCurrent(session) { return }
                    await self.build(path: path, session: session, text: session.storage.string, version: session.version)
                }
            } else if isCurrent(session) {
                return
            } else if snapshot?.path != path {
                apply(MarkdownPreviewSnapshot(path: path, text: session.storage.string), session: session, version: session.version)
            } else {
                let text = session.storage.string
                let version = session.version
                work = Task { [weak self] in await self?.build(path: path, session: session, text: text, version: version) }
            }
        } else {
            builtSession = nil
            builtVersion = -1
            work = Task { [weak self] in
                let built = await Task.detached(priority: .userInitiated) {
                    MarkdownPreviewSnapshot(path: path, text: (try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
                }.value
                guard !Task.isCancelled, let self, self.path == path else { return }
                self.snapshot = built
            }
        }
    }

    private func isCurrent(_ session: DocumentSession) -> Bool {
        snapshot?.path == session.path && builtSession === session && builtVersion == session.version
    }

    private func builtSessionCandidate(_ path: String) -> DocumentSession? {
        guard self.path == path, let storage = observedStorage else { return nil }
        let session = workspace?.documents[path]
        return session?.storage === storage ? session : nil
    }

    private func build(path: String, session: DocumentSession, text: String, version: Int) async {
        let built = await Task.detached(priority: .userInitiated) {
            MarkdownPreviewSnapshot(path: path, text: text)
        }.value
        guard !Task.isCancelled, self.path == path else { return }
        apply(built, session: session, version: version)
    }

    private func apply(_ built: MarkdownPreviewSnapshot, session: DocumentSession, version: Int) {
        builtSession = session
        builtVersion = version
        snapshot = built
    }

    private func observe(_ session: DocumentSession?) {
        let storage = session?.storage
        if observedStorage === storage, observer != nil || storage == nil { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        observedStorage = storage
        guard let storage else { return }
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] note in
            guard Thread.isMainThread, let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                guard let self, let workspace = self.workspace, let session = self.builtSessionCandidate(self.path) else { return }
                self.refresh(path: self.path, session: session, debounce: true, workspace: workspace)
            }
        }
    }
}
