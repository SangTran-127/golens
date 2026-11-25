package database

import (
	"os"
	"path/filepath"
)

func editingFixtures(def Definition, columns []Column, session *SessionState) map[string]any {
	execID := "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F"
	consoleID := "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A"
	tableConsole := "4B3A2918-0716-4F5E-8D4C-3B2A19080706"
	resultID := "r-6f1c2a9e0b7d4e31"
	tableSQL := "SELECT * FROM \"public\".\"users\"\nWHERE plan = 'pro'\nORDER BY created_at DESC"
	tableResult := StatementResult{Index: 0, Line: 1, StartByte: 0, EndByte: len(tableSQL), Kind: "select", ResultID: resultID,
		Columns: columns, RowsFetched: 500, DurationMs: 9.8, FirstRowMs: 6.2, PageEncodedMs: 0.5, Notices: []string{}}
	manual := &SessionState{State: "connected", Transaction: "active", Schema: "public", Mode: "manual", Isolation: "repeatable read"}
	editReq := EditRequest{ExecID: execID, ResultID: resultID,
		Edits: []CellEdit{
			{Row: 3, Column: 1, Value: "ada@example.org"},
			{Row: 7, Column: 1, IsNull: true},
		},
		Inserts: []RowInsert{{Cells: []InsertCell{{Column: 1, Value: "new@example.com"}}}},
		Deletes: []int64{12},
	}
	applyReq := editReq
	applyReq.Confirmed = []Confirmation{{Hash: "9b74c9897bac770ffc029102a200c5de2f5e2f1b1e8f2d1e0f6d1b2c3a4e5f60", Risk: RiskProductionWrite}}
	planned := []PlannedStatement{
		{Kind: "delete", Row: ptr(int64(12)), SQL: `DELETE FROM "public"."users" WHERE "id" = $1::bigint`, Params: []*string{s("13")}},
		{Kind: "update", Row: ptr(int64(3)), SQL: `UPDATE "public"."users" SET "email" = $1::text WHERE "id" = $2::bigint`, Params: []*string{s("ada@example.org"), s("4")}},
		{Kind: "update", Row: ptr(int64(7)), SQL: `UPDATE "public"."users" SET "email" = $1::text WHERE "id" = $2::bigint`, Params: []*string{nil, s("8")}},
		{Kind: "insert", Insert: ptr(0), SQL: `INSERT INTO "public"."users" ("email") VALUES ($1::text)`, Params: []*string{s("new@example.com")}},
	}
	return map[string]any{
		"open-table-request": OpenTableRequest{ExecID: execID, ConsoleID: tableConsole, DataSourceID: def.ID, WorkspaceRoot: "/Users/me/src/app",
			Schema: "public", Table: "users", Where: "plan = 'pro'", OrderBy: "created_at DESC", PageSize: 500},
		"open-table-response": OpenTableResponse{
			ExecuteResponse: ExecuteResponse{ExecID: execID, Blocked: []Blocked{}, Statements: []StatementResult{tableResult}, Session: session},
			SQL:             tableSQL, Editable: true, KeyColumns: []string{"id"}, ReadOnlyColumns: []ReadOnlyColumn{},
			ForeignKeyColumns: []int{},
			ReferencingTables: []ReferencingTable{{Schema: "public", Table: "orders", Columns: []string{"user_id"}, Constraint: "orders_user_id_fkey"}}},
		"open-table-response-read-only": OpenTableResponse{
			ExecuteResponse: ExecuteResponse{ExecID: execID, Blocked: []Blocked{}, Statements: []StatementResult{tableResult}, Session: session},
			SQL:             "SELECT * FROM \"public\".\"audit_log\"", Editable: false, KeyColumns: []string{}, Reason: reasonNoKey,
			ReadOnlyColumns: []ReadOnlyColumn{{Column: 2, Reason: "GoLens can't edit geometry values yet."}}},
		"open-table-response-error": OpenTableResponse{
			ExecuteResponse: ExecuteResponse{ExecID: execID, Blocked: []Blocked{}, Statements: []StatementResult{},
				Session: &SessionState{State: "notConnected", Transaction: "idle", Mode: "auto"},
				Error:   newError("syntax", "The filter must be a single expression, without a semicolon or an unclosed quote, comment or parenthesis.")},
			KeyColumns: []string{}, ReadOnlyColumns: []ReadOnlyColumn{}},
		"count-rows-request":        CountRowsRequest{ExecID: execID, DataSourceID: def.ID, Schema: "public", Table: "users", Where: "plan = 'pro'"},
		"count-rows-response":       CountRowsResult{Count: ptr(int64(1048576))},
		"count-rows-response-error": CountRowsResult{Error: errorFor("cancelled")},
		"plan-edits-request":        editReq,
		"plan-edits-response":       PlanEditsResult{Statements: planned, Issues: []EditIssue{}, Blocked: []Blocked{}},
		"plan-edits-response-issues": PlanEditsResult{Statements: planned[:1], Blocked: []Blocked{},
			Issues: []EditIssue{{Row: ptr(int64(3)), Column: ptr(4), Message: "Enter binary values as hexadecimal that starts with 0x."}}},
		"plan-edits-response-production": PlanEditsResult{Statements: planned, Issues: []EditIssue{},
			Blocked: []Blocked{{Index: 0, Hash: applyReq.Confirmed[0].Hash, Risk: RiskProductionWrite, Table: "users", Line: 0, Preview: "4 changes to users"}}},
		"plan-edits-response-error": PlanEditsResult{Statements: []PlannedStatement{}, Issues: []EditIssue{}, Blocked: []Blocked{},
			Error: newError("unsupported", reasonNoKey)},
		"apply-edits-request":         applyReq,
		"apply-edits-response":        ApplyEditsResult{Applied: true, Committed: true, RowsAffected: 4, Blocked: []Blocked{}, Session: session},
		"apply-edits-response-manual": ApplyEditsResult{Applied: true, Committed: false, RowsAffected: 4, Blocked: []Blocked{}, Session: manual},
		"apply-edits-response-conflict": ApplyEditsResult{FailedStatement: ptr(1), Blocked: []Blocked{}, Session: session,
			Error: newError("conflict", "Row 4 no longer matches its key in the database (someone may have changed or deleted it), so nothing was saved. Reload the table and make the change again.")},
		"apply-edits-response-blocked": ApplyEditsResult{Session: session,
			Blocked: []Blocked{{Hash: applyReq.Confirmed[0].Hash, Risk: RiskProductionWrite, Table: "users", Preview: "4 changes to users"}}},
		"transaction-request": TransactionRequest{ConsoleID: consoleID, DataSourceID: def.ID, Action: "setIsolation", Isolation: "repeatable read"},
		"transaction-response": TransactionResult{Session: manual,
			IsolationLevels: []string{"read committed", "repeatable read", "serializable"}},
		"transaction-response-error": TransactionResult{Session: manual,
			IsolationLevels: []string{"read committed", "repeatable read", "serializable"},
			Error:           newError("transactionOpen", "Commit or roll back the open transaction before switching to Auto-Commit.")},
		"parameters-request": map[string]any{"text": "SELECT * FROM users WHERE id = :id AND created_at > $2::timestamptz AND team = sqlc.narg(team)",
			"dialect": EnginePostgres, "startByte": 0, "endByte": 0},
		"parameters-response": Parameters("SELECT * FROM users WHERE id = :id AND created_at > $2::timestamptz AND team = sqlc.narg(team)", EnginePostgres, 0, 0),
		"execute-request-parameters": ExecuteRequest{ExecID: execID, ConsoleID: consoleID, DataSourceID: def.ID, WorkspaceRoot: "/Users/me/src/app",
			Text: "SELECT * FROM users WHERE id = :id AND token = :token", Mode: "caret", CaretByte: 0, Confirmed: []Confirmation{}, PageSize: 500,
			Parameters: []ParamValue{{Name: ":id", Value: "42"}, {Name: ":token", Value: "s3cr3t", Secret: true}}},
		"execute-response-needs-parameters": ExecuteResponse{ExecID: execID, Blocked: []Blocked{}, Statements: []StatementResult{}, Session: session,
			Error: missingParamsError([]string{":id", ":token"})},
		"explain-request": ExplainRequest{ExecuteRequest: ExecuteRequest{ExecID: execID, ConsoleID: consoleID, DataSourceID: def.ID,
			WorkspaceRoot: "/Users/me/src/app", Text: "DELETE FROM sessions WHERE expires_at < now()", Mode: "caret", CaretByte: 0,
			Confirmed: []Confirmation{}, PageSize: 500}, Analyze: true},
		"explain-response":      ExplainResult{Plan: recordedPlan("postgres-analyze.json", parsePostgresPlan), Analyzed: true, RolledBack: true, Blocked: []Blocked{}, Session: session},
		"explain-response-plan": ExplainResult{Plan: recordedPlan("mysql-plan.json", parseMySQLJSONPlan), Blocked: []Blocked{}, Session: session},
		"explain-response-tree": ExplainResult{Plan: recordedPlan("mysql-analyze.txt", parseMySQLTreePlan), Analyzed: true, Blocked: []Blocked{}, Session: session},
		"explain-response-unsupported": ExplainResult{Blocked: []Blocked{}, Session: session,
			Error: newError("unsupported", "MySQL can analyze only SELECT statements, so GoLens did not run this DELETE. Use Explain Plan to see its estimated plan.")},
		"export-request": ExportRequest{ExecID: execID, ResultID: resultID, Format: "csv", Scope: "all", Path: "/Users/me/Desktop/users.csv",
			Options: ExportOptions{IncludeHeader: ptr(true), NullText: ptr("")}},
		"export-request-clipboard": ExportRequest{ExecID: execID, ResultID: resultID, Format: "sql", Scope: "selection", Rows: []int64{0},
			Clipboard: true, Options: ExportOptions{TableName: "public.users_copy", Columns: []int{0, 1}}},
		"export-response":           ExportResult{RowsWritten: 1000000, Bytes: 61981551, CursorClosed: true},
		"export-response-clipboard": ExportResult{RowsWritten: 1, Bytes: 81, Text: "INSERT INTO \"public\".\"users_copy\" (\"id\", \"email\") VALUES (1, 'ada@example.com');\n"},
		"export-response-too-large": ExportResult{RowsWritten: 1536, Bytes: 0,
			Error: newError("tooLarge", "The result is larger than 10 MB, so GoLens did not copy it. Use Export Result to save it to a file instead.")},
		"detect-response": DetectResult{Candidates: []Candidate{
			{Definition: Definition{Name: "db", Engine: EnginePostgres, Host: "localhost", Port: 54320, Database: "golens", User: "golens", Password: "keychain", SSL: SSL{Mode: "prefer"}},
				Source: DetectSource{File: "compose.yaml", Line: 3, Key: "db"}, Kind: "compose", HasSecret: true, Secret: "devpass"},
			{Definition: Definition{Name: "app", Engine: EnginePostgres, Host: "localhost", Port: 5433, Database: "app", User: "app", Password: "ask", SSL: SSL{Mode: "disable"}},
				Source: DetectSource{File: ".env", Line: 2, Key: "DATABASE_URL"}, Kind: "env"},
			{Definition: Definition{Name: "maria", Engine: EngineMySQL, Host: "localhost", Port: 3306, Database: "shop", User: "root", Password: "keychain", SSL: SSL{Mode: "prefer"}, DefaultSchema: "shop"},
				Source: DetectSource{File: "compose.yaml", Line: 11, Key: "maria"}, Kind: "compose", HasSecret: true, Secret: "rootpw",
				Note: "The MariaDB service does not publish port 3306, so GoLens may not reach it from this Mac. Publish the port in compose.yaml or change the port here."},
			{Definition: Definition{Name: "dev.db", Engine: EngineSQLite, Password: "none", SQLitePath: "data/dev.db"},
				Source: DetectSource{File: "sqlc.yaml", Line: 7, Key: "database.uri"}, Kind: "sqlc"},
		}},
		"detect-response-empty":  DetectResult{Candidates: []Candidate{}},
		"history-request":        HistoryRequest{DataSourceID: def.ID, Query: "users", Limit: 100},
		"history-request-delete": HistoryRequest{DataSourceID: def.ID, Delete: "3f9a1c2b4d5e6f70"},
		"history-response": HistoryResult{Entries: []HistoryEntry{
			{ID: "3f9a1c2b4d5e6f70", Text: "SELECT * FROM users WHERE id = :id", Time: "2026-11-16T09:12:03+07:00", DurationMs: 3.4, RowCount: ptr(int64(1)), Source: "console",
				Parameters: []ParamValue{{Name: ":id", Value: "42"}}},
			{ID: "0a1b2c3d4e5f6a7b", Text: "UPDATE users SET plan = 'pro' WHERE id = 7", Time: "2026-11-16T09:10:44+07:00", DurationMs: 1.1, RowCount: ptr(int64(1)), Source: "console"},
			{ID: "7e6d5c4b3a291807", Text: "SELECT * FROM userz", Time: "2026-11-16T09:09:00+07:00", DurationMs: 0.8, Error: "The database could not run the statement as written. Fix it and run it again.", Source: "console"},
			{ID: "1122334455667788", Text: `UPDATE "public"."users" SET "email" = $1::text WHERE "id" = $2::bigint`, Time: "2026-11-16T09:08:00+07:00", DurationMs: 0.9, RowCount: ptr(int64(1)), Source: "edit"},
			{ID: "99aabbccddeeff00", Text: "SELECT * FROM users WHERE token = :token", Time: "2026-11-16T09:07:00+07:00", DurationMs: 0.7, RowCount: ptr(int64(0)), Source: "console",
				Parameters: []ParamValue{{Name: ":token", Secret: true}}},
		}},
	}
}

func recordedPlan(name string, parse func(string) (*Plan, error)) *Plan {
	b, err := os.ReadFile(filepath.Join("testdata", "explain", name))
	if err != nil {
		panic(err)
	}
	p, err := parse(string(b))
	if err != nil {
		panic(err)
	}
	return p
}
