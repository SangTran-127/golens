import AppKit
import SwiftUI

struct InterfaceCandidateItem: Codable, Identifiable, Hashable {
    let name: String
    let package: String
    let methods: [String]
    var id: String { "\(package).\(name)" }
}

struct ImplementInterfaceSheetView: View {
    let structName: String
    let candidates: [InterfaceCandidateItem]
    let onImplement: (String) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @State private var selectedID: String?
    @FocusState private var isSearchFocused: Bool

    init(
        structName: String = "",
        candidates: [InterfaceCandidateItem],
        onImplement: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.structName = structName
        self.candidates = candidates
        self.onImplement = onImplement
        self.onCancel = onCancel
    }

    private var filteredCandidates: [InterfaceCandidateItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { item in
            item.name.localizedCaseInsensitiveContains(trimmed)
                || item.package.localizedCaseInsensitiveContains(trimmed)
                || item.methods.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) })
        }
    }

    private var activeCandidate: InterfaceCandidateItem? {
        if let selectedID, let match = filteredCandidates.first(where: { $0.id == selectedID }) {
            return match
        }
        return filteredCandidates.first
    }

    private var canSubmit: Bool {
        activeCandidate != nil || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var receiverClause: String {
        let target = structName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = target.first else { return "s *Receiver" }
        let recvVar = String(first).lowercased()
        return "\(recvVar) *\(target)"
    }

    private var stubPreviewCode: String {
        if let candidate = activeCandidate, !candidate.methods.isEmpty {
            return candidate.methods.map { sig in
                "func (\(receiverClause)) \(sig) {\n\tpanic(\"not implemented\")\n}"
            }.joined(separator: "\n\n")
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "// Select or enter an interface such as \(trimmed) to generate method stubs on *\(!structName.isEmpty ? structName : "Receiver")."
    }

    private var codePreview: GeneratorCodePreview {
        GeneratorCodePreview(
            code: stubPreviewCode,
            placeholder: "Select an interface above to preview generated Go method stubs.",
            accessibilityLabel: "Generated interface method stubs preview"
        )
    }

    var body: some View {
        GeneratorSheet(
            title: "Implement Interface",
            subtitle: structName.isEmpty
                ? "Choose an interface to generate method stubs in the current file."
                : "Generate missing interface method stubs on \(structName).",
            primaryTitle: "Implement",
            primaryAccessibilityLabel: "Implement Selected Interface",
            cancelAccessibilityLabel: "Cancel Implement Interface",
            canConfirm: canSubmit,
            preview: codePreview,
            previewDetail: activeCandidate.map { "\($0.name) · \($0.methods.count) \($0.methods.count == 1 ? "method" : "methods")" } ?? "",
            onCancel: onCancel,
            onConfirm: submitSelection
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                HStack(spacing: Spacing.standard) {
                    Image(systemName: "magnifyingglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter interfaces (e.g. io.Reader, fmt.Stringer)…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .focused($isSearchFocused)
                        .background(PopupFieldAutoFocus())
                        .accessibilityLabel("Filter interfaces")
                        .onSubmit {
                            submitSelection()
                        }
                }
                .padding(.horizontal, Spacing.inset)
                .padding(.vertical, Spacing.standard)
                .wellBackground()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.row) {
                        if filteredCandidates.isEmpty {
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text("No matching workspace or standard library interfaces")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary)
                                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Press Return to implement \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                                        .font(.subheadline)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Spacing.section)
                            .wellBackground()
                        } else {
                            ForEach(filteredCandidates) { item in
                                let isSelected = activeCandidate?.id == item.id
                                Button {
                                    selectedID = item.id
                                } label: {
                                    VStack(alignment: .leading, spacing: Spacing.compact) {
                                        HStack(spacing: Spacing.standard) {
                                            Text(item.name)
                                                .font(.body.weight(.medium).monospaced())
                                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                                            Spacer()
                                            Text(item.package)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                                .padding(.horizontal, Spacing.standard)
                                                .padding(.vertical, Spacing.hairline)
                                                .background(
                                                    Capsule()
                                                        .fill(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.2) : ThemeColor.wellFill)
                                                )
                                        }
                                        Text(item.methods.joined(separator: "  ·  "))
                                            .font(.subheadline.monospaced())
                                            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85) : .secondary)
                                            .lineLimit(2)
                                            .truncationMode(.tail)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(Spacing.inset)
                                    .background(
                                        RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                                            .fill(
                                                isSelected
                                                    ? Color(nsColor: .selectedContentBackgroundColor)
                                                    : ThemeColor.wellFill
                                            )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                                            .strokeBorder(
                                                isSelected ? Color.clear : ThemeColor.wellStroke,
                                                lineWidth: Stroke.hairline
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.name) in package \(item.package)")
                            }
                        }
                    }
                    .padding(.vertical, Spacing.hairline)
                }
                .frame(height: 168)
            }
        }
        .onAppear {
            selectedID = candidates.first?.id
            isSearchFocused = true
        }
    }

    private func submitSelection() {
        if let candidate = activeCandidate {
            onImplement(candidate.name)
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onImplement(trimmed)
    }
}

struct MoveSymbolSheetView: View {
    let symbolName: String
    let currentFile: String
    let siblingFiles: [String]
    let onMove: (String) -> Void
    let onCancel: () -> Void

    @State private var targetFilename: String = ""
    @FocusState private var isInputFocused: Bool

    init(
        symbolName: String = "",
        currentFile: String,
        siblingFiles: [String],
        onMove: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.symbolName = symbolName
        self.currentFile = currentFile
        self.siblingFiles = siblingFiles
        self.onMove = onMove
        self.onCancel = onCancel
    }

    private var trimmedTarget: String {
        targetFilename.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        StandardSheetShell(
            title: "Move Symbol",
            subtitle: symbolName.isEmpty
                ? "Move the declaration at the cursor out of \((currentFile as NSString).lastPathComponent)."
                : "Move '\(symbolName)' from \((currentFile as NSString).lastPathComponent) to another file, in this package or another one.",
            size: .standard,
            primaryTitle: "Move",
            primaryAccessibilityLabel: "Move Symbol to Destination File",
            isPrimaryDisabled: trimmedTarget.isEmpty,
            closeTitle: "Cancel",
            closeAccessibilityLabel: "Cancel Move Symbol",
            onPrimary: submitMove,
            onClose: onCancel
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                VStack(alignment: .leading, spacing: Spacing.standard) {
                    Text("Destination")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("helpers.go or internal/store/store.go", text: $targetFilename)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .focused($isInputFocused)
                        .background(PopupFieldAutoFocus())
                        .accessibilityLabel("Destination file")
                        .onSubmit {
                            submitMove()
                        }

                    Text("A file name keeps it in this package. A path from the project root, such as internal/store/store.go, moves it to that package and updates every reference and import.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !siblingFiles.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.standard) {
                        Text("Existing Package Files")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: Spacing.row) {
                                ForEach(siblingFiles, id: \.self) { file in
                                    let base = (file as NSString).lastPathComponent
                                    let isSelected = trimmedTarget == base || trimmedTarget == file
                                    Button {
                                        targetFilename = base
                                    } label: {
                                        HStack(spacing: Spacing.standard) {
                                            Image(systemName: "doc.text")
                                                .font(.callout)
                                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary)
                                                .accessibilityHidden(true)
                                            Text(base)
                                                .font(.body.monospaced())
                                                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
                                            Spacer()
                                        }
                                        .padding(Spacing.standard)
                                        .background(
                                            RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                                                .fill(
                                                    isSelected
                                                        ? Color(nsColor: .selectedContentBackgroundColor)
                                                        : ThemeColor.wellFill
                                                )
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
                                                .strokeBorder(
                                                    isSelected ? Color.clear : ThemeColor.wellStroke,
                                                    lineWidth: Stroke.hairline
                                                )
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Select destination file \(base)")
                                }
                            }
                            .padding(.vertical, Spacing.hairline)
                        }
                        .frame(maxHeight: 160)
                    }
                }
            }
        }
        .onAppear {
            targetFilename = "helpers.go"
            isInputFocused = true
        }
    }

    private func submitMove() {
        guard !trimmedTarget.isEmpty else { return }
        onMove(trimmedTarget)
    }
}
