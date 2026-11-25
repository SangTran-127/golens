import SwiftUI
import AppKit
import GoLensFoundation

struct FileHistorySheetView: View {
    @Bindable var model: FileHistoryModel
    let close: () -> Void
    @Environment(\.windowWorkspace) private var workspace
    @FocusState private var listFocused: Bool
    @State private var openFailed = false
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footerBar
        }
        .sheetFrame(.splitInspector)
        .onExitCommand(perform: close)
        .alert("Couldn’t Open This Version", isPresented: $openFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Git could not read the file at this commit.")
        }
    }

    private var headerBar: some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text("File History — \(model.fileName)")
                    .font(.body.weight(.semibold))
                Text(model.relativePath.isEmpty ? workspace.projectRelativePath(model.filePath) : model.relativePath)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if model.loadState == .loaded {
                Text(commitCountText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.standard)
    }

    private var commitCountText: String {
        let count = model.entries.count
        let noun = count == 1 ? "commit" : "commits"
        return model.hasMore ? "\(count)+ \(noun)" : "\(count) \(noun)"
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView("Loading history…")
                .controlSize(.small)
        case .notInRepository:
            ContentUnavailableView(
                "Not in a Git Repository",
                systemImage: "folder.badge.questionmark",
                description: Text("“\(model.fileName)” isn’t inside a Git repository, so it has no commit history.")
            )
        case .untracked:
            ContentUnavailableView(
                "No History Yet",
                systemImage: "doc.badge.clock",
                description: Text("“\(model.fileName)” isn’t tracked by Git. Commit it to start its history.")
            )
        case .noCommits:
            ContentUnavailableView(
                "No Commits Yet",
                systemImage: "doc.badge.clock",
                description: Text("“\(model.fileName)” is staged but hasn’t been committed.")
            )
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load History", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
            }
        case .loaded:
            HStack(spacing: 0) {
                commitList
                Divider()
                detailPane
            }
        }
    }

    private var commitList: some View {
        List(selection: $model.selectedHash) {
            ForEach(model.entries) { entry in
                GitRevisionRow(
                    subject: entry.subject,
                    author: entry.author,
                    date: entry.date,
                    relativeDateText: Self.relativeDate(entry),
                    shortHash: entry.shortHash,
                    renamedFrom: entry.isRename ? entry.previousPath : nil,
                    customAccessibilityLabel: Self.accessibilityLabel(entry)
                )
                .tag(entry.hash)
            }
            if model.hasMore {
                HStack(spacing: Spacing.standard) {
                    if model.isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading more commits…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Load More Commits") {
                            Task { await model.loadMore() }
                        }
                        .buttonStyle(.link)
                        .font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.compact)
                .selectionDisabled()
                .onAppear {
                    Task { await model.loadMore() }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 288)
        .focused($listFocused)
        .contextMenu(forSelectionType: String.self) { hashes in
            if let hash = hashes.first, let entry = model.entries.first(where: { $0.hash == hash }) {
                Button("Copy Commit Hash", systemImage: "number") { model.copyHash(entry) }
                Button("Open File at This Version", systemImage: "doc.text") { openVersion(entry) }
                Button("Compare with Current", systemImage: "arrow.left.arrow.right") {
                    model.selectedHash = entry.hash
                    model.diffMode = .compareWithCurrent
                }
            }
        } primaryAction: { hashes in
            if let hash = hashes.first, let entry = model.entries.first(where: { $0.hash == hash }) {
                openVersion(entry)
            }
        }
        .onAppear { listFocused = true }
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = model.selectedEntry {
                detailHeader(entry)
                Divider()
                diffBody
            } else {
                ContentUnavailableView("No Commit Selected", systemImage: "clock", description: Text("Select a commit to see how it changed this file."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailHeader(_ entry: FileHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(entry.subject.isEmpty ? "(no message)" : entry.subject)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("\(entry.author) · \(Self.absoluteDate(entry)) · \(entry.shortHash)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if entry.path != model.relativePath {
                    Text("Path at this commit: \(entry.path)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: Spacing.standard) {
                Picker("Diff", selection: $model.diffMode) {
                    ForEach(FileHistoryModel.DiffMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Diff")
                Spacer()
                if !model.isLoadingDiff, model.diffAdded + model.diffRemoved > 0 {
                    HStack(spacing: Spacing.row) {
                        Text("+\(model.diffAdded)")
                            .foregroundStyle(StatusTone.success.tint)
                        Text("−\(model.diffRemoved)")
                            .foregroundStyle(StatusTone.failure.tint)
                    }
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(model.diffAdded) \(model.diffAdded == 1 ? "line" : "lines") added, \(model.diffRemoved) \(model.diffRemoved == 1 ? "line" : "lines") removed")
                }
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.standard)
    }

    @ViewBuilder
    private var diffBody: some View {
        if model.isLoadingDiff && model.diffItems.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else if let notice = model.diffNotice, model.diffItems.isEmpty {
            Text(notice)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(Spacing.section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            UnifiedDiffTextView(
                items: model.diffItems,
                estimatedWidth: model.diffEstimatedWidth,
                resetKey: "\(model.selectedHash ?? "")|\(model.diffMode)",
                scrollerAccessibilityLabel: "History Diff Horizontal Scrollbar"
            )
        }
    }

    private var footerBar: some View {
        HStack(spacing: Spacing.standard) {
            if let entry = model.selectedEntry {
                Button("Copy Commit Hash") { model.copyHash(entry) }
                    .help("Copy the full hash of \(entry.shortHash)")
            }
            Spacer()
            Button("Close", action: close)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
            if let entry = model.selectedEntry {
                Button("Open This Version") { openVersion(entry) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .help("Open \(model.fileName) as of \(entry.shortHash) in a read-only tab")
            }
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.standard)
    }

    private func openVersion(_ entry: FileHistoryEntry) {
        Task {
            if await model.openVersion(entry) {
                close()
            } else {
                openFailed = true
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func relativeDate(_ entry: FileHistoryEntry) -> String {
        guard let date = entry.date else { return entry.gitRelativeDate }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func absoluteDate(_ entry: FileHistoryEntry) -> String {
        guard let date = entry.date else { return entry.gitRelativeDate }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func accessibilityLabel(_ entry: FileHistoryEntry) -> String {
        var parts = [entry.subject.isEmpty ? "No message" : entry.subject, "by \(entry.author)", relativeDate(entry), "commit \(entry.shortHash)"]
        if let previous = entry.previousPath, entry.isRename {
            parts.append("renamed from \(previous)")
        }
        return parts.joined(separator: ", ")
    }
}
