package lsp

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"

	"golens/core/bridge"
)

func reply(s *server, req map[string]any, result string) {
	id := strconv.FormatInt(int64(req["id"].(float64)), 10)
	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":` + id + `,"result":` + result + `}`))
}

func async(fn func() string) chan string {
	ch := make(chan string, 1)
	go func() { ch <- fn() }()
	return ch
}

func TestCodeLensesResolveMissingCommands(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	OpenDocument("/w/go.mod", []byte("module x\n"))
	w.next()
	done := async(func() string { return CodeLenses("/w/go.mod") })
	req := w.next()
	if req["method"] != "textDocument/codeLens" {
		t.Fatalf("got %v", req)
	}
	reply(s, req, `[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":8}},"command":{"title":"Run go mod tidy","command":"gopls.tidy","arguments":[{"URIs":["file:///w/go.mod"]}]}},
		{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}},"data":{"k":1}}]`)
	res := w.next()
	if res["method"] != "codeLens/resolve" {
		t.Fatalf("expected resolve, got %v", res)
	}
	reply(s, res, `{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}},"command":{"title":"Check for upgrades","command":"gopls.check_upgrades"}}`)
	var out struct {
		Result []uiCodeLens `json:"result"`
	}
	_ = json.Unmarshal([]byte(<-done), &out)
	if len(out.Result) != 2 || out.Result[0].Command != "gopls.tidy" || out.Result[1].Line != 2 || out.Result[1].Title != "Check for upgrades" {
		t.Fatalf("lenses %+v", out.Result)
	}
	if len(out.Result[0].Arguments) != 1 {
		t.Fatalf("arguments must round-trip: %+v", out.Result[0])
	}
}

func TestExecuteCommandWithServerAppliedEdit(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	var gotToken int64
	var gotEdit string
	t.Cleanup(bridge.SetApplyEdit(func(token int64, edit string) bool {
		gotToken, gotEdit = token, edit
		go FinishApplyEdit(token, true, "")
		return true
	}))

	done := async(func() string {
		return ExecuteCommand(`{"command":"gopls.add_test","arguments":[{"uri":"file:///w/a.go"}],"formAnswers":[{"id":"x","value":"y"}]}`)
	})
	req := w.next()
	if req["method"] != "workspace/executeCommand" {
		t.Fatalf("got %v", req)
	}
	p := req["params"].(map[string]any)
	if p["command"] != "gopls.add_test" || len(p["formAnswers"].([]any)) != 1 {
		t.Fatalf("params %v", p)
	}
	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":99,"method":"workspace/applyEdit","params":{"label":"Add test","edit":{"documentChanges":[{"kind":"create","uri":"file:///w/a_test.go"}]}}}`))
	ack := w.next()
	if ack["id"].(float64) != 99 || ack["result"].(map[string]any)["applied"] != true {
		t.Fatalf("applyEdit answer %v", ack)
	}
	if gotToken == 0 || !strings.Contains(gotEdit, "a_test.go") || !strings.Contains(gotEdit, `"label":"Add test"`) {
		t.Fatalf("edit forwarded as %d %s", gotToken, gotEdit)
	}
	reply(s, req, `null`)
	if res := <-done; res != `{"result":null}` {
		t.Fatalf("execute result %s", res)
	}
	if pendingApplyCount() != 0 {
		t.Fatal("applyEdit left pending")
	}
}

func TestApplyEditWithoutEditorIsRefused(t *testing.T) {
	s, w := fakeServer(t, 2)
	t.Cleanup(bridge.SetApplyEdit(func(int64, string) bool { return false }))
	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":5,"method":"workspace/applyEdit","params":{"edit":{"changes":{}}}}`))
	ack := w.next()
	if r := ack["result"].(map[string]any); r["applied"] != false || r["failureReason"] == nil {
		t.Fatalf("got %v", ack)
	}
	s.c.dispatch([]byte(`{"jsonrpc":"2.0","id":6,"method":"workspace/applyEdit","params":{}}`))
	if r := w.next()["result"].(map[string]any); r["applied"] != false {
		t.Fatalf("malformed edit must be refused: %v", r)
	}
	FinishApplyEdit(12345, true, "")
	w.none()
}

func TestCodeActionsAndResolve(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	s.caps.CodeActions = true
	docs.attach(s)
	OpenDocument("/w/a.go", []byte("package a\n\nfunc F() {}\n"))
	w.next()
	done := async(func() string { return CodeActions("/w/a.go", 11, 17, []string{"source.addTest"}, nil) })
	req := w.next()
	p := req["params"].(map[string]any)
	ctx := p["context"].(map[string]any)
	r := p["range"].(map[string]any)
	if req["method"] != "textDocument/codeAction" || ctx["only"].([]any)[0] != "source.addTest" || r["start"].(map[string]any)["line"].(float64) != 2 {
		t.Fatalf("request %v", req)
	}
	reply(s, req, `[{"title":"Add test for F","kind":"source.addTest","data":{"k":"v"}}]`)
	if out := <-done; !strings.Contains(out, "Add test for F") {
		t.Fatalf("actions %s", out)
	}
	done = async(func() string {
		return ResolveCodeAction(`{"title":"Add test for F","kind":"source.addTest","data":{"k":"v"}}`)
	})
	req = w.next()
	if req["method"] != "codeAction/resolve" || req["params"].(map[string]any)["data"] == nil {
		t.Fatalf("resolve %v", req)
	}
	reply(s, req, `{"title":"Add test for F","command":{"title":"Add test","command":"gopls.add_test"}}`)
	if out := <-done; !strings.Contains(out, "gopls.add_test") {
		t.Fatalf("resolved %s", out)
	}
	if out := ResolveCodeAction("{not json"); !strings.Contains(out, "error") {
		t.Fatalf("invalid action must fail: %s", out)
	}
}

func TestInteractiveCommandResolve(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	if out := ResolveCommand(`{"command":"gopls.modify_tags","arguments":[]}`); !strings.Contains(out, `"command":"gopls.modify_tags"`) {
		t.Fatalf("server without interactive support must echo params: %s", out)
	}
	w.none()
	s.caps.InteractiveCommands = true
	done := async(func() string {
		return ResolveCommand(`{"command":"gopls.modify_tags","arguments":[{"URI":"file:///w/a.go"}],"formFields":[{"id":"stale"}],"formAnswers":[{"id":"tags","value":"json"}]}`)
	})
	req := w.next()
	p := req["params"].(map[string]any)
	if req["method"] != "command/resolve" || p["formFields"] != nil || p["formAnswers"].([]any)[0].(map[string]any)["value"] != "json" {
		t.Fatalf("resolve request %v", req)
	}
	reply(s, req, `{"command":"gopls.modify_tags","formFields":[{"id":"transform","description":"Transform","type":{"kind":"enum","entries":[{"value":"camelcase","description":"camelCase"}]},"required":true}]}`)
	if out := <-done; !strings.Contains(out, `"transform"`) {
		t.Fatalf("form %s", out)
	}
	if out := ExecuteCommand(`{"arguments":[]}`); !strings.Contains(out, "command is required") {
		t.Fatalf("missing command must fail: %s", out)
	}
	done = async(func() string { return ListEnum("workspaceSymbol", json.RawMessage(`{"a":1}`), "Read") })
	req = w.next()
	if req["method"] != "interactive/listEnum" || req["params"].(map[string]any)["query"] != "Read" {
		t.Fatalf("listEnum %v", req)
	}
	reply(s, req, `[{"value":"io.Reader","description":"io.Reader"}]`)
	select {
	case out := <-done:
		if !strings.Contains(out, "io.Reader") {
			t.Fatalf("entries %s", out)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("listEnum did not return")
	}
}

func TestUnchangedUserOptionsDoNotReloadGopls(t *testing.T) {
	old := userOptions.analyses
	oldHints := userOptions.hints
	t.Cleanup(func() { userOptions.analyses, userOptions.hints = old, oldHints })
	userOptions.analyses, userOptions.hints = nil, nil
	s := &server{}
	if !s.noteSettings(settingsJSON()) {
		t.Fatal("first settings not recorded")
	}
	userOptions.analyses = map[string]bool{"SA4006": true}
	userOptions.hints = map[string]bool{"ignoredError": true}
	if s.noteSettings(settingsJSON()) {
		t.Fatal("options equal to the defaults changed the configuration")
	}
	userOptions.analyses = map[string]bool{"SA4006": false, "any": false, "minmax": false}
	if !s.noteSettings(settingsJSON()) {
		t.Fatal("turning off default and gopls built-in checks did not change the configuration")
	}
	if s.noteSettings(settingsJSON()) {
		t.Fatal("unchanged negative user overrides triggered a second configuration reload")
	}
	a := goplsSettings()["analyses"].(map[string]bool)
	if a["SA4006"] || !a["SA1000"] {
		t.Fatalf("analyses %v", a)
	}
	if v, ok := a["any"]; !ok || v {
		t.Fatalf("expected explicit any=false override, got present=%v val=%v (%v)", ok, v, a)
	}
	if v, ok := a["minmax"]; !ok || v {
		t.Fatalf("expected explicit minmax=false override, got present=%v val=%v (%v)", ok, v, a)
	}
}

func TestMergeOptionsNegativeUserOverrides(t *testing.T) {
	defaults := map[string]bool{"SA1000": true, "ST1005": true, "SA4006": true}
	user := map[string]bool{
		"SA1000":       false,
		"any":          false,
		"minmax":       false,
		"bloop":        false,
		"mapsloop":     false,
		"slicesdelete": false,
		"nilness":      false,
		"waitgroup":    false,
		"hostport":     false,
		"shadow":       true,
	}
	merged := mergeOptions(defaults, user)
	for _, key := range []string{"SA1000", "any", "minmax", "bloop", "mapsloop", "slicesdelete", "nilness", "waitgroup", "hostport"} {
		val, ok := merged[key]
		if !ok || val {
			t.Fatalf("expected %s=false to survive mergeOptions, got present=%v val=%v", key, ok, val)
		}
	}
	if !merged["ST1005"] || !merged["SA4006"] || !merged["shadow"] {
		t.Fatalf("unexpected merged defaults/enables: %v", merged)
	}

	hints := mergeOptions(defaultHints, map[string]bool{"customHint": false, "assignVariableTypes": false})
	if v, ok := hints["customHint"]; !ok || v {
		t.Fatalf("expected customHint=false in merged hints, got present=%v val=%v", ok, v)
	}
	if v, ok := hints["assignVariableTypes"]; !ok || v {
		t.Fatalf("expected assignVariableTypes=false in merged hints, got present=%v val=%v", ok, v)
	}
	if !hints["ignoredError"] {
		t.Fatalf("expected default hint ignoredError=true preserved, got %v", hints)
	}
}

func TestCodeLensesResolveConcurrentlyPreservingOrder(t *testing.T) {
	freshStore(t)
	s, w := fakeServer(t, 2)
	docs.attach(s)
	OpenDocument("/w/go.mod", []byte("module x\n"))
	w.next()
	done := async(func() string { return CodeLenses("/w/go.mod") })
	req := w.next()
	reply(s, req, `[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}},"data":{"k":1}},
		{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}},"data":{"k":2}},
		{"range":{"start":{"line":3,"character":0},"end":{"line":3,"character":1}},"data":{"k":3}}]`)
	var pending []map[string]any
	for range 3 {
		r := w.next()
		if r["method"] != "codeLens/resolve" {
			t.Fatalf("expected resolve, got %v", r)
		}
		pending = append(pending, r)
	}
	for i := len(pending) - 1; i >= 0; i-- {
		k := pending[i]["params"].(map[string]any)["data"].(map[string]any)["k"].(float64)
		reply(s, pending[i], `{"command":{"title":"T`+strconv.Itoa(int(k))+`","command":"c"}}`)
	}
	var out struct {
		Result []uiCodeLens `json:"result"`
	}
	_ = json.Unmarshal([]byte(<-done), &out)
	if len(out.Result) != 3 {
		t.Fatalf("lenses %+v", out.Result)
	}
	for i, l := range out.Result {
		if l.Line != i+1 || l.Title != "T"+strconv.Itoa(i+1) {
			t.Fatalf("order not preserved: %+v", out.Result)
		}
	}
}

func TestCodeActionsSendGoplsOwnDiagnostics(t *testing.T) {
	c := &conn{}
	publish := `{"uri":"file:///m/main.go","diagnostics":[
		{"range":{"start":{"line":2,"character":7},"end":{"line":2,"character":45}},"severity":1,"source":"compiler","code":"BrokenImport","message":"could not import x"},
		{"range":{"start":{"line":9,"character":1},"end":{"line":9,"character":4}},"severity":2,"source":"unusedvariable","message":"declared and not used"}]}`
	c.keepRawDiagnostics(json.RawMessage(publish))
	got := c.diagnosticsIn("file:///m/main.go", lspRange{Start: lspPos{Line: 2, Character: 7}, End: lspPos{Line: 2, Character: 7}})
	if len(got) != 1 || !strings.Contains(string(got[0]), `"source":"compiler"`) || !strings.Contains(string(got[0]), `"code":"BrokenImport"`) {
		t.Fatalf("want the import diagnostic kept whole, got %s", got)
	}
	if n := len(c.diagnosticsIn("file:///m/main.go", lspRange{Start: lspPos{Line: 0}, End: lspPos{Line: 20}})); n != 2 {
		t.Fatalf("whole-file range: got %d diagnostics", n)
	}
	if n := len(c.diagnosticsIn("file:///m/main.go", lspRange{Start: lspPos{Line: 5}, End: lspPos{Line: 6}})); n != 0 {
		t.Fatalf("unrelated range: got %d diagnostics", n)
	}
	c.keepRawDiagnostics(json.RawMessage(`{"uri":"file:///m/main.go","diagnostics":[]}`))
	if len(c.rawDiags) != 0 {
		t.Fatal("an empty publish must drop the file")
	}
}
