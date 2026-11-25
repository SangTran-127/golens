import SwiftUI

struct DatabaseAttachMenuItems: View {
    @Bindable var workspace: WorkspaceState
    let path: String

    var body: some View {
        Picker("Data Source", selection: Binding(
            get: { workspace.databaseDataSourceID(forConsole: path) ?? "" },
            set: { workspace.attachDatabaseConsole(path, to: $0.isEmpty ? nil : $0) }
        )) {
            Text("No Data Source").tag("")
            ForEach(workspace.database.definitions) { source in
                Text(source.name).tag(source.id)
            }
        }
        .pickerStyle(.inline)
    }
}
