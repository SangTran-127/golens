import SwiftUI
import AppKit

struct SurroundWithPopupView: View {
    @Bindable var workspace: WorkspaceState
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isTextFieldFocused: Bool
    @State private var keyMonitor: Any?

    private var options: [SurroundOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = SurroundOption.all
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.standard) {
                Image(systemName: "curlybraces")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ThemeColor.textSecondary)
                    .accessibilityHidden(true)

                TextField("Surround With", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isTextFieldFocused)
                    .background(PopupFieldAutoFocus())
                    .font(.callout)
                    .accessibilityLabel("Filter Wrappers")
                    .onSubmit { apply() }
                    .onChange(of: searchText) { _, _ in
                        PopupMouseTracker.markKeyboardOrOpen()
                        selectedIndex = 0
                    }
            }
            .padding(.horizontal, Spacing.section)
            .padding(.vertical, Spacing.comfortable)

            Divider()

            if options.isEmpty {
                Text("No wrapper or template matches “\(searchText)”.")
                    .font(.callout)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(Spacing.section)
            } else {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        row(option, index: index)
                    }
                }
                .padding(Spacing.standard)
            }
        }
        .popupWidth(.compact)
        .floatingPanelBackground()
        .onAppear {
            PopupMouseTracker.markKeyboardOrOpen()
            DispatchQueue.main.async { isTextFieldFocused = true }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKeyDown(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private func row(_ option: SurroundOption, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let selectedText = Color(nsColor: .alternateSelectedControlTextColor)
        return HStack(spacing: Spacing.standard) {
            Text(option.title)
                .font(.body.monospaced().weight(isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? selectedText : ThemeColor.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Spacing.standard)
            Text(option.detail)
                .font(.caption)
                .foregroundStyle(isSelected ? selectedText : ThemeColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.row)
        .popupRow(isSelected: isSelected, onHoverSelect: {
            selectedIndex = index
        }) {
            selectedIndex = index
            apply()
        }
        .accessibilityLabel("\(option.title), \(option.detail)")
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard workspace.activePopup == .surroundWith else { return false }
        let count = options.count
        switch event.keyCode {
        case 53:
            workspace.activePopup = nil
            return true
        case 36, 76:
            apply()
            return true
        case 125:
            PopupMouseTracker.markKeyboardOrOpen()
            if count > 0 { selectedIndex = (selectedIndex + 1) % count }
            return true
        case 126:
            PopupMouseTracker.markKeyboardOrOpen()
            if count > 0 { selectedIndex = (selectedIndex - 1 + count) % count }
            return true
        default:
            return PopupSearchKeyCapture.routeIfFieldUnfocused(event, query: &searchText, onFocus: { isTextFieldFocused = true })
        }
    }

    private func apply() {
        let list = options
        guard list.indices.contains(selectedIndex) else {
            workspace.activePopup = nil
            return
        }
        workspace.surround(with: list[selectedIndex])
    }
}
