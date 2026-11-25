import SwiftUI
import AppKit

struct EditorConsoleSplitView: View {
    @Bindable var workspace: WorkspaceState
    let showConsole: Bool

    static let heightKey = "GoLensConsoleHeight"
    static let minEditorHeight: CGFloat = 240
    static let minConsoleHeight: CGFloat = 140
    static let defaultConsoleFraction: CGFloat = 0.3

    @State private var consoleHeight: CGFloat = {
        let saved = CGFloat(UserDefaults.standard.double(forKey: EditorConsoleSplitView.heightKey))
        return saved >= EditorConsoleSplitView.minConsoleHeight ? saved : 240
    }()
    @State private var isHoveringDivider: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let totalHeight = max(geometry.size.height, Self.minEditorHeight + Self.minConsoleHeight)
            let maxConsole = max(Self.minConsoleHeight, totalHeight - Self.minEditorHeight)
            let clampedHeight = min(max(consoleHeight, Self.minConsoleHeight), maxConsole)

            VStack(spacing: 0) {
                EditorAreaView(workspace: workspace)
                    .frame(
                        minWidth: 0,
                        maxWidth: .infinity,
                        minHeight: workspace.showConsole ? Self.minEditorHeight : 0,
                        maxHeight: .infinity
                    )

                if workspace.showConsole {
                    ZStack {
                        Divider()
                        Color.clear
                            .frame(height: 8)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                guard hovering != isHoveringDivider else { return }
                                isHoveringDivider = hovering
                                if hovering {
                                    NSCursor.resizeUpDown.push()
                                } else {
                                    NSCursor.pop()
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .named("EditorConsoleSplitSpace"))
                                    .onChanged { value in
                                        let proposed = totalHeight - value.location.y
                                        let nextHeight = min(max(proposed, Self.minConsoleHeight), maxConsole)
                                        consoleHeight = nextHeight
                                    }
                                    .onEnded { value in
                                        let proposed = totalHeight - value.location.y
                                        let nextHeight = min(max(proposed, Self.minConsoleHeight), maxConsole)
                                        consoleHeight = nextHeight
                                        UserDefaults.standard.set(Double(nextHeight), forKey: Self.heightKey)
                                    }
                            )
                            .accessibilityLabel("Resize Bottom Console Panel")
                    }
                    .frame(height: 1)
                    .zIndex(1)

                    ConsolePanelView(workspace: workspace)
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            minHeight: Self.minConsoleHeight,
                            idealHeight: clampedHeight,
                            maxHeight: clampedHeight
                        )
                }
            }
            .coordinateSpace(name: "EditorConsoleSplitSpace")
            .onAppear {
                let saved = CGFloat(UserDefaults.standard.double(forKey: Self.heightKey))
                if saved >= Self.minConsoleHeight {
                    consoleHeight = min(saved, maxConsole)
                } else {
                    let ideal = (totalHeight * Self.defaultConsoleFraction).rounded()
                    consoleHeight = min(max(ideal, Self.minConsoleHeight), maxConsole)
                }
            }
            .onChange(of: workspace.showConsole) { _, isShowing in
                if !isShowing && isHoveringDivider {
                    isHoveringDivider = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHoveringDivider {
                    isHoveringDivider = false
                    NSCursor.pop()
                }
            }
        }
    }
}

struct ConsolePanelView: View {
    @Bindable var workspace: WorkspaceState

    var body: some View {
        VStack(spacing: 0) {
            ConsoleHeaderView(workspace: workspace, selectedTab: $workspace.selectedConsoleTab)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ConsoleView(workspace: workspace, selectedTab: $workspace.selectedConsoleTab)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .clipped()
    }
}
