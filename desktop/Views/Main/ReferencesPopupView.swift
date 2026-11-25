import SwiftUI
import AppKit

struct ReferencesPopupView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedIndex = 0
    @State private var linePreviews: [String: String] = [:]
    @State private var contentHeight: CGFloat = 0
    @FocusState private var isFocused: Bool
    @State private var keyMonitor: Any? = nil

    private struct ContentHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var results: [LSPLocation] { workspace.referencesResults }
    private var resultsKeys: [String] { results.map { "\($0.uri):\($0.range.start.line):\($0.range.start.character)" } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(workspace.referencesPopupKind): \(workspace.referencesSymbolName)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if workspace.referencesPhase == .loaded {
                    Text(UserMessage.count(results.count, "result"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        workspace.openMultiBufferFromReferences(results, symbolName: workspace.referencesSymbolName)
                    } label: {
                        Label("Open in Multi-Buffer", systemImage: "rectangle.stack.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: [.option, .command])
                    .help("Open all references in the editable multi-buffer")
                }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.comfortable)

            Divider()

            if workspace.referencesPhase == .loading {
                VStack(spacing: Spacing.standard) {
                    HStack(spacing: Spacing.standard) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text("Finding \(workspace.referencesPopupKind.lowercased())…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if workspace.languageServerIsLoading {
                        Text("gopls is still loading the project, so this can take longer than usual.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.section)
                .padding(.vertical, Spacing.content)
                .accessibilityElement(children: .combine)
            } else if case .failed(let failure) = workspace.referencesPhase {
                NavigationFailureView(subject: workspace.referencesPopupKind.lowercased(), failure: failure) {
                    workspace.retryNavigationRequest()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.section)
                .padding(.vertical, Spacing.section)
            } else if results.isEmpty {
                Text("No \(workspace.referencesPopupKind.lowercased()) found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.content)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            ForEach(Array(results.enumerated()), id: \.offset) { index, loc in
                                let isSelected = index == selectedIndex
                                let fileName = (loc.path as NSString).lastPathComponent
                                let preview = linePreviews[previewKey(for: loc)] ?? ""
                                HStack(spacing: Spacing.standard) {
                                    FileIconView(fileName: fileName, path: loc.path, isSelected: isSelected, size: 16)

                                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                                        Text(preview.isEmpty ? fileName : preview)
                                            .font(.subheadline.weight(isSelected ? .medium : .regular).monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)

                                        Text("\(workspace.projectRelativePath(loc.path)):\(loc.range.start.line + 1)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Spacing.comfortable)
                                .padding(.vertical, Spacing.row)
                                .popupRow(isSelected: isSelected, onHoverSelect: {
                                    selectedIndex = index
                                }) {
                                    selectedIndex = index
                                    openSelected()
                                }
                                .id(index)
                            }
                        }
                        .padding(Spacing.standard)
                        .background(GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) })
                    }
                    .frame(height: min(max(contentHeight, 44), 320))
                    .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
                    .onChange(of: selectedIndex) { _, newValue in
                        guard !PopupMouseTracker.isHoverSelecting else { return }
                        if NSWorkspace.accessibilityReduceMotion {
                            proxy.scrollTo(newValue, anchor: .center)
                        } else {
                            withAnimation(Motion.quick) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .popupWidth(.medium)
        .floatingPanelBackground()
        .onAppear {
            PopupMouseTracker.markKeyboardOrOpen()
            selectedIndex = 0
            loadLinePreviews()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                if handleKeyDown(event) { return nil }
                return event
            }
        }
        .onChange(of: resultsKeys) { _, _ in
            PopupMouseTracker.markKeyboardOrOpen()
            selectedIndex = 0
            loadLinePreviews()
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            workspace.referencesPopupDidClose()
        }
    }

    private func previewKey(for loc: LSPLocation) -> String {
        "\(loc.path):\(loc.range.start.line)"
    }

    private func loadLinePreviews() {
        var previews: [String: String] = [:]
        let grouped = Dictionary(grouping: results, by: \.path)
        for (path, locs) in grouped {
            let neededLines = Set(locs.map { $0.range.start.line })
            let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if let session = workspace.documents[path] ?? workspace.documents[resolvedPath] {
                let ns = session.storage.string as NSString
                for line in neededLines {
                    if let range = session.lineRange(line) {
                        previews["\(path):\(line)"] = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let maxLine = neededLines.max() ?? 0
                var currentLine = 0
                text.enumerateLines { lineText, stop in
                    if neededLines.contains(currentLine) {
                        previews["\(path):\(currentLine)"] = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if currentLine >= maxLine {
                        stop = true
                    }
                    currentLine += 1
                }
            }
        }
        linePreviews = previews
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard workspace.showReferences else { return false }

        if event.keyCode == 53 {
            workspace.showReferences = false
            return true
        }
        if event.keyCode == 36 {
            switch workspace.referencesPhase {
            case .loaded:
                openSelected()
            case .failed:
                workspace.retryNavigationRequest()
            case .loading:
                return false
            }
            return true
        }
        if event.keyCode == 125 {
            PopupMouseTracker.markKeyboardOrOpen()
            if selectedIndex < results.count - 1 {
                selectedIndex += 1
            }
            return true
        }
        if event.keyCode == 126 {
            PopupMouseTracker.markKeyboardOrOpen()
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return true
        }
        return false
    }

    private func openSelected() {
        guard selectedIndex >= 0 && selectedIndex < results.count else { return }
        let loc = results[selectedIndex]
        workspace.jumpTo(filePath: loc.path, line: loc.range.start.line + 1, column: loc.range.start.character + 1)
        workspace.showReferences = false
    }
}

struct NavigationFailureView: View {
    let subject: String
    let failure: LSPRequestFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Spacing.standard) {
            HStack(spacing: Spacing.row) {
                Image(systemName: StatusTone.warning.symbol)
                    .foregroundStyle(StatusTone.warning.tint)
                    .accessibilityHidden(true)
                Text("Couldn’t load \(subject).")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Text(failure.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry", action: retry)
                .controlSize(.small)
                .help("Ask the language server again (Return)")
        }
        .accessibilityElement(children: .contain)
    }
}
