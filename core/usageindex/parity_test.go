package usageindex

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"golens/core/goast"
)

// TestParityWithGopls compares every lens declaration's count with gopls
// textDocument/references (includeDeclaration false), and, for every method,
// type and interface, its implementation locations (file, line, column) with
// gopls textDocument/implementation, in order. gopls reference locations outside the
// workspace directory are the cgo //export rows in generated build-cache
// files, which the index deliberately does not count; they are excluded from
// the gopls side and reported. Implementation locations are compared in full.
// A gopls implementation error counts as an empty result. Files whose package
// fails to load or type-check have no counts by design; they are listed and
// not compared.
func TestParityWithGopls(t *testing.T) {
	ws := os.Getenv("USAGEINDEX_PARITY_WS")
	if ws == "" {
		t.Skip("set USAGEINDEX_PARITY_WS to a workspace directory")
	}
	goplsPath, err := exec.LookPath("gopls")
	if err != nil {
		t.Skip("gopls is not on PATH")
	}
	ws, err = filepath.Abs(ws)
	if err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	ix, err := Build(context.Background(), ws, Options{})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	t.Logf("index built in %v", time.Since(start).Round(time.Millisecond))

	names := make([]string, 0, len(ix.files))
	for name := range ix.files {
		names = append(names, name)
	}
	sort.Strings(names)

	g, err := startGopls(goplsPath, ws)
	if err != nil {
		t.Fatal(err)
	}
	defer g.stop()

	var total, equal, excludedLocs, excludedDecls int
	var implTotal, implEqual, implLocs, implErrors int
	var diffs, implDiffs, broken []string
	for _, name := range names {
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		decls := goast.Declarations(src)
		if len(decls) == 0 {
			continue
		}
		if ix.files[name].broken {
			broken = append(broken, fmt.Sprintf("%s (%d declarations)", strings.TrimPrefix(name, ws+"/"), len(decls)))
			continue
		}
		lenses := ix.FileLenses(name)
		uri := fileURI(name)
		if err := g.notify("textDocument/didOpen", map[string]any{"textDocument": map[string]any{
			"uri": uri, "languageId": "go", "version": 1, "text": string(src)}}); err != nil {
			t.Fatal(err)
		}
		for _, d := range decls {
			total++
			where := fmt.Sprintf("%s:%d %s %s", strings.TrimPrefix(name, ws+"/"), d.Line, d.Kind, d.Name)
			res, err := g.call("textDocument/references", map[string]any{
				"textDocument": map[string]string{"uri": uri},
				"position":     map[string]int{"line": d.Line - 1, "character": d.Col - 1},
				"context":      map[string]bool{"includeDeclaration": false},
			})
			if err != nil {
				diffs = append(diffs, fmt.Sprintf("%s: gopls error: %v", where, err))
				continue
			}
			var locs []struct {
				URI   string `json:"uri"`
				Range struct {
					Start struct{ Line, Character int }
				} `json:"range"`
			}
			if err := json.Unmarshal(res, &locs); err != nil {
				t.Fatalf("%s: decode references: %v", where, err)
			}
			var inside []string
			outside := 0
			for _, loc := range locs {
				p, err := uriPath(loc.URI)
				if err != nil {
					t.Fatalf("%s: %v", where, err)
				}
				if rel, err := filepath.Rel(ws, p); err != nil || strings.HasPrefix(rel, "..") {
					outside++
					continue
				}
				inside = append(inside, fmt.Sprintf("%s:%d:%d", strings.TrimPrefix(p, ws+"/"), loc.Range.Start.Line+1, loc.Range.Start.Character+1))
			}
			if outside > 0 {
				excludedLocs += outside
				excludedDecls++
			}
			lens, ok := lenses[Pos{Line: d.Line, Col: d.Col}]
			got := lens.Count
			switch {
			case !ok:
				diffs = append(diffs, fmt.Sprintf("%s: index has no count, gopls %d", where, len(inside)))
			case got != len(inside):
				diffs = append(diffs, fmt.Sprintf("%s: index %d, gopls %d %v", where, got, len(inside), inside))
			default:
				equal++
			}
			if d.Kind == "func" {
				continue
			}
			implTotal++
			var want []string
			res, err = g.call("textDocument/implementation", map[string]any{
				"textDocument": map[string]string{"uri": uri},
				"position":     map[string]int{"line": d.Line - 1, "character": d.Col - 1},
			})
			if err != nil {
				implErrors++
			} else {
				if err := json.Unmarshal(res, &locs); err != nil {
					t.Fatalf("%s: decode implementation: %v", where, err)
				}
				for _, loc := range locs {
					p, err := uriPath(loc.URI)
					if err != nil {
						t.Fatalf("%s: %v", where, err)
					}
					want = append(want, fmt.Sprintf("%s:%d:%d", p, loc.Range.Start.Line+1, loc.Range.Start.Character+1))
				}
			}
			var have []string
			for _, loc := range lens.Impls {
				have = append(have, fmt.Sprintf("%s:%d:%d", loc.File, loc.Line, loc.Col))
			}
			ordered := slices.Equal(have, want)
			sort.Strings(want)
			sort.Strings(have)
			implLocs += len(want)
			switch {
			case err != nil && len(have) > 0:
				implDiffs = append(implDiffs, fmt.Sprintf("%s: gopls error %v, index %v", where, err, have))
			case !slices.Equal(have, want):
				implDiffs = append(implDiffs, fmt.Sprintf("%s:\n  index %v\n  gopls %v", where, have, want))
			case !ordered && err == nil:
				implDiffs = append(implDiffs, fmt.Sprintf("%s: same locations in a different order", where))
			default:
				implEqual++
			}
		}
		if err := g.notify("textDocument/didClose", map[string]any{"textDocument": map[string]string{"uri": uri}}); err != nil {
			t.Fatal(err)
		}
	}
	t.Logf("declarations %d, equal %d, different %d; excluded %d gopls locations outside the workspace on %d declarations",
		total, equal, len(diffs), excludedLocs, excludedDecls)
	if len(broken) > 0 {
		t.Logf("not compared, package failed to load or type-check so the index has no counts by design:\n%s", strings.Join(broken, "\n"))
	}
	t.Logf("implementations: declarations %d, equal %d, different %d; %d gopls locations; %d gopls errors",
		implTotal, implEqual, len(implDiffs), implLocs, implErrors)
	if len(diffs) > 0 {
		t.Errorf("%d declarations differ from gopls:\n%s", len(diffs), strings.Join(diffs, "\n"))
	}
	if len(implDiffs) > 0 {
		t.Errorf("%d declarations' implementations differ from gopls:\n%s", len(implDiffs), strings.Join(implDiffs, "\n"))
	}
}

func uriPath(uri string) (string, error) {
	u, err := url.Parse(uri)
	if err != nil || u.Scheme != "file" {
		return "", fmt.Errorf("unexpected location URI %q", uri)
	}
	return filepath.Clean(u.Path), nil
}

type goplsClient struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser
	out   *bufio.Reader
	next  int
}

func startGopls(path, ws string) (*goplsClient, error) {
	cmd := exec.Command(path, "serve")
	cmd.Dir = ws
	cmd.Stderr = io.Discard
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start gopls: %w", err)
	}
	g := &goplsClient{cmd: cmd, stdin: stdin, out: bufio.NewReaderSize(stdout, 1<<20)}
	root := fileURI(ws)
	if _, err := g.call("initialize", map[string]any{
		"processId":        os.Getpid(),
		"rootUri":          root,
		"capabilities":     map[string]any{},
		"workspaceFolders": []map[string]string{{"uri": root, "name": filepath.Base(ws)}},
	}); err != nil {
		g.stop()
		return nil, fmt.Errorf("gopls initialize: %w", err)
	}
	if err := g.notify("initialized", map[string]any{}); err != nil {
		g.stop()
		return nil, err
	}
	return g, nil
}

// stop asks gopls to shut down and waits for it, killing it if it does not
// exit in time.
func (g *goplsClient) stop() {
	exited := make(chan struct{})
	go func() {
		defer close(exited)
		_, _ = g.call("shutdown", nil)
		_ = g.notify("exit", nil)
		_ = g.stdin.Close()
		_ = g.cmd.Wait()
	}()
	select {
	case <-exited:
	case <-time.After(15 * time.Second):
		_ = g.cmd.Process.Kill()
		<-exited
	}
}

func (g *goplsClient) send(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(g.stdin, "Content-Length: %d\r\n\r\n%s", len(b), b)
	return err
}

func (g *goplsClient) read() (map[string]json.RawMessage, error) {
	n := -1
	for {
		line, err := g.out.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("read gopls header: %w", err)
		}
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		if v, ok := strings.CutPrefix(line, "Content-Length: "); ok {
			if n, err = strconv.Atoi(v); err != nil {
				return nil, fmt.Errorf("bad gopls header %q", line)
			}
		}
	}
	if n < 0 {
		return nil, fmt.Errorf("gopls message without Content-Length")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(g.out, buf); err != nil {
		return nil, fmt.Errorf("read gopls body: %w", err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(buf, &m); err != nil {
		return nil, fmt.Errorf("decode gopls message: %w", err)
	}
	return m, nil
}

func (g *goplsClient) call(method string, params any) (json.RawMessage, error) {
	g.next++
	id := strconv.Itoa(g.next)
	if err := g.send(map[string]any{"jsonrpc": "2.0", "id": g.next, "method": method, "params": params}); err != nil {
		return nil, err
	}
	for {
		m, err := g.read()
		if err != nil {
			return nil, err
		}
		if _, isRequest := m["method"]; isRequest {
			if rid, ok := m["id"]; ok {
				if err := g.send(map[string]any{"jsonrpc": "2.0", "id": rid, "result": nil}); err != nil {
					return nil, err
				}
			}
			continue
		}
		if string(m["id"]) != id {
			continue
		}
		if e, ok := m["error"]; ok && string(e) != "null" {
			return nil, fmt.Errorf("%s: %s", method, e)
		}
		return m["result"], nil
	}
}

func (g *goplsClient) notify(method string, params any) error {
	return g.send(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
}
