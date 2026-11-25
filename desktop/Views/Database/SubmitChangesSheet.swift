import SwiftUI

struct SubmitChangesSheet: View {
    @Bindable var workspace: WorkspaceState
    let preview: DBSubmitPreview
    @Environment(\.dismiss) private var dismiss

    @State private var isSubmitting = false
    @State private var failure: (error: DBError, statement: Int?)?
    @State private var confirmsProduction = false
    @State private var applyExecID: String?

    private var source: DBDataSourceDefinition? { workspace.database.definition(preview.dataSourceID) }
    private var sourceName: String { source?.name ?? "the data source" }
    private var statements: [DBPlannedStatement] { preview.plan.statements }
    private var issues: [DBEditIssue] { preview.plan.issues }

    private var consoleSession: DBSessionState? {
        workspace.database.result(preview.tabID).flatMap { workspace.database.session(forConsole: $0.consoleID) }
    }

    private var runsInOpenTransaction: Bool {
        consoleSession?.transactionMode == .manual || consoleSession?.hasOpenTransaction == true
    }

    var body: some View {
        StandardSheetShell(
            title: "Submit Changes",
            subtitle: subtitle,
            scopeBadge: preview.table,
            size: .generator,
            primaryTitle: "Submit Changes",
            primaryAccessibilityLabel: "Submit \(UserMessage.count(statements.count, "Statement"))",
            isPrimaryDisabled: isSubmitting || statements.isEmpty || !issues.isEmpty,
            closeTitle: "Cancel",
            onPrimary: submit,
            onClose: close,
            footerLeading: {
                if isSubmitting {
                    HStack(spacing: Spacing.standard) {
                        ProgressView().controlSize(.small)
                        Text("Submitting…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.comfortable) {
                banners
                GeneratorCodePreview(
                    code: sqlText,
                    placeholder: "There are no changes to submit.",
                    accessibilityLabel: "SQL that runs",
                    path: "preview.sql",
                    copyHelp: "Copy the SQL to the clipboard"
                )
            }
        }
        .alert(productionTitle, isPresented: $confirmsProduction) {
            Button("Submit Changes", role: .destructive) { apply() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(sourceName)” is marked as production, and these statements change data.")
        }
    }

    private var subtitle: String {
        let count = UserMessage.count(statements.count, "statement")
        return runsInOpenTransaction
            ? "\(count) run on “\(sourceName)” inside the console’s transaction. Nothing is written before you submit."
            : "\(count) run on “\(sourceName)” in one transaction. Nothing is written before you submit."
    }

    private var productionTitle: String {
        "Submit \(UserMessage.count(statements.count, "Change", "Changes")) to “\(sourceName)”?"
    }

    @ViewBuilder
    private var banners: some View {
        if let failure {
            InlineBanner(
                failure.error.kind == DBError.conflict ? .status(.warning) : .status(.failure),
                title: failure.statement.map { "Statement \($0 + 1) Failed" } ?? "Couldn’t Submit the Changes",
                message: failure.error.message + (failure.statement == nil ? "" : " GoLens rolled back every statement, so nothing was saved."),
                detail: DatabaseErrorPresentation.detail(failure.error)
            ) {
                if failure.error.kind == DBError.conflict {
                    Button("Reload Table") {
                        dismiss()
                        workspace.reloadDatabaseTable(preview.tabID, discardingChanges: true)
                    }
                }
            }
        } else if !issues.isEmpty {
            InlineBanner(
                .status(.warning),
                title: "Fix \(UserMessage.count(issues.count, "Value", "Values")) First",
                message: issues.map(issueText).joined(separator: " ")
            )
        } else if !preview.plan.blocked.isEmpty {
            InlineBanner(
                .status(.warning),
                title: "Production Data Source",
                message: "“\(sourceName)” is marked as production. GoLens asks once more before it submits."
            )
        } else if runsInOpenTransaction {
            InlineBanner(
                .symbol("info.circle"),
                title: "Manual Transaction",
                message: "The statements run inside the console’s transaction. Commit to keep them or Roll Back to undo them."
            )
        }
    }

    private func issueText(_ issue: DBEditIssue) -> String {
        let columns = workspace.database.result(preview.tabID)?.statement.columns ?? []
        let column = issue.column.flatMap { columns.indices.contains($0) ? "“\(columns[$0].name)”" : nil }
        let row: String
        if let index = issue.row {
            row = "Row \(UserMessage.integer(Int(index) + 1))"
        } else if let index = issue.insert {
            row = "New row \(UserMessage.integer(index + 1))"
        } else {
            row = "A row"
        }
        return [row + (column.map { ", \($0)" } ?? "") + ":", issue.message].joined(separator: " ")
    }

    private var sqlText: String {
        statements.enumerated().map { index, statement in
            var lines = ["-- \(index + 1) of \(statements.count): \(describe(statement))", statement.sql + ";"]
            if !statement.params.isEmpty {
                let values = statement.params.enumerated().map { position, value in
                    "\(position + 1) = " + (value.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL")
                }
                lines.append("-- parameters: " + values.joined(separator: ", "))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func describe(_ statement: DBPlannedStatement) -> String {
        switch statement.kind {
        case "delete": "delete row \(statement.row.map { UserMessage.integer(Int($0) + 1) } ?? "")"
        case "update": "update row \(statement.row.map { UserMessage.integer(Int($0) + 1) } ?? "")"
        case "insert": "insert new row \(statement.insert.map { UserMessage.integer($0 + 1) } ?? "")"
        default: statement.kind
        }
    }

    private func submit() {
        if !preview.plan.blocked.isEmpty {
            confirmsProduction = true
        } else {
            apply()
        }
    }

    private func close() {
        if isSubmitting, let applyExecID { workspace.cancelDatabaseApply(applyExecID) }
        dismiss()
    }

    private func apply() {
        isSubmitting = true
        failure = nil
        applyExecID = workspace.applyDatabaseChanges(preview) { outcome in
            isSubmitting = false
            applyExecID = nil
            switch outcome {
            case .applied:
                dismiss()
            case .failed(let error, let statement):
                failure = (error, statement)
            }
        }
    }
}
