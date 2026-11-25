package database

import (
	"encoding/json"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/go-sql-driver/mysql"

	"golens/core/remote"
)

type DetectSource struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Key  string `json:"key"`
}

type Candidate struct {
	Definition Definition   `json:"definition"`
	Source     DetectSource `json:"source"`
	Kind       string       `json:"kind"`
	HasSecret  bool         `json:"hasSecret"`
	Secret     string       `json:"secret,omitempty"`
	Note       string       `json:"note,omitempty"`
}

type DetectResult struct {
	Candidates []Candidate `json:"candidates"`
}

const detectMaxEntries = 20000

var detectSkipDirs = map[string]bool{".git": true, "node_modules": true, "vendor": true, ".build": true, ".golens": true, "dist": true, "build": true}

var dsnKeyRe = regexp.MustCompile(`(?i)(DSN|DATABASE|DB|POSTGRES|PG|MYSQL|MARIADB|SQLITE)`)

func DetectDataSources(root string) DetectResult {
	out := DetectResult{Candidates: []Candidate{}}
	if root == "" {
		return out
	}
	var envFiles, sqlcFiles []string
	seen := 0
	_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if seen++; seen > detectMaxEntries {
			return fs.SkipAll
		}
		rel, _ := filepath.Rel(root, path)
		if d.IsDir() {
			if path != root && (detectSkipDirs[d.Name()] || strings.Count(rel, string(filepath.Separator)) >= 3) {
				return fs.SkipDir
			}
			return nil
		}
		name := d.Name()
		switch {
		case strings.HasPrefix(name, ".env"):
			envFiles = append(envFiles, path)
		case name == "sqlc.yaml" || name == "sqlc.yml" || name == "sqlc.json":
			sqlcFiles = append(sqlcFiles, path)
		}
		return nil
	})
	rootVars := map[string]string{}
	if vars, _ := readEnvFile(filepath.Join(root, ".env")); vars != nil {
		for _, v := range vars {
			rootVars[v.key] = v.value
		}
	}
	keys := map[string]bool{}
	add := func(c Candidate) {
		k := connectionIdentity(c.Definition, root)
		if keys[k] {
			return
		}
		keys[k] = true
		out.Candidates = append(out.Candidates, c)
	}
	for _, f := range envFiles {
		for _, c := range detectEnv(root, f) {
			add(c)
		}
	}
	if f := remote.FindComposeFile(root); f != "" {
		for _, c := range detectCompose(root, f, rootVars) {
			add(c)
		}
	}
	for _, f := range sqlcFiles {
		for _, c := range detectSQLC(root, f, rootVars) {
			add(c)
		}
	}
	return out
}

type envVar struct {
	key, value string
	line       int
}

func readEnvFile(path string) ([]envVar, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var vars []envVar
	known := map[string]string{}
	for i, raw := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		switch {
		case len(v) >= 2 && v[0] == '\'' && strings.IndexByte(v[1:], '\'') >= 0:
			v = v[1 : 1+strings.IndexByte(v[1:], '\'')]
		case len(v) >= 2 && v[0] == '"':
			if end := strings.IndexByte(v[1:], '"'); end >= 0 {
				v = strings.NewReplacer(`\n`, "\n", `\"`, `"`, `\\`, `\`).Replace(v[1 : 1+end])
			}
			v = expandVars(v, known)
		default:
			if i := strings.Index(v, " #"); i >= 0 {
				v = strings.TrimSpace(v[:i])
			}
			v = expandVars(v, known)
		}
		known[k] = v
		vars = append(vars, envVar{key: k, value: v, line: i + 1})
	}
	return vars, nil
}

var composeVarRe = regexp.MustCompile(`\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:?[-?])([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)`)

func expandVars(s string, vars map[string]string) string {
	if !strings.Contains(s, "$") {
		return s
	}
	s = strings.ReplaceAll(s, "$$", "\x00")
	s = composeVarRe.ReplaceAllStringFunc(s, func(m string) string {
		p := composeVarRe.FindStringSubmatch(m)
		name := p[1]
		if name == "" {
			name = p[4]
		}
		v, ok := vars[name]
		if (p[2] == ":-" && v == "") || (p[2] == "-" && !ok) {
			return p[3]
		}
		return v
	})
	return strings.ReplaceAll(s, "\x00", "$")
}

func relPath(root, path string) string {
	if r, err := filepath.Rel(root, path); err == nil {
		return r
	}
	return path
}

func detectEnv(root, path string) []Candidate {
	vars, err := readEnvFile(path)
	if err != nil {
		return nil
	}
	var out []Candidate
	for _, v := range vars {
		def, secret, ok := parseConnection(v.value, dsnKeyRe.MatchString(v.key))
		if !ok {
			continue
		}
		if def.Engine == EngineSQLite {
			dir := relPath(root, filepath.Dir(path))
			if !filepath.IsAbs(def.SQLitePath) && dir != "." {
				def.SQLitePath = filepath.Join(dir, def.SQLitePath)
			}
		}
		c := candidateFor(def, secret, DetectSource{File: relPath(root, path), Line: v.line, Key: v.key}, "env")
		if c.Definition.Name == "" {
			c.Definition.Name = v.key
		}
		out = append(out, c)
	}
	return out
}

func candidateFor(def Definition, secret string, src DetectSource, kind string) Candidate {
	c := Candidate{Definition: def, Source: src, Kind: kind, HasSecret: secret != "", Secret: secret}
	if def.Engine != EngineSQLite && c.Definition.Password == "" {
		if secret != "" {
			c.Definition.Password = "keychain"
		} else {
			c.Definition.Password = "ask"
		}
	}
	if def.Engine != EngineSQLite && c.Definition.SSL.Mode == "" {
		c.Definition.SSL.Mode = "prefer"
	}
	if def.Engine == EngineSQLite {
		c.Definition.Password = "none"
	}
	if c.Definition.Name == "" {
		switch {
		case def.Database != "":
			c.Definition.Name = def.Database
		case def.SQLitePath != "":
			c.Definition.Name = filepath.Base(def.SQLitePath)
		}
	}
	return c
}

var sslModes = map[string]string{"disable": "disable", "allow": "prefer", "prefer": "prefer", "require": "require", "verify-ca": "verify-ca", "verify-full": "verify-full"}

func parseConnection(raw string, dsnLike bool) (Definition, string, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" || strings.Contains(raw, "${") {
		return Definition{}, "", false
	}
	if u, err := url.Parse(raw); err == nil && u.Scheme != "" {
		switch strings.ToLower(u.Scheme) {
		case "postgres", "postgresql", "pgx":
			return urlDefinition(u, EnginePostgres, 5432)
		case "mysql", "mariadb":
			return urlDefinition(u, EngineMySQL, 3306)
		case "sqlite", "sqlite3", "file":
			p := u.Opaque
			if p == "" {
				p = u.Host + u.Path
			}
			if p == "" || p == ":memory:" {
				return Definition{}, "", false
			}
			p = strings.TrimPrefix(p, "./")
			return Definition{Engine: EngineSQLite, SQLitePath: p}, "", true
		}
	}
	if !dsnLike {
		return Definition{}, "", false
	}
	if strings.Contains(raw, "@tcp(") || strings.Contains(raw, "@unix(") {
		cfg, err := mysql.ParseDSN(raw)
		if err != nil {
			return Definition{}, "", false
		}
		host, port := cfg.Addr, 3306
		if h, p, err := net.SplitHostPort(cfg.Addr); err == nil {
			host = h
			port, _ = strconv.Atoi(p)
		}
		return Definition{Engine: EngineMySQL, Host: host, Port: port, User: cfg.User, Database: cfg.DBName, DefaultSchema: cfg.DBName}, cfg.Passwd, true
	}
	if strings.Contains(raw, "=") && (strings.Contains(raw, "host=") || strings.Contains(raw, "dbname=")) {
		kv := keywordPairs(raw)
		def := Definition{Engine: EnginePostgres, Host: kv["host"], Database: kv["dbname"], User: kv["user"], Port: 5432}
		if p, err := strconv.Atoi(kv["port"]); err == nil {
			def.Port = p
		}
		if def.Host == "" {
			def.Host = "localhost"
		}
		def.SSL.Mode = sslModes[kv["sslmode"]]
		return def, kv["password"], true
	}
	return Definition{}, "", false
}

func keywordPairs(s string) map[string]string {
	out := map[string]string{}
	i := 0
	for i < len(s) {
		for i < len(s) && s[i] == ' ' {
			i++
		}
		eq := strings.IndexByte(s[i:], '=')
		if eq < 0 {
			break
		}
		key := strings.TrimSpace(s[i : i+eq])
		i += eq + 1
		var val strings.Builder
		if i < len(s) && s[i] == '\'' {
			i++
			for i < len(s) && s[i] != '\'' {
				if s[i] == '\\' && i+1 < len(s) {
					i++
				}
				val.WriteByte(s[i])
				i++
			}
			i++
		} else {
			for i < len(s) && s[i] != ' ' {
				val.WriteByte(s[i])
				i++
			}
		}
		out[key] = val.String()
	}
	return out
}

func urlDefinition(u *url.URL, engine string, defaultPort int) (Definition, string, bool) {
	def := Definition{Engine: engine, Host: u.Hostname(), Port: defaultPort, Database: strings.TrimPrefix(u.Path, "/")}
	if def.Host == "" {
		def.Host = "localhost"
	}
	if p, err := strconv.Atoi(u.Port()); err == nil {
		def.Port = p
	}
	secret := ""
	if u.User != nil {
		def.User = u.User.Username()
		secret, _ = u.User.Password()
	}
	if engine == EnginePostgres {
		def.SSL.Mode = sslModes[u.Query().Get("sslmode")]
	} else {
		def.DefaultSchema = def.Database
	}
	return def, secret, true
}

type composeBlock struct {
	line  int
	lines []string
	first int
}

func composeServiceBlocks(text string, names []string) map[string]composeBlock {
	want := map[string]bool{}
	for _, n := range names {
		want[n] = true
	}
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	out := map[string]composeBlock{}
	in := false
	childIndent := -1
	var cur string
	var block composeBlock
	flush := func() {
		if cur != "" {
			out[cur] = block
		}
		cur = ""
	}
	for i, raw := range lines {
		t := strings.TrimSpace(raw)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		indent := len(raw) - len(strings.TrimLeft(raw, " "))
		if indent == 0 {
			flush()
			in = strings.HasPrefix(t, "services:")
			childIndent = -1
			continue
		}
		if !in {
			continue
		}
		if childIndent < 0 {
			childIndent = indent
		}
		if indent == childIndent {
			flush()
			k, _, _ := strings.Cut(t, ":")
			k = strings.Trim(strings.TrimSpace(k), `"'`)
			if want[k] {
				cur = k
				block = composeBlock{line: i + 1, first: i + 1}
			}
			continue
		}
		if cur != "" {
			block.lines = append(block.lines, raw)
		}
	}
	flush()
	return out
}

func unquote(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.Index(s, " #"); i >= 0 && !strings.HasPrefix(s, `"`) && !strings.HasPrefix(s, "'") {
		s = strings.TrimSpace(s[:i])
	}
	if len(s) >= 2 && (s[0] == '"' || s[0] == '\'') && s[len(s)-1] == s[0] {
		return s[1 : len(s)-1]
	}
	return s
}

type composeService struct {
	image string
	ports map[int]int
	env   map[string]string
}

func parseComposeService(b composeBlock, vars map[string]string) composeService {
	svc := composeService{ports: map[int]int{}, env: map[string]string{}}
	keyIndent := -1
	section := ""
	var long map[string]string
	flushLong := func() {
		if long != nil {
			target, _ := strconv.Atoi(unquote(long["target"]))
			published, err := strconv.Atoi(unquote(long["published"]))
			if target > 0 && err == nil {
				svc.ports[target] = published
			}
		}
		long = nil
	}
	for _, raw := range b.lines {
		t := strings.TrimSpace(raw)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		indent := len(raw) - len(strings.TrimLeft(raw, " "))
		if keyIndent < 0 {
			keyIndent = indent
		}
		if indent == keyIndent {
			flushLong()
			k, v, _ := strings.Cut(t, ":")
			section = strings.TrimSpace(k)
			v = strings.TrimSpace(v)
			switch section {
			case "image":
				svc.image = expandVars(unquote(v), vars)
			case "environment":
				if strings.HasPrefix(v, "{") || strings.HasPrefix(v, "[") {
					section = ""
				}
			}
			continue
		}
		switch section {
		case "ports":
			if strings.HasPrefix(t, "- ") || t == "-" {
				flushLong()
				item := strings.TrimSpace(strings.TrimPrefix(t, "-"))
				if k, v, ok := strings.Cut(item, ":"); ok && (k == "target" || k == "published") {
					long = map[string]string{k: v}
					continue
				}
				spec := expandVars(unquote(item), vars)
				spec, _, _ = strings.Cut(spec, "/")
				parts := strings.Split(spec, ":")
				target, err := strconv.Atoi(parts[len(parts)-1])
				if err != nil {
					continue
				}
				published := 0
				if len(parts) >= 2 {
					published, _ = strconv.Atoi(parts[len(parts)-2])
				}
				svc.ports[target] = published
			} else if long != nil {
				if k, v, ok := strings.Cut(t, ":"); ok {
					long[strings.TrimSpace(k)] = expandVars(strings.TrimSpace(v), vars)
				}
			}
		case "environment":
			var k, v string
			var ok bool
			if strings.HasPrefix(t, "- ") {
				k, v, ok = strings.Cut(unquote(strings.TrimPrefix(t, "- ")), "=")
			} else {
				k, v, ok = strings.Cut(t, ":")
				v = unquote(v)
			}
			if ok {
				svc.env[strings.Trim(strings.TrimSpace(k), `"'`)] = expandVars(v, vars)
			}
		}
	}
	flushLong()
	return svc
}

func imageEngine(image string) (string, string) {
	name := strings.ToLower(image)
	if i := strings.LastIndexByte(name, '/'); i >= 0 {
		name = name[i+1:]
	}
	name, _, _ = strings.Cut(name, "@")
	name, _, _ = strings.Cut(name, ":")
	switch {
	case strings.Contains(name, "postgres"), strings.Contains(name, "postgis"), strings.Contains(name, "timescaledb"):
		return EnginePostgres, "PostgreSQL"
	case strings.Contains(name, "mariadb"):
		return EngineMySQL, "MariaDB"
	case strings.Contains(name, "mysql"), strings.Contains(name, "percona"):
		return EngineMySQL, "MySQL"
	}
	return "", ""
}

func firstEnv(env map[string]string, keys ...string) (string, bool) {
	for _, k := range keys {
		if v, ok := env[k]; ok {
			return v, true
		}
	}
	return "", false
}

func detectCompose(root, path string, vars map[string]string) []Candidate {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	text := string(b)
	names := remote.ParseComposeServices(text)
	blocks := composeServiceBlocks(text, names)
	sort.SliceStable(names, func(i, j int) bool { return blocks[names[i]].line < blocks[names[j]].line })
	var out []Candidate
	for _, name := range names {
		block, ok := blocks[name]
		if !ok {
			continue
		}
		svc := parseComposeService(block, vars)
		engine, label := imageEngine(svc.image)
		if engine == "" {
			continue
		}
		def := Definition{Engine: engine, Host: "localhost", Name: name}
		container := 5432
		var secret string
		if engine == EnginePostgres {
			def.User, _ = firstEnv(svc.env, "POSTGRES_USER")
			if def.User == "" {
				def.User = "postgres"
			}
			secret, _ = firstEnv(svc.env, "POSTGRES_PASSWORD")
			def.Database, _ = firstEnv(svc.env, "POSTGRES_DB")
			if def.Database == "" {
				def.Database = def.User
			}
			if m, _ := firstEnv(svc.env, "POSTGRES_HOST_AUTH_METHOD"); m == "trust" && secret == "" {
				def.Password = "none"
			}
		} else {
			container = 3306
			user, _ := firstEnv(svc.env, "MARIADB_USER", "MYSQL_USER")
			if user != "" {
				def.User = user
				secret, _ = firstEnv(svc.env, "MARIADB_PASSWORD", "MYSQL_PASSWORD")
			} else {
				def.User = "root"
				secret, _ = firstEnv(svc.env, "MARIADB_ROOT_PASSWORD", "MYSQL_ROOT_PASSWORD")
				if _, empty := firstEnv(svc.env, "MARIADB_ALLOW_EMPTY_ROOT_PASSWORD", "MYSQL_ALLOW_EMPTY_PASSWORD"); empty && secret == "" {
					def.Password = "none"
				}
			}
			def.Database, _ = firstEnv(svc.env, "MARIADB_DATABASE", "MYSQL_DATABASE")
			def.DefaultSchema = def.Database
		}
		def.Port = container
		note := ""
		if published, ok := svc.ports[container]; ok && published > 0 {
			def.Port = published
		} else {
			note = "The " + label + " service does not publish port " + strconv.Itoa(container) + ", so GoLens may not reach it from this Mac. Publish the port in " + filepath.Base(path) + " or change the port here."
		}
		c := candidateFor(def, secret, DetectSource{File: relPath(root, path), Line: block.line, Key: name}, "compose")
		c.Note = note
		out = append(out, c)
	}
	return out
}

type sqlcItem struct {
	engine  string
	uri     string
	uriLine int
	line    int
	queries []string
}

func inlineList(v string) []string {
	v = strings.TrimSpace(v)
	if strings.HasPrefix(v, "[") && strings.HasSuffix(v, "]") {
		var out []string
		for _, part := range strings.Split(v[1:len(v)-1], ",") {
			if p := unquote(part); p != "" {
				out = append(out, p)
			}
		}
		return out
	}
	if p := unquote(v); p != "" {
		return []string{p}
	}
	return nil
}

func parseSQLCConfig(path string) []sqlcItem {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	if strings.HasSuffix(path, ".json") {
		var cfg struct {
			SQL []struct {
				Engine   string          `json:"engine"`
				Queries  json.RawMessage `json:"queries"`
				Database struct {
					URI string `json:"uri"`
				} `json:"database"`
			} `json:"sql"`
		}
		if json.Unmarshal(b, &cfg) != nil {
			return nil
		}
		text := string(b)
		var out []sqlcItem
		for _, s := range cfg.SQL {
			line := 1
			if s.Database.URI != "" {
				if i := strings.Index(text, s.Database.URI); i >= 0 {
					line = strings.Count(text[:i], "\n") + 1
				}
			}
			item := sqlcItem{engine: s.Engine, uri: s.Database.URI, uriLine: line, line: line}
			var one string
			if json.Unmarshal(s.Queries, &one) == nil && one != "" {
				item.queries = []string{one}
			} else {
				_ = json.Unmarshal(s.Queries, &item.queries)
			}
			out = append(out, item)
		}
		return out
	}
	var out []sqlcItem
	in := false
	itemIndent := -1
	queriesIndent := -1
	for i, raw := range strings.Split(strings.ReplaceAll(string(b), "\r\n", "\n"), "\n") {
		t := strings.TrimSpace(raw)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		indent := len(raw) - len(strings.TrimLeft(raw, " "))
		if queriesIndent >= 0 {
			if (indent > queriesIndent || (indent == queriesIndent && indent > itemIndent)) && strings.HasPrefix(t, "- ") && len(out) > 0 {
				item := &out[len(out)-1]
				item.queries = append(item.queries, unquote(strings.TrimPrefix(t, "- ")))
				continue
			}
			queriesIndent = -1
		}
		if indent == 0 && !strings.HasPrefix(t, "-") {
			in = strings.HasPrefix(t, "sql:")
			itemIndent = -1
			continue
		}
		if !in {
			continue
		}
		if strings.HasPrefix(t, "- ") && (itemIndent < 0 || indent == itemIndent) {
			itemIndent = indent
			out = append(out, sqlcItem{line: i + 1})
			t = strings.TrimSpace(strings.TrimPrefix(t, "- "))
		}
		if len(out) == 0 {
			continue
		}
		item := &out[len(out)-1]
		k, v, ok := strings.Cut(t, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "engine":
			if item.engine == "" {
				item.engine = unquote(v)
			}
		case "uri":
			item.uri = unquote(v)
			item.uriLine = i + 1
		case "queries":
			if strings.TrimSpace(v) == "" {
				queriesIndent = indent
				if strings.HasPrefix(strings.TrimSpace(raw), "- ") {
					queriesIndent = indent + 2
				}
			} else {
				item.queries = inlineList(v)
			}
		}
	}
	return out
}

func detectSQLC(root, path string, vars map[string]string) []Candidate {
	var out []Candidate
	for _, item := range parseSQLCConfig(path) {
		if item.uri == "" {
			continue
		}
		def, secret, ok := parseConnection(expandVars(item.uri, vars), true)
		if !ok {
			continue
		}
		switch item.engine {
		case "postgresql":
			if def.Engine != EnginePostgres {
				continue
			}
		case "mysql":
			if def.Engine != EngineMySQL {
				continue
			}
		case "sqlite":
			if def.Engine != EngineSQLite {
				continue
			}
			dir := relPath(root, filepath.Dir(path))
			if !filepath.IsAbs(def.SQLitePath) && dir != "." {
				def.SQLitePath = filepath.Join(dir, def.SQLitePath)
			}
		}
		out = append(out, candidateFor(def, secret, DetectSource{File: relPath(root, path), Line: item.uriLine, Key: "database.uri"}, "sqlc"))
	}
	return out
}
