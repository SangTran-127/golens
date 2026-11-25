import SwiftUI
import GoLensFoundation

struct AcknowledgementsView: View {
    static let windowID = "acknowledgements"

    private static let bundledSections: [AcknowledgementSection] = {
        let url = AppResourceBundle.bundle.url(forResource: "ThirdPartyNotices", withExtension: "json", subdirectory: "Legal")
            ?? AppResourceBundle.url(forResource: "ThirdPartyNotices", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return Acknowledgements.decode(data)
    }()

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var query = ""
    @State private var runtimeSections: [AcknowledgementSection] = []

    private var sections: [AcknowledgementSection] { Self.bundledSections + runtimeSections }
    @State private var focusTrigger = 0

    var body: some View {
        let shown = Acknowledgements.filter(sections, query: query)
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("Acknowledgements")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("GoLens is built with \(UserMessage.count(Acknowledgements.componentCount(in: Self.bundledSections), "open source component")) and the artwork below\(runtimeSections.isEmpty ? "" : ", and the installed Linux Sandbox includes the software listed under Linux Sandbox"). Each license appears once, with the components it covers.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if Self.bundledSections.isEmpty {
                UnifiedEmptyState.empty(
                    symbol: StatusTone.warning.symbol,
                    title: "Acknowledgements Unavailable",
                    message: "This copy of GoLens is missing its license list. Reinstall GoLens, or read THIRD_PARTY_NOTICES.txt in the GoLens repository."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PanelFilterBar(
                    placeholder: "Search Components",
                    text: $query,
                    accessibilityTitle: "Search Components",
                    focusTrigger: focusTrigger,
                    onEscapeWhenEmpty: { dismissWindow(id: Self.windowID) }
                )

                if shown.isEmpty {
                    UnifiedEmptyState.filteredEmpty(itemNoun: "Components") {
                        query = ""
                        focusTrigger &+= 1
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(shown) { section in
                            Section(section.title) {
                                VStack(alignment: .leading, spacing: Spacing.standard) {
                                    if section.appliesTo.count > 1 {
                                        Text("Applies to " + section.appliesTo.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Text(section.text)
                                        .font(section.appliesTo.isEmpty ? .caption : .caption.monospaced())
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .textSelection(.enabled)
                                .padding(.vertical, Spacing.compact)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(SettingsMetrics.contentInset)
        .sheetFrame(SheetSize.inspector)
        .onAppear {
            focusTrigger &+= 1
            let notices = LinuxRuntimeLocation.directory.appendingPathComponent("NOTICES.txt")
            if LinuxRuntimeInstaller.shared.isInstalled, let text = try? String(contentsOf: notices, encoding: .utf8) {
                runtimeSections = Acknowledgements.runtimeSections(fromNotices: text, prefix: "Linux Sandbox")
            }
        }
        .onExitCommand {
            if query.isEmpty {
                dismissWindow(id: Self.windowID)
            } else {
                query = ""
                focusTrigger &+= 1
            }
        }
    }
}
