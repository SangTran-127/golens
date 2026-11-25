import AppKit
import SwiftUI

struct ExtractParamDTO: Codable, Hashable, Identifiable {
    let name: String
    let type: String

    var id: String {
        "\(name):\(type)"
    }
}

struct ExtractMethodPreviewDTO: Codable, Hashable, Identifiable {
    let defaultName: String?
    let receiver: String?
    let params: [ExtractParamDTO]?
    let results: [ExtractParamDTO]?
    let previewSignature: String?
    let previewCall: String?
    let startByte: Int
    let endByte: Int
    let editsByPath: [String: [LSPTextEdit]]?
    let error: String?

    var id: String {
        "\(startByte)-\(endByte)-\(defaultName ?? "extractedFunc")"
    }

    init(
        defaultName: String? = nil,
        receiver: String? = nil,
        params: [ExtractParamDTO]? = nil,
        results: [ExtractParamDTO]? = nil,
        previewSignature: String? = nil,
        previewCall: String? = nil,
        startByte: Int,
        endByte: Int,
        editsByPath: [String: [LSPTextEdit]]? = nil,
        error: String? = nil
    ) {
        self.defaultName = defaultName
        self.receiver = receiver
        self.params = params
        self.results = results
        self.previewSignature = previewSignature
        self.previewCall = previewCall
        self.startByte = startByte
        self.endByte = endByte
        self.editsByPath = editsByPath
        self.error = error
    }

    static func == (lhs: ExtractMethodPreviewDTO, rhs: ExtractMethodPreviewDTO) -> Bool {
        lhs.defaultName == rhs.defaultName
            && lhs.receiver == rhs.receiver
            && lhs.params == rhs.params
            && lhs.results == rhs.results
            && lhs.previewSignature == rhs.previewSignature
            && lhs.previewCall == rhs.previewCall
            && lhs.startByte == rhs.startByte
            && lhs.endByte == rhs.endByte
            && lhs.error == rhs.error
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(defaultName)
        hasher.combine(receiver)
        hasher.combine(params)
        hasher.combine(results)
        hasher.combine(previewSignature)
        hasher.combine(previewCall)
        hasher.combine(startByte)
        hasher.combine(endByte)
        hasher.combine(error)
    }
}

struct ExtractMethodSheetView: View {
    let preview: ExtractMethodPreviewDTO
    let onApply: (String) -> Void
    let onCancel: () -> Void
    @State private var funcName: String

    init(
        preview: ExtractMethodPreviewDTO,
        onApply: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.preview = preview
        self.onApply = onApply
        self.onCancel = onCancel
        let initial = (preview.defaultName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self._funcName = State(initialValue: initial.isEmpty ? "extractedFunc" : initial)
    }

    private var effectiveName: String {
        let trimmed = funcName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "extractedFunc" : trimmed
    }

    private var detectedParams: [ExtractParamDTO] {
        preview.params ?? []
    }

    private var detectedResults: [ExtractParamDTO] {
        preview.results ?? []
    }

    private var liveSignaturePreview: String {
        let recv = (preview.receiver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recvPrefix = recv.isEmpty ? "" : "(\(recv)) "
        let paramsPart = detectedParams
            .map { "\($0.name) \($0.type)" }
            .joined(separator: ", ")

        let resultsPart: String
        if detectedResults.isEmpty {
            resultsPart = ""
        } else if detectedResults.count == 1 {
            resultsPart = " \(detectedResults[0].type)"
        } else {
            let types = detectedResults.map(\.type).joined(separator: ", ")
            resultsPart = " (\(types))"
        }
        return "func \(recvPrefix)\(effectiveName)(\(paramsPart))\(resultsPart)"
    }

    private var liveCallPreview: String {
        let recv = (preview.receiver ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let recvIdent = recv.split(separator: " ").first.map(String.init) ?? ""
        let target = recvIdent.isEmpty ? effectiveName : "\(recvIdent).\(effectiveName)"
        let args = detectedParams.map(\.name).joined(separator: ", ")
        let callExpr = "\(target)(\(args))"
        if detectedResults.isEmpty {
            return callExpr
        }
        let lhs = detectedResults.map(\.name).joined(separator: ", ")
        let assignOp = (preview.previewCall ?? "").contains(":=") ? ":=" : "="
        return "\(lhs) \(assignOp) \(callExpr)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Extract Function")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Extract the selected statements into a reusable function or method.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.row) {
                HStack {
                    Text("Function Name")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let recv = preview.receiver, !recv.isEmpty {
                        Text("Method on (\(recv))")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("Function Name", text: $funcName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .background(PopupFieldAutoFocus())
                    .accessibilityLabel("Extracted Function Name")
                    .onSubmit { commit() }
            }

            HStack(alignment: .top, spacing: Spacing.comfortable) {
                parameterSummaryBox(
                    title: "Parameters (\(detectedParams.count))",
                    items: detectedParams,
                    emptyLabel: "No input parameters"
                )

                parameterSummaryBox(
                    title: "Return Values (\(detectedResults.count))",
                    items: detectedResults,
                    emptyLabel: "Void (no return values)"
                )
            }

            VStack(alignment: .leading, spacing: Spacing.row) {
                Text("Signature & Call Site Preview")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: Spacing.row) {
                    Text(liveSignaturePreview)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)

                    Divider()

                    HStack(spacing: Spacing.row) {
                        Text("Call:")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text(liveCallPreview)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.inset)
                .wellBackground()
            }

            HStack(spacing: Spacing.standard) {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Extract Function") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(funcName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Confirm Extract Function")
            }
        }
        .padding(Spacing.section)
        .sheetFrame(.standard)
        .onExitCommand {
            onCancel()
        }
    }

    private func parameterSummaryBox(
        title: String,
        items: [ExtractParamDTO],
        emptyLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                if items.isEmpty {
                    Text(emptyLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.hairline)
                } else {
                    ForEach(items) { item in
                        HStack(spacing: Spacing.row) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium).monospaced())
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Text(item.type)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.standard)
            .wellBackground()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commit() {
        let trimmed = funcName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onApply(trimmed)
    }
}
