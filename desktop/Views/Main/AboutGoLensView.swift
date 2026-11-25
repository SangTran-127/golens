import AppKit
import SwiftUI

struct AboutGoLensCommandButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About GoLens", systemImage: "info.circle") {
            openWindow(id: "about")
            DispatchQueue.main.async {
                if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "about" || $0.title == "About GoLens" }) {
                    win.makeKeyAndOrderFront(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

struct AboutGoLensView: View {
    @Bindable var workspace = WorkspaceState.shared
    @AppStorage(ThemeManager.mascotCostumeKey) private var mascotCostume = "default"
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    @State private var goToolchainVersion: String = "—"
    @State private var didCopy = false

    private var theme: Theme {
        workspace.currentTheme
    }

    private var primaryText: Color {
        ChromeColor.textPrimary
    }

    private var secondaryText: Color {
        ChromeColor.textSecondary
    }

    private var appVersionString: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(shortVersion) (\(buildNumber))"
    }

    private var architectureString: String {
        #if arch(arm64)
        return "Apple Silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "macOS"
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: ThemeManager.shared.appIconImage(themeId: workspace.selectedThemeId, costume: mascotCostume))
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
                .padding(.bottom, Spacing.comfortable)

            Text("GoLens")
                .font(.title2.weight(.bold))
                .foregroundStyle(primaryText)

            Text(appVersionString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(secondaryText)
                .padding(.top, Spacing.hairline)
                .padding(.bottom, Spacing.section)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Go")
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                        .gridColumnAlignment(.trailing)
                    Text(goToolchainVersion)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(primaryText)
                }
                GridRow {
                    Text("Architecture")
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                    Text("\(architectureString) · cgo")
                        .font(.caption)
                        .foregroundStyle(primaryText)
                }
                GridRow {
                    Text("Appearance")
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                    Text(theme.name)
                        .font(.caption)
                        .foregroundStyle(primaryText)
                }
            }
            .padding(.bottom, Spacing.section)

            Button {
                copySystemInfoToPasteboard()
            } label: {
                Text(didCopy ? "Copied" : "Copy System Info")
                    .frame(minWidth: 116)
            }
            .controlSize(.small)
            .keyboardShortcut(KeymapStore.shared.shortcut("edit.copy"))
            .help(KeymapStore.shared.labeled("Copy version and toolchain details", "edit.copy"))
            .accessibilityLabel("Copy System Info")
            .padding(.bottom, Spacing.section)

            Divider()
                .padding(.bottom, Spacing.comfortable)

            VStack(spacing: Spacing.compact) {
                if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                    Text(copyright)
                        .foregroundStyle(secondaryText)
                }
                HStack(spacing: Spacing.compact) {
                    Text("Go gopher by Renée French")
                        .foregroundStyle(secondaryText)
                    if let url = URL(string: "https://creativecommons.org/licenses/by/4.0/") {
                        Link("(CC BY 4.0)", destination: url)
                    }
                }
                Button("Acknowledgements") { openWindow(id: AcknowledgementsView.windowID) }
                    .buttonStyle(.link)
                    .help("Open source components in GoLens and their licenses")
            }
            .font(.caption2)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.content)
        .padding(.top, Spacing.content)
        .padding(.bottom, Spacing.section)
        .frame(width: 280)
        .chromeMaterialSurface(.regular)
        .onAppear {
            detectGoVersionIfNeeded()
        }
        .onExitCommand {
            dismissWindow(id: "about")
        }
    }

    private func detectGoVersionIfNeeded() {
        guard goToolchainVersion == "—" else { return }
        DispatchQueue.global(qos: .utility).async {
            let version = Self.installedGoVersion()
            DispatchQueue.main.async { self.goToolchainVersion = version }
        }
    }

    private static func installedGoVersion() -> String {
        guard let go = WorkspaceState.findTool("go") else { return "Not installed" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: go)
        process.arguments = ["env", "GOVERSION"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "Unknown" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return version.hasPrefix("go") ? String(version.dropFirst(2)) : "Unknown"
    }

    private func copySystemInfoToPasteboard() {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let report = """
        GoLens \(appVersionString)
        Go: \(goToolchainVersion)
        Architecture: \(architectureString) (cgo)
        macOS: \(osVersion)
        Appearance: \(theme.name)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            didCopy = false
        }
    }
}
