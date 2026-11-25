import AppKit
import Darwin
import SwiftUI

struct RuntimeDiagnosticsData: Codable, Equatable {
    let goHeapAllocBytes: UInt64
    let goHeapSysBytes: UInt64
    let goHeapIdleBytes: UInt64
    let goReleasedBytes: UInt64
    let goGoroutines: Int
    let goGCCycles: UInt32
    let openLSPBuffers: Int
    let goplsPID: Int
    let goplsRSSBytes: Int64

    static let empty = RuntimeDiagnosticsData(
        goHeapAllocBytes: 0,
        goHeapSysBytes: 0,
        goHeapIdleBytes: 0,
        goReleasedBytes: 0,
        goGoroutines: 0,
        goGCCycles: 0,
        openLSPBuffers: 0,
        goplsPID: 0,
        goplsRSSBytes: 0
    )
}

struct WorkspaceDiagnosticsSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var stats: RuntimeDiagnosticsData = .empty
    @State private var appFootprintBytes: UInt64 = 0
    @State private var statusBannerMessage: String? = nil
    @State private var largeFileToggleTick: Int = 0

    var body: some View {
        StandardSheetShell(
            title: "Workspace Diagnostics",
            subtitle: "Live memory footprint, Go runtime telemetry, and LSP process status",
            size: .standardTall,
            closeTitle: "Done",
            closeAccessibilityLabel: "Done",
            onClose: closeSheet,
            headerTrailing: {
                Button {
                    statusBannerMessage = nil
                    refreshTelemetry()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Refresh Workspace Diagnostics")
                .accessibilityLabel("Refresh Workspace Diagnostics")
            },
            footerLeading: {
                HStack(spacing: Spacing.standard) {
                    Button("Release Unused Caches") {
                        workspace.releaseUnusedCaches()
                        refreshTelemetry()
                        statusBannerMessage = "Released unused caches and returned free Go pages to macOS."
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityLabel("Release Unused Caches")

                    if let statusBannerMessage {
                        HStack(spacing: Spacing.row) {
                            Image(systemName: StatusTone.success.symbol)
                                .foregroundStyle(StatusTone.success.tint)
                                .font(.caption)
                                .accessibilityHidden(true)
                            Text(statusBannerMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.inset) {
                    appProcessCard
                    goCoreCard
                    languageServerCard
                    largeFileModeCard
                }
                .padding(.vertical, Spacing.hairline)
            }
        }
        .onAppear {
            refreshTelemetry()
        }
    }

    private var appProcessCard: some View {
        sectionCard(title: "macOS App Process (SwiftUI + AppKit)", symbol: "macwindow") {
            HStack(spacing: Spacing.comfortable) {
                metricCell(
                    label: "Physical Footprint",
                    value: UserMessage.byteCount(Int64(clamping: appFootprintBytes), style: .memory)
                )
                metricCell(
                    label: "Open Document Sessions",
                    value: UserMessage.integer(workspace.documents.count)
                )
                metricCell(
                    label: "Visible Editor Panes",
                    value: UserMessage.integer(workspace.visibleDocumentPaths.count)
                )
                metricCell(
                    label: "Console Log Ring",
                    value: "\(UserMessage.integer(workspace.consoleOutput.count)) lines"
                )
            }
        }
    }

    private var goCoreCard: some View {
        sectionCard(title: "Embedded Go Core (libgoagent.dylib)", symbol: "memorychip") {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                HStack(spacing: Spacing.comfortable) {
                    metricCell(
                        label: "Heap In-Use",
                        value: UserMessage.byteCount(Int64(clamping: stats.goHeapAllocBytes), style: .memory)
                    )
                    metricCell(
                        label: "Heap Sys / Released",
                        value: "\(UserMessage.byteCount(Int64(clamping: stats.goHeapSysBytes), style: .memory)) / \(UserMessage.byteCount(Int64(clamping: stats.goReleasedBytes), style: .memory))"
                    )
                    metricCell(
                        label: "Goroutines",
                        value: UserMessage.integer(stats.goGoroutines)
                    )
                }
                HStack(spacing: Spacing.comfortable) {
                    metricCell(
                        label: "Completed GC Cycles",
                        value: UserMessage.integer(Int(stats.goGCCycles))
                    )
                    metricCell(
                        label: "Synced LSP File Buffers",
                        value: UserMessage.integer(stats.openLSPBuffers)
                    )
                    metricCell(
                        label: "Heap Idle",
                        value: UserMessage.byteCount(Int64(clamping: stats.goHeapIdleBytes), style: .memory)
                    )
                }
            }
        }
    }

    private var languageServerCard: some View {
        sectionCard(title: "Language Server (gopls)", symbol: "server.rack") {
            HStack(spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text("Process Status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Spacing.row) {
                        Circle()
                            .fill(stats.goplsPID > 0 ? StatusTone.success.tint : Color.secondary)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(stats.goplsPID > 0 ? "Running (PID \(UserMessage.rawIdentifier(stats.goplsPID)))" : "Idle / Not Spawned")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                metricCell(
                    label: "Process RSS",
                    value: stats.goplsPID > 0 && stats.goplsRSSBytes > 0
                        ? UserMessage.byteCount(Int64(max(0, stats.goplsRSSBytes)), style: .memory)
                        : "—"
                )
            }
        }
    }

    private var largeFileModeCard: some View {
        let _ = largeFileToggleTick
        return sectionCard(title: "Large-File Mode Status", symbol: "doc.text.magnifyingglass") {
            if let session = workspace.activeDocument {
                let fileName = (session.path as NSString).lastPathComponent
                let sizeStr = UserMessage.byteCount(Int64(max(0, session.utf8.byteLength)), style: .file)
                let lineCount = session.lines.count
                HStack(spacing: Spacing.comfortable) {
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        HStack(spacing: Spacing.row) {
                            Circle()
                                .fill(session.isEffectiveLargeFileMode ? StatusTone.warning.tint : StatusTone.success.tint)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(largeFileHeadline(for: session, fileName: fileName))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        Text("\(fileName) · \(sizeStr) · \(UserMessage.integer(lineCount)) lines — \(largeFileDetail(for: session))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if session.isLargeFileMode && session.syncsToCore {
                        Button(session.largeFileAnalysisOverride ? "Enable Large-File Mode" : "Enable Anyway") {
                            session.largeFileAnalysisOverride.toggle()
                            workspace.largeFileModeRevision &+= 1
                            largeFileToggleTick &+= 1
                            workspace.activeTextView?.needsDisplay = true
                        }
                        .controlSize(.small)
                        .accessibilityLabel(session.largeFileAnalysisOverride ? "Enable Large-File Mode" : "Enable Anyway")
                    }
                }
            } else {
                Text("No active document open in the editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func closeSheet() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func refreshTelemetry() {
        appFootprintBytes = Self.currentPhysicalFootprintBytes()
        stats = workspace.fetchRuntimeDiagnostics()
    }

    private func largeFileHeadline(for session: DocumentSession, fileName: String) -> String {
        if !session.syncsToCore {
            return "Read-Only Large File (> 10 MB)"
        }
        if session.isEffectiveLargeFileMode {
            return "Large-File Mode Active"
        }
        if session.isLargeFileMode && session.largeFileAnalysisOverride {
            return "Full Analysis Override Enabled"
        }
        return "Standard Editor Mode"
    }

    private func largeFileDetail(for session: DocumentSession) -> String {
        if !session.syncsToCore {
            return "LSP sync and editing disabled above 10 MB"
        }
        if session.isEffectiveLargeFileMode {
            return "Expensive background AST/LSP passes paused (> 2 MB or > 50,000 lines)"
        }
        if session.isLargeFileMode && session.largeFileAnalysisOverride {
            return "Full analysis enabled manually for this session"
        }
        return "Within standard size limits (≤ 2 MB and ≤ 50,000 lines)"
    }

    private func sectionCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.row) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.inset)
        .wellBackground()
    }

    private func metricCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func currentPhysicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
