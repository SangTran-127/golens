import AppKit
import SwiftUI

struct DataSourcesSheet: View {
    @Bindable var workspace: WorkspaceState
    let initialSelection: String?
    @Environment(\.dismiss) private var dismiss

    @State private var drafts: [DBDataSourceDefinition] = []
    @State private var baseFile = DBDataSourcesFile()
    @State private var selection: String?
    @State private var secrets: [String: String] = [:]
    @State private var testing: Set<String> = []
    @State private var testResults: [String: DBTestConnectionResult] = [:]
    @State private var issues: [DBIssue] = []
    @State private var saveError: String?
    @State private var prepared = false
    @State private var sshShown: Set<String> = []

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return drafts.firstIndex { $0.id == selection }
    }

    var body: some View {
        ListDetailSheet(
            selection: $selection,
            listTitle: "Data Sources",
            addTitle: "Add Data Source",
            removeTitle: "Remove Data Source",
            showsDetail: selectedIndex != nil,
            onAdd: add,
            onRemove: remove,
            onCancel: { dismiss() },
            onDone: done
        ) {
            ForEach(drafts) { source in
                row(source)
                    .tag(source.id)
                    .contextMenu {
                        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(source) }
                        Divider()
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(source.id) }
                    }
            }
        } sidebarAccessory: {
            Button("Detect…") {
                dismiss()
                DispatchQueue.main.async { workspace.detectDataSourcesInProject() }
            }
            .controlSize(.small)
            .disabled(drafts != baseFile.dataSources)
            .help(drafts != baseFile.dataSources ? "Click Done to save your changes first, then detect data sources." : "Find databases in .env files, compose.yaml and sqlc.yaml in this project.")
        } detail: {
            if let index = selectedIndex {
                form($drafts[index])
            }
        } emptyDetail: {
            emptyDetail
        } banner: {
            banner
        } footerLeading: {
            if let index = selectedIndex {
                testControls(drafts[index])
            }
        }
        .onAppear(perform: prepare)
    }

    private func row(_ source: DBDataSourceDefinition) -> some View {
        HStack(spacing: Spacing.standard) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                Text(source.name.isEmpty ? "Untitled" : source.name)
                    .lineLimit(1)
                Text(rowSubtitle(source))
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

    private func rowSubtitle(_ source: DBDataSourceDefinition) -> String {
        var parts = [source.engineKind?.title ?? source.engine]
        if source.production {
            parts.append("Production")
        } else if source.readOnly {
            parts.append("Read-only")
        }
        if source.ssh.isEnabled && source.engineKind != .sqlite {
            parts.insert("SSH", at: 1)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var emptyDetail: some View {
        if drafts.isEmpty {
            ContentUnavailableView {
                Label("No Data Sources", systemImage: "cylinder.split.1x2")
            } description: {
                Text("Add a PostgreSQL, MySQL or SQLite database to run SQL in query consoles and browse its tables.")
            } actions: {
                Button("Add Data Source", action: add)
                Button("Detect Data Sources in Project…") {
                    dismiss()
                    DispatchQueue.main.async { workspace.detectDataSourcesInProject() }
                }
            }
        } else {
            ContentUnavailableView("No Data Source Selected", systemImage: "sidebar.left", description: Text("Select a data source in the sidebar."))
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let saveError {
            InlineBanner(
                .status(.failure),
                title: "Couldn’t Save Data Sources",
                message: saveError,
                onClose: { self.saveError = nil }
            )
        } else if let issue = issues.first {
            InlineBanner(
                .status(.warning),
                title: "Check “\(drafts.first { $0.id == issue.id }?.name ?? "Data Source")”",
                message: "\(issue.message) The data sources are saved; this one can’t connect until it is fixed.",
                onClose: { issues = [] }
            ) {
                if !issue.id.isEmpty, selection != issue.id {
                    Button("Show") { selection = issue.id }
                }
            }
        } else if let failure = selectedTestFailure {
            InlineBanner(
                .status(.warning),
                title: "Couldn’t Connect to “\(failure.source.name)”",
                message: failure.error?.message ?? "GoLens could not connect to the data source. Check the settings, then test again.",
                detail: failure.error?.detail,
                onClose: { testResults[failure.source.id] = nil }
            ) {
                Button("Retry") { test(failure.source) }
            }
        } else if let loadError = workspace.database.loadError {
            InlineBanner(
                .status(.warning),
                title: "Couldn’t Read Data Sources",
                message: "\(loadError) Saving keeps the old file as data-sources.json.unreadable in the .golens folder."
            )
        }
    }

    private func form(_ source: Binding<DBDataSourceDefinition>) -> some View {
        Form {
            Section("General") {
                TextField("Name", text: source.name, prompt: Text("Data source name"))
                Picker("Engine", selection: engineBinding(source)) {
                    ForEach(DBEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if source.wrappedValue.engineKind == .sqlite {
                sqliteSection(source)
            } else {
                serverSection(source)
                sshSection(source)
                sslSection(source)
            }
            optionsSection(source)
        }
        .formStyle(.grouped)
    }

    private func serverSection(_ source: Binding<DBDataSourceDefinition>) -> some View {
        Section {
            TextField("Host", text: source.host, prompt: Text("localhost"))
            TextField("Port", value: source.port, format: .number.grouping(.never), prompt: Text(String(source.wrappedValue.engineKind?.defaultPort ?? 0)))
            TextField("Database", text: source.database, prompt: Text("Optional"))
            TextField("User", text: source.user, prompt: Text("User name"))
            Picker("Password", selection: source.password) {
                ForEach(DBPasswordMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            if source.wrappedValue.passwordMode == .keychain {
                SecureField("Keychain Password", text: secretBinding(source.wrappedValue.id), prompt: Text(isSaved(source.wrappedValue.id) ? "Unchanged" : "Required"))
            }
        } header: {
            Text("Server")
        } footer: {
            footerText(passwordFooter(source.wrappedValue))
        }
    }

    private func passwordFooter(_ source: DBDataSourceDefinition) -> String {
        switch source.passwordMode {
        case .keychain:
            return workspace.database.definition(source.id)?.passwordMode == .keychain
                ? "The password is saved in the Keychain on this Mac, never in the project. Leave the field empty to keep the saved password."
                : "The password is saved in the Keychain on this Mac, never in the project."
        case .ask:
            return "GoLens asks for the password when it connects and keeps it only until the project closes."
        case .none:
            return "GoLens connects without a password."
        }
    }

    private func sqliteSection(_ source: Binding<DBDataSourceDefinition>) -> some View {
        Section {
            LabeledContent("Database File") {
                HStack(spacing: Spacing.standard) {
                    TextField("Database File", text: source.sqlitePath, prompt: Text("data/app.db"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                    Button("Choose…") { chooseFile(into: source.sqlitePath) }
                }
            }
            Toggle("Create the file if it does not exist", isOn: source.sqliteCreate)
        } header: {
            Text("File")
        } footer: {
            footerText("A path inside the project is saved relative to the project folder.")
        }
    }

    private func sshSection(_ source: Binding<DBDataSourceDefinition>) -> some View {
        Section {
            Toggle("Connect Through SSH", isOn: sshBinding(source))
            if sshBinding(source).wrappedValue {
                TextField("Destination", text: source.ssh.destination, prompt: Text("user@bastion or a Host alias"))
                TextField("SSH Port", value: sshPortBinding(source), format: .number.grouping(.never), prompt: Text("From ~/.ssh/config"))
            }
        } header: {
            Text("SSH Tunnel")
        } footer: {
            footerText("GoLens opens the tunnel with /usr/bin/ssh, so your keys, ssh-agent, ProxyJump and security keys from ~/.ssh/config work. SSH passwords are not supported. Host and Port above are as the SSH host sees them.")
        }
    }

    private func sshBinding(_ source: Binding<DBDataSourceDefinition>) -> Binding<Bool> {
        Binding(
            get: { sshShown.contains(source.wrappedValue.id) || source.wrappedValue.ssh.isEnabled },
            set: { isOn in
                if isOn {
                    sshShown.insert(source.wrappedValue.id)
                } else {
                    sshShown.remove(source.wrappedValue.id)
                    source.wrappedValue.ssh = DBSSHOptions()
                }
                testResults[source.wrappedValue.id] = nil
            }
        )
    }

    private func sshPortBinding(_ source: Binding<DBDataSourceDefinition>) -> Binding<Int?> {
        Binding(
            get: { source.wrappedValue.ssh.port == 0 ? nil : source.wrappedValue.ssh.port },
            set: { source.wrappedValue.ssh.port = $0 ?? 0 }
        )
    }

    private func sslSection(_ source: Binding<DBDataSourceDefinition>) -> some View {
        Section {
            Picker("Mode", selection: source.ssl.mode) {
                ForEach(DBSSLMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            fileField("CA Certificate", source.ssl.rootCert)
            fileField("Client Certificate", source.ssl.cert)
            fileField("Client Key", source.ssl.key)
        } header: {
            Text("SSL")
        } footer: {
            footerText("Verify CA and Verify Full check the server certificate against the CA certificate. A client certificate needs its key.")
        }
    }

    private func fileField(_ title: String, _ path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: Spacing.standard) {
                TextField(title, text: path, prompt: Text("None"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                Button("Choose…") { chooseFile(into: path) }
                    .accessibilityLabel("Choose \(title)")
            }
        }
    }

    private func optionsSection(_ source: Binding<DBDataSourceDefinition>) -> some View {
        Section {
            if source.wrappedValue.engineKind != .sqlite {
                TextField(source.wrappedValue.engineKind == .mysql ? "Default Database" : "Default Schema", text: source.defaultSchema, prompt: Text(schemaPrompt(source.wrappedValue)))
            }
            Toggle("Read-only", isOn: source.readOnly)
            Toggle("Production", isOn: productionBinding(source))
            Picker("Transactions", selection: source.transactionMode) {
                Text(source.wrappedValue.production ? "Default (Manual)" : "Default (Auto-Commit)").tag("")
                ForEach(DBTransactionMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Options")
        } footer: {
            footerText("Read-only refuses statements that change data. Production asks before every statement that changes data and turns on Read-only when you mark it. Transactions sets how new consoles start: Auto-Commit keeps each statement, Manual waits for Commit.")
        }
    }

    private func schemaPrompt(_ source: DBDataSourceDefinition) -> String {
        let schema = source.engineKind?.defaultSchema ?? ""
        return schema.isEmpty ? "Server default" : schema
    }

    private var selectedTestFailure: (source: DBDataSourceDefinition, error: DBError?)? {
        guard let index = selectedIndex, let result = testResults[drafts[index].id], !result.ok else { return nil }
        return (drafts[index], result.error)
    }

    private func testControls(_ source: DBDataSourceDefinition) -> some View {
        HStack(spacing: Spacing.comfortable) {
            Button("Test Connection") { test(source) }
                .disabled(testing.contains(source.id))
            testStatus(source)
        }
    }

    @ViewBuilder
    private func testStatus(_ source: DBDataSourceDefinition) -> some View {
        if testing.contains(source.id) {
            HStack(spacing: Spacing.standard) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(source.summary)…")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
        } else if let result = testResults[source.id] {
            Label {
                Text(result.ok ? connectedSummary(result) : "Couldn’t Connect")
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: (result.ok ? StatusTone.success : StatusTone.warning).symbol)
                    .foregroundStyle((result.ok ? StatusTone.success : StatusTone.warning).tint)
            }
            .help(result.ok ? connectedSummary(result) : (result.error?.message ?? ""))
            .accessibilityElement(children: .combine)
        }
    }

    private func connectedSummary(_ result: DBTestConnectionResult) -> String {
        (["Connected", result.serverVersion, UserMessage.duration(Double(result.latencyMs) / 1000)].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func engineBinding(_ source: Binding<DBDataSourceDefinition>) -> Binding<DBEngine> {
        Binding(
            get: { source.wrappedValue.engineKind ?? .postgres },
            set: { engine in
                var draft = source.wrappedValue
                let old = draft.engineKind
                guard old != engine else { return }
                draft.engine = engine.rawValue
                if draft.port == 0 || draft.port == old?.defaultPort { draft.port = engine.defaultPort }
                if draft.defaultSchema.isEmpty || draft.defaultSchema == old?.defaultSchema { draft.defaultSchema = engine.defaultSchema }
                if engine == .sqlite {
                    draft.password = DBPasswordMode.none.rawValue
                    draft.ssl.mode = DBSSLMode.disable.rawValue
                } else if old == .sqlite {
                    if draft.host.isEmpty { draft.host = "localhost" }
                    draft.password = DBPasswordMode.keychain.rawValue
                    draft.ssl.mode = DBSSLMode.prefer.rawValue
                }
                source.wrappedValue = draft
                testResults[draft.id] = nil
            }
        )
    }

    private func productionBinding(_ source: Binding<DBDataSourceDefinition>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue.production },
            set: { isOn in
                source.wrappedValue.production = isOn
                if isOn { source.wrappedValue.readOnly = true }
            }
        )
    }

    private func secretBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { secrets[id] ?? "" },
            set: { secrets[id] = $0 }
        )
    }

    private func isSaved(_ id: String) -> Bool {
        workspace.database.definition(id)?.passwordMode == .keychain
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        baseFile = workspace.database.file
        drafts = baseFile.dataSources
        selection = initialSelection.flatMap { id in drafts.contains { $0.id == id } ? id : nil } ?? drafts.first?.id
    }

    private func add() {
        var source = DBDataSourceDefinition(name: uniqueName("New Data Source"), engine: .postgres)
        source.user = NSUserName()
        drafts.append(source)
        selection = source.id
    }

    private func duplicate(_ source: DBDataSourceDefinition) {
        var copy = source
        copy.id = UUID().uuidString
        copy.name = uniqueName(source.name + " Copy")
        if let secret = secrets[source.id] { secrets[copy.id] = secret }
        drafts.append(copy)
        selection = copy.id
    }

    private func remove(_ id: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts.remove(at: index)
        secrets[id] = nil
        testResults[id] = nil
        issues.removeAll { $0.id == id }
        selection = drafts.isEmpty ? nil : drafts[min(index, drafts.count - 1)].id
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(drafts.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func test(_ source: DBDataSourceDefinition) {
        testing.insert(source.id)
        testResults[source.id] = nil
        workspace.testDataSourceConnection(source, typedSecret: secrets[source.id] ?? "") { result in
            testing.remove(source.id)
            testResults[source.id] = result
        }
    }

    private func done() {
        var file = baseFile
        file.dataSources = drafts.map { draft in
            var source = draft
            source.name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            source.host = source.host.trimmingCharacters(in: .whitespacesAndNewlines)
            source.user = source.user.trimmingCharacters(in: .whitespacesAndNewlines)
            source.sqlitePath = source.sqlitePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.name.isEmpty { source.name = "Untitled" }
            return source
        }
        let typed = secrets.filter { !$0.value.isEmpty }
        do {
            let found = try workspace.saveDataSources(file, secrets: typed)
            baseFile = workspace.database.file
            secrets = [:]
            if found.isEmpty {
                dismiss()
            } else {
                issues = found
                saveError = nil
                if let id = found.first?.id, drafts.contains(where: { $0.id == id }) { selection = id }
            }
        } catch {
            saveError = "\(WorkspaceState.failureReason(error)) Check that you can write to the .golens folder in the project, then try again."
        }
    }

    private func chooseFile(into path: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let root = workspace.activeWorkspacePath
        if !root.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: root)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let full = url.path
        path.wrappedValue = !root.isEmpty && full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : full
    }
}
