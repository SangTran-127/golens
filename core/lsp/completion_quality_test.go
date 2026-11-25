package lsp

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

type qualityCase struct {
	name   string
	file   string
	src    string
	caret  int
	want   []string
	forbid []string
	insert string
	after  string
	not    string
	commit string
	none   bool
}

const qualityModule = `module example.com/app

go 1.22

require example.com/dep v0.0.0

replace example.com/dep => ../dep
`

func splitList(v string) []string {
	var out []string
	for _, p := range strings.Split(v, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func loadQualityCases(t *testing.T) []qualityCase {
	files, err := filepath.Glob(filepath.Join("testdata", "completion", "*.txt"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no completion corpus: %v", err)
	}
	sort.Strings(files)
	var cases []qualityCase
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		head, src, ok := strings.Cut(string(data), "-- src --\n")
		if !ok {
			t.Fatalf("%s: missing -- src -- separator", f)
		}
		c := qualityCase{file: "case.go"}
		for _, line := range strings.Split(head, "\n") {
			k, v, ok := strings.Cut(line, ": ")
			if !ok {
				continue
			}
			switch k {
			case "name":
				c.name = v
			case "file":
				c.file = v
			case "want":
				c.want = splitList(v)
			case "forbid":
				c.forbid = splitList(v)
			case "insert":
				c.insert = strings.TrimSuffix(v, "|")
			case "expect":
				c.none = v == "none"
			case "after":
				c.after = strings.ReplaceAll(strings.TrimSuffix(v, "|"), `\n`, "\n")
			case "notafter":
				c.not = strings.TrimSuffix(v, "|")
			case "commit":
				c.commit = v
			}
		}
		c.caret = strings.IndexByte(src, '|')
		if c.caret < 0 || c.name == "" {
			t.Fatalf("%s: needs a name and a | caret", f)
		}
		c.src = src[:c.caret] + src[c.caret+1:]
		cases = append(cases, c)
	}
	return cases
}

func setupQualityWorkspace(t *testing.T, cases []qualityCase) (app, extra string) {
	root := t.TempDir()
	app = filepath.Join(root, "app")
	extra = filepath.Join(root, "extra")
	dep := filepath.Join(root, "dep", "depkit")
	for _, d := range []string{app, extra, dep} {
		_ = os.MkdirAll(d, 0o755)
	}
	_ = os.WriteFile(filepath.Join(app, "go.mod"), []byte(qualityModule), 0o644)
	_ = os.WriteFile(filepath.Join(root, "dep", "go.mod"), []byte("module example.com/dep\n\ngo 1.22\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dep, "depkit.go"), []byte("package depkit\n\nfunc Run() {}\n"), 0o644)
	_ = os.MkdirAll(filepath.Join(root, "dep", "go-kit"), 0o755)
	_ = os.WriteFile(filepath.Join(root, "dep", "go-kit", "kit.go"), []byte("package kit\n\nfunc New() {}\n"), 0o644)
	_ = os.WriteFile(filepath.Join(app, "app.go"), []byte("package app\n"), 0o644)
	for i, c := range cases {
		if strings.HasSuffix(c.file, ".go") {
			dir := filepath.Join(app, fmt.Sprintf("c%02d", i))
			_ = os.MkdirAll(dir, 0o755)
			_ = os.WriteFile(filepath.Join(dir, c.file), []byte(c.src), 0o644)
		}
	}
	return app, extra
}

func casePath(app, extra string, i int, c qualityCase) string {
	if strings.HasSuffix(c.file, ".go") {
		return filepath.Join(app, fmt.Sprintf("c%02d", i), c.file)
	}
	dir := filepath.Join(extra, fmt.Sprintf("c%02d", i))
	_ = os.MkdirAll(dir, 0o755)
	return filepath.Join(dir, c.file)
}

func sameLabel(label, want string) bool { return strings.TrimSpace(label) == strings.TrimSpace(want) }

func rawGoplsOrder(items []completionItem, query string) []string {
	idx := make([]int, len(items))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool { return items[idx[a]].SortText < items[idx[b]].SortText })
	var out []string
	for _, i := range idx {
		if _, ok := matchCandidate(query, items[i].filterKey()); ok {
			out = append(out, items[i].Label)
		}
	}
	return out
}

func TestCompletionQualityCorpus(t *testing.T) {
	setupPATH()
	if _, err := exec.LookPath("gopls"); err != nil {
		t.Skip("gopls not installed")
	}
	cases := loadQualityCases(t)
	if len(cases) < 50 {
		t.Fatalf("corpus has %d cases, want at least 50", len(cases))
	}
	freshStore(t)
	t.Cleanup(Shutdown)
	app, extra := setupQualityWorkspace(t, cases)
	OpenWorkspace(app)
	waitFor(t, "gopls ready", 30*time.Second, func() bool { srv := current(); return srv != nil && ServerPID() != 0 })
	waitFor(t, "module graph", 30*time.Second, func() bool { return projectModules.ready(app) })

	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			path := casePath(app, extra, i, c)
			OpenDocument(path, []byte(c.src))
			defer CloseDocument(path)
			var start completionStart
			deadline := time.Now().Add(30 * time.Second)
			if c.none {
				deadline = time.Now().Add(3 * time.Second)
			}
			for time.Now().Before(deadline) {
				_ = json.Unmarshal([]byte(StartCompletion(path, c.caret, 1, "")), &start)
				if start.OK && start.Count > 0 {
					break
				}
				time.Sleep(100 * time.Millisecond)
			}
			var got []string
			var res completionFilterResult
			var s *completionSession
			if start.OK {
				completions.mu.Lock()
				s = completions.session
				completions.mu.Unlock()
			}
			if s != nil {
				_ = json.Unmarshal([]byte(FilterCompletion(s.id, path, c.caret, s.query)), &res)
				for _, r := range res.Rows {
					got = append(got, r.Label)
				}
			}
			if c.none {
				for _, bad := range c.forbid {
					for _, g := range got {
						if sameLabel(g, bad) {
							t.Errorf("%q must not be offered in %s: %v", bad, c.file, head(got, 8))
						}
					}
				}
				return
			}
			if s == nil {
				if len(c.want) == 0 && c.after == "" {
					return
				}
				t.Fatalf("no completion session (start %+v)", start)
			}
			raw := rawGoplsOrder(s.items, s.query)
			if os.Getenv("GOLENS_QUALITY_DUMP") != "" {
				t.Logf("query %q\n raw gopls: %v\n golens:      %v", s.query, head(raw, 12), head(got, 12))
			}
			for k, w := range c.want {
				if k >= len(got) || !sameLabel(got[k], w) {
					t.Errorf("top-%d: want %v, got %v (raw gopls %v)", len(c.want), c.want, head(got, 6), head(raw, 6))
					break
				}
			}
			for _, bad := range c.forbid {
				for _, g := range got {
					if sameLabel(g, bad) {
						t.Errorf("%q must not be offered: %v", bad, head(got, 8))
					}
				}
			}
			if (c.insert != "" || c.after != "" || c.not != "") && len(res.Rows) > 0 {
				row := res.Rows[0]
				for _, r := range res.Rows {
					if c.commit != "" && sameLabel(r.Label, c.commit) {
						row = r
					}
				}
				var commit completionCommit
				_ = json.Unmarshal([]byte(CommitCompletion(s.id, row.Index, c.caret)), &commit)
				if c.insert != "" && !strings.HasPrefix(commit.Text, c.insert) {
					t.Errorf("commit inserts %q, want prefix %q", commit.Text, c.insert)
				}
				after := c.src[:commit.Start] + commit.Text + c.src[commit.End:]
				if c.after != "" && !strings.Contains(after, c.after) {
					t.Errorf("after committing %q the document has no %q:\n%s", row.Label, c.after, after)
				}
				if c.not != "" && strings.Contains(after, c.not) {
					t.Errorf("after committing %q the document contains %q:\n%s", row.Label, c.not, after)
				}
			}
			checkRows(t, res.Rows, projectModules.allowFunc(s.root), s.items)
			if len(c.want) > 0 {
				r, v := indexOfLabel(raw, c.want[0]), indexOfLabel(got, c.want[0])
				if r >= 0 && (v < 0 || v > r) {
					t.Errorf("GoLens ranks %q at #%d, raw gopls at #%d", c.want[0], v+1, r+1)
				}
			}
		})
	}
}

func checkRows(t *testing.T, rows []completionRow, allowed func(string) bool, items []completionItem) {
	t.Helper()
	seen := map[string]bool{}
	for _, r := range rows {
		k := r.Label + "\x00" + r.Kind + "\x00" + r.Package
		if seen[k] {
			t.Errorf("duplicate row %q (%s %s)", r.Label, r.Kind, r.Package)
		}
		seen[k] = true
		if imp := items[r.Index].unimportedPath(); imp != "" && !allowed(imp) {
			t.Errorf("unimported %q from outside stdlib and the module graph", imp)
		}
	}
}

func indexOfLabel(xs []string, s string) int {
	for i, x := range xs {
		if sameLabel(x, s) {
			return i
		}
	}
	return -1
}

func head(xs []string, n int) []string { return xs[:min(len(xs), n)] }

