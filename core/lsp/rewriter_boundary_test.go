package lsp

import (
	"strings"
	"testing"
)

func TestReplaceBoundedRespectsPathBoundaries(t *testing.T) {
	cases := []struct{ in, want string }{
		{`"/ws/app"`, `"/G"`},
		{`"/ws/app/main.go"`, `"/G/main.go"`},
		{`"/ws/app-labs/main.go"`, `"/ws/app-labs/main.go"`},
		{`"/ws/app2/x"`, `"/ws/app2/x"`},
		{`"/ws/app.bak/x"`, `"/ws/app.bak/x"`},
		{`/ws/app:12:3`, `/G:12:3`},
		{`/ws/app`, `/G`},
		{`a /ws/app/x and /ws/app-labs/y and /ws/app`, `a /G/x and /ws/app-labs/y and /G`},
		{`no match here`, `no match here`},
	}
	for _, c := range cases {
		if got := string(replaceBounded([]byte(c.in), []byte("/ws/app"), []byte("/G"))); got != c.want {
			t.Errorf("replaceBounded(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestTranslatorLeavesSiblingWorkspaceURIsAlone(t *testing.T) {
	root := "/Users/dev/WorkSpace/lms-saas"
	tr := NewURITranslator(root)
	inside := tr.TranslateHostURI("file://" + root + "/backend/main.go")
	if !strings.HasPrefix(inside, "file:///workspaces/") || !strings.HasSuffix(inside, "/backend/main.go") {
		t.Fatalf("inside URI not translated: %q", inside)
	}
	sibling := "file:///Users/dev/WorkSpace/lms-saas-labs/main.go"
	if got := tr.TranslateHostURI(sibling); got != sibling {
		t.Fatalf("sibling URI rewritten: %q", got)
	}
	if back := tr.TranslateGuestURI(inside); back != "file://"+root+"/backend/main.go" {
		t.Fatalf("round trip = %q", back)
	}
}
