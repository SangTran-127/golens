import AppKit
import Foundation

extension WorkspaceState {
    private func invokeExtractType(newTypeName: String, apply: Bool) -> ExtractTypeReplyDTO? {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            return nil
        }
        struct Req: Encodable {
            let workspacePath: String
            let path: String
            let src: String
            let startOffset: Int
            let endOffset: Int
            let newTypeName: String
        }
        let path = session.path
        let src = session.storage.string
        let sel = tv.selectedRange()
        let startOffset = session.utf8.byteOffset(sel.location)
        let endOffset = session.utf8.byteOffset(sel.location + sel.length)
        guard let reqData = try? JSONEncoder().encode(Req(
            workspacePath: activeWorkspacePath,
            path: path,
            src: src,
            startOffset: startOffset,
            endOffset: endOffset,
            newTypeName: newTypeName
        )), let reqStr = String(data: reqData, encoding: .utf8) else {
            return nil
        }
        let replyStr: String? = reqStr.withCString { cReq in
            let ptr = apply ? ApplyGoExtractType(cReq) : InspectGoExtractType(cReq)
            guard let ptr else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let replyStr else { return nil }
        return try? JSONDecoder().decode(ExtractTypeReplyDTO.self, from: Data(replyStr.utf8))
    }

    func presentExtractTypeSheet() {
        let preview = invokeExtractType(newTypeName: "", apply: false)
        guard let preview,
              (preview.error ?? "").isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(preview?.error, fallback: "Open a Go file and place the cursor on a type expression to extract a type definition."),
                title: "Extract Type Definition"
            )
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activeExtractTypePreview = preview
        showExtractTypeSheet = true
    }

    func refreshExtractTypePreview(newTypeName: String) -> ExtractTypeReplyDTO? {
        invokeExtractType(newTypeName: newTypeName, apply: false)
    }

    func applyExtractType(newTypeName: String) {
        showExtractTypeSheet = false
        let reply = invokeExtractType(newTypeName: newTypeName, apply: true)
        guard let tv = activeTextView as? GoLensTextView,
              let reply,
              (reply.error ?? "").isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(reply?.error, fallback: "Couldn’t apply the extracted type definition."),
                title: "Extract Type Definition",
                tone: .failure
            )
            return
        }
        if let edits = reply.edits, !edits.isEmpty {
            applyLSPTextEdits(edits, to: tv)
        } else if let editsByPath = reply.editsByPath, !editsByPath.isEmpty {
            var changes: [String: [LSPTextEdit]] = [:]
            for (editPath, edits) in editsByPath where !edits.isEmpty {
                changes[lspURI(forPath: editPath)] = edits
            }
            applyWorkspaceEdit(WorkspaceEdit(changes: changes), activeTextView: activeTextView)
        }
        (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
        tv.needsDisplay = true
    }

    private func invokePropagateInterfaceMethods() -> ExtractTypeReplyDTO? {
        guard let tv = activeTextView as? GoLensTextView,
              let session = tv.document,
              session.path.hasSuffix(".go") else {
            return nil
        }
        struct Req: Encodable {
            let workspacePath: String
            let path: String
            let src: String
            let startOffset: Int
            let endOffset: Int
            let newTypeName: String
        }
        let path = session.path
        let src = session.storage.string
        let sel = tv.selectedRange()
        let startOffset = session.utf8.byteOffset(sel.location)
        let endOffset = session.utf8.byteOffset(sel.location + sel.length)
        guard let reqData = try? JSONEncoder().encode(Req(
            workspacePath: activeWorkspacePath,
            path: path,
            src: src,
            startOffset: startOffset,
            endOffset: endOffset,
            newTypeName: ""
        )), let reqStr = String(data: reqData, encoding: .utf8) else {
            return nil
        }
        let replyStr: String? = reqStr.withCString { cReq in
            guard let ptr = PropagateGoInterfaceMethods(cReq) else { return nil }
            defer { FreeGoCString(ptr) }
            return String(cString: ptr)
        }
        guard let replyStr else { return nil }
        return try? JSONDecoder().decode(ExtractTypeReplyDTO.self, from: Data(replyStr.utf8))
    }

    func presentPropagateInterfaceSheet() {
        let preview = invokePropagateInterfaceMethods()
        guard let preview,
              (preview.error ?? "").isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(preview?.error, fallback: "Open a Go file and place the cursor inside an interface declaration to propagate its methods."),
                title: "Propagate Method to Implementations"
            )
            return
        }
        if let tv = activeTextView as? GoLensTextView,
           let win = tv.window,
           win.firstResponder === tv {
            win.makeFirstResponder(nil)
        }
        activePropagateInterfacePreview = preview
        showPropagateInterfaceSheet = true
    }

    func applyPropagateInterfaceMethods() {
        showPropagateInterfaceSheet = false
        let reply = activePropagateInterfacePreview ?? invokePropagateInterfaceMethods()
        guard let reply,
              let editsByPath = reply.editsByPath,
              !editsByPath.isEmpty else {
            presentCommandFeedback(
                Self.formatCommandReason(reply?.error, fallback: "All implementing structs already define every method of this interface."),
                title: "Propagate Method to Implementations"
            )
            return
        }
        var changes: [String: [LSPTextEdit]] = [:]
        for (editPath, edits) in editsByPath where !edits.isEmpty {
            changes[lspURI(forPath: editPath)] = edits
        }
        guard !changes.isEmpty else { return }
        applyWorkspaceEdit(WorkspaceEdit(changes: changes), activeTextView: activeTextView)
        if let tv = activeTextView as? GoLensTextView {
            (tv.delegate as? MacTextView.Coordinator)?.scheduleHighlight(for: tv)
            tv.needsDisplay = true
        }
        let structs = (reply.propagatedStructs ?? []).joined(separator: ", ")
        if !structs.isEmpty {
            appendLog("Propagated interface methods to: \(structs)")
        }
    }

    func runPreviewJob<T>(_ key: String, _ job: (() -> T?)?, deliver: @escaping (T?) -> Void) {
        guard let job else {
            BackgroundFFI.shared.cancel(key)
            deliver(nil)
            return
        }
        BackgroundFFI.shared.run(key, debounce: 0.15, work: job, deliver: deliver)
    }

    static func insertGoImportIfNeeded(_ source: String, importPath: String) -> String {
        guard !source.contains("\"\(importPath)\"") else {
            return source
        }
        var working = source
        if let r = working.range(of: "import (") {
            if let lineEnd = working[r.upperBound...].firstIndex(of: "\n") {
                let nextIdx = working.index(after: lineEnd)
                working.insert(contentsOf: "\t\"\(importPath)\"\n", at: nextIdx)
                return working
            }
        }
        var lines = working.components(separatedBy: "\n")
        if let pkgIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("package ") }) {
            lines.insert("\nimport \"\(importPath)\"", at: pkgIdx + 1)
            return lines.joined(separator: "\n")
        }
        return working
    }

    func discardGeneratorPreview(_ keyPath: ReferenceWritableKeyPath<WorkspaceState, String>) {
        BackgroundFFI.shared.cancel(keyPath)
        self[keyPath: keyPath] = ""
    }
}
