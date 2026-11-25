import Foundation
import SwiftUI

extension WorkspaceState {
    var currentTheme: Theme {
        ThemeManager.shared.theme(withId: selectedThemeId)
    }

    func tabBackgroundColor(isActive: Bool, isHovered: Bool = false, isDark: Bool) -> SwiftUI.Color {
        if isActive {
            return ChromeColor.accent.opacity(isDark ? 0.22 : 0.12)
        }
        if isHovered {
            return ChromeColor.hover
        }
        return SwiftUI.Color.clear
    }

    func tabTextColor(isActive: Bool, isHovered: Bool = false, isDark: Bool) -> SwiftUI.Color {
        (isActive || isHovered) ? ChromeColor.textPrimary : ChromeColor.textSecondary
    }

    func updateWindowAppearance() {
        ThemeManager.shared.applyAppIcon(themeId: selectedThemeId)
        let applyPass = { [weak self] in
            guard let self else { return }
            let effectiveAppearance = self.mainWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
            let sysDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if self.systemAppearanceIsDark != sysDark {
                self.systemAppearanceIsDark = sysDark
            }
            let targetBg: NSColor = .windowBackgroundColor

            for window in NSApp.windows {
                if window === self.mainWindow || (self.mainWindow == nil && !window.isSheet && !(window is NSPanel)) {
                    window.titlebarAppearsTransparent = true
                    window.backgroundColor = targetBg
                    for item in window.toolbar?.items ?? [] {
                        item.view?.appearance = nil
                        item.view?.needsDisplay = true
                    }
                    window.toolbar?.validateVisibleItems()
                } else if window.isSheet || !(window is NSPanel) {
                    window.backgroundColor = targetBg
                }
                if let frameView = window.contentView?.superview {
                    if frameView.appearance != nil {
                        frameView.appearance = nil
                    }
                    Self.refreshEditorAndTerminalViews(frameView)
                } else if let root = window.contentView {
                    Self.refreshEditorAndTerminalViews(root)
                }
            }
            for term in self.terminalEngines.values {
                (term as? GoLensTerminalView)?.applyThemeAppearance()
            }
        }
        if Thread.isMainThread {
            applyPass()
        }
        DispatchQueue.main.async(execute: applyPass)
    }

    static func refreshEditorAndTerminalViews(_ view: NSView) {
        if let textView = view as? GoLensTextView {
            (textView.delegate as? MacTextView.Coordinator)?.refreshAppearance(in: textView)
        } else if let termView = view as? GoLensTerminalView {
            termView.applyThemeAppearance()
        }
        view.needsDisplay = true
        for subview in view.subviews {
            refreshEditorAndTerminalViews(subview)
        }
    }

    func startPasteboardMonitor() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshClipboardState()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshClipboardState()
        }
        effectiveAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.updateWindowAppearance()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateWindowAppearance()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateWindowAppearance()
        }
        refreshClipboardState()
    }

    func refreshClipboardState() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pasteboard.changeCount
        let text = pasteboard.string(forType: .string)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let isStructConvertible = text.map {
                $0.utf8.count <= 4_000_000 && (
                    JSONToGo.generate(from: $0) != nil ||
                    EcosystemDocumentTools.generateGoStruct(fromConfigText: $0) != nil
                )
            } ?? false
            DispatchQueue.main.async {
                guard let self, self.clipboardHasJSONObject != isStructConvertible else { return }
                self.clipboardHasJSONObject = isStructConvertible
            }
        }
    }

    var canPasteJSONAsGoStruct: Bool {
        clipboardHasJSONObject && activeFilePath.hasSuffix(".go") && editorMode(for: activeFilePath) == .code
    }

    func pasteJSONAsGoStruct() {
        guard let textView = activeTextView as? GoLensTextView,
              textView.isEditable,
              textView.filePath.hasSuffix(".go") else {
            presentCommandFeedback(
                "Open a writable Go file in the editor to paste a generated Go struct.",
                title: "Paste Config/JSON as Go Struct"
            )
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string),
              let goCode = JSONToGo.generate(from: text) ?? EcosystemDocumentTools.generateGoStruct(fromConfigText: text) else {
            presentCommandFeedback(
                "Copy valid JSON, YAML, TOML, or .env content first.",
                title: "Paste Config/JSON as Go Struct"
            )
            return
        }
        textView.window?.makeFirstResponder(textView)
        textView.breakUndoCoalescing()
        textView.insertText(goCode, replacementRange: textView.selectedRange())
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName("Paste Config/JSON as Go Struct")
    }
}
