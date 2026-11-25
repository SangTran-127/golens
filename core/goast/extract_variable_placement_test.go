package goast

import (
	"go/format"
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

func TestExtractVariablePlacesDeclarationInsideTheBlock(t *testing.T) {
	cases := []struct {
		name, src, expr, want string
	}{
		{
			name: "one-line function",
			src:  "package p\n\nfunc f(a, b int) int { return a*b + 1 }\n",
			expr: "a*b",
			want: "func f(a, b int) int {\n\tv := a * b\n\treturn v + 1\n}",
		},
		{
			name: "same line as case",
			src:  "package p\n\nfunc f(x, a int) int {\n\tswitch x {\n\tcase 1: return a * 2\n\t}\n\treturn 0\n}\n",
			expr: "a * 2",
			want: "\tcase 1:\n\t\tv := a * 2\n\t\treturn v\n",
		},
		{
			name: "statement under case",
			src:  "package p\n\nfunc f(x, a int) int {\n\tswitch x {\n\tcase 1:\n\t\treturn a * 2\n\t}\n\treturn 0\n}\n",
			expr: "a * 2",
			want: "\tcase 1:\n\t\tv := a * 2\n\t\treturn v\n",
		},
		{
			name: "if condition",
			src:  "package p\n\nfunc f(a int) bool {\n\tif a*3 > 9 {\n\t\treturn true\n\t}\n\treturn false\n}\n",
			expr: "a*3",
			want: "\tv := a * 3\n\tif v > 9 {\n",
		},
		{
			name: "closure body",
			src:  "package p\n\nfunc f(a int) func() int {\n\treturn func() int { return a + 7 }\n}\n",
			expr: "a + 7",
			want: "return func() int {\n\t\tv := a + 7\n\t\treturn v\n\t}",
		},
	}
	for _, c := range cases {
		start := strings.Index(c.src, c.expr)
		reply := ApplyExtractVariable(ExtractVarReq{Path: "/p/f.go", Src: c.src, StartByte: start, EndByte: start + len(c.expr), VarName: "v"})
		if reply.Error != "" {
			t.Errorf("%s: %s", c.name, reply.Error)
			continue
		}
		got := applyEditsToText(c.src, reply.EditsByPath["/p/f.go"])
		if _, err := parser.ParseFile(token.NewFileSet(), "f.go", got, parser.AllErrors); err != nil {
			t.Errorf("%s: result does not parse: %v\n%s", c.name, err, got)
			continue
		}
		if formatted, _ := format.Source([]byte(got)); string(formatted) != got {
			t.Errorf("%s: result is not gofmt-clean:\n%s", c.name, got)
		}
		if !strings.Contains(got, c.want) {
			t.Errorf("%s: missing %q in\n%s", c.name, c.want, got)
		}
	}
}

func TestExtractVariableRefusesWholeStatementsAndPackageLevel(t *testing.T) {
	stmt := "package p\n\nfunc g() {}\n\nfunc f() {\n\tg()\n}\n"
	start := strings.Index(stmt, "g()\n}")
	if r := ApplyExtractVariable(ExtractVarReq{Path: "/p/f.go", Src: stmt, StartByte: start, EndByte: start + 3}); !strings.Contains(r.Error, "whole statement") {
		t.Fatalf("whole statement: %+v", r)
	}
	pkg := "package p\n\nvar x = 1 + 2\n"
	start = strings.Index(pkg, "1 + 2")
	if r := ApplyExtractVariable(ExtractVarReq{Path: "/p/f.go", Src: pkg, StartByte: start, EndByte: start + 5}); r.Error == "" {
		t.Fatalf("package-level expression extracted: %+v", r)
	}
}

func TestExtractVariableKeepsUnrelatedLinesOutOfTheEdit(t *testing.T) {
	src := "package p\n\nfunc a() int {\n\treturn 1\n}\n\nfunc f(a, b int) int {\n\treturn a*b + 1\n}\n\nfunc z() int {\n\treturn 2\n}\n"
	start := strings.Index(src, "a*b")
	r := ApplyExtractVariable(ExtractVarReq{Path: "/p/f.go", Src: src, StartByte: start, EndByte: start + 3, VarName: "v"})
	edits := r.EditsByPath["/p/f.go"]
	if r.Error != "" || len(edits) != 1 {
		t.Fatalf("reply %+v", r)
	}
	if strings.Contains(edits[0].NewText, "func a()") || strings.Contains(edits[0].NewText, "func z()") {
		t.Fatalf("edit spans unrelated functions: %q", edits[0].NewText)
	}
}
