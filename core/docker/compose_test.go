package docker

import (
	"strings"
	"testing"
)

const composeText = "services:\n  web:\n    image: nginx\n    ports: 12\n    environment:\n      A: b\n  db:\n    image: postgres\n"

func TestParseComposeErrors(t *testing.T) {
	cases := []struct {
		name, stderr string
		line, col    int
		msg          string
	}{
		{"schema key path", "validating /p/compose.yml: services.web.ports must be a array", 3, 4, "services.web.ports must be a array"},
		{"additional property", "validating /p/compose.yml: services.db additional properties 'foo' not allowed", 6, 2, "services.db additional properties 'foo' not allowed"},
		{"undefined dependency", `service "db" depends on undefined service "cache": invalid compose project`, 6, 2, `service "db" depends on undefined service "cache": invalid compose project`},
		{"yaml problem mark", "yaml: while parsing a block mapping at line 1, column 3: line 3, column 4: did not find expected key", 2, 3, ""},
		{"yaml line only", "yaml: while scanning a plain scalar at line 3, column 12: line 4: found a tab character that violates indentation", 3, 4, ""},
		{"construct errors", "failed to parse /p/compose.yml: yaml: construct errors:\n  line 1: line 7: mapping key \"db\" already defined at line 2", 6, 2, `line 1: line 7: mapping key "db" already defined at line 2`},
		{"file position", "compose.yml:5:7: unexpected value", 4, 6, ""},
		{"unlocated", "invalid containerPort: abc", 0, 0, "invalid containerPort: abc"},
		{"beyond end", "yaml: line 99: oops", 7, 4, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := parseComposeErrors(tc.stderr, "compose.yml", composeText)
			if len(d) != 1 {
				t.Fatalf("diagnostics = %+v", d)
			}
			if d[0].Line != tc.line || d[0].Col != tc.col || d[0].Severity != 1 || d[0].EndLine != tc.line || d[0].EndCol < d[0].Col {
				t.Fatalf("got %+v, want %d:%d", d[0], tc.line, tc.col)
			}
			if tc.msg != "" && d[0].Message != tc.msg {
				t.Fatalf("message = %q, want %q", d[0].Message, tc.msg)
			}
		})
	}
}

func TestLocateKeyPathStaysInParent(t *testing.T) {
	text := "services:\n  web:\n    image: a\n  db:\n    ports: []\n"
	if got := locateKeyPath(strings.Split(text, "\n"), []string{"services", "web", "ports"}); got != 1 {
		t.Fatalf("ports under web = %d, want 1 (web itself)", got)
	}
	if got := locateKeyPath(strings.Split(text, "\n"), []string{"volumes"}); got != -1 {
		t.Fatalf("missing root = %d", got)
	}
}
