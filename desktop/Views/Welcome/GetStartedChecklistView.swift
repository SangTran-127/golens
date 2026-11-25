import SwiftUI
import GoLensFoundation

struct GetStartedChecklistView: View {
    @Bindable var progress = GetStartedProgress.shared

    var body: some View {
        let checklist = progress.checklist
        VStack(alignment: .leading, spacing: Spacing.standard) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.standard) {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    Text("Get Started")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(checklist.progressText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.standard)
                Button("Hide") { progress.setHidden(true) }
                    .controlSize(.small)
                    .help("Hide Get Started. Choose Help ▸ Get Started to show it again.")
            }

            ForEach(GetStartedStep.allCases) { step in
                let done = checklist.isDone(step)
                SetupChecklistRow(
                    symbol: done ? StatusTone.success.symbol : "circle",
                    tint: done ? StatusTone.success.tint : .secondary,
                    title: Self.title(step),
                    detail: Self.detail(step),
                    accessibilityLabel: "\(Self.title(step)), \(done ? "done" : "not done")"
                )
            }
        }
        .padding(Spacing.comfortable)
        .wellBackground()
    }

    static func title(_ step: GetStartedStep) -> String {
        switch step {
        case .openProject: "Open a Go Project"
        case .goToDefinition: "Go to a Definition"
        case .runTestFromGutter: "Run a Test from the Gutter"
        case .stopAtBreakpoint: "Stop at a Breakpoint"
        case .commandPalette: "Find Any Command"
        }
    }

    static func detail(_ step: GetStartedStep) -> String {
        switch step {
        case .openProject:
            "Open a folder that has a go.mod file."
        case .goToDefinition:
            "Command-click a name, or \(hint("navigate.definition", menu: "Navigate ▸ Go to Definition"))."
        case .runTestFromGutter:
            "Click the run mark beside a test function."
        case .stopAtBreakpoint:
            "Click a line number to add one, then \(hint("product.debug", menu: "Product ▸ Debug"))."
        case .commandPalette:
            "\(hint("view.commandPalette", menu: "View ▸ Command Palette…").capitalizedFirst) and type what you want to do."
        }
    }

    private static func hint(_ id: String, menu: String) -> String {
        let shortcut = KeymapStore.shared.display(id)
        return shortcut.isEmpty ? "choose \(menu)" : "press \(shortcut)"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct OpenGetStartedCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Get Started", systemImage: "checklist") {
            GetStartedProgress.shared.setHidden(false)
            openWindow(id: "welcome")
        }
        .keyboardShortcut(KeymapStore.shared.shortcut("help.getStarted"))
    }
}
