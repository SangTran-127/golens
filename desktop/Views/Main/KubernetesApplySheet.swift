import AppKit
import GoLensFoundation
import Observation
import SwiftUI

@Observable
final class KubernetesApplyModel {
    enum Phase: Equatable {
        case comparing
        case failed(String)
        case ready
    }

    struct ObjectDiff: Identifiable {
        let object: KubeDiffObject
        let items: [DisplayDiffItem]
        let estimatedWidth: CGFloat
        let added: Int
        let removed: Int

        var id: String { object.id }
    }

    let request: KubeApplyRequest
    var phase: Phase = .comparing
    var objects: [ObjectDiff] = []
    var selectedID = ""

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var generation = 0

    init(request: KubeApplyRequest) {
        self.request = request
    }

    var fileName: String { (request.filePath as NSString).lastPathComponent }

    var selected: ObjectDiff? { objects.first { $0.id == selectedID } ?? objects.first }

    func compare(text: String) {
        cancel()
        generation += 1
        let run = generation
        phase = .comparing
        objects = []
        guard let kubectl = ServicesStore.shared.kubectlPath() else {
            phase = .failed("Apply to Cluster needs the kubectl command. Install it with Homebrew (brew install kubectl).")
            return
        }
        let manifest = FileManager.default.temporaryDirectory
            .appendingPathComponent("golens-apply-\(UUID().uuidString)")
            .appendingPathExtension((request.filePath as NSString).pathExtension.isEmpty ? "yaml" : (request.filePath as NSString).pathExtension)
        do {
            try Data(text.utf8).write(to: manifest, options: .atomic)
        } catch {
            phase = .failed("GoLens couldn’t prepare \(fileName) for kubectl diff.")
            return
        }
        let argv = KubeCommandLine.diff(kubectl: kubectl, context: request.context, namespace: request.namespace, file: manifest.path)
        let dir = (request.filePath as NSString).deletingLastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = KubectlLocator.environment
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        self.process = process
        let baseColor = Color(nsColor: .labelColor)
        DispatchQueue.global(qos: .userInitiated).async {
            var outText = ""
            var errText = ""
            var status: Int32 = -1
            do {
                try process.run()
                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()
                group.enter()
                DispatchQueue.global().async {
                    outData = output.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                errData = errors.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                status = process.terminationStatus
                outText = String(decoding: outData, as: UTF8.self)
                errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                errText = "GoLens couldn’t run kubectl."
            }
            try? FileManager.default.removeItem(at: manifest)
            var computed: [ObjectDiff] = []
            if status == 0 || status == 1 {
                computed = KubeDiffObject.split(outText).map { object in
                    let display = buildDisplayDiffOffMainThread(diffOutput: object.patch, collapseEnabled: true, expandedBlockIds: [], baseTextColor: baseColor)
                    return ObjectDiff(object: object, items: display.items, estimatedWidth: display.estimatedUnifiedWidth, added: display.addedCount, removed: display.removedCount)
                }
            }
            DispatchQueue.main.async {
                guard run == self.generation else { return }
                self.process = nil
                switch status {
                case 0, 1:
                    self.objects = computed
                    self.selectedID = computed.first?.id ?? ""
                    self.phase = .ready
                case 15, 9:
                    break
                default:
                    self.phase = .failed(Self.sentence(errText.isEmpty ? "kubectl diff stopped with exit code \(status)." : errText))
                }
            }
        }
    }

    func cancel() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    static func sentence(_ text: String) -> String {
        var line = text.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        if line.hasPrefix("error: ") { line.removeFirst("error: ".count) }
        if line.hasPrefix("Error from server ") , let colon = line.firstIndex(of: ":") {
            line = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let first = line.first else { return line }
        line = first.uppercased() + line.dropFirst()
        return line.hasSuffix(".") ? line : line + "."
    }
}

struct KubernetesApplySheet: View {
    @Bindable var workspace: WorkspaceState
    let request: KubeApplyRequest
    @Environment(\.dismiss) private var dismiss

    @State private var model: KubernetesApplyModel

    init(workspace: WorkspaceState, request: KubeApplyRequest) {
        self.workspace = workspace
        self.request = request
        _model = State(initialValue: KubernetesApplyModel(request: request))
    }

    private var store: ServicesStore { ServicesStore.shared }
    private var isReadOnly: Bool { store.kube.readOnlyContexts.contains(request.context) }

    private var currentText: String {
        workspace.documents[request.filePath]?.storage.string ?? (try? String(contentsOfFile: request.filePath, encoding: .utf8)) ?? ""
    }

    var body: some View {
        StandardSheetShell(
            title: "Apply to Cluster",
            subtitle: "Context “\(request.context)” · Namespace “\(request.namespace)”. Review what kubectl apply changes, then apply it.",
            scopeBadge: model.fileName,
            size: .wide,
            primaryTitle: "Apply",
            primaryAccessibilityLabel: "Apply \(model.fileName) to context \(request.context), namespace \(request.namespace)",
            isPrimaryDisabled: model.phase != .ready || isReadOnly,
            closeTitle: "Cancel",
            onPrimary: apply,
            onClose: close,
            footerLeading: { footer }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                if isReadOnly {
                    InlineBanner(
                        .symbol(ServiceSymbol.readOnly, tone: .info),
                        title: "“\(request.context)” Is Read-Only",
                        message: "GoLens doesn’t change this context. Turn off Read-Only for This Context to apply."
                    ) {
                        Button("Turn Off Read-Only") { store.kube.readOnlyContexts.remove(request.context) }
                    }
                }
                content
            }
        }
        .onAppear { model.compare(text: currentText) }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .comparing:
            UnifiedEmptyState.loading(message: "Comparing \(model.fileName) with the cluster…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            InlineBanner(.status(.failure), title: "Couldn’t Compare with the Cluster", message: message) {
                Button("Retry") { model.compare(text: currentText) }
            }
            Spacer(minLength: 0)
        case .ready:
            if model.objects.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: ServiceSymbol.apply,
                    title: "No Changes",
                    message: "The cluster already matches \(model.fileName). Applying it changes nothing."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    HStack(spacing: Spacing.standard) {
                        Text("\(UserMessage.count(model.objects.count, "object")) change")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if model.objects.count > 1 {
                            Picker("Object", selection: $model.selectedID) {
                                ForEach(model.objects) { object in
                                    Text(object.object.title).tag(object.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                        } else if let only = model.objects.first {
                            Text(only.object.title)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    if let selected = model.selected {
                        UnifiedDiffTextView(
                            items: selected.items,
                            estimatedWidth: selected.estimatedWidth,
                            resetKey: selected.id,
                            scrollerAccessibilityLabel: "Apply Diff Horizontal Scrollbar"
                        )
                        .wellBackground(cornerRadius: CornerRadius.compactPanel)
                        .accessibilityLabel("Changes to \(selected.object.title)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if model.phase == .comparing {
            HStack(spacing: Spacing.standard) {
                ProgressView().controlSize(.small)
                Text("Running kubectl diff…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if let selected = model.selected {
            Text("\(UserMessage.count(selected.added, "line")) added, \(UserMessage.count(selected.removed, "line")) removed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func apply() {
        guard model.phase == .ready, !isReadOnly, let kubectl = store.kubectlPath() else { return }
        let argv = KubeCommandLine.apply(kubectl: kubectl, context: request.context, namespace: request.namespace, file: model.fileName)
        let dir = (request.filePath as NSString).deletingLastPathComponent
        workspace.runExternalCommand(
            argv,
            in: dir,
            key: "kube:apply:" + request.filePath,
            title: "kubectl apply -f \(model.fileName) (\(request.context) / \(request.namespace))"
        )
        store.markKubernetesUsed(in: workspace)
        dismiss()
    }

    private func close() {
        model.cancel()
        dismiss()
    }
}
