package goast

import (
	"go/ast"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
)

type SQLPart struct {
	StartByte int `json:"startByte"`
	EndByte   int `json:"endByte"`
}

type SQLSite struct {
	Line        int       `json:"line"`
	StartByte   int       `json:"startByte"`
	EndByte     int       `json:"endByte"`
	SQL         string    `json:"sql"`
	DialectHint string    `json:"dialectHint"`
	API         string    `json:"api"`
	Parts       []SQLPart `json:"parts"`
	Params      []string  `json:"params"`
}

const (
	SQLAPIDatabaseSQL = "database/sql"
	SQLAPIPgx         = "pgx"
	SQLAPISqlx        = "sqlx"
	SQLAPIMarker      = "marker"
)

const (
	maxSiblingFiles = 200
	maxSiblingBytes = 4 << 20
)

var (
	sqlSitePrefilter = regexp.MustCompile(`\.(Query|QueryRow|Exec|Prepare|Queue|Select|Get|Named|MustExec|Preparex)\w*\(|language\s*=`)
	languageMarker   = regexp.MustCompile(`^(?://|/\*)\s*language\s*=\s*([A-Za-z0-9_]+)`)
)

var sqlMethodNames = map[string]bool{
	"Query": true, "QueryRow": true, "Exec": true, "Prepare": true,
	"QueryContext": true, "QueryRowContext": true, "ExecContext": true, "PrepareContext": true,
	"Queue":  true,
	"Select": true, "Get": true, "SelectContext": true, "GetContext": true,
	"NamedExec": true, "NamedQuery": true, "NamedExecContext": true, "NamedQueryContext": true,
	"Queryx": true, "QueryRowx": true, "QueryxContext": true, "QueryRowxContext": true,
	"MustExec": true, "MustExecContext": true, "Preparex": true, "PreparexContext": true,
}

var markerDialects = map[string]string{
	"sql":           "",
	"genericsql":    "",
	"postgresql":    "postgres",
	"postgres":      "postgres",
	"postgresplsql": "postgres",
	"mysql":         "mysql",
	"mariadb":       "mysql",
	"sqlite":        "sqlite",
}

func sqlAPIForPackage(path string) string {
	switch {
	case path == "database/sql":
		return SQLAPIDatabaseSQL
	case path == "github.com/jmoiron/sqlx":
		return SQLAPISqlx
	case strings.HasPrefix(path, "github.com/jackc/pgx/"), path == "github.com/jackc/pgconn":
		return SQLAPIPgx
	}
	return ""
}

var sqlStubTemplates = map[string]string{
	"context": `package context
type Context interface{}
`,
	"database/sql": `package sql
import "context"
type Result interface {
	LastInsertId() (int64, error)
	RowsAffected() (int64, error)
}
type Rows struct{}
type Row struct{}
type Stmt struct{}
type TxOptions struct{}
type DB struct{}
type Tx struct{}
type Conn struct{}
func Open(driverName, dataSourceName string) (*DB, error)
func OpenDB(c any) *DB
func (*DB) Query(query string, args ...any) (*Rows, error)
func (*DB) QueryContext(ctx context.Context, query string, args ...any) (*Rows, error)
func (*DB) QueryRow(query string, args ...any) *Row
func (*DB) QueryRowContext(ctx context.Context, query string, args ...any) *Row
func (*DB) Exec(query string, args ...any) (Result, error)
func (*DB) ExecContext(ctx context.Context, query string, args ...any) (Result, error)
func (*DB) Prepare(query string) (*Stmt, error)
func (*DB) PrepareContext(ctx context.Context, query string) (*Stmt, error)
func (*DB) Begin() (*Tx, error)
func (*DB) BeginTx(ctx context.Context, opts *TxOptions) (*Tx, error)
func (*DB) Conn(ctx context.Context) (*Conn, error)
func (*Tx) Query(query string, args ...any) (*Rows, error)
func (*Tx) QueryContext(ctx context.Context, query string, args ...any) (*Rows, error)
func (*Tx) QueryRow(query string, args ...any) *Row
func (*Tx) QueryRowContext(ctx context.Context, query string, args ...any) *Row
func (*Tx) Exec(query string, args ...any) (Result, error)
func (*Tx) ExecContext(ctx context.Context, query string, args ...any) (Result, error)
func (*Tx) Prepare(query string) (*Stmt, error)
func (*Tx) PrepareContext(ctx context.Context, query string) (*Stmt, error)
func (*Tx) Commit() error
func (*Tx) Rollback() error
func (*Conn) QueryContext(ctx context.Context, query string, args ...any) (*Rows, error)
func (*Conn) QueryRowContext(ctx context.Context, query string, args ...any) *Row
func (*Conn) ExecContext(ctx context.Context, query string, args ...any) (Result, error)
func (*Conn) PrepareContext(ctx context.Context, query string) (*Stmt, error)
func (*Conn) BeginTx(ctx context.Context, opts *TxOptions) (*Tx, error)
`,
	"github.com/jmoiron/sqlx": `package sqlx
import (
	"context"
	"database/sql"
)
type DB struct{ *sql.DB }
type Tx struct{ *sql.Tx }
type Conn struct{ *sql.Conn }
type Rows struct{ *sql.Rows }
type Row struct{}
type Stmt struct{}
type NamedStmt struct{}
type Queryer interface{}
type QueryerContext interface{}
type Ext interface{}
type ExtContext interface{}
func Open(driverName, dataSourceName string) (*DB, error)
func Connect(driverName, dataSourceName string) (*DB, error)
func ConnectContext(ctx context.Context, driverName, dataSourceName string) (*DB, error)
func MustConnect(driverName, dataSourceName string) *DB
func MustOpen(driverName, dataSourceName string) *DB
func NewDb(db *sql.DB, driverName string) *DB
func Select(q Queryer, dest any, query string, args ...any) error
func Get(q Queryer, dest any, query string, args ...any) error
func SelectContext(ctx context.Context, q QueryerContext, dest any, query string, args ...any) error
func GetContext(ctx context.Context, q QueryerContext, dest any, query string, args ...any) error
func NamedExec(e Ext, query string, arg any) (sql.Result, error)
func NamedExecContext(ctx context.Context, e ExtContext, query string, arg any) (sql.Result, error)
func (*DB) Select(dest any, query string, args ...any) error
func (*DB) Get(dest any, query string, args ...any) error
func (*DB) SelectContext(ctx context.Context, dest any, query string, args ...any) error
func (*DB) GetContext(ctx context.Context, dest any, query string, args ...any) error
func (*DB) NamedExec(query string, arg any) (sql.Result, error)
func (*DB) NamedExecContext(ctx context.Context, query string, arg any) (sql.Result, error)
func (*DB) NamedQuery(query string, arg any) (*Rows, error)
func (*DB) NamedQueryContext(ctx context.Context, query string, arg any) (*Rows, error)
func (*DB) Queryx(query string, args ...any) (*Rows, error)
func (*DB) QueryxContext(ctx context.Context, query string, args ...any) (*Rows, error)
func (*DB) QueryRowx(query string, args ...any) *Row
func (*DB) QueryRowxContext(ctx context.Context, query string, args ...any) *Row
func (*DB) MustExec(query string, args ...any) sql.Result
func (*DB) MustExecContext(ctx context.Context, query string, args ...any) sql.Result
func (*DB) Preparex(query string) (*Stmt, error)
func (*DB) PreparexContext(ctx context.Context, query string) (*Stmt, error)
func (*DB) PrepareNamed(query string) (*NamedStmt, error)
func (*DB) Beginx() (*Tx, error)
func (*DB) BeginTxx(ctx context.Context, opts *sql.TxOptions) (*Tx, error)
func (*DB) MustBegin() *Tx
func (*DB) Connx(ctx context.Context) (*Conn, error)
func (*Tx) Select(dest any, query string, args ...any) error
func (*Tx) Get(dest any, query string, args ...any) error
func (*Tx) SelectContext(ctx context.Context, dest any, query string, args ...any) error
func (*Tx) GetContext(ctx context.Context, dest any, query string, args ...any) error
func (*Tx) NamedExec(query string, arg any) (sql.Result, error)
func (*Tx) NamedExecContext(ctx context.Context, query string, arg any) (sql.Result, error)
func (*Tx) NamedQuery(query string, arg any) (*Rows, error)
func (*Tx) Queryx(query string, args ...any) (*Rows, error)
func (*Tx) QueryxContext(ctx context.Context, query string, args ...any) (*Rows, error)
func (*Tx) QueryRowx(query string, args ...any) *Row
func (*Tx) QueryRowxContext(ctx context.Context, query string, args ...any) *Row
func (*Tx) MustExec(query string, args ...any) sql.Result
func (*Tx) MustExecContext(ctx context.Context, query string, args ...any) sql.Result
func (*Tx) Preparex(query string) (*Stmt, error)
func (*Conn) SelectContext(ctx context.Context, dest any, query string, args ...any) error
func (*Conn) GetContext(ctx context.Context, dest any, query string, args ...any) error
func (*Conn) QueryxContext(ctx context.Context, query string, args ...any) (*Rows, error)
func (*Conn) QueryRowxContext(ctx context.Context, query string, args ...any) *Row
`,
	"PGCONN": `package pgconn
type CommandTag struct{}
type StatementDescription struct{}
`,
	"PGX": `package pgx
import (
	"context"
	"PGCONN"
)
type Rows interface {
	Close()
	Err() error
	Next() bool
	Scan(dest ...any) error
}
type Row interface {
	Scan(dest ...any) error
}
type BatchResults interface{}
type TxOptions struct{}
type ConnConfig struct{}
type QueuedQuery struct{}
type Batch struct{}
type Tx interface {
	Begin(ctx context.Context) (Tx, error)
	Commit(ctx context.Context) error
	Rollback(ctx context.Context) error
	SendBatch(ctx context.Context, b *Batch) BatchResults
	Exec(ctx context.Context, query string, arguments ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, query string, args ...any) (Rows, error)
	QueryRow(ctx context.Context, query string, args ...any) Row
	Conn() *Conn
}
type Conn struct{}
func Connect(ctx context.Context, connString string) (*Conn, error)
func ConnectConfig(ctx context.Context, cfg *ConnConfig) (*Conn, error)
func (*Conn) Exec(ctx context.Context, query string, arguments ...any) (pgconn.CommandTag, error)
func (*Conn) Query(ctx context.Context, query string, args ...any) (Rows, error)
func (*Conn) QueryRow(ctx context.Context, query string, args ...any) Row
func (*Conn) Begin(ctx context.Context) (Tx, error)
func (*Conn) BeginTx(ctx context.Context, opts TxOptions) (Tx, error)
func (*Conn) SendBatch(ctx context.Context, b *Batch) BatchResults
func (*Conn) Close(ctx context.Context) error
func (*Batch) Queue(query string, arguments ...any) *QueuedQuery
`,
	"PGXPOOL": `package pgxpool
import (
	"context"
	"PGX"
	"PGCONN"
)
type Config struct{}
type Pool struct{}
type Conn struct{}
type Tx struct{}
func New(ctx context.Context, connString string) (*Pool, error)
func NewWithConfig(ctx context.Context, config *Config) (*Pool, error)
func Connect(ctx context.Context, connString string) (*Pool, error)
func ConnectConfig(ctx context.Context, config *Config) (*Pool, error)
func (*Pool) Exec(ctx context.Context, query string, arguments ...any) (pgconn.CommandTag, error)
func (*Pool) Query(ctx context.Context, query string, args ...any) (pgx.Rows, error)
func (*Pool) QueryRow(ctx context.Context, query string, args ...any) pgx.Row
func (*Pool) Begin(ctx context.Context) (pgx.Tx, error)
func (*Pool) BeginTx(ctx context.Context, opts pgx.TxOptions) (pgx.Tx, error)
func (*Pool) Acquire(ctx context.Context) (*Conn, error)
func (*Pool) SendBatch(ctx context.Context, b *pgx.Batch) pgx.BatchResults
func (*Pool) Close()
func (*Conn) Exec(ctx context.Context, query string, arguments ...any) (pgconn.CommandTag, error)
func (*Conn) Query(ctx context.Context, query string, args ...any) (pgx.Rows, error)
func (*Conn) QueryRow(ctx context.Context, query string, args ...any) pgx.Row
func (*Conn) Begin(ctx context.Context) (pgx.Tx, error)
func (*Conn) Release()
func (*Tx) Exec(ctx context.Context, query string, arguments ...any) (pgconn.CommandTag, error)
func (*Tx) Query(ctx context.Context, query string, args ...any) (pgx.Rows, error)
func (*Tx) QueryRow(ctx context.Context, query string, args ...any) pgx.Row
func (*Tx) Commit(ctx context.Context) error
func (*Tx) Rollback(ctx context.Context) error
`,
}

type pgxLayout struct{ pgx, pgxpool, pgconn string }

var pgxLayouts = []pgxLayout{
	{"github.com/jackc/pgx/v5", "github.com/jackc/pgx/v5/pgxpool", "github.com/jackc/pgx/v5/pgconn"},
	{"github.com/jackc/pgx/v4", "github.com/jackc/pgx/v4/pgxpool", "github.com/jackc/pgconn"},
}

var (
	stubOnce     sync.Once
	stubPackages map[string]*types.Package
)

func stubSource(path string) (string, bool) {
	if src, ok := sqlStubTemplates[path]; ok {
		return src, true
	}
	for _, l := range pgxLayouts {
		var tmpl string
		switch path {
		case l.pgx:
			tmpl = sqlStubTemplates["PGX"]
		case l.pgxpool:
			tmpl = sqlStubTemplates["PGXPOOL"]
		case l.pgconn:
			tmpl = sqlStubTemplates["PGCONN"]
		default:
			continue
		}
		r := strings.NewReplacer(`"PGX"`, strconv.Quote(l.pgx), `"PGCONN"`, strconv.Quote(l.pgconn))
		return r.Replace(tmpl), true
	}
	return "", false
}

type stubImporter struct {
	done map[string]*types.Package
}

func (s *stubImporter) Import(path string) (*types.Package, error) {
	if p, ok := s.done[path]; ok {
		return p, nil
	}
	src, ok := stubSource(path)
	if !ok {
		return fakePackage(path), nil
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path+".go", src, parser.SkipObjectResolution)
	if err != nil {
		return fakePackage(path), nil
	}
	conf := types.Config{Importer: s, Error: func(error) {}}
	p, _ := conf.Check(path, fset, []*ast.File{f}, nil)
	if p == nil {
		p = fakePackage(path)
	}
	s.done[path] = p
	return p, nil
}

func loadStubs() map[string]*types.Package {
	stubOnce.Do(func() {
		imp := &stubImporter{done: map[string]*types.Package{}}
		paths := []string{"context", "database/sql", "github.com/jmoiron/sqlx"}
		for _, l := range pgxLayouts {
			paths = append(paths, l.pgconn, l.pgx, l.pgxpool)
		}
		for _, p := range paths {
			_, _ = imp.Import(p)
		}
		stubPackages = imp.done
	})
	return stubPackages
}

func packageNameGuess(path string) string {
	parts := strings.Split(path, "/")
	name := parts[len(parts)-1]
	if len(parts) > 1 && len(name) > 1 && name[0] == 'v' && strings.Trim(name[1:], "0123456789") == "" {
		name = parts[len(parts)-2]
	}
	if i := strings.IndexByte(name, '.'); i > 0 {
		name = name[:i]
	}
	name = strings.TrimPrefix(name, "go-")
	name = strings.Map(func(r rune) rune {
		if r == '-' {
			return '_'
		}
		return r
	}, name)
	return name
}

func fakePackage(path string) *types.Package {
	p := types.NewPackage(path, packageNameGuess(path))
	p.MarkComplete()
	return p
}

type scanImporter struct {
	stubs map[string]*types.Package
	fakes map[string]*types.Package
}

func (s *scanImporter) Import(path string) (*types.Package, error) {
	if p, ok := s.stubs[path]; ok {
		return p, nil
	}
	if p, ok := s.fakes[path]; ok {
		return p, nil
	}
	p := fakePackage(path)
	s.fakes[path] = p
	return p, nil
}

func within(path, root string) bool {
	if root == "" {
		return false
	}
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func siblingFiles(fset *token.FileSet, path, root, pkgName string) []*ast.File {
	if path == "" || !within(path, root) {
		return nil
	}
	dir := filepath.Dir(path)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []*ast.File
	total := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || filepath.Join(dir, name) == path {
			continue
		}
		if len(out) >= maxSiblingFiles || total > maxSiblingBytes {
			break
		}
		src, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		total += len(src)
		f, _ := parser.ParseFile(fset, filepath.Join(dir, name), src, parser.SkipObjectResolution)
		if f == nil || f.Name == nil || f.Name.Name != pkgName {
			continue
		}
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok {
				fd.Body = nil
			}
		}
		out = append(out, f)
	}
	return out
}

type stringExpr struct {
	expr  ast.Expr
	parts []*ast.BasicLit
}

func literalParts(e ast.Expr) []*ast.BasicLit {
	switch x := e.(type) {
	case *ast.ParenExpr:
		return literalParts(x.X)
	case *ast.BasicLit:
		if x.Kind == token.STRING {
			return []*ast.BasicLit{x}
		}
	case *ast.BinaryExpr:
		if x.Op != token.ADD {
			return nil
		}
		l := literalParts(x.X)
		if l == nil {
			return nil
		}
		r := literalParts(x.Y)
		if r == nil {
			return nil
		}
		return append(l, r...)
	}
	return nil
}

func importsSQLPackage(files []*ast.File) bool {
	for _, f := range files {
		for _, imp := range f.Imports {
			p, err := strconv.Unquote(imp.Path.Value)
			if err == nil && sqlAPIForPackage(p) != "" {
				return true
			}
		}
	}
	return false
}

func namedFromSQLPackage(t types.Type) string {
	for {
		switch x := t.(type) {
		case *types.Pointer:
			t = x.Elem()
			continue
		case *types.Named:
			if x.Obj().Pkg() != nil {
				return sqlAPIForPackage(x.Obj().Pkg().Path())
			}
		}
		return ""
	}
}

func queryParamIndex(sig *types.Signature) int {
	params := sig.Params()
	first := -1
	for i := 0; i < params.Len(); i++ {
		v := params.At(i)
		if sig.Variadic() && i == params.Len()-1 {
			break
		}
		b, ok := v.Type().Underlying().(*types.Basic)
		if !ok || b.Kind() != types.String {
			continue
		}
		if v.Name() == "query" || v.Name() == "sql" {
			return i
		}
		if first < 0 {
			first = i
		}
	}
	return first
}

func resolveCall(call *ast.CallExpr, info *types.Info, fallback bool) (api string, index int, ok bool) {
	sel, isSel := call.Fun.(*ast.SelectorExpr)
	if !isSel || !sqlMethodNames[sel.Sel.Name] {
		return "", 0, false
	}
	var fn *types.Func
	if s := info.Selections[sel]; s != nil {
		fn, _ = s.Obj().(*types.Func)
	} else if obj, found := info.Uses[sel.Sel]; found {
		fn, _ = obj.(*types.Func)
	}
	if fn == nil {
		if !fallback {
			return "", 0, false
		}
		tv, known := info.Types[sel.X]
		if known && tv.Type != nil && tv.Type != types.Typ[types.Invalid] {
			return "", 0, false
		}
		return SQLAPIDatabaseSQL, fallbackQueryIndex(sel.Sel.Name), true
	}
	sig, isSig := fn.Type().(*types.Signature)
	if !isSig {
		return "", 0, false
	}
	if fn.Pkg() != nil {
		api = sqlAPIForPackage(fn.Pkg().Path())
	}
	if api == "" && sig.Recv() != nil {
		res := sig.Results()
		for i := 0; i < res.Len() && api == ""; i++ {
			api = namedFromSQLPackage(res.At(i).Type())
		}
	}
	if api == "" {
		return "", 0, false
	}
	idx := queryParamIndex(sig)
	if idx < 0 {
		return "", 0, false
	}
	return api, idx, true
}

func fallbackQueryIndex(name string) int {
	base := strings.TrimSuffix(name, "Context")
	idx := 0
	if base != name {
		idx = 1
	}
	if base == "Select" || base == "Get" {
		idx++
	}
	return idx
}

func ScanSQLSites(path, content, root string) []SQLSite {
	out := []SQLSite{}
	if !sqlSitePrefilter.MatchString(content) {
		return out
	}
	fset := token.NewFileSet()
	f, _ := parser.ParseFile(fset, path, content, parser.ParseComments|parser.SkipObjectResolution)
	if f == nil || f.Name == nil {
		return out
	}
	files := append([]*ast.File{f}, siblingFiles(fset, path, root, f.Name.Name)...)
	info := &types.Info{
		Types:      map[ast.Expr]types.TypeAndValue{},
		Uses:       map[*ast.Ident]types.Object{},
		Selections: map[*ast.SelectorExpr]*types.Selection{},
	}
	conf := types.Config{
		Importer:                 &scanImporter{stubs: loadStubs(), fakes: map[string]*types.Package{}},
		Error:                    func(error) {},
		DisableUnusedImportCheck: true,
	}
	_, _ = conf.Check(f.Name.Name, fset, files, info)
	fallback := importsSQLPackage([]*ast.File{f})
	tf := fset.File(f.Pos())
	if tf == nil {
		return out
	}
	offset := func(p token.Pos) int { return tf.Offset(p) }

	byStart := map[int]*SQLSite{}
	var literals []stringExpr
	ast.Inspect(f, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.CallExpr:
			api, idx, ok := resolveCall(x, info, fallback)
			if !ok || idx >= len(x.Args) {
				return true
			}
			arg := x.Args[idx]
			parts := literalParts(arg)
			if parts == nil {
				return true
			}
			site := buildSite(fset, offset, arg, parts)
			site.API = api
			if api == SQLAPIPgx {
				site.DialectHint = "postgres"
			}
			byStart[site.StartByte] = &site
		case *ast.BinaryExpr, *ast.BasicLit, *ast.ParenExpr:
			if e, isExpr := x.(ast.Expr); isExpr {
				if parts := literalParts(e); parts != nil {
					literals = append(literals, stringExpr{expr: e, parts: parts})
					if _, isLit := x.(*ast.BasicLit); !isLit {
						return false
					}
				}
			}
		}
		return true
	})
	sort.Slice(literals, func(i, j int) bool { return literals[i].expr.Pos() < literals[j].expr.Pos() })
	for _, cg := range f.Comments {
		for _, c := range cg.List {
			m := languageMarker.FindStringSubmatch(c.Text)
			if m == nil {
				continue
			}
			dialect, known := markerDialects[strings.ToLower(m[1])]
			if !known {
				continue
			}
			endLine := fset.Position(c.End()).Line
			i := sort.Search(len(literals), func(i int) bool { return literals[i].expr.Pos() >= c.End() })
			if i >= len(literals) {
				continue
			}
			lit := literals[i]
			if fset.Position(lit.expr.Pos()).Line > endLine+1 {
				continue
			}
			start := offset(lit.expr.Pos())
			if existing := byStart[start]; existing != nil {
				if dialect != "" {
					existing.DialectHint = dialect
				}
				continue
			}
			site := buildSite(fset, offset, lit.expr, lit.parts)
			site.API = SQLAPIMarker
			site.DialectHint = dialect
			byStart[site.StartByte] = &site
		}
	}
	for _, s := range byStart {
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].StartByte < out[j].StartByte })
	return out
}

func buildSite(fset *token.FileSet, offset func(token.Pos) int, e ast.Expr, parts []*ast.BasicLit) SQLSite {
	site := SQLSite{
		Line:      fset.Position(e.Pos()).Line,
		StartByte: offset(e.Pos()),
		EndByte:   offset(e.End()),
		Parts:     make([]SQLPart, 0, len(parts)),
		Params:    []string{},
	}
	var b strings.Builder
	for _, p := range parts {
		start := offset(p.Pos())
		site.Parts = append(site.Parts, SQLPart{StartByte: start + 1, EndByte: start + len(p.Value) - 1})
		if v, err := strconv.Unquote(p.Value); err == nil {
			b.WriteString(v)
		}
	}
	site.SQL = b.String()
	return site
}
