// Decodes every golden database FFI fixture with the Swift DTOs (top-level code, so compile it as main.swift):
//   T=$(mktemp -d) && cp scripts/database-models-check.swift $T/main.swift && swiftc desktop/State/DatabaseModels.swift $T/main.swift -o $T/dbc && $T/dbc core/database/testdata/ffi
// Covers every JSON fixture except the page vectors, round-trips each shape, and checks that unknown fields in .golens/data-sources.json survive a save.
import Foundation

func expect(_ ok: Bool, _ what: String) {
    if !ok {
        print("FAIL:", what)
        exit(1)
    }
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "core/database/testdata/ffi"
let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
    .filter { $0.hasSuffix(".json") && !$0.hasPrefix("page-v1-") }
    .sorted()
expect(names.count >= 78, "found the FFI fixtures in \(dir) (\(names.count))")

var decoded = 0
for name in names {
    let data = try! Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
    guard let decode = DBFixtureCatalog.decoder(forFixture: name) else {
        expect(false, "\(name) has a Swift DTO")
        continue
    }
    do {
        _ = try decode(data)
        decoded += 1
    } catch {
        expect(false, "\(name) decodes: \(error)")
    }
}

func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String) {
    let data = try! Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name))
    let first = try! JSONDecoder().decode(T.self, from: data)
    let again = try! JSONDecoder().decode(T.self, from: try! JSONEncoder().encode(first))
    expect(first == again, "\(name) survives an encode and decode")
}

roundTrip(DBDataSourcesFile.self, "configure-request.json")
roundTrip(DBExecuteRequest.self, "execute-request.json")
roundTrip(DBExecuteResponse.self, "execute-response.json")
roundTrip(DBTestConnectionRequest.self, "test-connection-request.json")
roundTrip(DBEvent.self, "event-session-state.json")

let response = try! JSONDecoder().decode(DBExecuteResponse.self, from: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("execute-response.json")))
expect(response.statements.count == 3, "execute response lists three statements")
expect(response.statements[0].columns[2].nullable == nil, "nullable may be null")
expect(response.statements[0].columns[0].origin == nil, "origin may be null")
expect(response.statements[1].rowsAffected == 3, "rows affected decode")
expect(response.statements[1].notices == ["NOTICE: 3 rows touched"], "notices decode")

let blocked = try! JSONDecoder().decode(DBExecuteResponse.self, from: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("execute-response-blocked.json")))
expect(blocked.blocked.first?.risk == DBRisk.deleteWithoutWhere && blocked.blocked.first?.table == "orders", "blocked statement names its risk and table")

let errors = try! JSONDecoder().decode([DBError].self, from: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("errors.json")))
expect(errors.contains { $0.kind == DBError.server }, "the server error kind decodes")
expect(errors.first { $0.kind == DBError.syntax }?.position?.col == 16, "error position decodes")

let session = try! JSONDecoder().decode(DBEvent.self, from: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("event-session-state.json")))
expect(session.transactionOpenMinutes == 15 && session.dataSourceId != nil && session.session?.hasOpenTransaction == true, "session event carries the data source and transaction age")

let nullLists = #"{"execId":"x","blocked":null,"statements":null,"session":null,"error":null}"#
let empty = try! JSONDecoder().decode(DBExecuteResponse.self, from: Data(nullLists.utf8))
expect(empty.blocked.isEmpty && empty.statements.isEmpty, "null lists decode as empty")
let missingLists = try! JSONDecoder().decode(DBExecuteResponse.self, from: Data(#"{"execId":"x"}"#.utf8))
expect(missingLists.statements.isEmpty, "missing lists decode as empty")

let withUnknown = #"{"version":1,"future":{"a":[1,true,null]},"dataSources":[{"id":"A","name":"a","engine":"sqlite","sqlitePath":"a.db","color":"teal","ssl":{"mode":"disable","pinned":"x"}}]}"#
let file = try! JSONDecoder().decode(DBDataSourcesFile.self, from: Data(withUnknown.utf8))
let saved = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
expect(saved["future"] != nil, "unknown file fields are preserved")
let source = (saved["dataSources"] as! [[String: Any]])[0]
expect(source["color"] as? String == "teal", "unknown data source fields are preserved")
expect((source["ssl"] as! [String: Any])["pinned"] as? String == "x", "unknown SSL fields are preserved")
expect(source["password"] as? String == "none" && source["readOnly"] as? Bool == false, "missing fields get their defaults")

func fixture<T: Decodable>(_ type: T.Type, _ name: String) -> T {
    try! JSONDecoder().decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)))
}

roundTrip(DBEditRequest.self, "apply-edits-request.json")
roundTrip(DBExecuteRequest.self, "execute-request-parameters.json")
roundTrip(DBExplainRequest.self, "explain-request.json")
roundTrip(DBExportRequest.self, "export-request-clipboard.json")
roundTrip(DBTransactionRequest.self, "transaction-request.json")
roundTrip(DBOpenTableRequest.self, "open-table-request.json")

let parameterized = fixture(DBExecuteRequest.self, "execute-request-parameters.json")
expect(parameterized.parameters?.last?.isSecret == true && parameterized.parameters?.first?.value == "42", "execute parameters decode with the secret flag")
let txResult = fixture(DBTransactionResult.self, "transaction-response.json")
expect(txResult.session?.transactionMode == .manual && txResult.session?.isolation == "repeatable read" && txResult.isolationLevels.count == 3, "transaction state carries mode, isolation and the engine's levels")
expect(fixture(DBTransactionResult.self, "transaction-response-error.json").error?.kind == DBError.transactionOpen, "the open transaction refusal decodes")
let table = fixture(DBOpenTableResponse.self, "open-table-response.json")
expect(table.editable && table.keyColumns == ["id"] && table.statements.count == 1 && table.sql.contains("ORDER BY"), "open table returns the bound result and its keys")
let readOnlyTable = fixture(DBOpenTableResponse.self, "open-table-response-read-only.json")
expect(!readOnlyTable.editable && !readOnlyTable.reason.isEmpty && readOnlyTable.readOnlyColumns.first?.column == 2, "a table without a key says why and lists read-only columns")
let plan = fixture(DBPlanEditsResult.self, "plan-edits-response-production.json")
expect(plan.statements.map(\.kind) == ["delete", "update", "update", "insert"] && plan.statements[2].params.first == .some(nil) && plan.blocked.count == 1, "planned edits keep their order, null parameters and the production block")
expect(fixture(DBPlanEditsResult.self, "plan-edits-response-issues.json").issues.first?.column == 4, "edit issues name the cell")
let manual = fixture(DBApplyEditsResult.self, "apply-edits-response-manual.json")
expect(manual.applied && !manual.committed && manual.session?.hasOpenTransaction == true, "edits applied inside a manual transaction are not committed")
expect(fixture(DBApplyEditsResult.self, "apply-edits-response-conflict.json").failedStatement == 1, "a conflict names the failed statement")
let explain = fixture(DBExplainResult.self, "explain-response.json")
expect(explain.rolledBack && explain.analyzed && explain.plan?.mostExpensive == 0 && explain.plan?.nodes.count == 5 && explain.plan?.nodes[1].parent == 0, "the explain outline decodes with its parents and most expensive node")
expect(fixture(DBExplainResult.self, "explain-response-unsupported.json").plan == nil, "an unsupported explain has no plan")
expect(fixture(DBExportResult.self, "export-response.json").cursorClosed == true, "export says when it closed the cursor")
expect(fixture(DBExportResult.self, "export-response-too-large.json").error?.kind == DBError.tooLarge, "the clipboard limit decodes")
let history = fixture(DBHistoryResult.self, "history-response.json")
expect(history.entries.count == 5 && history.entries[2].rowCount == nil && history.entries[4].parameters?.first?.isSecret == true, "history entries decode with errors and secret parameters")
let detected = fixture(DBDetectResult.self, "detect-response.json")
expect(detected.candidates.count == 4 && detected.candidates[0].secret == "devpass" && detected.candidates[2].note != nil && detected.candidates[3].definition.engineKind == .sqlite, "detected candidates carry their source, secret and note")
let params = fixture(DBParametersResult.self, "parameters-response.json")
expect(params.parameters.map(\.name) == [":id", "$2", "@team"] && params.parameters[1].typeHint == "timestamptz" && params.parameters[2].nullable == true, "parameters decode with type hints")

var manualSource = DBDataSourceDefinition(name: "prod", engine: .postgres)
manualSource.production = true
expect(manualSource.effectiveTransactionMode == .manual, "production defaults to manual transactions")
let encodedSource = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(manualSource)) as! [String: Any]
expect(encodedSource["transactionMode"] == nil, "an empty transaction mode is not written")
manualSource.transactionMode = "auto"
expect(manualSource.effectiveTransactionMode == .auto, "an explicit transaction mode wins")

let pg = DBDataSourceDefinition(name: "local", engine: .postgres)
expect(pg.port == 5432 && pg.passwordMode == .keychain && pg.host == "localhost", "a new PostgreSQL source has its defaults")
expect(DBEngine.mysql.quoteIdentifier("a`b") == "`a``b`" && DBEngine.postgres.quoteIdentifier("a\"b") == "\"a\"\"b\"", "identifiers are quoted per dialect")

print("OK: \(decoded) database FFI fixtures decoded")
