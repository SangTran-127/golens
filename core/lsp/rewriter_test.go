package lsp

import (
	"encoding/json"
	"fmt"
	"net"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/vmexec"
)

func TestURITranslator_HostToGuest(t *testing.T) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)

	slug := vmexec.WorkspaceSlug(wsRoot)
	expectedGuestRoot := "/workspaces/" + slug

	// 1. Host URI translation
	hostURI := "file:///Users/testuser/projects/velo/core/lsp/server.go"
	guestURI := tr.TranslateHostURI(hostURI)
	expectedGuestURI := "file://" + expectedGuestRoot + "/core/lsp/server.go"
	if guestURI != expectedGuestURI {
		t.Fatalf("expected guest URI %s, got %s", expectedGuestURI, guestURI)
	}

	// 2. Modcache translation
	hostModURI := "file://" + tr.HostModCache + "/github.com/gin-gonic/gin@v1.9.1/gin.go"
	guestModURI := tr.TranslateHostURI(hostModURI)
	expectedGuestModURI := "file:///cache/gomod/github.com/gin-gonic/gin@v1.9.1/gin.go"
	if guestModURI != expectedGuestModURI {
		t.Fatalf("expected guest mod URI %s, got %s", expectedGuestModURI, guestModURI)
	}
}

func TestURITranslator_GuestToHost(t *testing.T) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)
	slug := vmexec.WorkspaceSlug(wsRoot)

	guestURI := "file:///workspaces/" + slug + "/core/lsp/server.go"
	hostURI := tr.TranslateGuestURI(guestURI)
	expectedHostURI := "file:///Users/testuser/projects/velo/core/lsp/server.go"
	if hostURI != expectedHostURI {
		t.Fatalf("expected host URI %s, got %s", expectedHostURI, hostURI)
	}

	guestModURI := "file:///cache/gomod/github.com/gin-gonic/gin@v1.9.1/gin.go"
	hostModURI := tr.TranslateGuestURI(guestModURI)
	expectedHostModURI := "file://" + tr.HostModCache + "/github.com/gin-gonic/gin@v1.9.1/gin.go"
	if hostModURI != expectedHostModURI {
		t.Fatalf("expected host mod URI %s, got %s", expectedHostModURI, hostModURI)
	}
}

func TestURITranslator_URLSpaces(t *testing.T) {
	wsRoot := "/Users/testuser/My Projects/velo"
	tr := NewURITranslator(wsRoot)
	slug := vmexec.WorkspaceSlug(filepath.Clean(wsRoot))

	// URL escaped space
	hostURI := "file:///Users/testuser/My%20Projects/velo/main.go"
	guestURI := tr.TranslateHostURI(hostURI)
	expectedGuestURI := "file:///workspaces/" + slug + "/main.go"
	if guestURI != expectedGuestURI {
		t.Fatalf("expected %s, got %s", expectedGuestURI, guestURI)
	}

	// Guest to host
	backURI := tr.TranslateGuestURI(guestURI)
	if backURI != hostURI {
		t.Fatalf("expected back URI %s, got %s", hostURI, backURI)
	}
}

func TestURITranslator_PreserveSourceBufferInDidOpenAndDidChange(t *testing.T) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)
	slug := vmexec.WorkspaceSlug(wsRoot)

	// User's Go source code has a comment mentioning their host workspace path!
	sourceCode := "// Author working in /Users/testuser/projects/velo\npackage main\n\nfunc main() {}\n"

	// 1. Test textDocument/didOpen
	didOpenPayload := map[string]any{
		"jsonrpc": "2.0",
		"method":  "textDocument/didOpen",
		"params": map[string]any{
			"textDocument": map[string]any{
				"uri":        "file:///Users/testuser/projects/velo/main.go",
				"languageId": "go",
				"version":    1,
				"text":       sourceCode,
			},
		},
	}
	didOpenBytes, _ := json.Marshal(didOpenPayload)
	rewrittenOpen := tr.RewriteHostToGuest(didOpenBytes)

	var parsedOpen map[string]json.RawMessage
	if err := json.Unmarshal(rewrittenOpen, &parsedOpen); err != nil {
		t.Fatalf("failed to unmarshal rewritten didOpen: %v", err)
	}
	var parsedParams map[string]json.RawMessage
	_ = json.Unmarshal(parsedOpen["params"], &parsedParams)
	var parsedTextDoc map[string]json.RawMessage
	_ = json.Unmarshal(parsedParams["textDocument"], &parsedTextDoc)

	var rewrittenURI string
	_ = json.Unmarshal(parsedTextDoc["uri"], &rewrittenURI)
	expectedURI := "file:///workspaces/" + slug + "/main.go"
	if rewrittenURI != expectedURI {
		t.Fatalf("expected rewritten URI %s, got %s", expectedURI, rewrittenURI)
	}

	var rewrittenText string
	_ = json.Unmarshal(parsedTextDoc["text"], &rewrittenText)
	if rewrittenText != sourceCode {
		t.Fatalf("source code was modified!\nExpected:\n%s\nGot:\n%s", sourceCode, rewrittenText)
	}

	// 2. Test textDocument/didChange
	didChangePayload := map[string]any{
		"jsonrpc": "2.0",
		"method":  "textDocument/didChange",
		"params": map[string]any{
			"textDocument": map[string]any{
				"uri":     "file:///Users/testuser/projects/velo/main.go",
				"version": 2,
			},
			"contentChanges": []map[string]any{
				{
					"text": "// Path in /Users/testuser/projects/velo still preserved\n",
				},
			},
		},
	}
	didChangeBytes, _ := json.Marshal(didChangePayload)
	rewrittenChange := tr.RewriteHostToGuest(didChangeBytes)

	var parsedChange map[string]json.RawMessage
	_ = json.Unmarshal(rewrittenChange, &parsedChange)
	var changeParams map[string]json.RawMessage
	_ = json.Unmarshal(parsedChange["params"], &changeParams)
	var changeTextDoc map[string]json.RawMessage
	_ = json.Unmarshal(changeParams["textDocument"], &changeTextDoc)

	var changeURI string
	_ = json.Unmarshal(changeTextDoc["uri"], &changeURI)
	if changeURI != expectedURI {
		t.Fatalf("expected change URI %s, got %s", expectedURI, changeURI)
	}

	var changes []map[string]any
	_ = json.Unmarshal(changeParams["contentChanges"], &changes)
	if changes[0]["text"] != "// Path in /Users/testuser/projects/velo still preserved\n" {
		t.Fatalf("contentChanges text was modified: %v", changes[0]["text"])
	}
}

func TestRewritingConn_FramingAndContentLength(t *testing.T) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)

	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	defer serverConn.Close()

	rewriter := NewRewritingConn(clientConn, tr)

	// Client writes a message with Host URI
	msgBody := `{"jsonrpc":"2.0","method":"textDocument/hover","params":{"textDocument":{"uri":"file:///Users/testuser/projects/velo/main.go"},"position":{"line":1,"character":5}}}`
	framedMsg := fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(msgBody), msgBody)

	go func() {
		_, _ = rewriter.Write([]byte(framedMsg))
	}()

	// Server reads the message from the raw pipe
	buf := make([]byte, 1024)
	n, err := serverConn.Read(buf)
	if err != nil {
		t.Fatalf("server failed to read: %v", err)
	}
	received := string(buf[:n])

	// Verify Content-Length was recalculated correctly
	if !strings.HasPrefix(received, "Content-Length: ") {
		t.Fatalf("expected Content-Length header, got: %s", received)
	}
	parts := strings.SplitN(received, "\r\n\r\n", 2)
	header := parts[0]
	body := parts[1]

	var declaredLen int
	_, _ = fmt.Sscanf(header, "Content-Length: %d", &declaredLen)
	if len(body) != declaredLen {
		t.Fatalf("Content-Length mismatch: header declared %d, body is %d bytes", declaredLen, len(body))
	}

	// Verify body contains rewritten guest path
	slug := vmexec.WorkspaceSlug(wsRoot)
	expectedGuestURI := "file:///workspaces/" + slug + "/main.go"
	if !strings.Contains(body, expectedGuestURI) {
		t.Fatalf("body does not contain rewritten guest URI %s: %s", expectedGuestURI, body)
	}
}

func TestRewritingConn_DiagnosticsRewriting(t *testing.T) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)
	slug := vmexec.WorkspaceSlug(wsRoot)

	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	defer serverConn.Close()

	rewriter := NewRewritingConn(clientConn, tr)

	// Gopls server sends publishDiagnostics with guest URI
	diagBody := fmt.Sprintf(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspaces/%s/main.go","diagnostics":[{"message":"syntax error"}]}}`, slug)
	framedDiag := fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(diagBody), diagBody)

	go func() {
		_, _ = serverConn.Write([]byte(framedDiag))
	}()

	// Client reads through rewriter
	buf := make([]byte, 1024)
	n, err := rewriter.Read(buf)
	if err != nil {
		t.Fatalf("rewriter failed to read: %v", err)
	}
	received := string(buf[:n])

	parts := strings.SplitN(received, "\r\n\r\n", 2)
	body := parts[1]

	expectedHostURI := "file:///Users/testuser/projects/velo/main.go"
	if !strings.Contains(body, expectedHostURI) {
		t.Fatalf("diagnostics did not translate back to host URI %s:\n%s", expectedHostURI, body)
	}
}

func TestURITranslator_RewriteHostToGuest_EscapedSlashes(t *testing.T) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)
	slug := vmexec.WorkspaceSlug(wsRoot)

	escapedHover := `{"jsonrpc":"2.0","method":"textDocument\/hover","params":{"position":{"line":31,"character":41},"textDocument":{"uri":"file:\/\/\/Users\/testuser\/projects\/velo\/backend\/cmd\/main.go"}},"id":4294967299}`
	rewritten := string(tr.RewriteHostToGuest([]byte(escapedHover)))
	expectedGuestURI := "file:///workspaces/" + slug + "/backend/cmd/main.go"
	if !strings.Contains(rewritten, expectedGuestURI) {
		t.Fatalf("expected rewritten payload to contain %s, got: %s", expectedGuestURI, rewritten)
	}
}

func BenchmarkURITranslator_RewriteHostToGuest(b *testing.B) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)
	payload := []byte(`{"jsonrpc":"2.0","id":42,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///Users/testuser/projects/velo/core/lsp/server.go"},"position":{"line":120,"character":18}}}`)
	b.ReportAllocs()
	b.SetBytes(int64(len(payload)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = tr.RewriteHostToGuest(payload)
	}
}

func BenchmarkURITranslator_RewriteGuestToHost(b *testing.B) {
	wsRoot := "/Users/testuser/projects/velo"
	tr := NewURITranslator(wsRoot)
	slug := vmexec.WorkspaceSlug(wsRoot)
	payload := []byte(fmt.Sprintf(`{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///workspaces/%s/core/lsp/server.go","diagnostics":[{"range":{"start":{"line":10,"character":2},"end":{"line":10,"character":15}},"severity":1,"message":"undefined: foo in /workspaces/%s/core/lsp/server.go"}]}}`, slug, slug))
	b.ReportAllocs()
	b.SetBytes(int64(len(payload)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = tr.RewriteGuestToHost(payload)
	}
}

