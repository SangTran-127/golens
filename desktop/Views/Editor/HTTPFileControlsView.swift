import SwiftUI

struct HTTPEnvironmentMenuItems: View {
    @Bindable var workspace: WorkspaceState
    let path: String

    var body: some View {
        let outline = workspace.http.outlines[path] ?? .empty
        let environments = outline.environments
        Picker("Environment", selection: Binding(
            get: { workspace.http.environment(for: path) ?? "" },
            set: { workspace.selectHTTPEnvironment($0.isEmpty ? nil : $0, for: path) }
        )) {
            Text("No Environment").tag("")
            ForEach(environments.names, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.inline)

        if !environments.issues.isEmpty {
            Section("Needs Attention") {
                ForEach(environments.issues, id: \.self) { issue in
                    Button("\((issue.file as NSString).lastPathComponent) \(issue.message)", systemImage: "exclamationmark.triangle") {
                        workspace.openFile(issue.file)
                    }
                }
            }
        }

        Divider()

        if let publicFile = environments.publicFile, !publicFile.isEmpty {
            Button("Open http-client.env.json", systemImage: "doc.text") { workspace.openFile(publicFile) }
        } else {
            Button("Create Environment File", systemImage: "doc.badge.plus") { workspace.openOrCreateHTTPEnvironmentFile(for: path) }
        }
        if let privateFile = environments.privateFile, !privateFile.isEmpty {
            Button("Open http-client.private.env.json", systemImage: "lock.doc") { workspace.openFile(privateFile) }
        }
        Button("Clear Global Variables", systemImage: "trash") { workspace.http.globals.removeAll() }
            .disabled(workspace.http.globals.isEmpty)
    }
}

struct HTTPFileControlsView: View {
    @Bindable var workspace: WorkspaceState
    let path: String

    var body: some View {
        let environment = workspace.http.environment(for: path)
        let hasIssues = !(workspace.http.outlines[path]?.environments.issues.isEmpty ?? true)
        let isRunningAll = workspace.http.runAllPaths.contains(path)
        HStack(spacing: Spacing.standard) {
            Menu {
                HTTPEnvironmentMenuItems(workspace: workspace, path: path)
            } label: {
                Label(
                    environment.map { "Environment: \($0)" } ?? "No Environment",
                    systemImage: hasIssues ? "exclamationmark.triangle" : "globe"
                )
                .labelStyle(.titleAndIcon)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help(hasIssues ? "An environment file has a problem. Open the menu to see it." : "Choose the environment whose variables fill {{placeholders}}")
            .accessibilityLabel("HTTP Environment")
            .accessibilityValue(environment ?? "None")

            Button {
                if isRunningAll {
                    workspace.stopAllHTTPRequests()
                } else {
                    workspace.runAllHTTPRequests(path: path)
                }
            } label: {
                Label(isRunningAll ? "Stop" : "Run All", systemImage: isRunningAll ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isRunningAll && (workspace.http.outlines[path]?.requests.isEmpty ?? true))
            .help(
                isRunningAll
                    ? KeymapStore.shared.labeled("Stop running the requests in this file", "product.stopHTTPRequests")
                    : KeymapStore.shared.labeled("Run every request in this file from top to bottom", "product.runAllHTTPRequests")
            )
        }
        .onAppear { workspace.refreshHTTPOutline(path) }
    }
}
