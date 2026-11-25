package database

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var updateFixtures = flag.Bool("update", false, "rewrite the golden FFI fixtures")

func ptr[T any](v T) *T { return &v }

func ffiFixtures() map[string]any {
	def := Definition{
		ID: "5E0C2D7A-3B1F-4C8E-9A61-2F4D8B7C1E90", Name: "local", Engine: EnginePostgres,
		Host: "localhost", Port: 5432, Database: "app", User: "app", Password: "keychain",
		SSL: SSL{Mode: "prefer"}, DefaultSchema: "public",
	}
	sqliteDef := Definition{
		ID: "8A1B6C3D-2E4F-4A5B-8C7D-9E0F1A2B3C4D", Name: "fixture", Engine: EngineSQLite,
		Password: "none", SSL: SSL{Mode: "disable"}, SQLitePath: "data/app.db", DefaultSchema: "main", ReadOnly: true,
	}
	prod := Definition{
		ID: "C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B", Name: "orders-prod", Engine: EngineMySQL,
		Host: "db.internal", Port: 3306, Database: "orders", User: "readonly", Password: "ask",
		SSL: SSL{Mode: "verify-full", RootCert: "certs/ca.pem"}, DefaultSchema: "orders", ReadOnly: true, Production: true,
		SSH: SSH{Destination: "deploy@bastion.example.com", Port: 2222},
	}
	columns := []Column{
		{Name: "id", DBType: "int8", Kind: "int", Nullable: ptr(false)},
		{Name: "email", DBType: "text", Kind: "text", Nullable: ptr(true)},
		{Name: "created_at", DBType: "timestamptz", Kind: "datetime"},
	}
	selectResult := StatementResult{
		Index: 0, Line: 12, StartByte: 640, EndByte: 702, Kind: "select", ResultID: "r-6f1c2a9e0b7d4e31",
		Columns: columns, RowsFetched: 500, DurationMs: 12.4, FirstRowMs: 8.1, PageEncodedMs: 0.6, Notices: []string{},
	}
	updateResult := StatementResult{
		Index: 1, Line: 14, StartByte: 704, EndByte: 748, Kind: "update", Columns: []Column{},
		RowsAffected: ptr(int64(3)), Complete: true, DurationMs: 4, FirstRowMs: 0, Notices: []string{"NOTICE: 3 rows touched"},
	}
	truncatedResult := selectResult
	truncatedResult.Truncated = true
	truncatedResult.ResultID = "r-0a9b8c7d6e5f4321"
	session := &SessionState{State: "connected", Transaction: "idle", Schema: "public", Mode: "auto"}
	errExample := func(kind string) *Error { return errorFor(kind) }
	allErrors := []*Error{}
	for _, k := range errorKinds {
		e := errExample(k)
		if k == "syntax" {
			e.Detail = `syntax error at or near "FROMM"`
			e.Code = "SQLSTATE 42601"
			e.Position = &Position{Byte: 655, Line: 12, Col: 16}
		}
		allErrors = append(allErrors, e)
	}
	fixtures := map[string]any{
		"configure-request": DataSourcesFile{Version: 1, DataSources: []Definition{def, sqliteDef, prod}},
		"configure-response": ConfigureResult{Issues: []Issue{
			{ID: "8A1B6C3D-2E4F-4A5B-8C7D-9E0F1A2B3C4D", Field: "sqlitePath", Message: "Choose the SQLite database file."},
		}},
		"configure-response-ok": ConfigureResult{Issues: []Issue{}},
		"set-secret-response":   OKResult{OK: true},
		"stats-response": Stats{Sessions: 1, Pools: 1, OpenResults: 2, SpoolMemBytes: 1048576, SpoolDiskBytes: 0, Goroutines: 41,
			Tunnels: []TunnelInfo{{DataSourceID: prod.ID, PID: 48213, LocalPort: 52811, Destination: "deploy@bastion.example.com"}}},
		"test-connection-request": TestConnectionRequest{
			Definition: def, Secret: "s3cret", WorkspaceRoot: "/Users/me/src/app",
		},
		"test-connection-response-ok":    TestConnectionResult{OK: true, ServerVersion: "PostgreSQL 17.2", LatencyMs: 3},
		"test-connection-response-error": TestConnectionResult{OK: false, Error: errExample("auth")},
		"disconnect-response":            DisconnectResult{OK: true, HadOpenTransaction: false},
		"close-console-response-refused": DisconnectResult{OK: false, HadOpenTransaction: true},
		"statements-request":             map[string]string{"text": statementsText, "dialect": EnginePostgres},
		"statements-response":            Statements(statementsText, EnginePostgres),
		"execute-request": ExecuteRequest{
			ExecID: "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F", ConsoleID: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A",
			DataSourceID: def.ID, WorkspaceRoot: "/Users/me/src/app",
			Text: "SELECT * FROM users;\nDELETE FROM orders;\n", Mode: "caret", CaretByte: 25,
			Selection: ByteRange{}, Confirmed: []Confirmation{{Hash: statementHash("DELETE FROM orders"), Risk: "deleteWithoutWhere"}},
			PageSize: 500,
		},
		"execute-response": ExecuteResponse{
			ExecID: "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F", Blocked: []Blocked{},
			Statements: []StatementResult{truncatedResult, updateResult, selectResult}, Session: session,
		},
		"execute-response-blocked": ExecuteResponse{
			ExecID: "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F",
			Blocked: []Blocked{{Index: 1, Hash: statementHash("DELETE FROM orders"),
				Risk: "deleteWithoutWhere", Table: "orders", Line: 2, Preview: "DELETE FROM orders"}},
			Statements: []StatementResult{}, Session: &SessionState{State: "notConnected", Transaction: "idle", Schema: "", Mode: "auto"},
		},
		"execute-response-needs-secret": ExecuteResponse{
			ExecID: "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F", Blocked: []Blocked{}, Statements: []StatementResult{},
			Session: &SessionState{State: "notConnected", Transaction: "idle", Schema: "", Mode: "auto"}, Error: errExample("needsSecret"),
		},
		"execute-response-statement-error": ExecuteResponse{
			ExecID: "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F", Blocked: []Blocked{},
			Statements: []StatementResult{{Index: 0, Line: 12, StartByte: 640, EndByte: 702, Kind: "select",
				Columns: []Column{}, Notices: []string{}, DurationMs: 1.2, Error: allErrors[indexOfKind("syntax")]}},
			Session: &SessionState{State: "connected", Transaction: "failed", Schema: "public", Mode: "auto"},
		},
		"event-statement-started": Event{Event: "statementStarted", ExecID: "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F",
			ConsoleID: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A", DataSource: def.ID,
			Statement: &StatementResult{Index: 0, Line: 12, StartByte: 640, EndByte: 702, Kind: "select", Columns: []Column{}, Notices: []string{}}},
		"event-statement-finished": Event{Event: "statementFinished", ExecID: "1C2D3E4F-5A6B-4C7D-8E9F-0A1B2C3D4E5F",
			ConsoleID: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A", DataSource: def.ID, Statement: &selectResult},
		"event-fetch-progress": Event{Event: "fetchProgress", ConsoleID: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A",
			DataSource: def.ID, ResultID: "r-6f1c2a9e0b7d4e31", RowsFetched: 250000},
		"event-session-state": Event{Event: "sessionState", ConsoleID: "9F8E7D6C-5B4A-4392-8170-6F5E4D3C2B1A",
			DataSource: def.ID, Session: &SessionState{State: "connected", Transaction: "active", Schema: "public", Mode: "auto"}, TransactionOpenMinutes: 15},
		"fetch-all-response":         FetchAllResult{RowsFetched: 1000000, Complete: true, SpoolDiskBytes: 48234496},
		"fetch-all-response-error":   FetchAllResult{RowsFetched: 731500, Complete: false, SpoolDiskBytes: 20971520, Error: errExample("cancelled")},
		"sort-request":               []SortKey{{Column: 3, Descending: true}, {Column: 0}},
		"sort-response":              SortResult{Version: 2, SortedRows: 1500, Complete: false},
		"cell-value-response":        CellValue{Kind: "json", Text: `{"a":1,"tags":["x","y"]}`, Encoding: "utf8", ByteCount: 24},
		"cell-value-response-binary": CellValue{Kind: "binary", Text: "89504e470d0a1a0a", Encoding: "hex", ByteCount: 70213, Truncated: true},
		"cell-value-response-null":   CellValue{IsNull: true, Kind: "text", Encoding: "utf8"},
		"introspect-request":         IntrospectRequest{DataSourceID: def.ID, Refresh: false},
		"introspect-response": IntrospectResult{DefaultSchema: "public", Schemas: []SchemaSummary{
			{Name: "public", Tables: 42, Views: 3, IntrospectedAt: "2026-11-15T17:40:00+07:00"},
			{Name: "audit", Tables: 0, Views: 0, IntrospectedAt: ""},
		}},
		"introspect-response-error": IntrospectResult{Schemas: []SchemaSummary{}, Error: errExample("connect")},
		"schema-children-request":   SchemaChildrenRequest{DataSourceID: def.ID, Path: []string{"public", "users"}},
		"schema-children-response-schemas": SchemaChildrenResult{Nodes: []Node{
			{Kind: "schema", Name: "public", Detail: "42 tables", HasChildren: true},
			{Kind: "schema", Name: "audit", Detail: "", HasChildren: true},
		}},
		"schema-children-response-tables": SchemaChildrenResult{Nodes: []Node{
			{Kind: "table", Name: "orders", Detail: "7 columns", HasChildren: true},
			{Kind: "table", Name: "users", Detail: "5 columns", HasChildren: true},
			{Kind: "view", Name: "active_users", Detail: "3 columns", HasChildren: true},
		}},
		"schema-children-response": SchemaChildrenResult{Nodes: []Node{
			{Kind: "column", Name: "id", Detail: "bigint · not null · default nextval('users_id_seq'::regclass)", HasChildren: false},
			{Kind: "column", Name: "email", Detail: "text", HasChildren: false},
			{Kind: "primaryKey", Name: "users_pkey", Detail: "id", HasChildren: false},
			{Kind: "foreignKey", Name: "users_team_id_fkey", Detail: "team_id → public.teams(id)", HasChildren: false},
			{Kind: "index", Name: "users_email_key", Detail: "unique (email)", HasChildren: false},
		}},
		"complete-request": CompleteRequest{DataSourceID: def.ID, Dialect: EnginePostgres,
			Text: "SELECT o.cu FROM orders o", CaretByte: 11},
		"complete-response": CompleteResult{ReplaceStartByte: 9, Items: []CompletionItem{
			{Label: "customer_id", Kind: "column", Detail: "orders · int8", Insert: "customer_id"},
			{Label: "currency", Kind: "column", Detail: "orders · text", Insert: "currency"},
		}},
		"complete-response-hint": CompleteResult{ReplaceStartByte: 7, Items: []CompletionItem{},
			Hint: "Connect to local to complete table and column names."},
		"errors": allErrors,
	}
	for name, v := range editingFixtures(def, columns, session) {
		fixtures[name] = v
	}
	for name, v := range goIntegrationFixtures() {
		fixtures[name] = v
	}
	return fixtures
}

const statementsText = "SELECT * FROM users;\nDELETE FROM orders;\n-- cleanup\nDROP TABLE IF EXISTS tmp_import;\nUPDATE users SET plan = 'pro' WHERE id = 7;\n"

func indexOfKind(kind string) int {
	for i, k := range errorKinds {
		if k == kind {
			return i
		}
	}
	return -1
}

type pageFixture struct {
	name     string
	firstRow int64
	flags    uint8
	version  uint32
	kinds    []uint8
	cells    [][]*string
}

func s(v string) *string { return &v }

func pageFixtures() []pageFixture {
	many := pageFixture{name: "many-columns", firstRow: 500, version: 1}
	for c := 0; c < 120; c++ {
		many.kinds = append(many.kinds, []uint8{KindInt, KindText, KindFloat, KindBool}[c%4])
	}
	for r := 0; r < 3; r++ {
		row := make([]*string, 120)
		for c := range row {
			switch c % 4 {
			case 0:
				row[c] = s(fmt.Sprint(r*1000 + c))
			case 1:
				row[c] = s(fmt.Sprintf("r%dc%d", r, c))
			case 2:
				if (r+c)%3 != 0 {
					row[c] = s(fmt.Sprintf("%d.5", c))
				}
			case 3:
				row[c] = s([]string{"true", "false"}[(r+c)%2])
			}
		}
		many.cells = append(many.cells, row)
	}
	long := strings.Repeat("abcdefghij", 60)
	wideLong := strings.Repeat("日本語テキスト", 30)
	return []pageFixture{
		{name: "basic", firstRow: 0, flags: PageFlagEnd, version: 0, kinds: []uint8{KindInt, KindText, KindDateTime, KindBool},
			cells: [][]*string{
				{s("1"), s("ada@example.com"), s("2026-11-15T10:00:00+07:00"), s("true")},
				{s("2"), s("grace@example.com"), s("2026-11-15T10:05:30.125+07:00"), s("false")},
			}},
		{name: "nulls", firstRow: 0, flags: PageFlagEnd, version: 0, kinds: []uint8{KindInt, KindText, KindDecimal, KindJSON, KindUUID},
			cells: [][]*string{
				{s("1"), nil, s("10.50"), nil, s("0b6a6d9c-1f2e-4c3b-9a8d-7e6f5a4b3c2d")},
				{nil, nil, nil, nil, nil},
				{s("3"), s(""), nil, s(`{"a":1}`), nil},
				{s("4"), s("x"), s("-0.001"), s("[]"), s("c1d2e3f4-a5b6-4c7d-8e9f-0a1b2c3d4e5f")},
				{nil, s("y"), s("1e3"), nil, nil},
				{s("6"), nil, s("0"), s("null"), nil},
				{s("7"), s("z"), nil, nil, nil},
				{s("8"), nil, s("12345678901234567890.123456789"), nil, nil},
				{s("9"), s("last"), nil, s(`{"b":[1,2]}`), nil},
			}},
		{name: "truncated", firstRow: 1000, flags: 0, version: 0, kinds: []uint8{KindText, KindBinary},
			cells: [][]*string{
				{s(long), s(string(bytes.Repeat([]byte{0xde, 0xad, 0xbe, 0xef}, 100)))},
				{s("short"), s("\x00\x01\x02")},
				{s(strings.Repeat("é", 300)), nil},
			}},
		{name: "wide-text", firstRow: 0, flags: PageFlagEnd, version: 0, kinds: []uint8{KindText, KindText},
			cells: [][]*string{
				{s("Grüße aus Saigon"), s("Tiếng Việt có dấu")},
				{s("emoji-free ✓ check"), s(wideLong)},
				{s("中文"), s("𝄞 musical symbol")},
			}},
		many,
		{name: "empty", firstRow: 0, flags: PageFlagEnd, version: 0, kinds: []uint8{KindInt, KindText}},
		{name: "sorted", firstRow: 0, flags: PageFlagEnd | PageFlagSorted, version: 3, kinds: []uint8{KindFloat, KindText},
			cells: [][]*string{
				{s("9.75"), s("c")},
				{s("2.5"), s("a")},
				{nil, s("b")},
			}},
	}
}

func (f pageFixture) encode() []byte {
	return encodePage(f.firstRow, f.flags, f.version, f.kinds, len(f.cells), func(r, c int) ([]byte, bool) {
		v := f.cells[r][c]
		if v == nil {
			return nil, true
		}
		return []byte(*v), false
	})
}

type pageSidecarColumn struct {
	Kind      string    `json:"kind"`
	Values    []*string `json:"values"`
	Truncated []bool    `json:"truncated"`
}

type pageSidecar struct {
	Magic          string              `json:"magic"`
	FormatVersion  int                 `json:"formatVersion"`
	ByteOrder      string              `json:"byteOrder"`
	BitmapBitOrder string              `json:"bitmapBitOrder"`
	Flags          uint8               `json:"flags"`
	EndOfResult    bool                `json:"endOfResult"`
	SortedView     bool                `json:"sortedView"`
	FirstRow       int64               `json:"firstRow"`
	RowCount       int                 `json:"rowCount"`
	ResultVersion  uint32              `json:"resultVersion"`
	ByteLength     int                 `json:"byteLength"`
	Columns        []pageSidecarColumn `json:"columns"`
}

func sidecarFor(b []byte) (pageSidecar, error) {
	p, err := DecodePage(b)
	if err != nil {
		return pageSidecar{}, err
	}
	sc := pageSidecar{Magic: "GLRP", FormatVersion: 1, ByteOrder: "little-endian",
		BitmapBitOrder: "row r is bit (r % 8) of byte (r / 8), least significant bit first",
		Flags:          p.Flags, EndOfResult: p.Flags&PageFlagEnd != 0, SortedView: p.Flags&PageFlagSorted != 0,
		FirstRow: p.FirstRow, RowCount: p.Rows, ResultVersion: p.Version, ByteLength: len(b), Columns: []pageSidecarColumn{}}
	for _, c := range p.Columns {
		col := pageSidecarColumn{Kind: KindName(c.Kind), Values: []*string{}, Truncated: c.Truncated}
		for r := range c.Values {
			if c.Nulls[r] {
				col.Values = append(col.Values, nil)
			} else {
				col.Values = append(col.Values, s(c.Values[r]))
			}
		}
		sc.Columns = append(sc.Columns, col)
	}
	return sc, nil
}

func marshalFixture(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func checkGolden(t *testing.T, path string, want []byte) {
	t.Helper()
	if *updateFixtures {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, want, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s is missing; run go test ./database -run Fixtures -update: %v", path, err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("%s is out of date; run go test ./database -run Fixtures -update", path)
	}
}

func TestFFIFixtures(t *testing.T) {
	fixtures := ffiFixtures()
	dir := filepath.Join("testdata", "ffi")
	for name, v := range fixtures {
		b, err := marshalFixture(v)
		if err != nil {
			t.Fatal(err)
		}
		checkGolden(t, filepath.Join(dir, name+".json"), b)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		name := strings.TrimSuffix(e.Name(), ".json")
		if _, ok := fixtures[name]; !ok && !strings.HasPrefix(name, "page-v1-") {
			t.Errorf("stale fixture %s", e.Name())
		}
	}
}

func TestRequestFixturesDecodeStrictly(t *testing.T) {
	targets := map[string]any{
		"configure-request":          &DataSourcesFile{},
		"open-table-request":         &OpenTableRequest{},
		"count-rows-request":         &CountRowsRequest{},
		"plan-edits-request":         &EditRequest{},
		"apply-edits-request":        &EditRequest{},
		"transaction-request":        &TransactionRequest{},
		"history-request":            &HistoryRequest{},
		"history-request-delete":     &HistoryRequest{},
		"execute-request-parameters": &ExecuteRequest{},
		"explain-request":            &ExplainRequest{},
		"export-request":             &ExportRequest{},
		"export-request-clipboard":   &ExportRequest{},
		"test-connection-request":    &TestConnectionRequest{},
		"execute-request":            &ExecuteRequest{},
		"sort-request":               &[]SortKey{},
		"introspect-request":         &IntrospectRequest{},
		"schema-children-request":    &SchemaChildrenRequest{},
		"complete-request":           &CompleteRequest{},
		"related-rows-request":       &RelatedRowsRequest{},
	}
	for name, target := range targets {
		b, err := os.ReadFile(filepath.Join("testdata", "ffi", name+".json"))
		if err != nil {
			t.Fatal(err)
		}
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.DisallowUnknownFields()
		if err := dec.Decode(target); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestPageFixtures(t *testing.T) {
	for _, f := range pageFixtures() {
		b := f.encode()
		checkGolden(t, filepath.Join("testdata", "ffi", "page-v1-"+f.name+".bin"), b)
		sc, err := sidecarFor(b)
		if err != nil {
			t.Fatalf("%s: %v", f.name, err)
		}
		js, err := marshalFixture(sc)
		if err != nil {
			t.Fatal(err)
		}
		checkGolden(t, filepath.Join("testdata", "ffi", "page-v1-"+f.name+".json"), js)
		for r, row := range f.cells {
			for c, v := range row {
				col := sc.Columns[c]
				if (v == nil) != (col.Values[r] == nil) {
					t.Fatalf("%s r%d c%d null mismatch", f.name, r, c)
				}
				if v != nil && !col.Truncated[r] && f.kinds[c] != KindBinary && *col.Values[r] != *v {
					t.Fatalf("%s r%d c%d = %q, want %q", f.name, r, c, *col.Values[r], *v)
				}
			}
		}
	}
}

func TestPageTruncationRules(t *testing.T) {
	var f pageFixture
	for _, p := range pageFixtures() {
		if p.name == "truncated" {
			f = p
		}
	}
	p, err := DecodePage(f.encode())
	if err != nil {
		t.Fatal(err)
	}
	text, bin := p.Columns[0], p.Columns[1]
	if !text.Truncated[0] || len(text.Values[0]) != DisplayMaxBytes {
		t.Fatalf("long ASCII text should cut at %d bytes, got %d", DisplayMaxBytes, len(text.Values[0]))
	}
	if !text.Truncated[2] || len(text.Values[2]) > DisplayMaxBytes || len(text.Values[2])%2 != 0 {
		t.Fatalf("multi-byte text must cut on a rune boundary, got %d bytes", len(text.Values[2]))
	}
	if !bin.Truncated[0] || len(bin.Values[0]) != DisplayMaxBytes || !strings.HasPrefix(bin.Values[0], "0xdeadbeef") {
		t.Fatalf("binary preview wrong: %d %q", len(bin.Values[0]), bin.Values[0][:12])
	}
	if bin.Truncated[1] || bin.Values[1] != "0x"+hex.EncodeToString([]byte{0, 1, 2}) {
		t.Fatalf("short binary preview wrong: %q", bin.Values[1])
	}
}

func FuzzPageRoundTrip(f *testing.F) {
	f.Add([]byte("hello\x00world\x01"), uint8(3), uint8(5))
	f.Add([]byte{}, uint8(1), uint8(0))
	f.Fuzz(func(t *testing.T, data []byte, ncols uint8, nrows uint8) {
		cols := int(ncols%8) + 1
		rows := int(nrows % 40)
		kinds := make([]uint8, cols)
		for c := range kinds {
			kinds[c] = uint8(c) % 10
		}
		cell := func(r, c int) ([]byte, bool) {
			i := r*cols + c
			if len(data) == 0 || data[i%len(data)]%5 == 0 {
				return nil, true
			}
			start := i % len(data)
			end := min(len(data), start+int(data[start])*3)
			return data[start:end], false
		}
		b := encodePage(int64(nrows), 1, uint32(ncols), kinds, rows, cell)
		p, err := DecodePage(b)
		if err != nil {
			t.Fatal(err)
		}
		if p.Rows != rows || len(p.Columns) != cols || p.FirstRow != int64(nrows) {
			t.Fatal("header mismatch")
		}
		for c := 0; c < cols; c++ {
			for r := 0; r < rows; r++ {
				v, null := cell(r, c)
				if p.Columns[c].Nulls[r] != null {
					t.Fatal("null mismatch")
				}
				if null || kinds[c] == KindBinary {
					continue
				}
				want, cut := displayText(kinds[c], v, nil)
				if p.Columns[c].Values[r] != string(want) || p.Columns[c].Truncated[r] != cut {
					t.Fatal("value mismatch")
				}
			}
		}
		_, _ = DecodePage(data)
	})
}
