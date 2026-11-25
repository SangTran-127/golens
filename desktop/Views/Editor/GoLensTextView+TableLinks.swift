import AppKit
import GoLensFoundation

extension GoLensTextView {
    func updateTableLink(atCharacter index: Int) {
        guard EcosystemDocumentTools.isSQLFile(filePath),
              let reference = SQLNameReference.at(index, in: liveText) else { return clearTableLink() }
        let range = Self.tableLinkRange(reference)
        guard tableLinkRequest != range, tableLink?.range != range else { return }
        clearTableLink()
        tableLinkRequest = range
        let path = filePath
        workspaceState.resolveDatabaseTable(inConsole: path, reference: reference) { [weak self] table in
            guard let self, self.tableLinkRequest == range, self.filePath == path else { return }
            self.tableLinkRequest = nil
            guard table != nil, NSMaxRange(range) <= self.liveText.length, let lm = self.layoutManager else { return }
            lm.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range)
            self.tableLink = (path, range)
        }
    }

    func clearTableLink() {
        tableLinkRequest = nil
        guard let link = tableLink else { return }
        tableLink = nil
        guard link.path == filePath, NSMaxRange(link.range) <= liveText.length, let lm = layoutManager else { return }
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: link.range)
        (delegate as? MacTextView.Coordinator)?.restoreDiagnosticUnderlines(in: self)
    }

    func openTableOrSQLMethod(at charIndex: Int) {
        guard let reference = SQLNameReference.at(charIndex, in: liveText) else { return goToSQLMethod(at: charIndex) }
        workspaceState.resolveDatabaseTable(inConsole: filePath, reference: reference) { [weak self] table in
            guard let self else { return }
            guard let table else { return self.goToSQLMethod(at: charIndex) }
            self.clearTableLink()
            self.workspaceState.databaseUI.uiOpenTable(dataSourceID: table.dataSourceID, schema: table.schema, table: table.table)
        }
    }

    private static func tableLinkRange(_ reference: SQLNameReference) -> NSRange {
        let parts = reference.parts.suffix(2)
        guard let first = parts.first, let last = parts.last else { return reference.range }
        return NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
    }
}
