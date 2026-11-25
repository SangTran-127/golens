import GoLensFoundation
import SwiftUI

struct DockerCleanUpSheet: View {
    @Bindable var workspace: WorkspaceState
    let request: DockerCleanUpRequest
    @Environment(\.dismiss) private var dismiss

    @State private var model = DockerCleanUpModel()
    @State private var confirmsVolumes = false

    private var volumeCount: Int {
        model.plannedKinds.contains(.volumes) ? model.usage?.category(.volumes).count ?? 0 : 0
    }

    private var primaryTitle: String {
        let bytes = model.plannedBytes
        return bytes > 0 ? "Clean Up (\(UserMessage.byteCount(bytes)))" : "Clean Up"
    }

    private var subtitle: String {
        let base = "Removes Docker data that nothing uses. Running containers and the images, volumes and networks they use are kept."
        guard let label = DockerCleanUpModel.pruneLabel else { return base }
        return base + " Only objects labelled “\(label)” are removed."
    }

    var body: some View {
        StandardSheetShell(
            title: "Clean Up",
            subtitle: subtitle,
            scopeBadge: request.context,
            size: .compact,
            primaryTitle: primaryTitle,
            primaryAccessibilityLabel: model.plannedBytes > 0 ? "Clean Up, frees \(UserMessage.byteCount(model.plannedBytes))" : "Clean Up",
            isPrimaryDisabled: model.isCleaning || model.isMeasuring || model.plannedKinds.isEmpty,
            closeTitle: "Cancel",
            onPrimary: start,
            onClose: close,
            footerLeading: { progress }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                banner
                GeneratorSection("Remove") {
                    VStack(alignment: .leading, spacing: Spacing.standard) {
                        ForEach(DockerPruneKind.allCases) { kind in
                            category(kind)
                        }
                    }
                }
            }
        }
        .onAppear { model.measure() }
        .alert("Remove \(UserMessage.count(volumeCount, "Unused Volume"))?", isPresented: $confirmsVolumes) {
            Button("Clean Up", role: .destructive) { run() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Data stored in these volumes is deleted and can’t be recovered. The other checked items are removed too.")
        }
    }

    @ViewBuilder
    private func category(_ kind: DockerPruneKind) -> some View {
        let item = model.usage?.category(kind)
        let detail = detailText(item)
        VStack(alignment: .leading, spacing: Spacing.compact) {
            GeneratorOptionToggle(
                title: kind.title,
                detail: detail,
                isOn: Binding(
                    get: { model.selected.contains(kind) },
                    set: { on in
                        if on { model.selected.insert(kind) } else { model.selected.remove(kind) }
                    }
                ),
                accessibilityLabel: "\(kind.title), \(detail)"
            )
            .disabled(model.isCleaning || (item?.count ?? 0) == 0)
            if kind == .volumes {
                GeneratorStatusMessage("Data stored in unused volumes is deleted and can’t be recovered.", tone: .warning)
            }
        }
    }

    private func detailText(_ item: DockerDiskCategory?) -> String {
        guard let item else { return model.usageError == nil ? "Measuring…" : "Unknown" }
        guard item.count > 0 else { return "Nothing to remove" }
        guard item.bytes > 0 else { return UserMessage.integer(item.count) }
        return UserMessage.integer(item.count) + " · " + UserMessage.byteCount(item.bytes)
    }

    @ViewBuilder
    private var banner: some View {
        if let error = model.usageError {
            InlineBanner(.status(.failure), title: "Couldn’t Measure Disk Usage", message: error) {
                Button("Retry") { model.measure() }
                    .disabled(model.isMeasuring)
            }
        } else if case .failed(let kind, let error) = model.phase {
            InlineBanner(
                .status(.failure),
                title: "Couldn’t Remove \(kind.title)",
                message: error,
                detail: model.results.isEmpty ? nil : model.summary
            )
        } else if model.wasCanceled {
            InlineBanner(
                .status(.inactive),
                title: "Clean Up Canceled",
                message: model.results.isEmpty ? "Nothing was removed." : model.summary + " Nothing else was removed."
            )
        }
    }

    @ViewBuilder
    private var progress: some View {
        if case .cleaning(let kind) = model.phase {
            HStack(spacing: Spacing.standard) {
                ProgressView().controlSize(.small)
                Text(model.isCanceling
                    ? "Stopping after \(kind.title.lowercased())…"
                    : "Removing \(kind.title.lowercased())… (\(model.results.count + 1) of \(model.runTotal))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } else if model.isMeasuring {
            HStack(spacing: Spacing.standard) {
                ProgressView().controlSize(.small)
                Text("Measuring disk usage…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func start() {
        if volumeCount > 0 {
            confirmsVolumes = true
        } else {
            run()
        }
    }

    private func run() {
        model.cleanUp {
            let store = ServicesStore.shared
            for window in store.allWindows where window.isVisible { store.reloadExpandedLists(window) }
            workspace.presentCommandFeedback(model.summary, title: "Clean Up Finished", tone: .success)
            dismiss()
        }
    }

    private func close() {
        if model.isCleaning {
            model.cancel()
        } else {
            dismiss()
        }
    }
}
