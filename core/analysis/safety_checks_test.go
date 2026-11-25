package analysis

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPathTraversalASTDetection_PositiveNegativeAndAdversarial(t *testing.T) {
	src := `package filesrv

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type DownloadReq struct {
	Filename string
}

func UnsafeQueryServe(w http.ResponseWriter, r *http.Request) {
	p := filepath.Join("/srv/uploads", r.URL.Query().Get("file"))
	http.ServeFile(w, r, p)
}

func UnsafeParamOpen(baseDir, userPath string) ([]byte, error) {
	clean := filepath.Clean(userPath)
	full := filepath.Join(baseDir, clean)
	return os.ReadFile(full)
}

func UnsafeConcatWrite(dir string, req DownloadReq, data []byte) error {
	target := dir + "/" + req.Filename
	return os.WriteFile(target, data, 0o600)
}

func UnsafeHTTPAbsBypass(r *http.Request) ([]byte, error) {
	f := r.URL.Query().Get("path")
	if !filepath.IsAbs(f) {
		f = filepath.Join("/var/data", f)
	}
	return os.ReadFile(f)
}

func SafeLiteralAndNumeric(baseDir string, idx int) ([]byte, error) {
	a, err := os.ReadFile(filepath.Join(baseDir, "config.json"))
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(filepath.Join(baseDir, "item_"+strconv.Itoa(idx)+".json"))
	if err != nil {
		return nil, err
	}
	_ = a
	return b, os.WriteFile(filepath.Join(baseDir, fmt.Sprintf("%d_%s", idx, filepath.Base(baseDir))), nil, 0o600)
}

func SafeHasPrefixClean(baseDir, userPath string) ([]byte, error) {
	full := filepath.Join(baseDir, userPath)
	cleanBase := filepath.Clean(baseDir) + string(os.PathSeparator)
	if !strings.HasPrefix(filepath.Clean(full), cleanBase) {
		return nil, os.ErrPermission
	}
	return os.ReadFile(full)
}

func SafeRelGuard(baseDir, userPath string) error {
	full := filepath.Join(baseDir, userPath)
	rel, err := filepath.Rel(baseDir, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return os.ErrPermission
	}
	return os.Remove(full)
}

func SafeIsLocal(baseDir, userPath string) (*os.File, error) {
	if !filepath.IsLocal(userPath) {
		return nil, os.ErrPermission
	}
	return os.Open(filepath.Join(baseDir, userPath))
}

func SafeNonHTTPIsAbsFallback(workspace, filePath string) ([]byte, error) {
	data, err := os.ReadFile(filePath)
	if err != nil && workspace != "" && !filepath.IsAbs(filePath) {
		data, err = os.ReadFile(filepath.Join(workspace, filePath))
	}
	return data, err
}

func SafeExtensionAppend(target string, data []byte) error {
	return os.WriteFile(target+".tmp", data, 0o600)
}
`

	pkgDir := t.TempDir()
	path := filepath.Join(pkgDir, "filesrv.go")
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	testPath := filepath.Join(pkgDir, "filesrv_test.go")
	testSrc := `package filesrv

import (
	"os"
	"path/filepath"
	"testing"
)

func ReadTestFixture(t *testing.T, name string) []byte {
	t.Helper()
	b, _ := os.ReadFile(filepath.Join(t.TempDir(), name))
	return b
}
`
	if err := os.WriteFile(testPath, []byte(testSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	raw := RunPackageAnalyzersJSON(pkgDir, pkgDir, "")
	var out PackageAnalyzeResult
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatal(err)
	}

	var traversalLines []int
	for _, d := range out.Files[path] {
		if d.Code == CategorySecurity && strings.Contains(d.Message, "path traversal") {
			traversalLines = append(traversalLines, d.Line+1)
		}
	}
	if len(traversalLines) != 4 {
		t.Fatalf("expected exactly 4 path traversal diagnostics (lines 18, 24, 29, 37), got %v\nfull=%+v", traversalLines, out.Files[path])
	}
	wantLines := []int{18, 24, 29, 37}
	for i, want := range wantLines {
		if traversalLines[i] != want {
			t.Errorf("hit %d: got 1-based line %d, want %d", i, traversalLines[i], want)
		}
	}
	if len(out.Files[testPath]) != 0 {
		t.Fatalf("expected _test.go path helpers not flagged, got %+v", out.Files[testPath])
	}
}

func TestSQLTxLeakASTDetection_PositiveNegativeAndAdversarial(t *testing.T) {
	src := `package repo

import (
	"context"
	"database/sql"
	"errors"
)

var errBadInput = errors.New("bad input")

func LeakEarlyReturn(ctx context.Context, db *sql.DB, valid bool) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if !valid {
		return errBadInput
	}
	return tx.Commit()
}

func LeakDeferAfterEarlyReturn(db *sql.DB, ok bool) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	if !ok {
		return errBadInput
	}
	defer tx.Rollback()
	return tx.Commit()
}

func SafeDeferRollback(ctx context.Context, db *sql.DB, valid bool) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if !valid {
		return errBadInput
	}
	return tx.Commit()
}

func SafeDeferClosureRollback(db *sql.DB, valid bool) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if !valid {
		return errBadInput
	}
	return tx.Commit()
}

func SafeExplicitBranchRollbacks(db *sql.DB, a, b bool) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	if !a {
		tx.Rollback()
		return errBadInput
	}
	if !b {
		tx.Rollback()
		return errBadInput
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return nil
}

func SafeFactoryReturningTx(ctx context.Context, db *sql.DB) (*sql.Tx, error) {
	return db.BeginTx(ctx, nil)
}

func SafeAssignedFactoryReturningTx(ctx context.Context, db *sql.DB) (*sql.Tx, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	return tx, nil
}
`

	pkgDir := t.TempDir()
	path := filepath.Join(pkgDir, "repo.go")
	if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}

	raw := RunPackageAnalyzersJSON(pkgDir, pkgDir, "")
	var out PackageAnalyzeResult
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatal(err)
	}

	var txLines []int
	for _, d := range out.Files[path] {
		if d.Code == CategoryResourceSafety && strings.Contains(d.Message, "SQL transaction") {
			txLines = append(txLines, d.Line+1)
		}
	}
	if len(txLines) != 2 {
		t.Fatalf("expected exactly 2 SQL tx leak diagnostics (lines 12, 23), got %v\nfull=%+v", txLines, out.Files[path])
	}
	if txLines[0] != 12 || txLines[1] != 23 {
		t.Fatalf("expected lines [12 23], got %v", txLines)
	}
}

func TestFixSQLTransactionIssue_FixesEarlyReturnAndRefusesLoop(t *testing.T) {
	src := `package repo

import (
	"context"
	"database/sql"
	"errors"
)

func CreateOrder(ctx context.Context, db *sql.DB, ok bool) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("not ok")
	}
	return tx.Commit()
}

func CreateBatch(ctx context.Context, db *sql.DB, count int) error {
	for i := 0; i < count; i++ {
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		if i < 0 {
			return errors.New("bad")
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}
`
	lineOfNeedle := func(needle string) int {
		for idx, l := range strings.Split(src, "\n") {
			if strings.Contains(l, needle) {
				return idx + 1
			}
		}
		t.Fatalf("missing needle %q", needle)
		return 0
	}

	fixed, title, err := FixSQLTransactionIssue("repo.go", src, lineOfNeedle(`db.BeginTx(`))
	if err != nil {
		t.Fatalf("FixSQLTransactionIssue failed: %v", err)
	}
	if title != "Add defer tx.Rollback()" {
		t.Fatalf("unexpected title %q", title)
	}
	if !strings.Contains(fixed, "defer tx.Rollback()") {
		t.Fatalf("expected defer tx.Rollback() inserted:\n%s", fixed)
	}
	typeCheckFixture(t, "repo.go", fixed)

	pkgDir := t.TempDir()
	path := filepath.Join(pkgDir, "repo.go")
	onlyFixedFunc := strings.Split(fixed, "func CreateBatch")[0]
	if err := os.WriteFile(path, []byte(onlyFixedFunc), 0o644); err != nil {
		t.Fatal(err)
	}
	raw := RunPackageAnalyzersJSON(pkgDir, pkgDir, "")
	var out PackageAnalyzeResult
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatal(err)
	}
	for _, d := range out.Files[path] {
		if d.Code == CategoryResourceSafety && strings.Contains(d.Message, "SQL transaction") {
			t.Fatalf("expected 0 SQL transaction findings after fix, got %+v", d)
		}
	}

	if _, _, loopErr := FixSQLTransactionIssue("repo.go", src, lineOfNeedle(`db.Begin()`)); loopErr == nil {
		t.Fatalf("expected FixSQLTransactionIssue to refuse transaction started inside loop")
	}
}

func TestSQLTransaction_NonTerminatingElseAndElseIfNilSafe(t *testing.T) {
	lineOf := func(s, needle string) int {
		for idx, l := range strings.Split(s, "\n") {
			if strings.Contains(l, needle) {
				return idx + 1
			}
		}
		t.Fatalf("missing %q", needle)
		return 0
	}

	nonTermElse := `package txelse

import (
	"context"
	"database/sql"
	"errors"
	"log"
)

func execWithElse(ctx context.Context, db *sql.DB, fail bool) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		log.Println(err)
	} else {
		if fail {
			return errors.New("bad")
		}
		return tx.Commit()
	}
	if fail {
		return errors.New("outer bad")
	}
	return nil
}
`
	fixedElse, _, err := FixSQLTransactionIssue("txelse.go", nonTermElse, lineOf(nonTermElse, "db.BeginTx("))
	if err != nil {
		t.Fatalf("execWithElse fix: %v", err)
	}
	if strings.Contains(strings.Split(fixedElse, "if err != nil")[0], "defer tx.Rollback()") {
		t.Fatalf("bare defer tx.Rollback() must NEVER be emitted before if err != nil:\n%s", fixedElse)
	}
	if !strings.Contains(fixedElse, "} else {\n\t\tdefer tx.Rollback()") {
		t.Fatalf("expected defer tx.Rollback() inserted inside else block:\n%s", fixedElse)
	}
	typeCheckFixture(t, "txelse.go", fixedElse)

	pkgDir := t.TempDir()
	modErr := os.WriteFile(filepath.Join(pkgDir, "go.mod"), []byte("module txelse\n\ngo 1.22\n"), 0644)
	if modErr != nil {
		t.Fatal(modErr)
	}
	elsePath := filepath.Join(pkgDir, "txelse.go")
	if wErr := os.WriteFile(elsePath, []byte(fixedElse), 0644); wErr != nil {
		t.Fatal(wErr)
	}
	raw := RunPackageAnalyzersJSON(pkgDir, pkgDir, "")
	var out PackageAnalyzeResult
	if jErr := json.Unmarshal([]byte(raw), &out); jErr != nil {
		t.Fatal(jErr)
	}
	for _, d := range out.Files[elsePath] {
		if d.Code == CategoryResourceSafety && strings.Contains(d.Message, "SQL transaction") {
			t.Fatalf("expected 0 SQL_TX findings after non-terminating else fix, got %+v\n%s", d, fixedElse)
		}
	}

	elseIfSrc := `package txelseif

import (
	"context"
	"database/sql"
	"errors"
	"log"
)

func execWithElseIf(ctx context.Context, db *sql.DB, alt bool, fail bool) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		log.Println(err)
	} else if alt {
		_, _ = tx.ExecContext(ctx, "SELECT 1")
	}
	if fail {
		return errors.New("bad")
	}
	return nil
}
`
	fixedElseIf, _, err := FixSQLTransactionIssue("txelseif.go", elseIfSrc, lineOf(elseIfSrc, "db.BeginTx("))
	if err != nil {
		t.Fatalf("execWithElseIf fix: %v", err)
	}
	if strings.Contains(strings.Split(fixedElseIf, "if err != nil")[0], "defer tx.Rollback()") {
		t.Fatalf("bare defer tx.Rollback() must NEVER be emitted before if err != nil:\n%s", fixedElseIf)
	}
	if !strings.Contains(fixedElseIf, "if tx != nil {\n\t\tdefer tx.Rollback()\n\t}") {
		t.Fatalf("expected nil-guarded defer after if/else-if chain:\n%s", fixedElseIf)
	}
	typeCheckFixture(t, "txelseif.go", fixedElseIf)
	elseIfPath := filepath.Join(pkgDir, "txelseif.go")
	if wErr := os.WriteFile(elseIfPath, []byte(strings.Replace(fixedElseIf, "package txelseif", "package txelse", 1)), 0644); wErr != nil {
		t.Fatal(wErr)
	}
	raw2 := RunPackageAnalyzersJSON(pkgDir, pkgDir, "")
	var out2 PackageAnalyzeResult
	if jErr := json.Unmarshal([]byte(raw2), &out2); jErr != nil {
		t.Fatal(jErr)
	}
	for _, d := range out2.Files[elseIfPath] {
		if d.Code == CategoryResourceSafety && strings.Contains(d.Message, "SQL transaction") {
			t.Fatalf("expected 0 SQL_TX findings after else-if fix, got %+v\n%s", d, fixedElseIf)
		}
	}
}
