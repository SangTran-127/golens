package syntaxcheck

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestValidSourceHasNoIssues(t *testing.T) {
	src := "package demo\n\nimport \"fmt\"\n\nfunc Hello() { fmt.Println(\"hi\") }\n"
	result := Check("demo/hello.go", []byte(src))
	if len(result.Issues) != 0 {
		t.Fatalf("expected no issues, got %v", result.Issues)
	}
}

func TestMissingBraceReportsLineAndColumn(t *testing.T) {
	src := "package demo\n\nfunc Broken() {\n\tif true {\n\t\treturn\n}\n"
	result := Check("demo/broken.go", []byte(src))
	if len(result.Issues) == 0 {
		t.Fatal("expected a syntax issue")
	}
	first := result.Issues[0]
	if first.Path != "demo/broken.go" || first.Line < 1 || first.Column < 1 {
		t.Fatalf("unexpected position %+v", first)
	}
	if !strings.HasPrefix(first.String(), "demo/broken.go:") {
		t.Fatalf("unexpected format %q", first.String())
	}
}

func TestMissingPackageClauseIsReported(t *testing.T) {
	result := Check("x.go", []byte("func main() {}\n"))
	if len(result.Issues) == 0 || result.Issues[0].Line != 1 {
		t.Fatalf("expected an issue on line 1, got %+v", result.Issues)
	}
	if !strings.Contains(result.Issues[0].Message, "package") {
		t.Fatalf("expected a package clause message, got %q", result.Issues[0].Message)
	}
}

func TestIssueCountIsBounded(t *testing.T) {
	var b strings.Builder
	b.WriteString("package demo\n")
	for i := 0; i < 200; i++ {
		b.WriteString("func f() { var x = }\n")
	}
	result := Check("many.go", []byte(b.String()))
	if len(result.Issues) > MaxIssues {
		t.Fatalf("expected at most %d issues, got %d", MaxIssues, len(result.Issues))
	}
}

func TestCheckJSONRoundTrips(t *testing.T) {
	raw := CheckJSON("a.go", []byte("package a\nfunc (\n"))
	var decoded Result
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		t.Fatalf("invalid JSON %q: %v", raw, err)
	}
	if len(decoded.Issues) == 0 || decoded.Issues[0].Path != "a.go" {
		t.Fatalf("unexpected decoded result %+v", decoded)
	}
	clean := CheckJSON("b.go", []byte("package b\n"))
	if clean != `{"issues":[],"truncated":false}` {
		t.Fatalf("unexpected clean JSON %q", clean)
	}
}
