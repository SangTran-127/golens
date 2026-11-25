import AppKit
import GoLensFoundation
import SwiftUI

struct DocumentationPageView: View {
    @Bindable var session: DocumentationBrowserSession
    @Binding var showTargetPopover: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("GoLensBuildGOOS") private var goos: String = ""
    @AppStorage("GoLensBuildGOARCH") private var goarch: String = ""
    @AppStorage("GoLensBuildTags") private var buildTags: String = ""
    @State private var moduleFilter = ""
    @State private var copiedExampleID: String?

    var body: some View {
        switch session.currentRoute {
        case .module(let path):
            moduleOverview(modulePath: path)
        case .package(let importPath, _):
            packageContent(importPath: importPath)
        case nil:
            if session.isLoadingIndex {
                UnifiedEmptyState.loading(message: "Loading documentation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                UnifiedEmptyState.empty(
                    symbol: "book",
                    title: "Select a Package or Module",
                    message: "Choose a package in the sidebar or search to read Go API documentation."
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func moduleOverview(modulePath: String) -> some View {
        let mod = (session.index?.modules ?? []).first(where: { $0.path == modulePath })
        let allPkgs = (session.index?.packages ?? []).filter { $0.modulePath == modulePath }
        let q = moduleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = q.isEmpty ? allPkgs : allPkgs.filter {
            $0.importPath.localizedCaseInsensitiveContains(q) || ($0.synopsis ?? "").localizedCaseInsensitiveContains(q)
        }

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.standard) {
                HStack(spacing: Spacing.standard) {
                    Text(modulePath).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let badge = mod?.versionBadge {
                        Text(badge).font(.caption.weight(.medium)).foregroundStyle(ThemeColor.textSecondary)
                            .padding(.horizontal, Spacing.standard).padding(.vertical, Spacing.hairline).wellBackground(cornerRadius: CornerRadius.small)
                    }
                    Spacer()
                    if mod?.isMissing == true {
                        Button("Download Dependency…") { session.requestDownload(module: modulePath, version: mod?.version ?? "") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                if let replacePath = mod?.replace?.path, !replacePath.isEmpty {
                    Text("Local replacement: \(replacePath)").font(.caption.monospaced()).foregroundStyle(ThemeColor.textSecondary).textSelection(.enabled)
                }
                PanelFilterBar(placeholder: "Filter Module Packages", text: $moduleFilter, accessibilityTitle: "Filter Module Packages").frame(maxWidth: 360)
            }
            .padding(Spacing.content).background(ThemeColor.panelSurface).overlay(alignment: .bottom) { Divider() }

            if mod?.isMissing == true && filtered.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: "arrow.down.circle",
                    title: "Download Dependency Source",
                    message: "Download this dependency to read its documentation.",
                    actionTitle: "Download Dependency…",
                    action: { session.requestDownload(module: modulePath, version: mod?.version ?? "") }
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                UnifiedEmptyState.filteredEmpty(itemNoun: "Packages") { moduleFilter = "" }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { pkg in
                    Button { session.navigate(to: .package(importPath: pkg.importPath, symbol: nil)) } label: {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(pkg.importPath).font(.callout.weight(.semibold).monospaced()).foregroundStyle(ThemeColor.textPrimary)
                            if let syn = pkg.synopsis, !syn.isEmpty {
                                Text(syn).font(.caption).foregroundStyle(ThemeColor.textSecondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, Spacing.compact).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private func packageContent(importPath: String) -> some View {
        VStack(spacing: 0) {
            if let page = session.currentPage, page.importPath == importPath {
                statusBanners(for: page)
                if page.missingSource == true {
                    UnifiedEmptyState.empty(
                        symbol: "arrow.down.circle",
                        title: "Download Dependency Source",
                        message: "Download this dependency to read its documentation.",
                        actionTitle: "Download Dependency…",
                        action: {
                            session.requestDownload(
                                module: page.missingModule ?? page.modulePath ?? importPath,
                                version: page.missingVersion ?? page.version ?? ""
                            )
                        }
                    ).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    scrollablePageBody(page)
                }
            } else if let err = session.pageError, !session.isLoadingPage {
                UnifiedEmptyState.failed(title: "Couldn’t Load Documentation", message: err) { session.refreshCurrent() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                UnifiedEmptyState.loading(message: "Loading documentation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func statusBanners(for page: DocsPackageDocDTO) -> some View {
        switch session.staleReason {
        case .refreshFailed(let err):
            InlineBanner(.status(.failure), title: "Couldn’t refresh documentation.", message: err) {
                Button("Retry") { session.refreshCurrent() }.buttonStyle(.bordered)
            }
        case .sourceChanged:
            InlineBanner(.status(.warning), title: "Source has changed since this documentation was loaded.") {
                if session.hasDirtyFilesInCurrentPackage {
                    Button("Save & Refresh") { session.refreshCurrent(saveDirtyFirst: true) }.buttonStyle(.borderedProminent)
                }
                Button("Refresh") { session.refreshCurrent() }.buttonStyle(.bordered)
                if session.packageSourceLocation(for: page) != nil {
                    Button("Open Source") { session.openPackageSource(for: page) }.buttonStyle(.bordered)
                }
            }
        case .targetChanged:
            InlineBanner(.status(.info), title: "Build target changed to \(session.target.displayLabel).") {
                Button("Refresh") { session.refreshCurrent() }.buttonStyle(.bordered)
            }
        case .manifestChanged:
            InlineBanner(.status(.warning), title: "Module dependencies changed since this documentation was loaded.") {
                Button("Refresh") { session.refreshCurrent() }.buttonStyle(.bordered)
            }
        case nil:
            EmptyView()
        }

        if let fromBuf = page.fromBuffer, !fromBuf.isEmpty {
            let names = fromBuf.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            InlineBanner(.status(.info), title: "Showing documentation from unsaved buffer.", detail: names) {
                Button("Save & Refresh") { session.refreshCurrent(saveDirtyFirst: true) }.buttonStyle(.bordered)
            }
        } else if (page.origin == "project" || page.source == "local-replace"), session.hasDirtyFilesInCurrentPackage {
            InlineBanner(.status(.info), title: "Showing documentation from saved source.") {
                Button("Save & Refresh") { session.refreshCurrent(saveDirtyFirst: true) }.buttonStyle(.borderedProminent)
            }
        }

        if let parseErrs = page.parseErrors, !parseErrs.isEmpty {
            InlineBanner(.status(.warning), title: "Some source files have syntax errors.", detail: parseErrs.first)
        }
        if page.errorKind == "buildConstraint" {
            InlineBanner(.status(.warning), title: "This package isn’t included in the current build target.") { targetButton }
        }
    }

    private func scrollablePageBody(_ page: DocsPackageDocDTO) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    pageHeader(page)
                    Divider()
                    if let doc = page.doc, !doc.isEmpty {
                        markdownSection(doc)
                    } else if page.missingDoc == true {
                        HStack(spacing: Spacing.standard) {
                            Text("No documentation comment is available for this package.").font(.callout).foregroundStyle(ThemeColor.textSecondary)
                            Spacer()
                            if session.packageSourceLocation(for: page) != nil {
                                Button("Open Source") { session.openPackageSource(for: page) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    if let examples = page.examples, !examples.isEmpty { examplesSection("Examples", examples: examples) }
                    if let consts = page.consts, !consts.isEmpty { symbolGroupSection("Constants", symbols: consts) }
                    if let vars = page.vars, !vars.isEmpty { symbolGroupSection("Variables", symbols: vars) }
                    if let funcs = page.funcs, !funcs.isEmpty { symbolGroupSection("Functions", symbols: funcs) }
                    if let types = page.types, !types.isEmpty { typesSection(types) }
                    if let excluded = page.excluded, !excluded.isEmpty { excludedSection(excluded) }
                }
                .padding(Spacing.content)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.scrollRequestNonce) { _, _ in
                let target = session.pendingScrollTarget
                guard !target.isEmpty else { return }
                if reduceMotion {
                    proxy.scrollTo(target, anchor: .top)
                } else {
                    withAnimation(Motion.quick) { proxy.scrollTo(target, anchor: .top) }
                }
            }
            .onAppear {
                let target = session.pendingScrollTarget
                if !target.isEmpty { DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) } }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if let route = DocsDocLinkParser.parse(url) {
                session.navigate(to: route)
                return .handled
            }
            return .systemAction
        })
    }

    private func pageHeader(_ page: DocsPackageDocDTO) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.compact) {
                if let mod = page.modulePath, !mod.isEmpty {
                    Button(mod) { session.navigate(to: .module(path: mod)) }.buttonStyle(.link).font(.caption.monospaced())
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(ThemeColor.textTertiary).accessibilityHidden(true)
                }
                Text(page.importPath).font(.caption.monospaced()).foregroundStyle(ThemeColor.textSecondary)
                if let sym = session.currentRoute?.symbolAnchor, !sym.isEmpty {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(ThemeColor.textTertiary).accessibilityHidden(true)
                    Text(sym).font(.caption.weight(.semibold).monospaced())
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                Text("package \(page.name?.isEmpty == false ? page.name! : page.importPath)").font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer(minLength: Spacing.standard)
                if let ext = DocsDocLinkParser.publicPkgGoDevURL(
                    importPath: page.importPath, version: page.version, source: page.source, origin: page.origin, symbol: session.currentRoute?.symbolAnchor
                ) {
                    Button { session.requestOpenExternal(ext) } label: {
                        Label("Open in Browser", systemImage: "arrow.up.right.square")
                    }.buttonStyle(.bordered).controlSize(.small).help("Open public documentation on pkg.go.dev")
                }
            }

            HStack(spacing: Spacing.standard) {
                Text(page.importPath).font(.subheadline.monospaced()).foregroundStyle(ThemeColor.textSecondary).textSelection(.enabled)
                Text(sourceSummary(page)).font(.caption.weight(.medium)).foregroundStyle(ThemeColor.textSecondary)
                    .padding(.horizontal, Spacing.row).padding(.vertical, Spacing.hairline).wellBackground(cornerRadius: CornerRadius.small)
                Label(session.target.displayLabel, systemImage: "cpu").font(.caption).foregroundStyle(ThemeColor.textSecondary)
                    .padding(.horizontal, Spacing.row).padding(.vertical, Spacing.hairline).wellBackground(cornerRadius: CornerRadius.small)
            }
        }
    }

    private func sourceSummary(_ page: DocsPackageDocDTO) -> String {
        if page.source == "local-replace" { return (page.replacePath?.isEmpty == false) ? "Local replacement (\(page.replacePath!))" : "Local replacement" }
        if page.origin == "stdlib" || page.source == "stdlib" { return "Standard library" }
        if page.source == "vendor" { return page.version.map { "Vendored · \($0)" } ?? "Vendored" }
        return page.version?.isEmpty == false ? page.version! : "Workspace"
    }

    private func markdownSection(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            ForEach(parseHoverDocBlocks(raw)) { block in
                switch block {
                case .heading(_, let level, let text):
                    inlineMarkdown(text).font(level <= 2 ? .headline : .callout.weight(.semibold)).textSelection(.enabled)
                case .bullet(_, let text):
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
                        Text("•").font(.callout.weight(.bold)).foregroundStyle(ThemeColor.textSecondary)
                        inlineMarkdown(text).font(.callout).textSelection(.enabled)
                    }
                case .codeBlock(_, let code):
                    HighlightedCodeText(code).font(TechnicalTypography.codeCompact).textSelection(.enabled).padding(Spacing.standard)
                        .frame(maxWidth: .infinity, alignment: .leading).background(ThemeColor.editorSurface)
                        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous).strokeBorder(ThemeColor.separator, lineWidth: Stroke.hairline))
                case .paragraph(_, let text):
                    inlineMarkdown(text).font(.callout).lineSpacing(Spacing.hairline).textSelection(.enabled)
                }
            }
        }
    }

    private func inlineMarkdown(_ raw: String) -> Text {
        if let attr = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(attr) }
        return Text(raw)
    }

    private func symbolGroupSection(_ title: String, symbols: [DocsSymbolDTO]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            Text(title).font(.headline)
            ForEach(symbols) { sym in symbolBlock(sym) }
        }
    }

    private func typesSection(_ types: [DocsSymbolDTO]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("Types").font(.headline)
            ForEach(types) { t in
                VStack(alignment: .leading, spacing: Spacing.comfortable) {
                    symbolBlock(t)
                    if let funcs = t.funcs, !funcs.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.standard) { ForEach(funcs) { symbolBlock($0) } }.padding(.leading, Spacing.section)
                    }
                    if let methods = t.methods, !methods.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.standard) { ForEach(methods) { symbolBlock($0) } }.padding(.leading, Spacing.section)
                    }
                }
            }
        }
    }

    private func symbolBlock(_ sym: DocsSymbolDTO) -> some View {
        let highlighted = session.currentRoute?.symbolAnchor == sym.anchorName || session.currentRoute?.symbolAnchor == sym.name
        return VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(spacing: Spacing.standard) {
                SymbolIconView(kind: sym.kind, isSelected: false, size: 16)
                Text(sym.anchorName).font(.callout.weight(.semibold).monospaced()).textSelection(.enabled)
                if sym.exported == false {
                    Text("Unexported").font(.caption2.weight(.medium)).foregroundStyle(ThemeColor.textSecondary)
                        .padding(.horizontal, Spacing.compact).wellBackground(cornerRadius: CornerRadius.small)
                }
                Spacer(minLength: Spacing.standard)
                Button("Open Source") { session.openSource(file: sym.position.file, line: sym.position.line, column: sym.position.column) }
                    .buttonStyle(.borderless).controlSize(.small).help("Jump to \(sym.anchorName) in editor")
            }

            ScrollView(.horizontal) {
                HighlightedCodeText(sym.signature).font(TechnicalTypography.codeCompact).textSelection(.enabled).padding(Spacing.inset)
            }
            .frame(maxWidth: .infinity, alignment: .leading).background(ThemeColor.editorSurface)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous).strokeBorder(ThemeColor.separator, lineWidth: Stroke.hairline))

            if let doc = sym.doc, !doc.isEmpty {
                markdownSection(doc)
            } else if sym.missingDoc == true {
                Text("No documentation comment is available for this symbol.").font(.caption).foregroundStyle(ThemeColor.textSecondary)
            }
            if let examples = sym.examples, !examples.isEmpty { examplesSection("Examples", examples: examples) }
        }
        .padding(Spacing.comfortable).wellBackground(cornerRadius: CornerRadius.compactPanel)
        .overlay(RoundedRectangle(cornerRadius: CornerRadius.compactPanel, style: .continuous)
            .strokeBorder(highlighted ? Color.accentColor : Color.clear, lineWidth: Stroke.hairline))
        .id(sym.anchorName)
    }

    private func examplesSection(_ title: String, examples: [DocsExampleDTO]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(ThemeColor.textSecondary)
            ForEach(examples) { ex in
                VStack(alignment: .leading, spacing: Spacing.row) {
                    HStack {
                        Text(ex.suffix?.isEmpty == false ? "Example (\(ex.suffix!))" : "Example").font(.caption.weight(.semibold)).foregroundStyle(ThemeColor.textSecondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ex.code, forType: .string); copiedExampleID = ex.id
                        } label: {
                            Label(copiedExampleID == ex.id ? "Copied" : "Copy", systemImage: copiedExampleID == ex.id ? "checkmark" : "doc.on.doc").font(.caption)
                        }.buttonStyle(.bordered).controlSize(.small)
                        Button("Open Source") { session.openSource(file: ex.position.file, line: ex.position.line, column: ex.position.column) }
                            .buttonStyle(.borderless).controlSize(.small)
                    }
                    ScrollView(.horizontal) {
                        HighlightedCodeText(ex.code).font(TechnicalTypography.codeCompact).textSelection(.enabled).padding(Spacing.standard)
                    }.background(ThemeColor.editorSurface).clipShape(RoundedRectangle(cornerRadius: CornerRadius.control, style: .continuous))
                    if let out = ex.output, !out.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            Text(ex.unordered == true ? "Unordered Output" : "Output").font(.caption2.weight(.semibold)).foregroundStyle(ThemeColor.textSecondary)
                            Text(out).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(Spacing.standard).frame(maxWidth: .infinity, alignment: .leading).wellBackground(cornerRadius: CornerRadius.small)
                    }
                }.padding(Spacing.inset).wellBackground(cornerRadius: CornerRadius.control)
            }
        }
    }

    private func excludedSection(_ excluded: [DocsExcludedSymbolDTO]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack { Text("Excluded Symbols").font(.headline); Spacer(); targetButton }
            ForEach(excluded) { item in
                HStack(spacing: Spacing.standard) {
                    Text(item.name).font(.callout.monospaced()).foregroundStyle(ThemeColor.textPrimary)
                    Text(item.reason == "test-only" ? "Test file only" : "This symbol isn’t included in the current build target.")
                        .font(.caption).foregroundStyle(ThemeColor.textSecondary)
                    if let build = item.build, !build.isEmpty {
                        Text(build).font(.caption2.monospaced()).foregroundStyle(StatusTone.warning.tint)
                            .padding(.horizontal, Spacing.compact).wellBackground(cornerRadius: CornerRadius.small)
                    }
                    Spacer()
                    Button("Open Source") { session.openSource(file: item.position.file, line: item.position.line, column: item.position.column) }
                        .buttonStyle(.borderless).controlSize(.small)
                }.padding(.vertical, Spacing.compact)
            }
        }
    }

    private var targetButton: some View {
        Button("Change Build Target") { showTargetPopover = true }.buttonStyle(.bordered).controlSize(.small)
            .popover(isPresented: $showTargetPopover, arrowEdge: .bottom) {
                BuildTargetPopoverContent(goos: $goos, goarch: $goarch, buildTags: $buildTags)
                    .onChange(of: goos) { _, _ in NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil) }
                    .onChange(of: goarch) { _, _ in NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil) }
                    .onChange(of: buildTags) { _, _ in NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil) }
            }
    }
}
