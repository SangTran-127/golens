import AppKit
import SwiftUI

struct CommandFeedbackNotice: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String
    let tone: StatusTone
    let presentedAt: TimeInterval
}

struct CommandFeedbackPresenter: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let notice = workspace.commandFeedback {
                InlineBanner(
                    .status(notice.tone),
                    title: notice.title,
                    message: notice.message,
                    onClose: { workspace.dismissCommandFeedback() }
                )
                .accessibilityLabel("\(notice.title). \(notice.message)")
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.quick, value: workspace.commandFeedback)
    }
}

extension WorkspaceState {
    static func formatCommandReason(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let capitalized = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        if capitalized.hasSuffix(".") || capitalized.hasSuffix("!") || capitalized.hasSuffix("?") {
            return capitalized
        }
        return capitalized + "."
    }

    func presentCommandFeedback(_ message: String, title: String = "Command Unavailable", tone: StatusTone = .info) {
        let applyBlock = { [weak self] in
            guard let self else { return }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanMessage = trimmed.isEmpty ? "This command cannot run in the current context." : trimmed
            let notice = CommandFeedbackNotice(
                id: UUID(),
                title: title,
                message: cleanMessage,
                tone: tone,
                presentedAt: ProcessInfo.processInfo.systemUptime
            )
            self.commandFeedbackDismissWorkItem?.cancel()
            withAnimation(Motion.quick) {
                self.commandFeedback = notice
            }
            self.installCommandFeedbackKeyMonitorIfNeeded()

            let work = DispatchWorkItem { [weak self] in
                guard let self, self.commandFeedback?.id == notice.id else { return }
                self.dismissCommandFeedback()
            }
            self.commandFeedbackDismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
        }
        if Thread.isMainThread {
            applyBlock()
        } else {
            DispatchQueue.main.async(execute: applyBlock)
        }
    }

    func dismissCommandFeedback() {
        let clearBlock = { [weak self] in
            guard let self else { return }
            self.commandFeedbackDismissWorkItem?.cancel()
            self.commandFeedbackDismissWorkItem = nil
            if let monitor = self.commandFeedbackKeyMonitor {
                NSEvent.removeMonitor(monitor)
                self.commandFeedbackKeyMonitor = nil
            }
            if self.commandFeedback != nil {
                withAnimation(Motion.quick) {
                    self.commandFeedback = nil
                }
            }
        }
        if Thread.isMainThread {
            clearBlock()
        } else {
            DispatchQueue.main.async(execute: clearBlock)
        }
    }

    private func installCommandFeedbackKeyMonitorIfNeeded() {
        guard commandFeedbackKeyMonitor == nil else { return }
        commandFeedbackKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let notice = self.commandFeedback else { return event }
            let elapsed = ProcessInfo.processInfo.systemUptime - notice.presentedAt
            if event.keyCode == 53 && elapsed > 0.05 {
                self.dismissCommandFeedback()
                return nil
            }
            if elapsed > 0.15 {
                self.dismissCommandFeedback()
            }
            return event
        }
    }
}
