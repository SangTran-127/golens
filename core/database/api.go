package database

const (
	EnginePostgres = "postgres"
	EngineMySQL    = "mysql"
	EngineSQLite   = "sqlite"
)

type SSL struct {
	Mode     string `json:"mode"`
	RootCert string `json:"rootCert"`
	Cert     string `json:"cert"`
	Key      string `json:"key"`
}

type Definition struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	Engine        string `json:"engine"`
	Host          string `json:"host"`
	Port          int    `json:"port"`
	Database      string `json:"database"`
	User          string `json:"user"`
	Password      string `json:"password"`
	SSL           SSL    `json:"ssl"`
	SQLitePath    string `json:"sqlitePath"`
	SQLiteCreate  bool   `json:"sqliteCreate"`
	DefaultSchema string `json:"defaultSchema"`
	ReadOnly      bool   `json:"readOnly"`
	Production    bool   `json:"production"`
	TxMode        string `json:"transactionMode,omitempty"`
	SSH           SSH    `json:"ssh"`
}

type DataSourcesFile struct {
	Version     int          `json:"version"`
	DataSources []Definition `json:"dataSources"`
}

type Issue struct {
	ID      string `json:"id"`
	Field   string `json:"field"`
	Message string `json:"message"`
}

type ConfigureResult struct {
	Issues []Issue `json:"issues"`
}

type OKResult struct {
	OK bool `json:"ok"`
}

type Stats struct {
	Sessions       int          `json:"sessions"`
	Pools          int          `json:"pools"`
	OpenResults    int          `json:"openResults"`
	SpoolMemBytes  int64        `json:"spoolMemBytes"`
	SpoolDiskBytes int64        `json:"spoolDiskBytes"`
	Goroutines     int          `json:"goroutines"`
	Tunnels        []TunnelInfo `json:"tunnels"`
}

type Position struct {
	Byte int `json:"byte"`
	Line int `json:"line"`
	Col  int `json:"col"`
}

type Error struct {
	Kind     string    `json:"kind"`
	Message  string    `json:"message"`
	Detail   string    `json:"detail,omitempty"`
	Code     string    `json:"code,omitempty"`
	Position *Position `json:"position,omitempty"`
}

type TestConnectionRequest struct {
	Definition    Definition `json:"definition"`
	Secret        string     `json:"secret"`
	WorkspaceRoot string     `json:"workspaceRoot"`
}

type TestConnectionResult struct {
	OK            bool   `json:"ok"`
	ServerVersion string `json:"serverVersion"`
	LatencyMs     int64  `json:"latencyMs"`
	Error         *Error `json:"error"`
}

type DisconnectResult struct {
	OK                 bool `json:"ok"`
	HadOpenTransaction bool `json:"hadOpenTransaction"`
}

type StatementInfo struct {
	Index     int      `json:"index"`
	StartByte int      `json:"startByte"`
	EndByte   int      `json:"endByte"`
	Line      int      `json:"line"`
	Kind      string   `json:"kind"`
	Writes    bool     `json:"writes"`
	Risks     []string `json:"risks"`
}

type ByteRange struct {
	StartByte int `json:"startByte"`
	EndByte   int `json:"endByte"`
}

type Confirmation struct {
	Hash string `json:"hash"`
	Risk string `json:"risk"`
}

type ExecuteRequest struct {
	ExecID        string         `json:"execId"`
	ConsoleID     string         `json:"consoleId"`
	DataSourceID  string         `json:"dataSourceId"`
	WorkspaceRoot string         `json:"workspaceRoot"`
	Text          string         `json:"text"`
	Mode          string         `json:"mode"`
	CaretByte     int            `json:"caretByte"`
	Selection     ByteRange      `json:"selection"`
	Confirmed     []Confirmation `json:"confirmed"`
	PageSize      int            `json:"pageSize"`
	Parameters    []ParamValue   `json:"parameters,omitempty"`
	Source        string         `json:"source,omitempty"`
}

type Blocked struct {
	Index   int    `json:"index"`
	Hash    string `json:"hash"`
	Risk    string `json:"risk"`
	Table   string `json:"table"`
	Line    int    `json:"line"`
	Preview string `json:"preview"`
}

type Origin struct {
	Schema string `json:"schema"`
	Table  string `json:"table"`
	Column string `json:"column"`
}

type Column struct {
	Name     string  `json:"name"`
	DBType   string  `json:"dbType"`
	Kind     string  `json:"kind"`
	Nullable *bool   `json:"nullable"`
	Origin   *Origin `json:"origin"`
}

type StatementResult struct {
	Index         int      `json:"index"`
	Line          int      `json:"line"`
	StartByte     int      `json:"startByte"`
	EndByte       int      `json:"endByte"`
	Kind          string   `json:"kind"`
	ResultID      string   `json:"resultId"`
	Columns       []Column `json:"columns"`
	RowsFetched   int64    `json:"rowsFetched"`
	Complete      bool     `json:"complete"`
	Truncated     bool     `json:"truncated"`
	RowsAffected  *int64   `json:"rowsAffected"`
	DurationMs    float64  `json:"durationMs"`
	FirstRowMs    float64  `json:"firstRowMs"`
	PageEncodedMs float64  `json:"pageEncodedMs"`
	Notices       []string `json:"notices"`
	Error         *Error   `json:"error"`
}

type SessionState struct {
	State       string `json:"state"`
	Transaction string `json:"transaction"`
	Schema      string `json:"schema"`
	Mode        string `json:"mode"`
	Isolation   string `json:"isolation"`
}

type ExecuteResponse struct {
	ExecID     string            `json:"execId"`
	Blocked    []Blocked         `json:"blocked"`
	Statements []StatementResult `json:"statements"`
	Session    *SessionState     `json:"session"`
	Error      *Error            `json:"error"`
}

type Event struct {
	Event                  string           `json:"event"`
	ExecID                 string           `json:"execId,omitempty"`
	ConsoleID              string           `json:"consoleId,omitempty"`
	DataSource             string           `json:"dataSourceId,omitempty"`
	Statement              *StatementResult `json:"statement,omitempty"`
	ResultID               string           `json:"resultId,omitempty"`
	RowsFetched            int64            `json:"rowsFetched,omitempty"`
	Session                *SessionState    `json:"session,omitempty"`
	TransactionOpenMinutes int              `json:"transactionOpenMinutes,omitempty"`
}

type FetchAllResult struct {
	RowsFetched    int64  `json:"rowsFetched"`
	Complete       bool   `json:"complete"`
	SpoolDiskBytes int64  `json:"spoolDiskBytes"`
	Error          *Error `json:"error"`
}

type SortKey struct {
	Column     int  `json:"column"`
	Descending bool `json:"descending"`
}

type SortResult struct {
	Version    uint32 `json:"version"`
	SortedRows int64  `json:"sortedRows"`
	Complete   bool   `json:"complete"`
	Error      *Error `json:"error"`
}

type CellValue struct {
	IsNull    bool   `json:"isNull"`
	Kind      string `json:"kind"`
	Text      string `json:"text"`
	Encoding  string `json:"encoding"`
	ByteCount int64  `json:"byteCount"`
	Truncated bool   `json:"truncated"`
	Error     *Error `json:"error"`
}

type IntrospectRequest struct {
	DataSourceID string `json:"dataSourceId"`
	Refresh      bool   `json:"refresh"`
}

type SchemaSummary struct {
	Name           string `json:"name"`
	Tables         int    `json:"tables"`
	Views          int    `json:"views"`
	IntrospectedAt string `json:"introspectedAt"`
}

type IntrospectResult struct {
	Schemas       []SchemaSummary `json:"schemas"`
	DefaultSchema string          `json:"defaultSchema"`
	Error         *Error          `json:"error"`
}

type SchemaChildrenRequest struct {
	DataSourceID string   `json:"dataSourceId"`
	Path         []string `json:"path"`
}

type Node struct {
	Kind        string `json:"kind"`
	Name        string `json:"name"`
	Detail      string `json:"detail"`
	HasChildren bool   `json:"hasChildren"`
}

type SchemaChildrenResult struct {
	Nodes []Node `json:"nodes"`
	Error *Error `json:"error"`
}

type CompleteRequest struct {
	DataSourceID string `json:"dataSourceId"`
	Dialect      string `json:"dialect"`
	Text         string `json:"text"`
	CaretByte    int    `json:"caretByte"`
}

type CompletionItem struct {
	Label  string `json:"label"`
	Kind   string `json:"kind"`
	Detail string `json:"detail"`
	Insert string `json:"insert"`
}

type CompleteResult struct {
	ReplaceStartByte int              `json:"replaceStartByte"`
	Items            []CompletionItem `json:"items"`
	Hint             string           `json:"hint"`
}
