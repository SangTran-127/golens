import SwiftUI
import AppKit

extension Notification.Name {
    static let golensBuildTargetChanged = Notification.Name("golensBuildTargetChanged")
}

struct BuildTargetStatusBarItem: View {
    @AppStorage("GoLensBuildGOOS") private var goos: String = ""
    @AppStorage("GoLensBuildGOARCH") private var goarch: String = ""
    @AppStorage("GoLensBuildTags") private var buildTags: String = ""
    @State private var showPopover = false
    private var vm = SandboxVMManager.shared

    #if arch(arm64)
    static let hostGOARCH = "arm64"
    #elseif arch(x86_64)
    static let hostGOARCH = "amd64"
    #else
    static let hostGOARCH = "arm64"
    #endif

    private var defaultGOOS: String {
        vm.executionMode == .linuxVM ? "linux" : "darwin"
    }

    private var isDefault: Bool {
        goos.isEmpty && goarch.isEmpty && buildTags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayLabel: String {
        let effectiveGOOS = goos.isEmpty ? defaultGOOS : goos
        let effectiveGOARCH = goarch.isEmpty ? Self.hostGOARCH : goarch
        let trimmedTags = buildTags.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTags.isEmpty {
            return "\(effectiveGOOS)/\(effectiveGOARCH)"
        }
        return "\(effectiveGOOS)/\(effectiveGOARCH) · \(trimmedTags)"
    }

    var body: some View {
        let secondaryColor = ThemeColor.textSecondary
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: Spacing.compact) {
                Image(systemName: "cpu")
                    .accessibilityHidden(true)
                Text(displayLabel)
            }
            .font(.caption)
            .foregroundStyle(isDefault ? AnyShapeStyle(secondaryColor) : AnyShapeStyle(Color.accentColor))
        }
        .buttonStyle(.borderless)
        .help("Build Target (\(displayLabel))")
        .accessibilityLabel("Build Target, \(displayLabel)")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            BuildTargetPopoverContent(goos: $goos, goarch: $goarch, buildTags: $buildTags)
        }
        .onChange(of: goos) { _, _ in
            NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil)
        }
        .onChange(of: goarch) { _, _ in
            NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil)
        }
        .onChange(of: buildTags) { _, _ in
            NotificationCenter.default.post(name: .golensBuildTargetChanged, object: nil)
        }
    }
}

struct BuildTargetPopoverContent: View {
    @Binding var goos: String
    @Binding var goarch: String
    @Binding var buildTags: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.comfortable) {
            Text("Build Target")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            Form {
                Picker("OS (GOOS)", selection: $goos) {
                    Text("Host Default").tag("")
                    Divider()
                    Text("darwin").tag("darwin")
                    Text("linux").tag("linux")
                    Text("windows").tag("windows")
                    Text("freebsd").tag("freebsd")
                    Text("js").tag("js")
                    Text("wasip1").tag("wasip1")
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("OS (GOOS)")

                Picker("Arch (GOARCH)", selection: $goarch) {
                    Text("Host Default").tag("")
                    Divider()
                    Text("arm64").tag("arm64")
                    Text("amd64").tag("amd64")
                    Text("386").tag("386")
                    Text("wasm").tag("wasm")
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Arch (GOARCH)")

                TextField("Build Tags", text: $buildTags, prompt: Text("e.g. integration, e2e"))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .accessibilityLabel("Build Tags (comma-separated)")
            }
            .font(.subheadline)

            HStack {
                Spacer()
                Button("Reset to Host Default") {
                    goos = ""
                    goarch = ""
                    buildTags = ""
                }
                .controlSize(.small)
                .disabled(goos.isEmpty && goarch.isEmpty && buildTags.isEmpty)
                .accessibilityLabel("Reset to Host Default")
            }
        }
        .padding(Spacing.section)
        .frame(width: 320, alignment: .leading)
    }
}
