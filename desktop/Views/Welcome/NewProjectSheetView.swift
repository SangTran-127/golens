import SwiftUI

struct NewProjectSheetView: View {
    @Environment(\.dismiss) var dismiss
    @Bindable var workspace = WorkspaceState.shared

    @State private var projectName = "my-app"
    @State private var moduleName = "example.com/my-app"
    @State private var moduleEdited = false
    @State private var selectedParentFolder = Self.defaultParentFolder()
    @State private var selectedTemplateIndex = 0
    @State private var locationError: String?
    @FocusState private var isProjectNameFocused: Bool

    let templates = [
        NewProjectTemplate(
            id: "cli",
            name: "CLI Application",
            description: "Console executable with main print statements.",
            icon: "terminal"
        ),
        NewProjectTemplate(
            id: "http",
            name: "HTTP Web Server",
            description: "net/http server listening on port 8080.",
            icon: "globe"
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Spacing.compact) {
                Text("New Go Project")
                    .font(.headline)
                Text("Choose a template and configure your workspace.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Spacing.section)
            .padding(.bottom, Spacing.section)

            Divider()

            if let locationError {
                InlineBanner(
                    .status(.failure),
                    title: "Couldn’t Create Project",
                    message: locationError,
                    onClose: { self.locationError = nil }
                )
            }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text("Template")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.section)

                    List(0..<templates.count, id: \.self, selection: $selectedTemplateIndex) { index in
                        let t = templates[index]
                        HStack(spacing: Spacing.inset) {
                            Image(systemName: t.icon)
                                .font(.body)
                                .rowTint(.accentColor)
                                .frame(width: 20, height: 20)

                            VStack(alignment: .leading, spacing: Spacing.hairline) {
                                Text(t.name)
                                    .font(.callout.weight(.semibold))
                                Text(t.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, Spacing.compact)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                .frame(width: 240)
                .padding(.vertical, Spacing.comfortable)

                Divider()

                VStack(alignment: .leading, spacing: Spacing.section) {
                    Text("Configuration")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("Project Name")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("my-app", text: $projectName)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                            .focused($isProjectNameFocused)
                            .onAppear { isProjectNameFocused = true }
                            .onChange(of: projectName) { _, name in
                                locationError = nil
                                if !moduleEdited { moduleName = Self.defaultModule(for: name) }
                            }
                    }

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("Module Path")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("github.com/user/my-app", text: Binding(get: { moduleName }, set: { moduleName = $0; moduleEdited = true; locationError = nil }))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("Location")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(selectedParentFolder.isEmpty ? "No folder selected" : selectedParentFolder)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(selectedParentFolder.isEmpty ? .secondary : .primary)

                            Spacer()

                            Button("Choose…") { chooseDestination() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }

                    Spacer()

                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Button("Create") { createProject() }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(projectName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      moduleName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      selectedParentFolder.isEmpty)
                    }
                }
                .padding(Spacing.section)
            }
        }
        .sheetFrame(.medium)
        .frame(minHeight: 340)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Location"
        if panel.runModal() == .OK, let url = panel.url {
            SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
            selectedParentFolder = url.path
            locationError = nil
        }
    }

    private func createProject() {
        let projName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modName = moduleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projName.isEmpty && !modName.isEmpty && !selectedParentFolder.isEmpty else { return }

        let projectURL = URL(fileURLWithPath: selectedParentFolder).appendingPathComponent(projName)
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        if fileManager.fileExists(atPath: projectURL.path, isDirectory: &isFolder),
           !isFolder.boolValue || !((try? fileManager.contentsOfDirectory(atPath: projectURL.path))?.isEmpty ?? false) {
            locationError = "“\(projName)” already exists in “\(projectURL.deletingLastPathComponent().lastPathComponent)”. Choose a different name or location."
            return
        }

        do {
            try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true, attributes: nil)
            SecurityScopedBookmarkManager.shared.saveBookmark(for: projectURL)

            try Self.initModule(modName, in: projectURL)
            let mainGoContent = selectedTemplateIndex == 1 ? Self.httpMain : Self.cliMain
            let mainGoURL = projectURL.appendingPathComponent("main.go")
            try mainGoContent.write(to: mainGoURL, atomically: true, encoding: .utf8)

            UserDefaults.standard.set(selectedParentFolder, forKey: Self.parentFolderKey)
            let projectPath = projectURL.path
            let mainGoPath = mainGoURL.path
            workspace.showNewProjectSheet = false
            WorkspaceSessionRegistry.shared.showWelcomeNewProjectSheet = false
            dismiss()
            DispatchQueue.main.async {
                WorkspaceSessionRegistry.shared.openProject(at: projectPath) { targetWorkspace in
                    targetWorkspace.openFile(mainGoPath)
                }
            }
        } catch {
            locationError = error.localizedDescription
            workspace.appendLog("Failed to create project: \(error.localizedDescription)")
        }
    }
}

extension NewProjectSheetView {
    static let parentFolderKey = "GoLensNewProjectFolder"

    static func defaultParentFolder() -> String {
        let fm = FileManager.default
        if let last = UserDefaults.standard.string(forKey: parentFolderKey), fm.fileExists(atPath: last) { return last }
        let home = fm.homeDirectoryForCurrentUser
        for name in ["GolandProjects", "Developer"] where fm.fileExists(atPath: home.appendingPathComponent(name).path) {
            return home.appendingPathComponent(name).path
        }
        return home.appendingPathComponent("Documents").path
    }

    static func defaultModule(for name: String) -> String {
        "example.com/" + name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
    }

    static func initModule(_ module: String, in dir: URL) throws {
        try "module \(module)\n\ngo 1.22\n".write(to: dir.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
    }

    static let cliMain = """
    package main

    import "fmt"

    func main() {
    \tfmt.Println("Hello, GoLens!")
    }

    """

    static let httpMain = """
    package main

    import (
    \t"fmt"
    \t"net/http"
    )

    func main() {
    \thttp.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
    \t\tfmt.Fprintln(w, "Hello from GoLens!")
    \t})
    \tfmt.Println("Listening on :8080")
    \tif err := http.ListenAndServe(":8080", nil); err != nil {
    \t\tfmt.Println("Error:", err)
    \t}
    }

    """
}

struct NewProjectTemplate {
    let id: String
    let name: String
    let description: String
    let icon: String
}
