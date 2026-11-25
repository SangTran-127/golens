import SwiftUI

struct DebuggableProcess: Codable, Identifiable, Hashable {
    let pid: Int
    let name: String
    let command: String
    var id: Int { pid }
}

struct AttachProcessSheetView: View {
    enum AttachMode: String, CaseIterable {
        case local = "Local Process"
        case remote = "Remote Delve"
    }

    let processes: [DebuggableProcess]
    let onRefresh: () -> Void
    let onAttachPID: (Int) -> Void
    let onAttachRemote: (String) -> Void
    let onCancel: () -> Void

    @State private var mode: AttachMode = .local
    @State private var filterText: String = ""
    @State private var selectedPID: Int?
    @State private var remoteAddress: String = "127.0.0.1:2345"

    private var filteredProcesses: [DebuggableProcess] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return processes }
        return processes.filter { proc in
            proc.name.lowercased().contains(query) ||
            proc.command.lowercased().contains(query) ||
            String(proc.pid).contains(query)
        }
    }

    private var trimmedRemoteAddress: String {
        remoteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            HStack {
                Text("Attach to Process")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Picker("Attach Mode", selection: $mode) {
                    ForEach(AttachMode.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 220)
                .accessibilityLabel("Attach Mode")
            }

            if mode == .local {
                localProcessContent
            } else {
                remoteDelveContent
            }
        }
        .padding(Spacing.section)
        .sheetFrame(.standard)
        .onAppear {
            if selectedPID == nil {
                selectedPID = filteredProcesses.first?.pid
            }
        }
        .onChange(of: processes) {
            if let current = selectedPID, filteredProcesses.contains(where: { $0.pid == current }) {
                return
            }
            selectedPID = filteredProcesses.first?.pid
        }
        .onChange(of: filterText) {
            if let current = selectedPID, filteredProcesses.contains(where: { $0.pid == current }) {
                return
            }
            selectedPID = filteredProcesses.first?.pid
        }
        .onExitCommand {
            onCancel()
        }
    }

    private var localProcessContent: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            HStack(spacing: Spacing.standard) {
                TextField("Filter", text: $filterText, prompt: Text("Filter by process name or PID…"))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .background(PopupFieldAutoFocus())
                    .accessibilityLabel("Filter by process name or PID")

                Button("Refresh") {
                    onRefresh()
                }
                .controlSize(.regular)
                .font(.callout)
                .accessibilityLabel("Refresh Processes")
            }

            Group {
                if filteredProcesses.isEmpty {
                    VStack(spacing: Spacing.standard) {
                        Text(processes.isEmpty ? "No debuggable processes found" : "No processes match \"\(filterText)\"")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: Spacing.hairline) {
                            ForEach(filteredProcesses) { proc in
                                processRow(proc)
                            }
                        }
                        .padding(Spacing.compact)
                    }
                }
            }
            .frame(height: 260)
            .wellBackground()

            HStack(spacing: Spacing.standard) {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel Attach")

                Button("Attach") {
                    if let pid = selectedPID {
                        onAttachPID(pid)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedPID == nil)
                .accessibilityLabel("Attach to Selected Process")
            }
        }
    }

    private func processRow(_ proc: DebuggableProcess) -> some View {
        let isSelected = selectedPID == proc.pid
        return Button {
            selectedPID = proc.pid
        } label: {
            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.standard) {
                    Text(proc.name)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                        .lineLimit(1)
                    Spacer()
                    Text("PID \(String(proc.pid))")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : .secondary)
                }
                Text(proc.command)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Spacing.standard)
            .padding(.vertical, Spacing.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selectedPID = proc.pid
                onAttachPID(proc.pid)
            }
        )
        .accessibilityLabel("\(proc.name), PID \(String(proc.pid))")
    }

    private var remoteDelveContent: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            VStack(alignment: .leading, spacing: Spacing.row) {
                Text("Delve DAP Server Address")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Host:Port", text: $remoteAddress, prompt: Text("127.0.0.1:2345"))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit {
                        if !trimmedRemoteAddress.isEmpty {
                            onAttachRemote(trimmedRemoteAddress)
                        }
                    }
                    .accessibilityLabel("Host and Port")
                Text("Start Delve with: dlv dap --listen=127.0.0.1:2345")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Spacing.standard) {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel Remote Attach")

                Button("Connect & Attach") {
                    if !trimmedRemoteAddress.isEmpty {
                        onAttachRemote(trimmedRemoteAddress)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedRemoteAddress.isEmpty)
                .accessibilityLabel("Connect and Attach to Remote Delve")
            }
        }
    }
}
