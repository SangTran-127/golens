package database

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var detectProject = map[string]string{
	".env": `# local services
DATABASE_URL=postgres://app:s3cret@localhost:5433/app?sslmode=disable
REDIS_URL=redis://localhost:6379
GREETING=hello
MYSQL_DSN=shop:pw@tcp(127.0.0.1:3307)/shop?parseTime=true
PG_PASS=fromdotenv
`,
	".env.local": `DB_USER=tester
export TEST_DATABASE_URL="postgres://${DB_USER}@db.internal/test"
SQLITE_URL=sqlite://./data/dev.db # dev file
WORKER_DSN="host=10.0.0.5 port=6432 user=worker password='wpw' dbname=jobs sslmode=require"
`,
	"services/api/.env.example": `DATABASE_URL=mysql://reader@localhost/catalog
`,
	"compose.yaml": `name: demo
services:
  db:
    image: postgres:17
    ports:
      - "54320:5432"
    environment:
      POSTGRES_USER: golens
      POSTGRES_PASSWORD: ${PG_PASS:-devpass}
      POSTGRES_DB: golens
  maria:
    image: docker.io/library/mariadb:11.4
    environment:
      - MARIADB_ROOT_PASSWORD=rootpw
      - MARIADB_DATABASE=shop
    ports:
      - target: 3306
        published: 33070
  hidden:
    image: mysql:8.4
    environment:
      MYSQL_ALLOW_EMPTY_PASSWORD: "yes"
  web:
    image: golang:1.27
    ports:
      - 8080:8080
`,
	"sqlc.yaml": `version: "2"
sql:
  - engine: "postgresql"
    queries: "query.sql"
    schema: "schema.sql"
    database:
      uri: postgresql://sqlc:sqlcpw@localhost:5432/sqlc
  - schema: "lite.sql"
    engine: "sqlite"
    database:
      uri: file:lite.db
  - engine: postgresql
    database:
      managed: true
`,
	"inventory/sqlc.json": `{"version": "2", "sql": [{"engine": "mysql", "queries": "q.sql",
  "database": {"uri": "mysql://root:x@localhost:3306/inv"}}]}`,
	"node_modules/pkg/.env": "DATABASE_URL=postgres://ignored@localhost/nope\n",
}

func writeProject(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for name, body := range files {
		p := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func describe(c Candidate) string {
	d := c.Definition
	where := fmt.Sprintf("%s:%d %s", c.Source.File, c.Source.Line, c.Source.Key)
	if d.Engine == EngineSQLite {
		return fmt.Sprintf("%s | %s sqlite %s password=%s", where, d.Name, d.SQLitePath, d.Password)
	}
	s := fmt.Sprintf("%s | %s %s %s:%d db=%s user=%s password=%s ssl=%s secret=%v", where, d.Name, d.Engine, d.Host, d.Port, d.Database, d.User, d.Password, d.SSL.Mode, c.HasSecret)
	if c.Note != "" {
		s += " note"
	}
	return s
}

func TestDetectDataSources(t *testing.T) {
	root := writeProject(t, detectProject)
	before := snapshotTree(t, root)
	res := DetectDataSources(root)
	var got []string
	for _, c := range res.Candidates {
		got = append(got, describe(c))
	}
	want := []string{
		".env:2 DATABASE_URL | app postgres localhost:5433 db=app user=app password=keychain ssl=disable secret=true",
		".env:5 MYSQL_DSN | shop mysql 127.0.0.1:3307 db=shop user=shop password=keychain ssl=prefer secret=true",
		".env.local:2 TEST_DATABASE_URL | test postgres db.internal:5432 db=test user=tester password=ask ssl=prefer secret=false",
		".env.local:3 SQLITE_URL | dev.db sqlite data/dev.db password=none",
		".env.local:4 WORKER_DSN | jobs postgres 10.0.0.5:6432 db=jobs user=worker password=keychain ssl=require secret=true",
		"services/api/.env.example:1 DATABASE_URL | catalog mysql localhost:3306 db=catalog user=reader password=ask ssl=prefer secret=false",
		"compose.yaml:3 db | db postgres localhost:54320 db=golens user=golens password=keychain ssl=prefer secret=true",
		"compose.yaml:11 maria | maria mysql localhost:33070 db=shop user=root password=keychain ssl=prefer secret=true",
		"compose.yaml:19 hidden | hidden mysql localhost:3306 db= user=root password=none ssl=prefer secret=false note",
		"inventory/sqlc.json:2 database.uri | inv mysql localhost:3306 db=inv user=root password=keychain ssl=prefer secret=true",
		"sqlc.yaml:7 database.uri | sqlc postgres localhost:5432 db=sqlc user=sqlc password=keychain ssl=prefer secret=true",
		"sqlc.yaml:11 database.uri | lite.db sqlite lite.db password=none",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("got:\n%s\n\nwant:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	secrets := map[string]string{}
	for _, c := range res.Candidates {
		secrets[c.Source.File+":"+c.Source.Key] = c.Secret
	}
	if secrets["compose.yaml:db"] != "fromdotenv" || secrets[".env.local:WORKER_DSN"] != "wpw" || secrets[".env:DATABASE_URL"] != "s3cret" {
		t.Fatalf("%v", secrets)
	}
	for _, c := range res.Candidates {
		if c.Definition.ID != "" {
			t.Fatal("candidates are proposals; Swift assigns identifiers")
		}
		if issues := validate([]Definition{func() Definition { d := c.Definition; d.ID = "x"; return d }()}); len(issues) > 0 && c.Note == "" && c.Definition.User != "" {
			t.Errorf("%s: %+v", describe(c), issues)
		}
	}
	if after := snapshotTree(t, root); after != before {
		t.Fatal("detection must not write anything")
	}
	if GetStats().Sessions != 0 {
		t.Fatal("detection must not connect")
	}
	if empty := DetectDataSources(t.TempDir()); len(empty.Candidates) != 0 {
		t.Fatal(empty)
	}
}

func snapshotTree(t *testing.T, root string) string {
	t.Helper()
	var b strings.Builder
	_ = filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err == nil {
			fmt.Fprintf(&b, "%s %d %v\n", p, info.Size(), info.ModTime().UnixNano())
		}
		return nil
	})
	return b.String()
}

func TestParseConnectionForms(t *testing.T) {
	cases := []struct {
		raw     string
		dsnLike bool
		want    string
	}{
		{"postgresql://u:p%40ss@[::1]:6543/db?sslmode=verify-full", false, "postgres ::1 6543 db u p@ss verify-full"},
		{"mariadb://root@maria/shop", false, "mysql maria 3306 shop root  "},
		{"sqlite3:///abs/app.db", false, "sqlite /abs/app.db"},
		{"file:local.db?cache=shared", false, "sqlite local.db"},
		{"sqlite://:memory:", false, ""},
		{"https://example.com/db", false, ""},
		{"host=localhost dbname=x", false, ""},
		{"host=localhost dbname=x", true, "postgres localhost 5432 x   "},
		{"u:p@unix(/tmp/mysql.sock)/db", true, "mysql /tmp/mysql.sock 3306 db u p "},
		{"postgres://${USER}@localhost/db", false, ""},
	}
	for _, c := range cases {
		def, secret, ok := parseConnection(c.raw, c.dsnLike)
		got := ""
		if ok {
			if def.Engine == EngineSQLite {
				got = "sqlite " + def.SQLitePath
			} else {
				got = fmt.Sprintf("%s %s %d %s %s %s %s", def.Engine, def.Host, def.Port, def.Database, def.User, secret, def.SSL.Mode)
			}
		}
		if got != c.want {
			t.Errorf("%q: got %q want %q", c.raw, got, c.want)
		}
	}
}
