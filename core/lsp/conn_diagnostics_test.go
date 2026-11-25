package lsp

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDiagnosticsDeliveryDoesNotBlockDispatchAndKeepsLatest(t *testing.T) {
	c := newConn()
	defer close(c.closed)
	release := make(chan struct{})
	var mu sync.Mutex
	got := map[string][]string{}
	delivered := make(chan struct{}, 16)
	c.onDiag = func(path string, payload []byte) {
		<-release
		mu.Lock()
		got[path] = append(got[path], string(payload))
		mu.Unlock()
		delivered <- struct{}{}
	}
	publish := func(uri, msg string) {
		c.dispatch([]byte(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"` + uri + `","diagnostics":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":1,"message":"` + msg + `"}]}}`))
	}
	done := make(chan struct{})
	go func() {
		publish("file:///w/a.go", "a1")
		time.Sleep(20 * time.Millisecond)
		publish("file:///w/a.go", "a2")
		publish("file:///w/b.go", "b1")
		publish("file:///w/a.go", "a3")
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("dispatch blocked on diagnostics delivery")
	}
	close(release)
	deadline := time.After(2 * time.Second)
	for {
		mu.Lock()
		a, b := got["/w/a.go"], got["/w/b.go"]
		mu.Unlock()
		if len(a) > 0 && strings.Contains(a[len(a)-1], "a3") && len(b) == 1 {
			for _, p := range a {
				if strings.Contains(p, "a2") {
					t.Fatalf("superseded diagnostics delivered: %v", a)
				}
			}
			var diags []uiDiagnostic
			if err := json.Unmarshal([]byte(a[len(a)-1]), &diags); err != nil || len(diags) != 1 {
				t.Fatalf("payload %s", a[len(a)-1])
			}
			return
		}
		select {
		case <-delivered:
		case <-deadline:
			t.Fatalf("diagnostics not delivered: %v", got)
		}
	}
}
