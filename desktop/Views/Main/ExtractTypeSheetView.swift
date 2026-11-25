import AppKit
import SwiftUI

struct ExtractTypeReplyDTO: Codable, Equatable, Hashable {
    var defaultTypeName: String
    var extractedTypeExpr: String
    var previewDeclaration: String
    var previewReplacement: String
    var edits: [LSPTextEdit]?
    var editsByPath: [String: [LSPTextEdit]]?
    var propagatedStructs: [String]?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case defaultTypeName
        case extractedTypeExpr
        case previewDeclaration
        case previewReplacement
        case edits
        case editsByPath
        case propagatedStructs
        case error
    }

    init(
        defaultTypeName: String = "",
        extractedTypeExpr: String = "",
        previewDeclaration: String = "",
        previewReplacement: String = "",
        edits: [LSPTextEdit]? = nil,
        editsByPath: [String: [LSPTextEdit]]? = nil,
        propagatedStructs: [String]? = nil,
        error: String? = nil
    ) {
        self.defaultTypeName = defaultTypeName
        self.extractedTypeExpr = extractedTypeExpr
        self.previewDeclaration = previewDeclaration
        self.previewReplacement = previewReplacement
        self.edits = edits
        self.editsByPath = editsByPath
        self.propagatedStructs = propagatedStructs
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultTypeName = try container.decodeIfPresent(String.self, forKey: .defaultTypeName) ?? ""
        self.extractedTypeExpr = try container.decodeIfPresent(String.self, forKey: .extractedTypeExpr) ?? ""
        self.previewDeclaration = try container.decodeIfPresent(String.self, forKey: .previewDeclaration) ?? ""
        self.previewReplacement = try container.decodeIfPresent(String.self, forKey: .previewReplacement) ?? ""
        self.edits = try container.decodeIfPresent([LSPTextEdit].self, forKey: .edits)
        self.editsByPath = try container.decodeIfPresent([String: [LSPTextEdit]].self, forKey: .editsByPath)
        self.propagatedStructs = try container.decodeIfPresent([String].self, forKey: .propagatedStructs)
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    static func == (lhs: ExtractTypeReplyDTO, rhs: ExtractTypeReplyDTO) -> Bool {
        lhs.defaultTypeName == rhs.defaultTypeName
            && lhs.extractedTypeExpr == rhs.extractedTypeExpr
            && lhs.previewDeclaration == rhs.previewDeclaration
            && lhs.previewReplacement == rhs.previewReplacement
            && lhs.propagatedStructs == rhs.propagatedStructs
            && lhs.error == rhs.error
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(defaultTypeName)
        hasher.combine(extractedTypeExpr)
        hasher.combine(previewDeclaration)
        hasher.combine(previewReplacement)
        hasher.combine(propagatedStructs)
        hasher.combine(error)
    }
}

struct ExtractTypeSheetView: View {
    let initialPreview: ExtractTypeReplyDTO
    let onRefresh: (_ newTypeName: String) -> ExtractTypeReplyDTO?
    let onApply: (_ newTypeName: String) -> Void
    let onCancel: () -> Void

    @State private var typeName: String
    @State private var currentPreview: ExtractTypeReplyDTO
    @FocusState private var isTypeNameFocused: Bool

    init(
        initialPreview: ExtractTypeReplyDTO,
        onRefresh: @escaping (_ newTypeName: String) -> ExtractTypeReplyDTO?,
        onApply: @escaping (_ newTypeName: String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialPreview = initialPreview
        self.onRefresh = onRefresh
        self.onApply = onApply
        self.onCancel = onCancel
        let initialName = initialPreview.defaultTypeName.trimmingCharacters(in: .whitespacesAndNewlines)
        self._typeName = State(initialValue: initialName.isEmpty ? "ExtractedType" : initialName)
        self._currentPreview = State(initialValue: initialPreview)
    }

    private var trimmedTypeName: String {
        typeName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveTypeName: String {
        trimmedTypeName.isEmpty ? "ExtractedType" : trimmedTypeName
    }

    private var liveDeclarationText: String {
        if !currentPreview.previewDeclaration.isEmpty {
            return currentPreview.previewDeclaration
        }
        return "type \(effectiveTypeName) \(initialPreview.extractedTypeExpr)"
    }

    private var liveReplacementText: String {
        if !currentPreview.previewReplacement.isEmpty {
            return currentPreview.previewReplacement
        }
        return effectiveTypeName
    }

    private func refreshPreview() {
        if let updated = onRefresh(effectiveTypeName), (updated.error ?? "").isEmpty {
            currentPreview = updated
        } else {
            currentPreview.previewDeclaration = "type \(effectiveTypeName) \(initialPreview.extractedTypeExpr)"
            currentPreview.previewReplacement = effectiveTypeName
        }
    }

    private func commit() {
        guard !trimmedTypeName.isEmpty else { return }
        onApply(trimmedTypeName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Extract Type Definition")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Introduce a named package-level type for the selected type expression.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.row) {
                HStack {
                    Text("Type Name")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !initialPreview.extractedTypeExpr.isEmpty {
                        Text(initialPreview.extractedTypeExpr.components(separatedBy: .newlines).first ?? "")
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TextField("Type Name", text: $typeName)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .focused($isTypeNameFocused)
                    .background(PopupFieldAutoFocus())
                    .accessibilityLabel("Extracted Type Name")
                    .onSubmit {
                        commit()
                    }
            }
            .onChange(of: typeName) { _, _ in
                refreshPreview()
            }

            VStack(alignment: .leading, spacing: Spacing.row) {
                Text("Live Preview")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text(liveDeclarationText)
                        .font(.callout.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    Divider()

                    HStack(alignment: .top, spacing: Spacing.row) {
                        Text("Usage:")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text(liveReplacementText)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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
                .accessibilityLabel("Cancel Extract Type")

                Button("Extract Type") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trimmedTypeName.isEmpty)
                .accessibilityLabel("Confirm Extract Type")
            }
        }
        .padding(Spacing.section)
        .sheetFrame(.standard)
        .onAppear {
            isTypeNameFocused = true
        }
        .onExitCommand {
            onCancel()
        }
    }
}

struct PropagateInterfaceSheetView: View {
    let preview: ExtractTypeReplyDTO
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Propagate Method to Implementations")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Add missing interface method stubs to implementing structs across the package.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Spacing.row) {
                Text("Target Types (\(preview.propagatedStructs?.count ?? 0))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                let structs = preview.propagatedStructs ?? []
                if structs.isEmpty {
                    Text("All implementing structs in this package already satisfy \(preview.defaultTypeName.isEmpty ? "the interface" : preview.defaultTypeName).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(Spacing.inset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .wellBackground()
                } else {
                    HStack(spacing: Spacing.row) {
                        ForEach(structs, id: \.self) { name in
                            HStack(spacing: Spacing.compact) {
                                Image(systemName: "s.square")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                Text(name)
                                    .font(.callout.weight(.medium).monospaced())
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, Spacing.standard)
                            .padding(.vertical, Spacing.compact)
                            .wellBackground(cornerRadius: CornerRadius.panelRow)
                        }
                    }
                }
            }

            if !preview.previewDeclaration.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.row) {
                    Text("Generated Method Stubs Preview")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(preview.previewDeclaration)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 80, maxHeight: 160)
                    .padding(Spacing.inset)
                    .wellBackground()
                }
            }

            HStack(spacing: Spacing.standard) {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel Propagate Methods")

                Button("Propagate Methods") {
                    onApply()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled((preview.propagatedStructs ?? []).isEmpty)
                .accessibilityLabel("Confirm Propagate Methods")
            }
        }
        .padding(Spacing.section)
        .sheetFrame(.standard)
        .onExitCommand {
            onCancel()
        }
    }
}
