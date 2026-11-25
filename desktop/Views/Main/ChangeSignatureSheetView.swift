import SwiftUI
import AppKit

struct ChangeSignatureSheetView: View {
    @State var spec: FuncSignatureSpec
    let onApply: (FuncSignatureSpec) -> Void
    let onCancel: () -> Void

    init(spec: FuncSignatureSpec, onApply: @escaping (FuncSignatureSpec) -> Void, onCancel: @escaping () -> Void) {
        self._spec = State(initialValue: spec)
        self.onApply = onApply
        self.onCancel = onCancel
    }

    private var fileName: String {
        URL(fileURLWithPath: spec.path).lastPathComponent
    }

    private var canApply: Bool {
        !spec.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        spec.params.allSatisfy { !$0.type.trimmingCharacters(in: .whitespaces).isEmpty } &&
        spec.results.allSatisfy { !$0.type.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var previewSignature: String {
        let recv = spec.receiver.trimmingCharacters(in: .whitespaces)
        let recvPart = recv.isEmpty ? "" : "(\(recv)) "
        let fnName = spec.name.trimmingCharacters(in: .whitespaces)
        let paramsText = spec.params.map { p in
            let n = p.name.trimmingCharacters(in: .whitespaces)
            let t = p.type.trimmingCharacters(in: .whitespaces)
            return n.isEmpty ? t : "\(n) \(t)"
        }.joined(separator: ", ")

        let resultsText: String
        if spec.results.isEmpty {
            resultsText = ""
        } else if spec.results.count == 1 && spec.results[0].name.trimmingCharacters(in: .whitespaces).isEmpty {
            let t = spec.results[0].type.trimmingCharacters(in: .whitespaces)
            resultsText = t.isEmpty ? "" : " \(t)"
        } else {
            let inner = spec.results.map { r in
                let n = r.name.trimmingCharacters(in: .whitespaces)
                let t = r.type.trimmingCharacters(in: .whitespaces)
                return n.isEmpty ? t : "\(n) \(t)"
            }.joined(separator: ", ")
            resultsText = " (\(inner))"
        }
        return "func \(recvPart)\(fnName)(\(paramsText))\(resultsText)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Text("Change Signature")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text(fileName)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.standard) {
                Text("Function Name")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Function Name", text: $spec.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
            }

            VStack(alignment: .leading, spacing: Spacing.standard) {
                HStack {
                    Text("Parameters")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        spec.params.append(
                            FuncParamSpec(
                                origIndex: -1,
                                name: "param\(spec.params.count + 1)",
                                type: "string",
                                defaultValue: "\"\""
                            )
                        )
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Parameter")
                    .help("Add Parameter")
                }

                if spec.params.isEmpty {
                    Text("No parameters")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, Spacing.compact)
                } else {
                    ScrollView {
                        VStack(spacing: Spacing.row) {
                            ForEach(Array(spec.params.enumerated()), id: \.element.id) { index, param in
                                HStack(spacing: Spacing.standard) {
                                    TextField("Name", text: paramBinding(index, \.name))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout.monospaced())
                                        .frame(width: 112)

                                    TextField("Type", text: paramBinding(index, \.type))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout.monospaced())
                                        .frame(minWidth: 120)

                                    if param.origIndex < 0 {
                                        TextField("Default call value", text: paramBinding(index, \.defaultValue))
                                            .textFieldStyle(.roundedBorder)
                                            .font(.callout.monospaced())
                                            .frame(width: 112)
                                    }

                                    Spacer(minLength: 4)

                                    Button {
                                        if index > 0 {
                                            spec.params.swapAt(index, index - 1)
                                        }
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index == 0)
                                    .accessibilityLabel("Move Parameter Up")
                                    .help("Move Parameter Up")

                                    Button {
                                        if index + 1 < spec.params.count {
                                            spec.params.swapAt(index, index + 1)
                                        }
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index + 1 >= spec.params.count)
                                    .accessibilityLabel("Move Parameter Down")
                                    .help("Move Parameter Down")

                                    Button {
                                        if spec.params.indices.contains(index) {
                                            spec.params.remove(at: index)
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove Parameter")
                                    .help("Remove Parameter")
                                }
                                .padding(.horizontal, Spacing.standard)
                                .padding(.vertical, Spacing.compact)
                                .wellBackground()
                            }
                        }
                    }
                    .frame(height: min(CGFloat(spec.params.count) * 38, 110))
                }
            }

            VStack(alignment: .leading, spacing: Spacing.standard) {
                HStack {
                    Text("Return Values")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        spec.results.append(
                            FuncParamSpec(
                                origIndex: -1,
                                name: "",
                                type: "error"
                            )
                        )
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Return Value")
                    .help("Add Return Value")
                }

                if spec.results.isEmpty {
                    Text("No return values")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, Spacing.compact)
                } else {
                    ScrollView {
                        VStack(spacing: Spacing.row) {
                            ForEach(Array(spec.results.enumerated()), id: \.element.id) { index, _ in
                                HStack(spacing: Spacing.standard) {
                                    TextField("Name (optional)", text: resultBinding(index, \.name))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout.monospaced())
                                        .frame(width: 120)

                                    TextField("Type", text: resultBinding(index, \.type))
                                        .textFieldStyle(.roundedBorder)
                                        .font(.callout.monospaced())

                                    Spacer(minLength: 4)

                                    Button {
                                        if index > 0 {
                                            spec.results.swapAt(index, index - 1)
                                        }
                                    } label: {
                                        Image(systemName: "chevron.up")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index == 0)
                                    .accessibilityLabel("Move Return Value Up")
                                    .help("Move Return Value Up")

                                    Button {
                                        if index + 1 < spec.results.count {
                                            spec.results.swapAt(index, index + 1)
                                        }
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index + 1 >= spec.results.count)
                                    .accessibilityLabel("Move Return Value Down")
                                    .help("Move Return Value Down")

                                    Button {
                                        if spec.results.indices.contains(index) {
                                            spec.results.remove(at: index)
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove Return Value")
                                    .help("Remove Return Value")
                                }
                                .padding(.horizontal, Spacing.standard)
                                .padding(.vertical, Spacing.compact)
                                .wellBackground()
                            }
                        }
                    }
                    .frame(height: min(CGFloat(spec.results.count) * 38, 110))
                }
            }

            VStack(alignment: .leading, spacing: Spacing.standard) {
                Text("Preview")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(previewSignature)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.inset)
                    .wellBackground()
            }

            HStack(spacing: Spacing.standard) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Refactor") {
                    onApply(spec)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
        }
        .padding(Spacing.section)
        .sheetFrame(.standard)
    }

    private func paramBinding(_ index: Int, _ keyPath: WritableKeyPath<FuncParamSpec, String>) -> Binding<String> {
        Binding(
            get: { spec.params.indices.contains(index) ? spec.params[index][keyPath: keyPath] : "" },
            set: { if spec.params.indices.contains(index) { spec.params[index][keyPath: keyPath] = $0 } }
        )
    }

    private func resultBinding(_ index: Int, _ keyPath: WritableKeyPath<FuncParamSpec, String>) -> Binding<String> {
        Binding(
            get: { spec.results.indices.contains(index) ? spec.results[index][keyPath: keyPath] : "" },
            set: { if spec.results.indices.contains(index) { spec.results[index][keyPath: keyPath] = $0 } }
        )
    }
}
