package database

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"golens/core/goast"
	"golens/core/sqlc"
)

var pgPositional = regexp.MustCompile(`\$[0-9]`)

func siteDialect(sql, hint string) string {
	if hint != "" {
		return normalizeDialect(hint)
	}
	if pgPositional.MatchString(sql) {
		return EnginePostgres
	}
	return EngineSQLite
}

func SiteParams(sql, dialectHint string) []string {
	out := []string{}
	for _, p := range Parameters(sql, siteDialect(sql, dialectHint), 0, len(sql)).Parameters {
		out = append(out, p.Name)
	}
	return out
}

type GoSQLSitesResult struct {
	Sites []goast.SQLSite `json:"sites"`
}

func GoSQLSites(path, content, root string) GoSQLSitesResult {
	sites := goast.ScanSQLSites(path, content, root)
	for i := range sites {
		sites[i].Params = SiteParams(sites[i].SQL, sites[i].DialectHint)
	}
	return GoSQLSitesResult{Sites: sites}
}

type SqlcQueryResult struct {
	Name       string      `json:"name"`
	Cmd        string      `json:"cmd"`
	Line       int         `json:"line"`
	SQL        string      `json:"sql"`
	StartByte  int         `json:"startByte"`
	EndByte    int         `json:"endByte"`
	Parameters []Parameter `json:"parameters"`
	Engine     string      `json:"engine"`
	ConfigDir  string      `json:"configDir"`
	Error      *Error      `json:"error,omitempty"`
}

func sqlcEngine(name string) string {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "postgresql", "postgres":
		return EnginePostgres
	case "mysql":
		return EngineMySQL
	case "sqlite", "sqlite3":
		return EngineSQLite
	}
	return ""
}

func sqlcConfigEngine(configDir, sqlPath string) string {
	var items []sqlcItem
	for _, name := range []string{"sqlc.yaml", "sqlc.yml", "sqlc.json"} {
		if p := filepath.Join(configDir, name); fileExists(p) {
			items = parseSQLCConfig(p)
			break
		}
	}
	clean := filepath.Clean(sqlPath)
	for _, it := range items {
		for _, q := range it.queries {
			full := filepath.Clean(filepath.Join(configDir, q))
			if full == clean || strings.HasPrefix(clean, full+string(filepath.Separator)) {
				return sqlcEngine(it.engine)
			}
		}
	}
	engine := ""
	for _, it := range items {
		e := sqlcEngine(it.engine)
		if e == "" {
			continue
		}
		if engine != "" && engine != e {
			return ""
		}
		engine = e
	}
	return engine
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func SqlcQuery(sqlPath, content string, line int) SqlcQueryResult {
	q, ok := sqlc.QueryAt(content, line)
	if !ok {
		return SqlcQueryResult{Parameters: []Parameter{}, Error: newError("internal", "There is no sqlc query on this line.")}
	}
	out := SqlcQueryResult{Name: q.Name, Cmd: q.Cmd, Line: q.Line, SQL: q.SQL, StartByte: q.StartByte, EndByte: q.EndByte, Parameters: []Parameter{}}
	out.ConfigDir = sqlc.ConfigDir(sqlPath, "")
	if out.ConfigDir != "" {
		out.Engine = sqlcConfigEngine(out.ConfigDir, sqlPath)
	}
	dialect := out.Engine
	if dialect == "" {
		dialect = siteDialect(q.SQL, "")
	}
	if q.SQL != "" {
		out.Parameters = Parameters(content, dialect, q.StartByte, q.EndByte).Parameters
	}
	return out
}
