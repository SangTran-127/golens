package lsp

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"golang.org/x/text/unicode/norm"

	"golens/core/vmexec"
)

const (
	testHostGoroot = "/Users/dev/Library/Containers/dev.golens.app/Data/Library/Application Support/GoLens/VMRuntime/goroot"
	testHostMod    = "/Users/dev/go/pkg/mod"
)

func testTranslator(root string) *URITranslator {
	return NewURITranslatorWithRoots(TranslatorRoots{
		HostWorkspace:  root,
		GuestWorkspace: "/workspaces/" + vmexec.WorkspaceSlug(root),
		HostModCache:   testHostMod,
		HostGoroot:     testHostGoroot,
	})
}

func TestStdlibURIsMapBothWays(t *testing.T) {
	tr := testTranslator("/Users/dev/proj")
	guest := "file:///usr/local/go/src/fmt/print.go"
	host := tr.TranslateGuestURI(guest)
	want := pathToURI(testHostGoroot + "/src/fmt/print.go")
	if host != want {
		t.Fatalf("guest stdlib URI -> %q, want %q", host, want)
	}
	if back := tr.TranslateHostURI(host); back != guest {
		t.Fatalf("host stdlib URI -> %q, want %q", back, guest)
	}
	swiftStyle := "file://" + strings.ReplaceAll(testHostGoroot, " ", "%20") + "/src/fmt/print.go"
	if back := tr.TranslateHostURI(swiftStyle); back != guest {
		t.Fatalf("Swift-encoded stdlib URI -> %q, want %q", back, guest)
	}
	if got := tr.TranslateGuestURI("file:///usr/local/gopher/x.go"); got != "file:///usr/local/gopher/x.go" {
		t.Fatalf("sibling of guest GOROOT rewritten: %q", got)
	}
}

func TestStdlibLocationsInResponsesMapToHost(t *testing.T) {
	tr := testTranslator("/Users/dev/proj")
	body := `{"jsonrpc":"2.0","id":4294967301,"result":[{"uri":"file:///usr/local/go/src/net/http/server.go","range":{}}]}`
	got := string(tr.RewriteGuestToHost([]byte(body)))
	if !strings.Contains(got, pathToURI(testHostGoroot+"/src/net/http/server.go")) {
		t.Fatalf("definition into stdlib not mapped to host: %s", got)
	}
	hover := `{"result":{"contents":{"value":"defined in /usr/local/go/src/fmt/print.go:10 and [link](file:///usr/local/go/src/fmt/print.go#L10)"}}}`
	got = string(tr.RewriteGuestToHost([]byte(hover)))
	if !strings.Contains(got, "defined in "+testHostGoroot+"/src/fmt/print.go:10") {
		t.Fatalf("raw stdlib path in hover not mapped: %s", got)
	}
	if !strings.Contains(got, "[link]("+pathToURI(testHostGoroot+"/src/fmt/print.go")+"#L10)") {
		t.Fatalf("markdown link into stdlib not mapped: %s", got)
	}
}

func swiftFileURI(p string) string {
	var b strings.Builder
	b.WriteString("file://")
	for _, c := range []byte(norm.NFD.String(p)) {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', strings.IndexByte("-._~!$&'()*+,;=:@/", c) >= 0:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

func TestHostURIEncodingVariantsAllReachGuest(t *testing.T) {
	roots := []string{
		"/Users/dev/Dự án/Tài (copy)!",
		"/Users/dev/My Projects/velo",
		"/Users/dev/a+b@c/x~y",
		"/Users/dev/projects/velo",
	}
	for _, root := range roots {
		tr := testTranslator(root)
		wantURI := encodeFileURI(tr.GuestWorkspaceRoot + "/pkg/Tài liệu.go")
		file := root + "/pkg/Tài liệu.go"
		variants := map[string]string{
			"go NFC":    pathToURI(norm.NFC.String(file)),
			"go NFD":    pathToURI(norm.NFD.String(file)),
			"swift":     swiftFileURI(file),
			"raw NFC":   "file://" + norm.NFC.String(file),
			"raw NFD":   "file://" + norm.NFD.String(file),
			"localhost": "file://localhost" + strings.TrimPrefix(pathToURI(file), "file://"),
		}
		for name, uri := range variants {
			if got := tr.TranslateHostURI(uri); got != wantURI {
				t.Errorf("%s / %s: %q -> %q, want %q", root, name, uri, got, wantURI)
			}
			body := fmt.Sprintf(`{"jsonrpc":"2.0","id":4294967297,"method":"textDocument/references","params":{"textDocument":{"uri":%q},"position":{"line":1,"character":2}}}`, uri)
			out := tr.RewriteHostToGuest([]byte(body))
			var msg struct {
				Params struct {
					TextDocument struct {
						URI string `json:"uri"`
					} `json:"textDocument"`
				} `json:"params"`
			}
			if err := json.Unmarshal(out, &msg); err != nil {
				t.Fatalf("%s / %s: rewritten body is not JSON: %v\n%s", root, name, err, out)
			}
			if msg.Params.TextDocument.URI != wantURI {
				t.Errorf("%s / %s: body uri %q, want %q", root, name, msg.Params.TextDocument.URI, wantURI)
			}
		}
		back := tr.TranslateGuestURI(wantURI)
		if back != pathToURI(root+"/pkg/Tài liệu.go") {
			t.Errorf("%s: guest -> host %q, want %q", root, back, pathToURI(root+"/pkg/Tài liệu.go"))
		}
	}
}

func TestEscapedSlashVariants(t *testing.T) {
	root := "/Users/dev/proj"
	tr := testTranslator(root)
	body := `{"method":"textDocument\/hover","params":{"textDocument":{"uri":"file:\/\/\/Users\/dev\/proj\/a.go"},"note":"C:\\\/tmp","n2":"x\\\\\/y"}}`
	out := tr.RewriteHostToGuest([]byte(body))
	var msg struct {
		Method string `json:"method"`
		Params struct {
			TextDocument struct {
				URI string `json:"uri"`
			} `json:"textDocument"`
			Note string `json:"note"`
			N2   string `json:"n2"`
		} `json:"params"`
	}
	if err := json.Unmarshal(out, &msg); err != nil {
		t.Fatalf("not JSON after unescape: %v\n%s", err, out)
	}
	if msg.Method != "textDocument/hover" || msg.Params.TextDocument.URI != "file://"+tr.GuestWorkspaceRoot+"/a.go" {
		t.Fatalf("escaped hover not rewritten: %+v", msg)
	}
	if msg.Params.Note != `C:\/tmp` {
		t.Fatalf(`"\\\/" decoded to %q, want C:\/tmp`, msg.Params.Note)
	}
	if msg.Params.N2 != `x\\/y` {
		t.Fatalf(`"\\\\\/" decoded to %q, want x\\/y`, msg.Params.N2)
	}
	cases := map[string]string{
		`"\\/"`:    `"\\/"`,
		`"\/"`:     `"/"`,
		`"\\\/"`:   `"\\/"`,
		`"a\"\/"`:  `"a\"/"`,
		`"\u002f"`: `"\u002f"`,
		`"tail\`:   `"tail\`,
	}
	for in, want := range cases {
		if got := string(unescapeJSONSlashes([]byte(in))); got != want {
			t.Errorf("unescapeJSONSlashes(%s) = %s, want %s", in, got, want)
		}
	}
}

func TestDidOpenFromSwiftEncodingKeepsText(t *testing.T) {
	root := "/Users/dev/Dự án/Tài (copy)!"
	tr := testTranslator(root)
	text := "// see " + swiftFileURI(root+"/a.go") + " and " + root + "\npackage a\n"
	body, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "method": "textDocument/didOpen",
		"params": map[string]any{"textDocument": map[string]any{"uri": swiftFileURI(root + "/a.go"), "languageId": "go", "version": 1, "text": text}},
	})
	var msg struct {
		Params struct {
			TextDocument struct {
				URI  string `json:"uri"`
				Text string `json:"text"`
			} `json:"textDocument"`
		} `json:"params"`
	}
	if err := json.Unmarshal(tr.RewriteHostToGuest(body), &msg); err != nil {
		t.Fatal(err)
	}
	if msg.Params.TextDocument.URI != encodeFileURI(tr.GuestWorkspaceRoot+"/a.go") {
		t.Fatalf("didOpen uri = %q", msg.Params.TextDocument.URI)
	}
	if msg.Params.TextDocument.Text != text {
		t.Fatalf("didOpen text changed: %q", msg.Params.TextDocument.Text)
	}
}

func TestPathBoundaries(t *testing.T) {
	root := "/Users/dev/proj"
	tr := testTranslator(root)
	g := tr.GuestWorkspaceRoot
	cases := []struct{ name, in, want string }{
		{"embedded prefix", `"/Volumes/x/Users/dev/proj/a.go"`, `"/Volumes/x/Users/dev/proj/a.go"`},
		{"sibling", `"/Users/dev/project/a.go"`, `"/Users/dev/project/a.go"`},
		{"non-ascii sibling", `"/Users/dev/projà/a.go"`, `"/Users/dev/projà/a.go"`},
		{"nfd sibling", `"/Users/dev/proja` + "\u0300" + `/a.go"`, `"/Users/dev/proja` + "\u0300" + `/a.go"`},
		{"exact", `"/Users/dev/proj"`, `"` + g + `"`},
		{"line suffix", `at /Users/dev/proj/a.go:3:1`, `at ` + g + `/a.go:3:1`},
		{"uri inside other uri", `"file:///Volumes/x/Users/dev/proj/a.go"`, `"file:///Volumes/x/Users/dev/proj/a.go"`},
		{"uri sibling", `"file:///Users/dev/proj-labs/a.go"`, `"file:///Users/dev/proj-labs/a.go"`},
		{"uri with query", `"file:///Users/dev/proj/a.go#L3"`, `"file://` + g + `/a.go#L3"`},
		{"remote authority", `"file://server/Users/dev/proj/a.go"`, `"file://server/Users/dev/proj/a.go"`},
	}
	for _, c := range cases {
		if got := string(tr.RewriteHostToGuest([]byte(c.in))); got != c.want {
			t.Errorf("%s: %s -> %s, want %s", c.name, c.in, got, c.want)
		}
	}
	back := []struct{ name, in, want string }{
		{"embedded guest", `"/x/workspaces/` + strings.TrimPrefix(g, "/workspaces/") + `/a.go"`, `"/x/workspaces/` + strings.TrimPrefix(g, "/workspaces/") + `/a.go"`},
		{"guest sibling", `"file://` + g + `x/a.go"`, `"file://` + g + `x/a.go"`},
		{"guest exact", `"file://` + g + `"`, `"file://` + root + `"`},
		{"mod cache", `"file:///cache/gomod/github.com/a/b@v1.0.0/c.go"`, `"file://` + testHostMod + `/github.com/a/b@v1.0.0/c.go"`},
		{"mod cache sibling", `"file:///cache/gomodx/a.go"`, `"file:///cache/gomodx/a.go"`},
	}
	for _, c := range back {
		if got := string(tr.RewriteGuestToHost([]byte(c.in))); got != c.want {
			t.Errorf("%s: %s -> %s, want %s", c.name, c.in, got, c.want)
		}
	}
}

func TestWorkspaceInsideModCachePrefersLongestRoot(t *testing.T) {
	root := testHostMod + "/github.com/a/b@v1.0.0"
	tr := testTranslator(root)
	got := tr.TranslateHostURI("file://" + root + "/c.go")
	if got != "file://"+tr.GuestWorkspaceRoot+"/c.go" {
		t.Fatalf("workspace inside module cache mapped to %q", got)
	}
}

func BenchmarkURITranslator_RewriteHostToGuestSwiftEncoded(b *testing.B) {
	root := "/Users/dev/Dự án/Tài (copy)!"
	tr := testTranslator(root)
	payload := []byte(fmt.Sprintf(`{"jsonrpc":"2.0","id":4294967297,"method":"textDocument/references","params":{"textDocument":{"uri":%q},"position":{"line":120,"character":18},"context":{"includeDeclaration":true}}}`, swiftFileURI(root+"/core/lsp/server.go")))
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = tr.RewriteHostToGuest(payload)
	}
}
