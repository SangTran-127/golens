import SwiftUI
import AppKit

enum HTTPResponseSection: String, CaseIterable, Identifiable {
    case body = "Body"
    case headers = "Headers"
    case tests = "Tests"
    case request = "Request"

    var id: String { rawValue }
}

struct ReadOnlyCodeView: NSViewRepresentable {
    let text: String
    var background: NSColor = .textBackgroundColor
    var foreground: NSColor = .labelColor

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Response Text")
        apply(to: textView, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        apply(to: textView, scroll: scroll)
    }

    private func apply(to textView: NSTextView, scroll: NSScrollView) {
        scroll.backgroundColor = background
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.font = TechnicalTypography.codeCanvasNSFont(size: 13, weight: .regular)
        if textView.string != text {
            textView.string = text
            textView.scrollToBeginningOfDocument(nil)
        }
    }
}

struct HTTPResponsesView: View {
    @Environment(\.windowWorkspace) private var workspace
    @State private var section: HTTPResponseSection = .body

    var body: some View {
        if workspace.http.entries.isEmpty {
            emptyState
        } else {
            PanelListDetail {
                HTTPHistoryList(workspace: workspace)
            } detail: {
                if let entry = workspace.http.selectedEntry {
                    HTTPEntryDetailView(workspace: workspace, entry: entry, section: $section)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Requests Run", systemImage: "network")
        } description: {
            if workspace.isActiveFileHTTP {
                Text("Place the cursor in a request and run it. Its status, headers, body and test results appear here.")
            } else {
                Text("Requests live in .http files you can commit with your code. Create one, then choose Run Request above a request.")
            }
        } actions: {
            if workspace.isActiveFileHTTP {
                Button("Run Request at Cursor") { workspace.runHTTPRequestAtCaret() }
                    .disabled(!workspace.canRunHTTPRequestAtCaret)
            } else {
                Button("New HTTP Request File") { workspace.newHTTPRequestFile() }
                    .disabled(workspace.activeWorkspacePath.isEmpty)
            }
        }
    }
}

struct HTTPOutcomeSymbol: View {
    let entry: HTTPRunEntry

    var body: some View {
        Group {
            if entry.isRunning {
                ProgressView().controlSize(.mini)
            } else if entry.isSuccess {
                Image(systemName: StatusTone.success.symbol).foregroundStyle(StatusTone.success.tint)
            } else if entry.isFailure {
                Image(systemName: StatusTone.failure.symbol).foregroundStyle(StatusTone.failure.tint)
            } else {
                Image(systemName: StatusTone.inactive.symbol).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(width: 16)
        .accessibilityLabel(entry.isRunning ? "Running" : entry.isSuccess ? "Passed" : entry.isFailure ? "Failed" : "Finished")
    }
}

struct HTTPHistoryList: View {
    @Bindable var workspace: WorkspaceState

    private var groups: [(key: String, entries: [HTTPRunEntry])] {
        var order: [String] = []
        var map: [String: [HTTPRunEntry]] = [:]
        for entry in workspace.http.entries {
            if map[entry.requestKey] == nil { order.append(entry.requestKey) }
            map[entry.requestKey, default: []].append(entry)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        List(selection: Binding(
            get: { workspace.http.selectedEntry?.id },
            set: { workspace.http.selectedEntryID = $0 }
        )) {
            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.entries) { entry in
                        HStack(spacing: Spacing.standard) {
                            HTTPOutcomeSymbol(entry: entry)
                            Text(rowTitle(entry))
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(HTTPFormat.time(entry.startedAt))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(entry.id)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    let first = group.entries.first
                    Text(first?.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    .help(first.map { "\($0.title) in \($0.path)" } ?? "")
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Request History")
    }

    private func rowTitle(_ entry: HTTPRunEntry) -> String {
        if entry.isRunning { return "Running…" }
        if let response = entry.response, entry.error == nil {
            var text = response.statusLabel + " · " + HTTPFormat.duration(response.timing.totalMs)
            if !entry.tests.isEmpty {
                text += " · \(entry.tests.count - entry.failedTests)/\(entry.tests.count)"
            }
            return text
        }
        return entry.summary
    }
}

struct HTTPEntryDetailView: View {
    @Bindable var workspace: WorkspaceState
    let entry: HTTPRunEntry
    @Binding var section: HTTPResponseSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Spacing.comfortable)
                .padding(.vertical, Spacing.standard)
            Divider()
            if entry.isRunning {
                runningState
            } else if let error = entry.error {
                HTTPRunErrorView(workspace: workspace, entry: entry, error: error)
            } else if let response = entry.response {
                responseContent(response)
            }
        }
    }

    private var displayURL: String {
        entry.request?.url ?? entry.rawURL
    }

    private var header: some View {
        HStack(spacing: Spacing.standard) {
            Text(entry.method)
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.secondary)
            Text(displayURL)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(displayURL)
            Spacer(minLength: 8)
            if let environment = entry.environment {
                Label(environment, systemImage: "globe")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .help("Environment: \(environment)")
            }
            Button {
                workspace.jumpToLocation(path: entry.path, line: max(1, entry.request?.line ?? 1))
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help("Go to Request in \((entry.path as NSString).lastPathComponent)")
            .accessibilityLabel("Go to Request")

            if entry.isRunning {
                Button {
                    workspace.stopHTTPRequest(runID: entry.runID)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.small)
                .help("Stop this request")
            } else {
                Button {
                    workspace.runHTTPRequest(path: entry.path, index: entry.requestIndex)
                } label: {
                    Label("Run Again", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(workspace.http.runningRunIDs[entry.requestKey] != nil)
                .help("Run this request again with the current environment and variables")
            }
        }
    }

    private var runningState: some View {
        VStack(spacing: Spacing.standard) {
            ProgressView().controlSize(.small)
            Text("Waiting for \(hostLabel)…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Stop Request") { workspace.stopHTTPRequest(runID: entry.runID) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hostLabel: String {
        let raw = displayURL.contains("://") ? displayURL : "http://" + displayURL
        return URL(string: raw)?.host ?? displayURL
    }

    @ViewBuilder
    private func responseContent(_ response: HTTPResponseDTO) -> some View {
        HStack(spacing: Spacing.comfortable) {
            statusBadge(response)
            Label(HTTPFormat.duration(response.timing.totalMs), systemImage: "clock")
                .help(timingHelp(response.timing))
            Label(HTTPFormat.bytes(response.size), systemImage: "arrow.down.circle")
                .help(response.truncated ? "GoLens kept the first 8 MB of the response." : "Response body size")
            if !entry.tests.isEmpty || entry.scriptError != nil {
                testsBadge
            }
            Spacer(minLength: 8)
            Picker("Section", selection: $section) {
                Text("Body").tag(HTTPResponseSection.body)
                Text("Headers (\(response.headers.count))").tag(HTTPResponseSection.headers)
                Text(entry.tests.isEmpty ? "Tests" : "Tests (\(entry.tests.count))").tag(HTTPResponseSection.tests)
                Text("Request").tag(HTTPResponseSection.request)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        Divider()
        switch section {
        case .body:
            VStack(spacing: 0) {
                if response.truncated {
                    notice("The response is larger than 8 MB. GoLens shows the first 8 MB.")
                }
                if response.body.isEmpty {
                    Text("The response has no body.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ReadOnlyCodeView(text: response.displayBody)
                }
            }
        case .headers:
            ReadOnlyCodeView(text: response.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
        case .tests:
            HTTPTestsView(workspace: workspace, entry: entry)
        case .request:
            ReadOnlyCodeView(text: requestText)
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: StatusTone.warning.symbol)
                .foregroundStyle(StatusTone.warning.tint)
                .accessibilityHidden(true)
            Text(text).font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }

    private var requestText: String {
        guard let request = entry.request else { return "" }
        var lines = ["\(request.method) \(request.url)"]
        lines += request.headers.map { "\($0.name): \($0.value)" }
        if !request.body.isEmpty {
            lines.append("")
            lines.append(request.body)
        }
        return lines.joined(separator: "\n")
    }

    private func statusBadge(_ response: HTTPResponseDTO) -> some View {
        let color: Color = response.isSuccess ? StatusTone.success.tint : (response.isGRPC || response.status >= 400 ? StatusTone.failure.tint : .secondary)
        return HStack(spacing: Spacing.compact) {
            Image(systemName: response.isSuccess ? StatusTone.success.symbol : (response.isGRPC || response.status >= 400 ? StatusTone.failure.symbol : "arrow.turn.up.right"))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(response.statusLabel)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status \(response.statusLabel)")
        .help(response.protocol)
    }

    private var testsBadge: some View {
        let failed = entry.failedTests
        let failing = failed > 0 || entry.scriptError != nil
        let text: String
        if entry.scriptError != nil {
            text = "Handler error"
        } else if failed == 0 {
            text = entry.tests.count == 1 ? "1 test passed" : "\(entry.tests.count) tests passed"
        } else {
            text = "\(failed) of \(entry.tests.count) failed"
        }
        return Button {
            section = .tests
        } label: {
            Label {
                Text(text).foregroundStyle(.primary)
            } icon: {
                Image(systemName: failing ? StatusTone.failure.symbol : StatusTone.success.symbol)
                    .foregroundStyle(failing ? StatusTone.failure.tint : StatusTone.success.tint)
            }
        }
        .buttonStyle(.borderless)
        .help("Show test results")
    }

    private func timingHelp(_ t: HTTPTimingDTO) -> String {
        var parts: [String] = []
        if t.dnsMs > 0 { parts.append("DNS \(t.dnsMs) ms") }
        if t.connectMs > 0 { parts.append("Connect \(t.connectMs) ms") }
        if t.tlsMs > 0 { parts.append("TLS \(t.tlsMs) ms") }
        parts.append("First byte \(t.firstByteMs) ms")
        parts.append("Total \(t.totalMs) ms")
        return parts.joined(separator: ", ")
    }
}

struct HTTPTestsView: View {
    @Bindable var workspace: WorkspaceState
    let entry: HTTPRunEntry

    var body: some View {
        if entry.tests.isEmpty && entry.scriptError == nil && entry.logs.isEmpty {
            ContentUnavailableView {
                Label("No Tests", systemImage: "checklist")
            } description: {
                Text("Add a response handler below the request to check the response, for example:\n> {% client.test(\"OK\", function () { client.assert(response.status === 200) }) %}")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    if let error = entry.scriptError {
                        HStack(alignment: .top, spacing: Spacing.standard) {
                            Image(systemName: StatusTone.warning.symbol)
                                .foregroundStyle(StatusTone.failure.tint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text("The response handler stopped with an error.")
                                    .font(.callout.weight(.semibold))
                                Text(entry.scriptErrorLine.map { "\(error) (line \($0) of the handler)" } ?? error)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                if let line = entry.handlerLine {
                                    Button("Show Handler") {
                                        workspace.jumpToLocation(path: entry.path, line: line)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    if !entry.tests.isEmpty {
                        Text(summary)
                            .font(.callout.weight(.semibold))
                        ForEach(entry.tests) { test in
                            testRow(test)
                        }
                    }
                    if !entry.logs.isEmpty {
                        Text("Log")
                            .font(.callout.weight(.semibold))
                            .padding(.top, Spacing.standard)
                        Text(entry.logs.joined(separator: "\n"))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.comfortable)
            }
        }
    }

    private var summary: String {
        let failed = entry.failedTests
        let total = entry.tests.count
        if failed == 0 { return total == 1 ? "1 test passed" : "All \(total) tests passed" }
        return "\(failed) of \(total) tests failed"
    }

    private func testRow(_ test: HTTPTestResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: test.passed ? StatusTone.success.symbol : StatusTone.failure.symbol)
                    .foregroundStyle(test.passed ? StatusTone.success.tint : StatusTone.failure.tint)
                    .accessibilityHidden(true)
                Text(test.name)
                    .font(.callout.weight(.medium))
                if !test.passed && !test.message.isEmpty && test.assertions.isEmpty {
                    Text(test.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(test.passed ? "Passed" : "Failed"): \(test.name)\(test.passed || test.message.isEmpty ? "" : ", \(test.message)")")
            ForEach(Array(test.assertions.enumerated()), id: \.offset) { _, assertion in
                HStack(spacing: Spacing.standard) {
                    Image(systemName: assertion.passed ? "checkmark" : "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(assertion.passed ? StatusTone.success.tint : StatusTone.failure.tint)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(assertion.message)
                        .font(.callout)
                        .foregroundStyle(assertion.passed ? .secondary : .primary)
                }
                .padding(.leading, Spacing.content)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(assertion.passed ? "Passed" : "Failed") assertion: \(assertion.message)")
            }
            if !test.passed, !test.assertions.contains(where: { !$0.passed }), !test.message.isEmpty, !test.assertions.isEmpty {
                Text(test.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Spacing.content)
            }
        }
    }
}

struct HTTPRunErrorView: View {
    @Bindable var workspace: WorkspaceState
    let entry: HTTPRunEntry
    let error: HTTPRunErrorDTO

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: Spacing.comfortable) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(error.kind == "cancelled" ? Color.secondary : StatusTone.failure.tint)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text(error.message)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let detail = error.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: Spacing.standard) {
                        actions
                    }
                    .controlSize(.small)
                    .padding(.top, Spacing.compact)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.section)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var symbol: String {
        switch error.kind {
        case "unresolved": return "curlybraces"
        case "network", "grpc": return "network.slash"
        case "timeout": return "clock.badge.exclamationmark"
        case "file": return "doc.questionmark"
        case "cancelled": return "stop.circle"
        default: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private var actions: some View {
        let outline = workspace.http.outlines[entry.path] ?? .empty
        if error.kind == "unresolved" {
            if !outline.environments.names.isEmpty {
                Menu("Choose Environment") {
                    HTTPEnvironmentMenuItems(workspace: workspace, path: entry.path)
                }
                .fixedSize()
            }
            Button(outline.environments.publicFile == nil ? "Create Environment File" : "Open Environment File") {
                workspace.openOrCreateHTTPEnvironmentFile(for: entry.path)
            }
        }
        if error.kind == "network", !workspace.activeWorkspacePath.isEmpty, !workspace.isRunning {
            Button("Run Project") { workspace.runProject() }
        }
        Button("Run Again") {
            workspace.runHTTPRequest(path: entry.path, index: entry.requestIndex)
        }
        .disabled(workspace.http.runningRunIDs[entry.requestKey] != nil)
    }
}
