package database

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type columnInfo struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Nullable bool   `json:"nullable"`
	Default  string `json:"default,omitempty"`
}

type keyInfo struct {
	Name    string   `json:"name"`
	Columns []string `json:"columns"`
}

type foreignKeyInfo struct {
	Name       string   `json:"name"`
	Columns    []string `json:"columns"`
	RefSchema  string   `json:"refSchema"`
	RefTable   string   `json:"refTable"`
	RefColumns []string `json:"refColumns"`
}

type indexInfo struct {
	Name    string   `json:"name"`
	Columns []string `json:"columns"`
	Unique  bool     `json:"unique"`
}

type tableInfo struct {
	Name        string           `json:"name"`
	Kind        string           `json:"kind"`
	Columns     []columnInfo     `json:"columns"`
	PrimaryKey  *keyInfo         `json:"primaryKey,omitempty"`
	ForeignKeys []foreignKeyInfo `json:"foreignKeys,omitempty"`
	Indexes     []indexInfo      `json:"indexes,omitempty"`
}

type schemaInfo struct {
	Name           string       `json:"name"`
	IntrospectedAt string       `json:"introspectedAt"`
	Tables         []*tableInfo `json:"tables"`
	Routines       []string     `json:"routines,omitempty"`
}

type snapshot struct {
	Version       int           `json:"version"`
	Identity      string        `json:"identity"`
	DefaultSchema string        `json:"defaultSchema"`
	Schemas       []*schemaInfo `json:"schemas"`
}

type introspector interface {
	schemas(ctx context.Context, c engineConn) ([]string, string, error)
	schema(ctx context.Context, c engineConn, name string) (*schemaInfo, error)
}

func introspectorFor(engine string) introspector {
	switch engine {
	case EngineMySQL:
		return mysqlIntrospector{}
	case EngineSQLite:
		return sqliteIntrospector{}
	}
	return pgIntrospector{}
}

var schemaCacheRoot string

func schemaCacheDir() string {
	if schemaCacheRoot != "" {
		return schemaCacheRoot
	}
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	return filepath.Join(base, "GoLens", "db-schema")
}

func cachePath(id string) string {
	safe := strings.Map(func(r rune) rune {
		if r == '/' || r == '\\' || r == '.' || r == 0 {
			return '_'
		}
		return r
	}, id)
	return filepath.Join(schemaCacheDir(), safe+".json")
}

func loadSnapshot(id, identity string) *snapshot {
	b, err := os.ReadFile(cachePath(id))
	if err != nil {
		return nil
	}
	var s snapshot
	if json.Unmarshal(b, &s) != nil || s.Identity != identity || s.Version != 1 {
		return nil
	}
	return &s
}

func saveSnapshot(id string, s *snapshot) {
	b, err := json.Marshal(s)
	if err != nil {
		return
	}
	dir := schemaCacheDir()
	if os.MkdirAll(dir, 0o700) != nil {
		return
	}
	tmp, err := os.CreateTemp(dir, ".snapshot-*")
	if err != nil {
		return
	}
	_, werr := tmp.Write(b)
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmp.Name(), cachePath(id)) != nil {
		_ = os.Remove(tmp.Name())
	}
}

func (s *snapshot) find(name string) *schemaInfo {
	for _, sc := range s.Schemas {
		if sc.Name == name {
			return sc
		}
	}
	return nil
}

func (ds *dataSource) cachedSnapshot() *snapshot {
	ds.mu.Lock()
	defer ds.mu.Unlock()
	if ds.snap == nil {
		ds.snap = loadSnapshot(ds.def.ID, connectionIdentity(ds.def, ds.root))
	}
	return ds.snap
}

func (ds *dataSource) refreshSnapshot(ctx context.Context, only string) (*snapshot, *Error) {
	ds.introMu.Lock()
	defer ds.introMu.Unlock()
	prev := ds.cachedSnapshot()
	def := ds.definition()
	in := introspectorFor(def.Engine)
	var next *snapshot
	e := ds.withMeta(ctx, func(c engineConn) error {
		names, dflt, err := in.schemas(ctx, c)
		if err != nil {
			return err
		}
		next = &snapshot{Version: 1, DefaultSchema: dflt}
		for _, n := range names {
			var old *schemaInfo
			if prev != nil {
				old = prev.find(n)
			}
			want := n == dflt || (only != "" && n == only) || (only == "" && old != nil && old.IntrospectedAt != "")
			if only != "" && n != only && old != nil {
				next.Schemas = append(next.Schemas, old)
				continue
			}
			if !want {
				next.Schemas = append(next.Schemas, &schemaInfo{Name: n})
				continue
			}
			sc, err := in.schema(ctx, c, n)
			if err != nil {
				return err
			}
			sc.Name = n
			sc.IntrospectedAt = time.Now().Format(time.RFC3339)
			next.Schemas = append(next.Schemas, sc)
		}
		return nil
	})
	if e != nil {
		return nil, e
	}
	ds.mu.Lock()
	next.Identity = connectionIdentity(ds.def, ds.root)
	ds.snap = next
	ds.snapStale = false
	id := ds.def.ID
	ds.mu.Unlock()
	saveSnapshot(id, next)
	return next, nil
}

func summarize(s *snapshot) IntrospectResult {
	out := IntrospectResult{Schemas: []SchemaSummary{}, DefaultSchema: s.DefaultSchema}
	for _, sc := range s.Schemas {
		sum := SchemaSummary{Name: sc.Name, IntrospectedAt: sc.IntrospectedAt}
		for _, t := range sc.Tables {
			if t.Kind == "view" {
				sum.Views++
			} else {
				sum.Tables++
			}
		}
		out.Schemas = append(out.Schemas, sum)
	}
	return out
}

func Introspect(req IntrospectRequest) IntrospectResult {
	ds := reg.source(req.DataSourceID)
	if ds == nil {
		return IntrospectResult{Schemas: []SchemaSummary{}, Error: newError("connect", "GoLens does not know this data source. Open Data Sources and save it again.")}
	}
	snap := ds.cachedSnapshot()
	ds.mu.Lock()
	stale := ds.snapStale
	ds.mu.Unlock()
	if snap == nil || req.Refresh || stale {
		var e *Error
		snap, e = ds.refreshSnapshot(context.Background(), "")
		if e != nil {
			return IntrospectResult{Schemas: []SchemaSummary{}, Error: e}
		}
	}
	return summarize(snap)
}

func SchemaChildren(req SchemaChildrenRequest) SchemaChildrenResult {
	out := SchemaChildrenResult{Nodes: []Node{}}
	ds := reg.source(req.DataSourceID)
	if ds == nil {
		out.Error = newError("connect", "GoLens does not know this data source. Open Data Sources and save it again.")
		return out
	}
	snap := ds.cachedSnapshot()
	if snap == nil {
		var e *Error
		if snap, e = ds.refreshSnapshot(context.Background(), ""); e != nil {
			out.Error = e
			return out
		}
	}
	if len(req.Path) == 0 {
		for _, sc := range snap.Schemas {
			detail := ""
			if sc.IntrospectedAt != "" {
				tables, views := 0, 0
				for _, t := range sc.Tables {
					if t.Kind == "view" {
						views++
					} else {
						tables++
					}
				}
				detail = plural(tables, "table", "tables")
				if views > 0 {
					detail += ", " + plural(views, "view", "views")
				}
			}
			out.Nodes = append(out.Nodes, Node{Kind: "schema", Name: sc.Name, Detail: detail, HasChildren: true})
		}
		return out
	}
	sc := snap.find(req.Path[0])
	if sc != nil && sc.IntrospectedAt == "" {
		var e *Error
		if snap, e = ds.refreshSnapshot(context.Background(), sc.Name); e != nil {
			out.Error = e
			return out
		}
		sc = snap.find(req.Path[0])
	}
	if sc == nil {
		return out
	}
	if len(req.Path) == 1 {
		tables := append([]*tableInfo(nil), sc.Tables...)
		sort.SliceStable(tables, func(i, j int) bool { return tables[i].Kind < tables[j].Kind })
		for _, t := range tables {
			out.Nodes = append(out.Nodes, Node{Kind: t.Kind, Name: t.Name, Detail: plural(len(t.Columns), "column", "columns"), HasChildren: true})
		}
		return out
	}
	var t *tableInfo
	for _, x := range sc.Tables {
		if x.Name == req.Path[1] {
			t = x
		}
	}
	if t == nil {
		return out
	}
	for _, c := range t.Columns {
		parts := []string{c.Type}
		if !c.Nullable {
			parts = append(parts, "not null")
		}
		if c.Default != "" {
			parts = append(parts, "default "+c.Default)
		}
		out.Nodes = append(out.Nodes, Node{Kind: "column", Name: c.Name, Detail: strings.Join(parts, " · ")})
	}
	if t.PrimaryKey != nil {
		out.Nodes = append(out.Nodes, Node{Kind: "primaryKey", Name: t.PrimaryKey.Name, Detail: strings.Join(t.PrimaryKey.Columns, ", ")})
	}
	for _, fk := range t.ForeignKeys {
		ref := fk.RefTable
		if fk.RefSchema != "" {
			ref = fk.RefSchema + "." + ref
		}
		out.Nodes = append(out.Nodes, Node{Kind: "foreignKey", Name: fk.Name,
			Detail: fmt.Sprintf("%s → %s(%s)", strings.Join(fk.Columns, ", "), ref, strings.Join(fk.RefColumns, ", "))})
	}
	for _, ix := range t.Indexes {
		d := "(" + strings.Join(ix.Columns, ", ") + ")"
		if ix.Unique {
			d = "unique " + d
		}
		out.Nodes = append(out.Nodes, Node{Kind: "index", Name: ix.Name, Detail: d})
	}
	return out
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}

func indexTables(sc *schemaInfo) map[string]*tableInfo {
	m := map[string]*tableInfo{}
	for _, t := range sc.Tables {
		m[t.Name] = t
	}
	return m
}
