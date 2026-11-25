package lsp

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
)

type wire struct {
	t    *testing.T
	msgs chan map[string]any
}

func readFrames(t *testing.T, r io.Reader) *wire {
	w := &wire{t: t, msgs: make(chan map[string]any, 256)}
	go func() {
		br := bufio.NewReader(r)
		for {
			n := -1
			for {
				line, err := br.ReadString('\n')
				if err != nil {
					close(w.msgs)
					return
				}
				line = strings.TrimSpace(line)
				if line == "" {
					break
				}
				if v, ok := strings.CutPrefix(line, "Content-Length:"); ok {
					n, _ = strconv.Atoi(strings.TrimSpace(v))
				}
			}
			body := make([]byte, n)
			_, _ = io.ReadFull(br, body)
			var m map[string]any
			_ = json.Unmarshal(body, &m)
			w.msgs <- m
		}
	}()
	return w
}

func (w *wire) next() map[string]any {
	w.t.Helper()
	select {
	case m := <-w.msgs:
		return m
	case <-time.After(2 * time.Second):
		w.t.Fatal("timed out waiting for a message to gopls")
		return nil
	}
}

func (w *wire) none() {
	w.t.Helper()
	select {
	case m := <-w.msgs:
		w.t.Fatalf("unexpected message %v", m)
	case <-time.After(50 * time.Millisecond):
	}
}

func fakeServer(t *testing.T, syncKind int) (*server, *wire) {
	pr, pw := io.Pipe()
	s := &server{c: newConn(), caps: serverCaps{SyncKind: syncKind, SemanticFull: true}, exited: make(chan struct{})}
	go s.c.writeLoop(pw)
	t.Cleanup(func() { s.c.close(); _ = pr.Close() })
	return s, readFrames(t, pr)
}

func freshStore(t *testing.T) {
	old := docs
	docs = &docStore{docs: make(map[string]*document)}
	t.Cleanup(func() { docs = old })
}

func TestCloseThenLateEditDoesNotResurrect(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	OpenDocument("/w/a.go", []byte("package a\n"))
	if m := w.next(); m["method"] != "textDocument/didOpen" {
		t.Fatalf("got %v", m)
	}
	CloseDocument("/w/a.go")
	if m := w.next(); m["method"] != "textDocument/didClose" {
		t.Fatalf("got %v", m)
	}
	if st := ChangeDocument("/w/a.go", 0, 0, []byte("x"), 10); st != ChangeUnknownDocument {
		t.Fatalf("late edit status %v", st)
	}
	if st := ReplaceDocument("/w/a.go", []byte("x")); st != ChangeUnknownDocument {
		t.Fatalf("late full change status %v", st)
	}
	w.none()
	if docs.count() != 0 {
		t.Fatalf("closed document resurrected: %d docs", docs.count())
	}
}

func TestIncrementalDidChangeUsesUTF16Positions(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	OpenDocument("/w/a.go", []byte("package a\n// héllo\n"))
	w.next()
	content := "package a\n// héllo\n"
	start := strings.Index(content, "llo")
	if st := ChangeDocument("/w/a.go", start, start+1, []byte("L\n"), len(content)); st != ChangeApplied {
		t.Fatalf("status %v", st)
	}
	m := w.next()
	params := m["params"].(map[string]any)
	if v := params["textDocument"].(map[string]any)["version"].(float64); v != 2 {
		t.Fatalf("version %v", v)
	}
	ch := params["contentChanges"].([]any)[0].(map[string]any)
	r := ch["range"].(map[string]any)
	st := r["start"].(map[string]any)
	if st["line"].(float64) != 1 || st["character"].(float64) != 5 || ch["text"] != "L\n" {
		t.Fatalf("change %v", ch)
	}
	docs.withDoc("/w/a.go", func(d *document) {
		if string(d.buf.Content) != "package a\n// héL\nlo\n" || len(d.buf.LineStarts) != 4 {
			t.Fatalf("buffer %q %v", d.buf.Content, d.buf.LineStarts)
		}
	})
}

func TestFullSyncServerReceivesWholeText(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 1)
	docs.attach(s)
	OpenDocument("/w/a.go", []byte("ab"))
	w.next()
	ChangeDocument("/w/a.go", 1, 1, []byte("X"), 2)
	ch := w.next()["params"].(map[string]any)["contentChanges"].([]any)[0].(map[string]any)
	if _, has := ch["range"]; has || ch["text"] != "aXb" {
		t.Fatalf("full sync change %v", ch)
	}
}

func TestDesyncIsDetected(t *testing.T) {
	freshStore(t)
	OpenDocument("/w/a.go", []byte("abc"))
	if st := ChangeDocument("/w/a.go", 0, 0, []byte("x"), 99); st != ChangeDesync {
		t.Fatalf("status %v", st)
	}
	if st := ChangeDocument("/w/a.go", 2, 9, nil, 3); st != ChangeDesync {
		t.Fatalf("out of range status %v", st)
	}
}

func TestOnlyGoFamilyDocumentsReachGopls(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	for _, p := range []string{"/w/README.md", "/w/config.yaml", "/w/Makefile"} {
		OpenDocument(p, []byte("text"))
		ChangeDocument(p, 0, 0, []byte("x"), 4)
	}
	w.none()
	langs := map[string]string{"/w/a.go": "go", "/w/go.mod": "go.mod", "/w/go.sum": "go.sum", "/w/go.work": "go.work"}
	for p, lang := range langs {
		OpenDocument(p, []byte("x"))
		m := w.next()
		td := m["params"].(map[string]any)["textDocument"].(map[string]any)
		if td["languageId"] != lang {
			t.Fatalf("%s languageId %v", p, td["languageId"])
		}
	}
}

func TestAttachReplaysOpenDocumentsAfterRestart(t *testing.T) {
	freshStore(t)
	OpenDocument("/w/a.go", []byte("package a"))
	ChangeDocument("/w/a.go", 9, 9, []byte("\n"), 9)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	m := w.next()
	td := m["params"].(map[string]any)["textDocument"].(map[string]any)
	if m["method"] != "textDocument/didOpen" || td["text"] != "package a\n" || td["version"].(float64) != 2 {
		t.Fatalf("replay %v", m)
	}
	docs.detach(s)
	ChangeDocument("/w/a.go", 0, 0, []byte("x"), 10)
	w.none()
}

func TestURIsArePercentEncoded(t *testing.T) {
	p := "/Users/me/My Projects/a#b/main.go"
	u := pathToURI(p)
	if u != "file:///Users/me/My%20Projects/a%23b/main.go" {
		t.Fatalf("uri %s", u)
	}
	if back := uriToPath(u); back != p {
		t.Fatalf("round trip %s", back)
	}
}

func TestCallRoutingCancellationAndServerRequests(t *testing.T) {
	s, w := fakeServer(t, 2)
	var forwarded []string
	t.Cleanup(bridge.SetLSPResponse(func(b []byte) { forwarded = append(forwarded, string(b)) }))

	done := make(chan error, 1)
	go func() {
		_, err := s.c.call("textDocument/completion", nil, time.Second, "completion")
		done <- err
	}()
	first := w.next()
	go func() {
		res, err := s.c.call("textDocument/completion", nil, time.Second, "completion")
		if err == nil && string(res) != `{"items":[]}` {
			err = errors.New("wrong result " + string(res))
		}
		done <- err
	}()
	cancel := w.next()
	if cancel["method"] != "$/cancelRequest" || cancel["params"].(map[string]any)["id"] != first["id"] {
		t.Fatalf("expected cancel of first request, got %v", cancel)
	}
	if err := <-done; !errors.Is(err, errCancelled) {
		t.Fatalf("superseded call returned %v", err)
	}
	second := w.next()
	id := int64(second["id"].(float64))
	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":` + strconv.FormatInt(id, 10) + `,"result":{"items":[]}}`))
	if err := <-done; err != nil {
		t.Fatal(err)
	}

	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":` + strconv.FormatInt(int64(first["id"].(float64)), 10) + `,"result":null}`))
	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":4294967297,"result":{"ok":1}}`))
	if len(forwarded) != 1 || !strings.Contains(forwarded[0], "4294967297") {
		t.Fatalf("forwarding %v", forwarded)
	}

	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":7,"method":"window/workDoneProgress/create","params":{}}`))
	resp := w.next()
	if resp["id"].(float64) != 7 || resp["method"] != nil {
		t.Fatalf("server request not answered: %v", resp)
	}
	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":"cfg","method":"workspace/configuration","params":{"items":[{"section":"gopls"}]}}`))
	resp = w.next()
	if res, ok := resp["result"].([]any); !ok || len(res) != 1 {
		t.Fatalf("configuration answer %v", resp)
	}
}

func TestCallTimeoutSendsCancel(t *testing.T) {
	s, w := fakeServer(t, 2)
	go func() { _, _ = s.c.call("textDocument/hover", nil, 30*time.Millisecond, "") }()
	req := w.next()
	cancel := w.next()
	if cancel["method"] != "$/cancelRequest" || cancel["params"].(map[string]any)["id"] != req["id"] {
		t.Fatalf("got %v", cancel)
	}
	s.c.mu.Lock()
	n := len(s.c.pending)
	s.c.mu.Unlock()
	if n != 0 {
		t.Fatalf("%d pending calls leaked", n)
	}
}

func TestParseCapsHonoursServer(t *testing.T) {
	caps := parseCaps(json.RawMessage(`{"capabilities":{"textDocumentSync":{"change":2},"semanticTokensProvider":{"full":true,"range":true,"legend":{"tokenTypes":["namespace","type"]}},"documentFormattingProvider":true,"codeActionProvider":{"codeActionKinds":["source.organizeImports"]}}}`))
	if caps.SyncKind != 2 || !caps.SemanticRange || !caps.Formatting || !caps.CodeActions || len(caps.TokenTypes) != 2 {
		t.Fatalf("%+v", caps)
	}
	if parseCaps(json.RawMessage(`{"capabilities":{"textDocumentSync":1}}`)).SyncKind != 1 {
		t.Fatal("numeric sync kind")
	}
}

func TestDecodeTokensToAbsoluteBytes(t *testing.T) {
	buf := NewFileBuffer([]byte("var é = 1\nfunc f() {}\n"))
	got := decodeTokens(buf, []int{0, 0, 3, 1, 0, 0, 6, 1, 2, 0, 1, 0, 4, 0, 0, 0, 5, 1, 3, 0}, []int{9, 5, 6})
	want := []int32{0, 3, 5, 7, 1, 6, 11, 4, 9}
	if len(got) != len(want) {
		t.Fatalf("got %v want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v want %v", got, want)
		}
	}
}

type nopWriteCloser struct{ io.Writer }

func (nopWriteCloser) Close() error { return nil }

func benchKeystroke(b *testing.B, size int) {
	old := docs
	docs = &docStore{docs: make(map[string]*document)}
	defer func() { docs = old }()
	s := &server{c: newConn(), caps: serverCaps{SyncKind: 2}, exited: make(chan struct{})}
	go s.c.writeLoop(nopWriteCloser{io.Discard})
	defer s.c.close()
	docs.attach(s)
	doc := makeDoc(size)
	OpenDocument("/w/a.go", doc)
	n := len(doc)
	mid := n / 2
	ch := []byte("x")
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ChangeDocument("/w/a.go", mid, mid, ch, n)
		ChangeDocument("/w/a.go", mid, mid+1, nil, n+1)
	}
}

func BenchmarkKeystroke10KB(b *testing.B)  { benchKeystroke(b, 10<<10) }
func BenchmarkKeystroke100KB(b *testing.B) { benchKeystroke(b, 100<<10) }
func BenchmarkKeystroke1MB(b *testing.B)   { benchKeystroke(b, 1<<20) }

func TestSwiftRequestIDPartitionMatchesClient(t *testing.T) {
	src, err := os.ReadFile("../../desktop/State/LSPClient.swift")
	if err != nil {
		t.Skip("desktop sources not available")
	}
	if !strings.Contains(string(src), "firstRequestID: Int64 = 1 << 32") {
		t.Fatal("Swift request IDs must start at SwiftIDBase so responses are routed to Swift")
	}
}

func TestSemanticTokensOnlyForVisibleDocuments(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	s.caps.TokenTypes = []string{"keyword"}
	docs.attach(s)
	OpenDocument("/w/shown.go", []byte("package a\n"))
	OpenDocument("/w/hidden.go", []byte("package b\n"))
	w.next()
	w.next()
	SetVisibleDocuments([]string{"/w/shown.go"})
	if _, ok := SemanticTokens("/w/hidden.go", 0, 0); ok {
		t.Fatal("tokens served for a hidden document")
	}
	w.none()
	go SemanticTokens("/w/shown.go", 0, 0)
	req := w.next()
	if req["method"] != "textDocument/semanticTokens/full" {
		t.Fatalf("got %v", req)
	}
	uri := req["params"].(map[string]any)["textDocument"].(map[string]any)["uri"]
	if uri != pathToURI("/w/shown.go") {
		t.Fatalf("request targeted %v", uri)
	}
	SetVisibleDocuments(nil)
	if _, ok := SemanticTokens("/w/shown.go", 0, 0); ok {
		t.Fatal("tokens served after the editor was hidden")
	}
}

func TestEditsWaitForDiagnosticsAndCoalesce(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	OpenDocument("/w/a.go", []byte("package a\n"))
	w.next()
	version := func(m map[string]any) float64 {
		return m["params"].(map[string]any)["textDocument"].(map[string]any)["version"].(float64)
	}
	changes := func(m map[string]any) int { return len(m["params"].(map[string]any)["contentChanges"].([]any)) }
	ChangeDocument("/w/a.go", 10, 10, []byte("x"), 10)
	if m := w.next(); m["method"] != "textDocument/didChange" || version(m) != 2 {
		t.Fatalf("first edit not sent at once: %v", m)
	}
	ChangeDocument("/w/a.go", 11, 11, []byte("y"), 11)
	ChangeDocument("/w/a.go", 12, 12, []byte("z"), 12)
	w.none()
	uri := pathToURI("/w/a.go")
	s.c.publishDiagnostics(json.RawMessage(`{"uri":"` + uri + `","version":2,"diagnostics":[]}`))
	if m := w.next(); version(m) != 4 || changes(m) != 2 {
		t.Fatalf("held edits not coalesced after diagnostics: %v", m)
	}
	ChangeDocument("/w/a.go", 13, 13, []byte("w"), 13)
	w.none()
	_ = s.c.notify("textDocument/didSave", map[string]any{})
	if m := w.next(); m["method"] != "textDocument/didChange" || version(m) != 5 {
		t.Fatalf("request not preceded by the newest text: %v", m)
	}
	if m := w.next(); m["method"] != "textDocument/didSave" {
		t.Fatalf("got %v", m)
	}
	old := changeGateMax
	changeGateMax = 100 * time.Millisecond
	t.Cleanup(func() { changeGateMax = old })
	s.c.gateMu.Lock()
	s.c.gateTimer.Reset(changeGateMax)
	s.c.gateMu.Unlock()
	ChangeDocument("/w/a.go", 14, 14, []byte("v"), 14)
	if m := w.next(); version(m) != 6 {
		t.Fatalf("edit held past the gate limit: %v", m)
	}
}
