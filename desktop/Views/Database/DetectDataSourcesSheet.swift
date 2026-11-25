import SwiftUI

struct DetectDataSourcesSheet: View {
    @Bindable var workspace: WorkspaceState
    let request: DBDetectSheetRequest
    @Environment(\.dismiss) private var dismiss

    private struct Proposal: Identifiable {
        var definition: DBDataSourceDefinition
        let candidate: DBDetectCandidate?
        var savesSecret = false

        var id: String { definition.id }
    }

    @State private var proposals: [Proposal] = []
    @State private var skipped = 0
    @State private var selection: String?
    @State private var prepared = false
    @State private var saveError: String?

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return proposals.firstIndex { $0.id == selection }
    }

    var body: some View {
        ListDetailSheet(
            selection: $selection,
            listTitle: "Found in Project",
            addTitle: "Add Data Source",
            removeTitle: "Don’t Add",
            showsDetail: selectedIndex != nil,
            onAdd: addBlank,
            onRemove: remove,
            onCancel: { dismiss() },
            onDone: done
        ) {
            ForEach(proposals) { proposal in
                row(proposal)
                    .tag(proposal.id)
            }
        } detail: {
            if let index = selectedIndex {
                form($proposals[index])
            }
        } emptyDetail: {
            emptyDetail
        } banner: {
            if let saveError {
                InlineBanner(.status(.failure), title: "Couldn’t Add the Data Sources", message: saveError, onClose: { self.saveError = nil })
            }
        } footerLeading: {
            Text(footerText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .onAppear(perform: prepare)
    }

    private var footerText: String {
        var parts: [String] = []
        parts.append(proposals.isEmpty ? "Done adds nothing." : "Done adds \(UserMessage.count(proposals.count, "data source")).")
        if skipped > 0 {
            parts.append("\(UserMessage.count(skipped, "data source")) found \(skipped == 1 ? "is" : "are") already added.")
        }
        return parts.joined(separator: " ")
    }

    private func row(_ proposal: Proposal) -> some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: DatabaseSymbol.dataSource)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(proposal.definition.name.isEmpty ? "Untitled" : proposal.definition.name)
                    .lineLimit(1)
                Text(rowSubtitle(proposal))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Spacing.compact)
        }
        .padding(.vertical, Spacing.hairline)
        .accessibilityElement(children: .combine)
    }

    private func rowSubtitle(_ proposal: Proposal) -> String {
        let engine = proposal.definition.engineKind?.title ?? proposal.definition.engine
        guard let source = proposal.candidate?.source else { return engine }
        return "\(engine) · \(source.file)"
    }

    @ViewBuilder
    private var emptyDetail: some View {
        if proposals.isEmpty {
            ContentUnavailableView {
                Label(skipped > 0 ? "Nothing New Found" : "No Data Sources Found", systemImage: DatabaseSymbol.dataSource)
            } description: {
                Text(skipped > 0
                     ? "Every database GoLens found in the project is already a data source."
                     : "GoLens looked for DATABASE_URL-style variables in .env files, PostgreSQL, MySQL and MariaDB services in compose.yaml, and sqlc.yaml. Add a data source by hand instead.")
            } actions: {
                Button("Add Data Source", action: addBlank)
            }
        } else {
            ContentUnavailableView("No Data Source Selected", systemImage: "sidebar.left", description: Text("Select a data source in the sidebar to check its settings."))
        }
    }

    private func form(_ proposal: Binding<Proposal>) -> some View {
        let definition = proposal.definition
        return Form {
            if let candidate = proposal.wrappedValue.candidate {
                Section {
                    LabeledContent("File", value: candidate.source.file)
                    LabeledContent("Line", value: UserMessage.integer(candidate.source.line))
                    if !candidate.source.key.isEmpty {
                        LabeledContent("Found", value: candidate.source.key)
                    }
                } header: {
                    Text("Source")
                } footer: {
                    if let note = candidate.note {
                        Label(note, systemImage: StatusTone.warning.symbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("General") {
                TextField("Name", text: definition.name, prompt: Text("Data source name"))
                LabeledContent("Engine", value: definition.wrappedValue.engineKind?.title ?? definition.wrappedValue.engine)
            }
            if definition.wrappedValue.engineKind == .sqlite {
                Section("File") {
                    TextField("Database File", text: definition.sqlitePath, prompt: Text("data/app.db"))
                }
            } else {
                Section {
                    TextField("Host", text: definition.host, prompt: Text("localhost"))
                    TextField("Port", value: definition.port, format: .number.grouping(.never))
                    TextField("Database", text: definition.database, prompt: Text("Optional"))
                    TextField("User", text: definition.user, prompt: Text("User name"))
                    Picker("Password", selection: definition.password) {
                        ForEach(DBPasswordMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    if proposal.wrappedValue.candidate?.hasSecret == true {
                        Toggle("Save the password found in \(proposal.wrappedValue.candidate?.source.file ?? "the file") in the Keychain", isOn: proposal.savesSecret)
                            .disabled(definition.wrappedValue.passwordMode != .keychain)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text(passwordFooter(proposal.wrappedValue))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Toggle("Read-only", isOn: definition.readOnly)
                Toggle("Production", isOn: definition.production)
            } header: {
                Text("Options")
            }
        }
        .formStyle(.grouped)
    }

    private func passwordFooter(_ proposal: Proposal) -> String {
        guard proposal.candidate?.hasSecret == true else {
            return proposal.definition.passwordMode == .keychain ? "GoLens asks for the password when it first connects." : ""
        }
        return proposal.savesSecret
            ? "GoLens saves the password from the file in the Keychain on this Mac, never in the project."
            : "GoLens doesn’t store the password from the file unless you turn this on. It asks for the password when it first connects."
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        var names = Set(workspace.database.definitions.map(\.name))
        var next: [Proposal] = []
        for candidate in request.candidates {
            guard !workspace.isAlreadyAdded(candidate.definition) else {
                skipped += 1
                continue
            }
            var definition = candidate.definition
            definition.id = UUID().uuidString
            definition.name = unique(definition.name.isEmpty ? "Data Source" : definition.name, in: &names)
            next.append(Proposal(definition: definition, candidate: candidate))
        }
        proposals = next
        selection = next.first?.id
    }

    private func unique(_ base: String, in names: inout Set<String>) -> String {
        var name = base
        var n = 2
        while names.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        names.insert(name)
        return name
    }

    private func addBlank() {
        var names = Set(workspace.database.definitions.map(\.name) + proposals.map(\.definition.name))
        var definition = DBDataSourceDefinition(name: unique("New Data Source", in: &names), engine: .postgres)
        definition.user = NSUserName()
        proposals.append(Proposal(definition: definition, candidate: nil))
        selection = definition.id
    }

    private func remove(_ id: String) {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return }
        proposals.remove(at: index)
        selection = proposals.isEmpty ? nil : proposals[min(index, proposals.count - 1)].id
    }

    private func done() {
        guard !proposals.isEmpty else {
            dismiss()
            return
        }
        var secrets: [String: String] = [:]
        let sources = proposals.map { proposal -> DBDataSourceDefinition in
            var source = proposal.definition
            source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.name.isEmpty { source.name = "Untitled" }
            if proposal.savesSecret, source.passwordMode == .keychain, let secret = proposal.candidate?.secret, !secret.isEmpty {
                secrets[source.id] = secret
            }
            return source
        }
        do {
            _ = try workspace.addDetectedDataSources(sources, secrets: secrets)
            dismiss()
        } catch {
            saveError = "\(WorkspaceState.failureReason(error)) Check that you can write to the .golens folder in the project, then try again."
        }
    }
}
