import GoLensFoundation
import SwiftUI

struct DocumentationSidebarView: View {
    @Bindable var session: DocumentationBrowserSession
    @State private var expandedModules: Set<String> = []

    private var projectPackages: [DocsPackageDTO] {
        (session.index?.packages ?? []).filter { $0.origin == "project" }
    }

    private var dependencyModules: [DocsModuleDTO] {
        (session.index?.modules ?? []).filter { !$0.isMain && $0.source != "stdlib" }
    }

    private var stdlibPackages: [DocsPackageDTO] {
        (session.index?.packages ?? []).filter { $0.origin == "stdlib" }
    }

    private func packages(forModulePath modulePath: String) -> [DocsPackageDTO] {
        (session.index?.packages ?? []).filter { $0.origin == "dependency" && $0.modulePath == modulePath }
    }

    var body: some View {
        Group {
            if session.isLoadingIndex && session.index == nil {
                UnifiedEmptyState.loading(message: "Loading documentation…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = session.indexError, session.index == nil {
                UnifiedEmptyState.failed(title: "Couldn’t Load Documentation", message: err) {
                    session.refreshIndex(selectDefaultRouteIfNeeded: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section("Project") {
                        if projectPackages.isEmpty {
                            Text("No workspace packages found.")
                                .font(.caption)
                                .foregroundStyle(ChromeColor.textSecondary)
                        } else {
                            ForEach(projectPackages) { pkg in
                                packageButton(pkg)
                            }
                        }
                    }

                    Section("Dependencies") {
                        if dependencyModules.isEmpty {
                            Text("No external dependencies in go.mod.")
                                .font(.caption)
                                .foregroundStyle(ChromeColor.textSecondary)
                        } else {
                            ForEach(dependencyModules) { mod in
                                dependencyModuleRow(mod)
                            }
                        }
                    }

                    Section("Standard Library") {
                        if !session.includeStd {
                            Button("Load Standard Library") {
                                session.toggleIncludeStd()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Load Go standard library package list for the active toolchain")
                        } else if session.isLoadingIndex && stdlibPackages.isEmpty {
                            HStack(spacing: Spacing.row) {
                                ProgressView().controlSize(.small)
                                Text("Loading Standard Library…")
                                    .font(.caption)
                                    .foregroundStyle(ChromeColor.textSecondary)
                            }
                        } else {
                            ForEach(stdlibPackages) { pkg in
                                packageButton(pkg)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: session.currentRoute) { _, route in
                    if case .module(let modPath) = route {
                        expandedModules.insert(modPath)
                    } else if case .package(let importPath, _) = route,
                              let modPath = (session.index?.packages ?? []).first(where: { $0.importPath == importPath })?.modulePath {
                        expandedModules.insert(modPath)
                    }
                }
            }
        }
    }

    private func packageButton(_ pkg: DocsPackageDTO) -> some View {
        let isSelected = session.currentRoute?.importPath == pkg.importPath
        return Button {
            session.navigate(to: .package(importPath: pkg.importPath, symbol: nil))
        } label: {
            HStack(spacing: Spacing.row) {
                Image(systemName: pkg.isMissing ? "arrow.down.circle" : "shippingbox")
                    .font(.caption)
                    .foregroundStyle(isSelected ? ChromeColor.selectedText : (pkg.isMissing ? StatusTone.warning.tint : ChromeColor.textSecondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text(pkg.displayName)
                        .font(.callout)
                        .foregroundStyle(isSelected ? ChromeColor.selectedText : ChromeColor.textPrimary)
                        .lineLimit(1)
                    if pkg.importPath != pkg.displayName {
                        Text(pkg.importPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(isSelected ? ChromeColor.selectedSecondaryText : ChromeColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: Spacing.compact)
            }
            .padding(.horizontal, Spacing.row)
            .padding(.vertical, Spacing.compact)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                    .fill(isSelected ? ChromeColor.selection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pkg.importPath)
    }

    private func dependencyModuleRow(_ mod: DocsModuleDTO) -> some View {
        let modSelected: Bool = {
            if case .module(let path) = session.currentRoute { return path == mod.path }
            return false
        }()
        let pkgs = packages(forModulePath: mod.path)
        let isExpanded = Binding(
            get: { expandedModules.contains(mod.path) || pkgs.contains(where: { $0.importPath == session.currentRoute?.importPath }) },
            set: { open in
                if open { expandedModules.insert(mod.path) } else { expandedModules.remove(mod.path) }
            }
        )

        return DisclosureGroup(isExpanded: isExpanded) {
            if pkgs.isEmpty && mod.isMissing {
                Button("Download \(mod.versionBadge)…") {
                    session.requestDownload(module: mod.path, version: mod.version ?? "")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                ForEach(pkgs) { pkg in
                    packageButton(pkg)
                }
            }
        } label: {
            Button {
                expandedModules.insert(mod.path)
                session.navigate(to: .module(path: mod.path))
            } label: {
                HStack(spacing: Spacing.row) {
                    VStack(alignment: .leading, spacing: Spacing.hairline) {
                        Text(mod.path)
                            .font(.callout)
                            .foregroundStyle(modSelected ? ChromeColor.selectedText : ChromeColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: Spacing.compact) {
                            Text(mod.versionBadge)
                                .font(.caption2)
                                .foregroundStyle(modSelected ? ChromeColor.selectedSecondaryText : ChromeColor.textSecondary)
                            if mod.isMissing {
                                Text("Missing")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(StatusTone.warning.tint)
                            }
                        }
                    }
                    Spacer(minLength: Spacing.compact)
                }
                .padding(.horizontal, Spacing.row)
                .padding(.vertical, Spacing.compact)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
                        .fill(modSelected ? ChromeColor.selection : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(mod.path), \(mod.versionBadge)")
        }
    }
}
