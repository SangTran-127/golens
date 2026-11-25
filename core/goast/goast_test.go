package goast

import (
	"reflect"
	"strings"
	"testing"
)

const src = `package main

func run(n int, name string) (total int) {
	i := 0
	for j := 0; j < n; j++ {
		k := j * 2
		total += k
	}
	if x := n; x > 0 {
		i = x
	}
	msg := name + "!"
	i++
	_ = msg
	return total
}
`

func TestInlineValueLinesMapsToDeclarationsAndAssignments(t *testing.T) {
	got := InlineValueLines([]byte(src), 14, []string{"n", "name", "total", "i", "j", "k", "x", "msg", "(shadow)"})
	want := map[string]int{"n": 3, "name": 3, "total": 7, "i": 13, "msg": 12}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestInlineValueLinesInsideLoopShowsLoopVariables(t *testing.T) {
	got := InlineValueLines([]byte(src), 7, []string{"i", "j", "k", "total"})
	want := map[string]int{"i": 4, "j": 5, "k": 6, "total": 3}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}

func TestInlineValueLinesSkipsCurrentLineAndOutOfRange(t *testing.T) {
	if got := InlineValueLines([]byte(src), 4, []string{"i"}); len(got) != 0 {
		t.Fatalf("assignment on the stopped line was shown: %v", got)
	}
	if got := InlineValueLines([]byte(src), 999, []string{"i"}); len(got) != 0 {
		t.Fatalf("out of range: %v", got)
	}
	if got := InlineValueLines([]byte("package x\nvar a = 1\n"), 2, []string{"a"}); len(got) != 0 {
		t.Fatalf("outside a function: %v", got)
	}
}

func TestDeclarationAt(t *testing.T) {
	cases := map[string]bool{"run": true, "name": true, "total": true, "msg": true, "j": true}
	for word, want := range cases {
		off := strings.Index(src, word)
		if word == "msg" {
			off = strings.Index(src, "msg :=")
		}
		name, ok := DeclarationAt([]byte(src), off+1)
		if ok != want || name != word {
			t.Fatalf("%s: got %q %v", word, name, ok)
		}
	}
	use := strings.Index(src, "_ = msg") + 4
	if name, ok := DeclarationAt([]byte(src), use+1); ok {
		t.Fatalf("usage reported as declaration: %q", name)
	}
	broken := "package x\nfunc renamed(a int) {\n\treturn a +\n}\n"
	if name, ok := DeclarationAt([]byte(broken), strings.Index(broken, "renamed")+3); !ok || name != "renamed" {
		t.Fatalf("partial AST: %q %v", name, ok)
	}
}

func TestInlineValueLinesInsideClosureIncludesCapturedVariables(t *testing.T) {
	src := "package x\n\nfunc f(list []int) {\n\tfor _, v := range list {\n\t\trun(func() {\n\t\t\tw := v + 1\n\t\t\t_ = w\n\t\t})\n\t}\n}\n\nfunc run(func()) {}\n"
	got := InlineValueLines([]byte(src), 7, []string{"v", "w", "list"})
	want := map[string]int{"v": 4, "w": 6, "list": 3}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
}
