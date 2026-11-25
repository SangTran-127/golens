import AppKit
import SwiftUI

@Observable
final class GenerateDockerfileModel: Identifiable {
    let id = UUID()
    static let runtimeImages: [(id: String, title: String)] = [
        ("distroless-static", "Distroless Static, Nonroot"),
        ("distroless-base", "Distroless Base, Nonroot"),
        ("alpine", "Alpine"),
        ("scratch", "Scratch"),
    ]

    let contextDir: String
    weak var workspace: WorkspaceState?
    var proposal: DockerfileProposal?
    var package = ""
    var base = ""
    var portText = ""
    var writeError: String?
    var confirmReplace = false
    @ObservationIgnored private var generation = 0

    init(contextDir: String) {
        self.contextDir = contextDir
    }

    var isLoading: Bool { proposal == nil }

    var port: Int? {
        let text = portText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return 0 }
        guard let n = Int(text), (1...65535).contains(n) else { return nil }
        return n
    }

    var targetDir: String {
        if let dir = proposal?.dir, !dir.isEmpty { return dir }
        return contextDir
    }
    var dockerfilePath: String { (targetDir as NSString).appendingPathComponent("Dockerfile") }
    var dockerfileExists: Bool { FileManager.default.fileExists(atPath: dockerfilePath) }
    var dockerignoreExists: Bool { FileManager.default.fileExists(atPath: (targetDir as NSString).appendingPathComponent(".dockerignore")) }

    var canCreate: Bool {
        guard let proposal else { return false }
        return proposal.error == nil && !proposal.dockerfile.isEmpty && port != nil
    }

    var detectedPort: DockerfileProposal.Port? {
        let ports = proposal?.detectedPorts ?? []
        return ports.first { $0.package == package } ?? ports.first
    }

    func load() {
        regenerate(initial: true)
    }

    func regenerate(initial: Bool = false) {
        guard initial || port != nil else { return }
        generation += 1
        let current = generation
        let dir = contextDir
        let package = initial ? nil : package
        let base = initial ? nil : base
        let port = initial ? nil : port
        DispatchQueue.global(qos: .userInitiated).async {
            let result = WorkspaceState.proposeDockerfile(contextDir: dir, package: package, base: base, port: port)
            DispatchQueue.main.async {
                guard current == self.generation else { return }
                self.proposal = result
                if initial {
                    self.package = result.package
                    self.base = result.base
                    self.portText = result.port > 0 ? String(result.port) : ""
                }
            }
        }
    }

    func create(replacing: Bool) -> Bool {
        guard let proposal, canCreate else { return false }
        if dockerfileExists && !replacing {
            confirmReplace = true
            return false
        }
        writeError = (workspace ?? WorkspaceState.shared).writeGeneratedDockerfile(proposal)
        return writeError == nil
    }
}

struct GenerateDockerfileSheet: View {
    @Bindable var model: GenerateDockerfileModel
    let close: () -> Void

    private var folderName: String { (model.targetDir as NSString).lastPathComponent }

    var body: some View {
        GeneratorSheet(
            title: "Generate Dockerfile for Go Project",
            subtitle: "A multi-stage image that builds one main package and runs it as a non-root user.",
            primaryTitle: "Create",
            canConfirm: model.canCreate,
            errorMessage: model.writeError ?? "",
            footnote: model.canCreate ? footnote : "",
            preview: preview,
            onCancel: close,
            onConfirm: {
                if model.create(replacing: false) { close() }
            }
        ) {
            if let proposal = model.proposal {
                if proposal.mainPackages.isEmpty {
                    GeneratorStatusMessage(proposal.error ?? "The module has no main package.", tone: .warning)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    options(proposal)
                    if let error = proposal.error {
                        GeneratorStatusMessage(error, tone: .warning)
                    }
                }
            } else {
                ProgressView("Scanning the module…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .onAppear { model.load() }
        .onChange(of: model.package) { model.regenerate() }
        .onChange(of: model.base) { model.regenerate() }
        .onChange(of: model.portText) { model.regenerate() }
        .alert("Replace the existing Dockerfile?", isPresented: $model.confirmReplace) {
            Button("Replace", role: .destructive) {
                if model.create(replacing: true) { close() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Dockerfile in \(folderName) will be overwritten with the generated one.")
        }
    }

    private var preview: GeneratorCodePreview? {
        guard let proposal = model.proposal, !proposal.mainPackages.isEmpty, proposal.error == nil else { return nil }
        return GeneratorCodePreview(
            code: proposal.dockerfile,
            accessibilityLabel: "Dockerfile preview",
            path: "Dockerfile",
            copyHelp: "Copy generated Dockerfile to clipboard"
        )
    }

    private var footnote: String {
        let ignore = model.dockerignoreExists ? "keeps the existing .dockerignore" : "adds a .dockerignore"
        return "Saves Dockerfile in \(folderName) and \(ignore)."
    }

    @ViewBuilder
    private func options(_ proposal: DockerfileProposal) -> some View {
        Form {
            Picker("Main package:", selection: $model.package) {
                ForEach(proposal.mainPackages, id: \.self) { pkg in
                    Text(pkg == "." ? "Module root" : pkg).tag(pkg)
                }
            }
            .help("The package main that becomes the image’s program")

            LabeledContent("Go version:") {
                Text(proposal.goVersion.isEmpty ? "Not set in go.mod" : "\(proposal.goVersion), from go.mod")
                    .foregroundStyle(.secondary)
            }

            Picker("Runtime image:", selection: $model.base) {
                ForEach(GenerateDockerfileModel.runtimeImages, id: \.id) { image in
                    Text(image.title).tag(image.id)
                }
            }
            .help("The image the program runs in")
            if proposal.usesCgo {
                GeneratorNote("This module uses cgo (\(proposal.cgoReason)), so the program needs a C library. Distroless Base and Alpine have one; Distroless Static and Scratch don’t.")
            }

            LabeledContent("Exposed port:") {
                TextField("Exposed port", text: $model.portText, prompt: Text("None"))
                    .labelsHidden()
                    .frame(width: 80)
            }
            .help("The port the program listens on, written as EXPOSE")
            if model.port == nil {
                GeneratorStatusMessage("Enter a port from 1 to 65535, or leave it empty.", tone: .warning)
            } else if let found = model.detectedPort {
                GeneratorNote("Found \(found.via) on port \(found.port) in \(found.file):\(found.line).")
            } else {
                GeneratorNote("No listening port found in the code.")
            }
        }
        .formStyle(.columns)

        ForEach(proposal.warnings, id: \.self) { warning in
            GeneratorStatusMessage(warning, tone: .warning)
        }
    }
}
