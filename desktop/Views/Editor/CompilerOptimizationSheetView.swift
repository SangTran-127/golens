import AppKit
import SwiftUI

struct CompilerOptimizationSheetView: View {
    @Environment(\.windowWorkspace) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onClose: () -> Void

    enum CategoryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case inlining = "Inlining"
        case bce = "BCE"
        case heap = "Heap"

        var id: String { rawValue }
    }

    enum TargetArch: String, CaseIterable, Identifiable {
        case arm64 = "ARM64"
        case amd64 = "AMD64"

        var id: String { rawValue }
    }

    @State private var filter: CategoryFilter = .all
    @State private var selectedArch: TargetArch = .arm64
    @State private var decisions: [CompilerDecisionItem] = []
    @State private var disasmInstructions: [DisasmInstruction] = []
    @State private var selectedLine: Int? = nil
    @State private var isLoadingDecisions: Bool = false
    @State private var isLoadingDisasm: Bool = false
    @State private var errorMessage: String? = nil

    private var currentFunctionName: String {
        let text = workspace.activeTextView?.string ?? ""
        let decls = workspace.activeGoDeclarations.isEmpty ? workspace.findGoDeclarations(in: text) : workspace.activeGoDeclarations
        if let line = selectedLine, let decl = decls.last(where: { $0.line <= line && ($0.kind == "func" || $0.kind == "method") }) {
            return decl.symbolName
        }
        if let decl = decls.last(where: { $0.line <= workspace.cursorLine && ($0.kind == "func" || $0.kind == "method") }) {
            return decl.symbolName
        }
        return decls.first(where: { $0.kind == "func" || $0.kind == "method" })?.symbolName ?? "main"
    }

    private var filteredDecisions: [CompilerDecisionItem] {
        switch filter {
        case .all:
            return decisions
        case .inlining:
            return decisions.filter { $0.category == "inline_ok" || $0.category == "inline_blocked" || $0.kind == "inline" || $0.kind == "inline_blocked" }
        case .bce:
            return decisions.filter { $0.category == "bce_check" || $0.kind == "bce_check" }
        case .heap:
            return decisions.filter { $0.category == "escape" || $0.category == "leak" || $0.kind == "heap" || $0.kind == "leak" }
        }
    }

    var body: some View {
        let isDark = workspace.currentTheme.resolvedIsDark
        VStack(spacing: 0) {
            headerBar(isDark: isDark)
            Divider()

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    decisionsHeader
                    Divider()
                    decisionsList(isDark: isDark)
                }
                .frame(width: 380)

                Divider()

                VStack(spacing: 0) {
                    disasmHeader
                    Divider()
                    disasmTable(isDark: isDark)
                }
                .frame(maxWidth: .infinity)
            }

            Divider()
            footerBar(isDark: isDark)
        }
        .sheetFrame(.splitInspector)
        .onExitCommand(perform: onClose)
        .onAppear {
            loadDecisions()
            loadDisassembly()
        }
    }

    private func headerBar(isDark: Bool) -> some View {
        let fileName = (workspace.activeFilePath as NSString).lastPathComponent
        return HStack(spacing: Spacing.standard) {
            Image(systemName: "cpu")
                .foregroundStyle(Color.accentColor)
                .font(.headline)

            Text("Compiler Optimization & Live Disassembly")
                .font(.headline)
                .foregroundStyle(.primary)

            if !fileName.isEmpty {
                Text(fileName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.row)
                    .padding(.vertical, Spacing.hairline)
                    .wellBackground(cornerRadius: CornerRadius.small)
            }

            Spacer()

            Button {
                loadDecisions()
                loadDisassembly()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Re-analyze Optimization & Refresh Disassembly")
            .accessibilityLabel("Refresh Compiler Analysis")
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.inset)
    }

    private var decisionsHeader: some View {
        HStack {
            Text("Compiler Decisions (\(filteredDecisions.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Picker("Category", selection: $filter) {
                ForEach(CategoryFilter.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 200)
            .accessibilityLabel("Compiler Decision Filter")
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }

    private func decisionsList(isDark: Bool) -> some View {
        Group {
            if isLoadingDecisions {
                VStack(spacing: Spacing.standard) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing compiler SSA…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDecisions.isEmpty {
                VStack(spacing: Spacing.row) {
                    Image(systemName: "checkmark.seal")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No Decisions Found")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Code has no escape or bounds check warnings for this filter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.content)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedLine) {
                    ForEach(filteredDecisions) { item in
                        decisionRow(item: item, isDark: isDark)
                            .tag(item.line)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func decisionRow(item: CompilerDecisionItem, isDark: Bool) -> some View {
        Button {
            selectedLine = item.line
        } label: {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.row) {
                    Text("L\(item.line)")
                        .font(.caption.weight(.bold).monospaced())
                        .padding(.horizontal, Spacing.compact)
                        .padding(.vertical, Spacing.hairline)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))

                    categoryBadge(for: item)

                    Text(item.summary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()
                }

                if let hint = item.hint, !hint.isEmpty {
                    HStack(alignment: .top, spacing: Spacing.compact) {
                        Image(systemName: "lightbulb.fill")
                            .font(.caption2)
                            .foregroundStyle(StatusTone.warning.tint)
                            .padding(.top, Spacing.hairline)
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, Spacing.hairline)
                }
            }
            .padding(.vertical, Spacing.compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func categoryBadge(for item: CompilerDecisionItem) -> some View {
        let (label, color): (String, Color) = {
            switch item.category ?? item.kind {
            case "bce_check":
                return ("BCE", StatusTone.warning.tint)
            case "inline_ok":
                return ("Inline", StatusTone.success.tint)
            case "inline_blocked":
                return ("Blocked", StatusTone.failure.tint)
            case "escape":
                return ("Heap", .purple)
            case "leak":
                return ("Leak", .blue)
            default:
                return ("SSA", .secondary)
            }
        }()

        return Text(label)
            .font(TechnicalTypography.badgeMicro)
            .foregroundStyle(color)
            .padding(.horizontal, Spacing.compact)
            .padding(.vertical, Spacing.hairline)
            .background(ThemeColor.tintFill(color))
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
    }

    private var disasmHeader: some View {
        HStack {
            Text("Function: \(currentFunctionName)")
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Picker("Target Architecture", selection: $selectedArch) {
                ForEach(TargetArch.allCases) { arch in
                    Text(arch.rawValue).tag(arch)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 140)
            .onChange(of: selectedArch) {
                loadDisassembly()
            }
            .onChange(of: currentFunctionName) {
                loadDisassembly()
            }
            .accessibilityLabel("Target Architecture")
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
    }

    private func disasmTable(isDark: Bool) -> some View {
        Group {
            if isLoadingDisasm {
                VStack(spacing: Spacing.standard) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Compiling and disassembling (\(selectedArch.rawValue))...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if disasmInstructions.isEmpty {
                VStack(spacing: Spacing.row) {
                    Image(systemName: "terminal")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No Instructions")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(errorMessage ?? "Disassembly for function '\(currentFunctionName)' returned zero instructions.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.content)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Spacing.hairline) {
                            ForEach(disasmInstructions) { inst in
                                let isHighlighted = (inst.line == selectedLine)
                                HStack(spacing: Spacing.comfortable) {
                                    Text(inst.address)
                                        .font(.subheadline.monospaced())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 80, alignment: .leading)

                                    Text(inst.line > 0 ? "L\(inst.line)" : "—")
                                        .font(.caption.weight(.semibold).monospaced())
                                        .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                                        .frame(width: 36, alignment: .trailing)

                                    Text(inst.mnemonic)
                                        .font(.subheadline.weight(.bold).monospaced())
                                        .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
                                        .frame(width: 70, alignment: .leading)

                                    Text(inst.operands)
                                        .font(.subheadline.monospaced())
                                        .foregroundStyle(isHighlighted ? Color.primary : Color.secondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, Spacing.comfortable)
                                .padding(.vertical, Spacing.compact)
                                .background(isHighlighted ? Color.accentColor.opacity(0.18) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
                                .id(inst.id)
                            }
                        }
                        .padding(.vertical, Spacing.row)
                    }
                    .onChange(of: selectedLine) {
                        if let line = selectedLine,
                           let firstMatching = disasmInstructions.first(where: { $0.line == line }) {
                            if reduceMotion {
                                proxy.scrollTo(firstMatching.id, anchor: .center)
                            } else {
                                withAnimation(Motion.quick) {
                                    proxy.scrollTo(firstMatching.id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func footerBar(isDark: Bool) -> some View {
        HStack(spacing: Spacing.comfortable) {
            Text("\(UserMessage.count(decisions.count, "compiler decision")) · \(UserMessage.count(disasmInstructions.count, "instruction")) (\(selectedArch.rawValue))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            if let line = selectedLine {
                Button("Jump to Line \(line)") {
                    workspace.jumpToLocation(path: workspace.activeFilePath, line: line, column: 1)
                    onClose()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Button("Done") {
                onClose()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Compiler Optimization Sheet")
        }
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.inset)
    }

    private func loadDecisions() {
        guard !workspace.activeFilePath.isEmpty else { return }
        isLoadingDecisions = true
        let wsPath = workspace.activeWorkspacePath
        let filePath = workspace.activeFilePath

        DispatchQueue.global(qos: .userInitiated).async {
            let jsonStr: String? = wsPath.withCString { cWs in
                filePath.withCString { cPath in
                    guard let ptr = AnalyzeGoEscape(cWs, cPath) else { return nil }
                    defer { FreeGoCString(ptr) }
                    return String(cString: ptr)
                }
            }

            guard let jsonStr,
                  let data = jsonStr.data(using: .utf8),
                  let res = try? JSONDecoder().decode(EscapeAnalysisResultDTO.self, from: data) else {
                DispatchQueue.main.async {
                    self.isLoadingDecisions = false
                }
                return
            }

            let items = (res.items ?? []).map { item in
                CompilerDecisionItem(
                    file: item.file,
                    line: item.line,
                    col: item.col,
                    kind: item.kind,
                    category: item.category,
                    subject: item.subject,
                    message: item.message,
                    summary: item.summary,
                    hint: item.hint
                )
            }

            DispatchQueue.main.async {
                self.decisions = items
                self.isLoadingDecisions = false
                if self.selectedLine == nil, let first = items.first {
                    self.selectedLine = first.line
                }
            }
        }
    }

    private func loadDisassembly() {
        guard !workspace.activeFilePath.isEmpty else { return }
        isLoadingDisasm = true
        errorMessage = nil
        let pkgDir = (workspace.activeFilePath as NSString).deletingLastPathComponent
        let funcName = currentFunctionName
        let arch = selectedArch.rawValue.lowercased()

        DispatchQueue.global(qos: .userInitiated).async {
            let jsonStr: String? = pkgDir.withCString { cPkg in
                funcName.withCString { cFunc in
                    arch.withCString { cArch in
                        guard let ptr = DisassembleGoFunction(cPkg, cFunc, cArch) else { return nil }
                        defer { FreeGoCString(ptr) }
                        return String(cString: ptr)
                    }
                }
            }

            guard let jsonStr,
                  let data = jsonStr.data(using: .utf8),
                  let res = try? JSONDecoder().decode(DisasmResult.self, from: data) else {
                DispatchQueue.main.async {
                    self.isLoadingDisasm = false
                    self.errorMessage = "Couldn’t read the disassembly output."
                }
                return
            }

            DispatchQueue.main.async {
                guard funcName == self.currentFunctionName, arch == self.selectedArch.rawValue.lowercased() else { return }
                self.disasmInstructions = res.instructions
                self.errorMessage = res.error
                self.isLoadingDisasm = false
            }
        }
    }
}
