import AppKit
import SwiftUI

struct PopupAnchor: Equatable {
    let rect: CGRect
    let bounds: CGRect
}

private struct PopupAvailableHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct InsidePopupPanelKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var popupAvailableHeight: CGFloat? {
        get { self[PopupAvailableHeightKey.self] }
        set { self[PopupAvailableHeightKey.self] = newValue }
    }

    var insidePopupPanel: Bool {
        get { self[InsidePopupPanelKey.self] }
        set { self[InsidePopupPanelKey.self] = newValue }
    }
}

struct FloatingPopup<Content: View>: NSViewRepresentable {
    @Environment(\.windowWorkspace) private var windowWorkspace
    let isPresented: Bool
    let origin: CGPoint
    var anchor: PopupAnchor? = nil
    var acceptsKeyboard = false
    var onCancel: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        guard isPresented, let window = view.window else { return coordinator.hide() }
        coordinator.show(AnyView(content().windowScope(windowWorkspace)), at: origin, anchor: anchor, in: window, acceptsKeyboard: acceptsKeyboard, onCancel: onCancel)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.hide()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var panel: PopupPanel?

        func show(_ content: AnyView, at origin: CGPoint, anchor: PopupAnchor?, in window: NSWindow, acceptsKeyboard: Bool, onCancel: (() -> Void)?) {
            let panel = self.panel ?? PopupPanel()
            self.panel = panel
            if panel.appearance != window.appearance { panel.appearance = window.appearance }
            panel.acceptsKeyboard = acceptsKeyboard
            panel.onCancel = onCancel
            guard let contentView = window.contentView else { return }
            panel.host.isPlacing = true
            defer { panel.host.isPlacing = false }
            let hostedContent = content.environment(\.insidePopupPanel, true)
            panel.host.rootView = AnyView(hostedContent)
            var size = panel.host.idealSize
            var edgeY = origin.y
            var opensAbove = false
            if let anchor {
                let bounds = anchor.bounds.isEmpty ? CGRect(origin: .zero, size: contentView.bounds.size) : anchor.bounds
                let placement = PopupPlacement.resolve(anchor: anchor.rect, bounds: bounds, naturalHeight: size.height)
                panel.host.rootView = AnyView(hostedContent.environment(\.popupAvailableHeight, placement.availableHeight))
                size = panel.host.idealSize
                edgeY = placement.edgeY
                opensAbove = placement.edge == .above
            }
            panel.host.pinsBottomEdge = opensAbove
            let localY = contentView.isFlipped ? edgeY : contentView.bounds.height - edgeY
            let edge = window.convertPoint(toScreen: contentView.convert(NSPoint(x: origin.x, y: localY), to: nil))
            let winFrame = window.frame
            let clampedX = max(winFrame.minX + 8, min(edge.x, winFrame.maxX - size.width - 8))
            let y = opensAbove ? edge.y : edge.y - size.height
            panel.setFrame(NSRect(x: clampedX, y: y, width: size.width, height: size.height), display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            if acceptsKeyboard {
                panel.makeKeyAndOrderFront(nil)
            } else {
                if panel.isKeyWindow { window.makeKey() }
                panel.orderFront(nil)
            }
        }

        func hide() {
            guard let panel, panel.isVisible else { return }
            let parent = panel.parent
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.host.rootView = AnyView(EmptyView())
            if panel.acceptsKeyboard { parent?.makeKey() }
        }
    }

    final class ResizingHost: NSHostingView<AnyView> {
        var pinsBottomEdge = false
        var isPlacing = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        var idealSize: NSSize {
            let size = intrinsicContentSize
            return size.width > 0 && size.height > 0 ? size : fittingSize
        }

        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            guard !isPlacing, let window, window.isVisible else { return }
            let size = idealSize
            guard size != window.frame.size, size.width > 0, size.height > 0 else { return }
            var x = window.frame.minX
            if let parentFrame = window.parent?.frame {
                x = max(parentFrame.minX + 8, min(x, parentFrame.maxX - size.width - 8))
            }
            let y = pinsBottomEdge ? window.frame.minY : window.frame.maxY - size.height
            window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        }
    }

    final class PopupPanel: NSPanel {
        let host = ResizingHost(rootView: AnyView(EmptyView()))
        var acceptsKeyboard = false
        var onCancel: (() -> Void)?

        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            isFloatingPanel = true
            hidesOnDeactivate = true
            hasShadow = true
            isOpaque = false
            backgroundColor = .clear
            animationBehavior = .none
            host.sizingOptions = [.intrinsicContentSize]
            contentView = host
        }

        override var canBecomeKey: Bool { acceptsKeyboard }

        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, event.keyCode == 53, let onCancel {
                onCancel()
                return
            }
            super.sendEvent(event)
        }

        override func resignKey() {
            super.resignKey()
            if acceptsKeyboard {
                let workspace = WorkspaceState.owning(window: parent)
                if workspace.issuePopup != nil {
                    workspace.issuePopup = nil
                }
            }
        }

        override func scrollWheel(with event: NSEvent) {
            if !acceptsKeyboard {
                let workspace = WorkspaceState.owning(window: parent)
                workspace.dismissTransientEditorOverlays(includeRename: false, includePopovers: false)
                if let scrollView = workspace.activeTextView?.enclosingScrollView {
                    scrollView.scrollWheel(with: event)
                    return
                }
            }
            super.scrollWheel(with: event)
        }
    }
}

struct FloatingPanelBackground: ViewModifier {
    let cornerRadius: CGFloat
    var castShadow: Bool = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.insidePopupPanel) private var insidePopupPanel

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shouldShadow = castShadow && !insidePopupPanel
        if reduceTransparency {
            let base = content
                .foregroundStyle(ChromeColor.textPrimary)
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(ChromeColor.separator, lineWidth: Stroke.standard))
            if shouldShadow {
                base.shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
            } else {
                base
            }
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

struct PopupRowModifier: ViewModifier {
    let isSelected: Bool
    let onHoverSelect: (() -> Void)?
    let action: () -> Void

    func body(content: Content) -> some View {
        let rowShape = RoundedRectangle(cornerRadius: CornerRadius.panelRow, style: .continuous)
        content
            .background(
                isSelected ? ChromeColor.selection : Color.clear,
                in: rowShape
            )
            .rowButton(action: action)
            .onContinuousHover { phase in
                if case .active = phase, let onHoverSelect, !isSelected {
                    PopupMouseTracker.performHoverSelect(onHoverSelect)
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum PopupMouseTracker {
    private static var anchorMouseLocation: NSPoint = NSEvent.mouseLocation
    private static var mouseActive: Bool = false
    private(set) static var isHoverSelecting: Bool = false

    static func markKeyboardOrOpen() {
        anchorMouseLocation = NSEvent.mouseLocation
        mouseActive = false
        isHoverSelecting = false
    }

    static func didMouseMove() -> Bool {
        if mouseActive { return true }
        let current = NSEvent.mouseLocation
        if hypot(current.x - anchorMouseLocation.x, current.y - anchorMouseLocation.y) > 1.5 {
            mouseActive = true
            return true
        }
        return false
    }

    static func performHoverSelect(_ update: () -> Void) {
        guard didMouseMove() else { return }
        isHoverSelecting = true
        update()
        DispatchQueue.main.async {
            isHoverSelecting = false
        }
    }
}

enum ChromeMaterialStyle {
    case regular
    case thick
}

struct ChromeMaterialSurface: ViewModifier {
    let style: ChromeMaterialStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            } else {
                switch style {
                case .regular:
                    Rectangle().fill(.regularMaterial).ignoresSafeArea()
                case .thick:
                    Rectangle().fill(.thickMaterial).ignoresSafeArea()
                }
            }
        }
    }
}

struct GlassControlCapsuleModifier: ViewModifier {
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .contentShape(.capsule)
                .background(ChromeColor.panelSurface, in: .capsule)
                .overlay(Capsule().strokeBorder(ChromeColor.separator, lineWidth: Stroke.hairline))
        } else {
            content
                .contentShape(.capsule)
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        }
    }
}

struct FloatingHudTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if !reduceTransparency {
            content.glassEffectTransition(.materialize)
        } else {
            content.transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        }
    }
}

extension View {
    func floatingPanelBackground(cornerRadius: CGFloat = CornerRadius.panel, castShadow: Bool = true) -> some View {
        modifier(FloatingPanelBackground(cornerRadius: cornerRadius, castShadow: castShadow))
    }

    func chromeMaterialSurface(_ style: ChromeMaterialStyle = .regular) -> some View {
        modifier(ChromeMaterialSurface(style: style))
    }

    func glassControlCapsule(interactive: Bool = true) -> some View {
        modifier(GlassControlCapsuleModifier(interactive: interactive))
    }

    func floatingHudTransition() -> some View {
        modifier(FloatingHudTransitionModifier())
    }

    func popupRow(isSelected: Bool, onHoverSelect: (() -> Void)? = nil, action: @escaping () -> Void) -> some View {
        modifier(PopupRowModifier(isSelected: isSelected, onHoverSelect: onHoverSelect, action: action))
    }

    func rowButton(action: @escaping () -> Void) -> some View {
        Button(action: action) { contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}

struct PopupFieldAutoFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = FocusAnchorView()
        view.requestFocus()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FocusAnchorView)?.requestFocus()
    }

    final class FocusAnchorView: NSView {
        private var didFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            didFocus = false
            requestFocus()
        }

        func requestFocus() {
            guard !didFocus else { return }
            if tryFocusNow() {
                didFocus = true
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.didFocus else { return }
                if self.tryFocusNow() {
                    self.didFocus = true
                }
            }
        }

        @discardableResult
        private func tryFocusNow() -> Bool {
            guard let window else { return false }
            if let tv = window.firstResponder as? NSTextView, tv.isFieldEditor {
                return true
            }
            var node: NSView? = superview
            while let current = node {
                if let field = Self.findTextField(in: current) {
                    window.makeFirstResponder(field)
                    return (window.firstResponder as? NSTextView)?.isFieldEditor == true || window.firstResponder === field
                }
                node = current.superview
            }
            return false
        }

        static func findTextField(in root: NSView) -> NSTextField? {
            if let tf = root as? NSTextField, tf.isEditable {
                return tf
            }
            for sub in root.subviews {
                if let found = findTextField(in: sub) {
                    return found
                }
            }
            return nil
        }
    }
}

enum PopupSearchKeyCapture {
    static func routeIfFieldUnfocused(_ event: NSEvent, query: inout String, onFocus: () -> Void) -> Bool {
        if let tv = event.window?.firstResponder as? NSTextView, tv.isFieldEditor {
            return false
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !mods.contains(.command), !mods.contains(.control), !mods.contains(.function) else {
            return false
        }
        if event.keyCode == 51 {
            if !query.isEmpty { query.removeLast() }
            onFocus()
            return true
        }
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            return false
        }
        query.append(chars)
        onFocus()
        return true
    }
}
