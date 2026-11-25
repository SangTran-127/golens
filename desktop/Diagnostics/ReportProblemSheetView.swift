import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ReportProblemModel {
    var items: [DiagnosticItem] = []
    var expandedIDs: Set<String> = ["system"]
    var isLoading = true
    var isExporting = false
    var statusMessage: String?
    var statusTone: StatusTone?
    private var logEnrichmentTask: Task<Void, Never>?

    var includedItems: [DiagnosticItem] {
        DiagnosticsArchiveExporter.includedItems(from: items)
    }

    var totalIncludedBytes: Int {
        includedItems.reduce(0) { $0 + $1.byteCount }
    }

    func load() async {
        logEnrichmentTask?.cancel()
        isLoading = true
        statusMessage = nil
        statusTone = nil
        let collected = await DiagnosticsCollector.collectInitial()
        items = collected
        if let first = collected.first, expandedIDs.isEmpty {
            expandedIDs = [first.id]
        }
        isLoading = false

        logEnrichmentTask = Task {
            let fullLogs = await DiagnosticsCollector.collectFullLogs()
            guard !Task.isCancelled else { return }
            mergeLogs(fullLogs)
        }
    }

    private func mergeLogs(_ fullLogs: String) {
        guard let index = items.firstIndex(where: { $0.id == "logs" }) else { return }
        let existing = items[index]
        items[index] = DiagnosticItem(
            id: existing.id,
            title: existing.title,
            filename: existing.filename,
            summary: existing.summary,
            content: fullLogs,
            isIncluded: existing.isIncluded
        )
    }

    func setIncluded(_ included: Bool, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isIncluded = included
    }

    func toggleExpanded(id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
        }
    }

    func removeItem(id: String) {
        items.removeAll { $0.id == id }
        expandedIDs.remove(id)
        statusMessage = nil
        statusTone = nil
    }
}

struct ReportProblemSheetView: View {
    @State private var model = ReportProblemModel()
    let onClose: () -> Void

    var body: some View {
        StandardSheetShell(
            title: "Report a Problem",
            subtitle: "Review redacted local diagnostics before saving an archive. Nothing leaves your Mac automatically.",
            size: .inspector,
            primaryTitle: "Save Archive…",
            primaryAccessibilityLabel: "Save Diagnostics Archive",
            isPrimaryDisabled: model.isLoading || model.isExporting || model.includedItems.isEmpty,
            closeTitle: "Close",
            closeAccessibilityLabel: "Close Report a Problem",
            onPrimary: saveArchive,
            onClose: onClose,
            headerTrailing: {
                EmptyView()
            },
            footerLeading: {
                HStack(spacing: Spacing.standard) {
                    if let statusMessage = model.statusMessage {
                        HStack(spacing: Spacing.compact) {
                            if let tone = model.statusTone {
                                Image(systemName: tone.symbol)
                                    .foregroundStyle(tone.tint)
                                    .accessibilityHidden(true)
                            }
                            Text(statusMessage)
                                .font(.callout)
                                .foregroundStyle(model.statusTone == .failure ? StatusTone.failure.tint : ChromeColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            },
            content: {
                sheetContent
            }
        )
        .task {
            await model.load()
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if model.isLoading {
            VStack(spacing: Spacing.comfortable) {
                ProgressView()
                Text("Collecting and redacting local diagnostics…")
                    .font(.callout)
                    .foregroundStyle(ChromeColor.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.content)
        } else if model.items.isEmpty {
            ContentUnavailableView {
                Label("No Diagnostic Items", systemImage: "exclamationmark.bubble")
            } description: {
                Text("Every item was removed. Refresh to collect the diagnostics again.")
            } actions: {
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                summaryHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.standard) {
                        ForEach(model.items) { item in
                            diagnosticSection(item)
                        }
                    }
                }
            }
            .padding(Spacing.section)
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "doc.zipper")
                .foregroundStyle(ChromeColor.textSecondary)
                .accessibilityHidden(true)

            Text("\(UserMessage.count(model.includedItems.count, "item", "items")) selected for export (\(UserMessage.byteCount(Int64(model.totalIncludedBytes))))")
                .font(.callout)
                .foregroundStyle(ChromeColor.textSecondary)

            Spacer()

            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Refresh Diagnostics")
        }
    }

    private func diagnosticSection(_ item: DiagnosticItem) -> some View {
        let isExpanded = model.expandedIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                Toggle(isOn: Binding(
                    get: { item.isIncluded },
                    set: { model.setIncluded($0, for: item.id) }
                )) {
                    Text(item.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(ChromeColor.textPrimary)
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include \(item.title)")

                Text(item.filename)
                    .font(TechnicalTypography.codeCompact)
                    .foregroundStyle(ChromeColor.textTertiary)

                Spacer()

                Text(UserMessage.byteCount(Int64(item.byteCount)))
                    .font(TechnicalTypography.metricMono)
                    .foregroundStyle(ChromeColor.textSecondary)

                Button {
                    model.toggleExpanded(id: item.id)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(ChromeColor.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Collapse \(item.title)" : "Expand \(item.title)")
                .accessibilityLabel(isExpanded ? "Collapse \(item.title)" : "Expand \(item.title)")

                Button(role: .destructive) {
                    model.removeItem(id: item.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(ChromeColor.textSecondary)
                }
                .buttonStyle(.borderless)
                .help("Remove \(item.title)")
                .accessibilityLabel("Remove \(item.title)")
            }

            Text(item.summary)
                .font(.callout)
                .foregroundStyle(ChromeColor.textSecondary)

            if isExpanded {
                ScrollView {
                    Text(item.content)
                        .font(TechnicalTypography.codeCompact)
                        .foregroundStyle(ChromeColor.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.standard)
                }
                .frame(maxHeight: 136)
                .wellBackground(cornerRadius: CornerRadius.small)
            }
        }
        .padding(Spacing.comfortable)
        .wellBackground(cornerRadius: CornerRadius.compactPanel)
    }

    private func saveArchive() {
        let selected = model.includedItems
        guard !selected.isEmpty else { return }

        let panel = NSSavePanel()
        panel.title = "Save Redacted Diagnostics Archive"
        panel.nameFieldStringValue = Self.defaultArchiveFilename()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        model.isExporting = true
        model.statusMessage = nil
        model.statusTone = nil

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DiagnosticsArchiveExporter.exportArchive(items: selected, to: destinationURL)
                }.value
                model.statusMessage = "Saved \(destinationURL.lastPathComponent)"
                model.statusTone = .success
            } catch {
                model.statusMessage = error.localizedDescription
                model.statusTone = .failure
            }
            model.isExporting = false
        }
    }

    private static func defaultArchiveFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "golens-diagnostics-\(stamp).zip"
    }
}
