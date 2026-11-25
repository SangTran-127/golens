package analysis

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"testing"
)

func rescanEveryFixLoop[C any](f lastCandidateFixer[C], src string) (string, int, []C) {
	current := src
	fixed := 0
	var appliedOrder []C
	for pass := 0; pass < f.maxFixes; pass++ {
		cands, ok, _ := f.scan(current)
		if !ok {
			break
		}
		chosen := -1
		for i := len(cands) - 1; i >= 0; i-- {
			if f.fixable(cands[i]) {
				chosen = i
				break
			}
		}
		if chosen < 0 {
			break
		}
		updated, applied := f.apply(current, cands[chosen])
		if !applied || updated == current {
			break
		}
		current = updated
		fixed++
		appliedOrder = append(appliedOrder, cands[chosen])
	}
	return current, fixed, appliedOrder
}

func harvestGoFixtures(t *testing.T, testFile string) []string {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, testFile, nil, 0)
	if err != nil {
		t.Fatalf("parse %s: %v", testFile, err)
	}
	seen := make(map[string]bool)
	var out []string
	ast.Inspect(file, func(n ast.Node) bool {
		expr, ok := n.(ast.Expr)
		if !ok {
			return true
		}
		val, ok := foldStringLiteral(expr)
		if !ok {
			return true
		}
		if !strings.HasPrefix(strings.TrimSpace(val), "package ") || seen[val] {
			return false
		}
		seen[val] = true
		out = append(out, val)
		if dup := duplicateFuncDecls(val); dup != "" && !seen[dup] {
			seen[dup] = true
			out = append(out, dup)
		}
		return false
	})
	return out
}

func foldStringLiteral(expr ast.Expr) (string, bool) {
	switch e := expr.(type) {
	case *ast.BasicLit:
		if e.Kind != token.STRING {
			return "", false
		}
		val, err := strconv.Unquote(e.Value)
		return val, err == nil
	case *ast.BinaryExpr:
		if e.Op != token.ADD {
			return "", false
		}
		left, ok := foldStringLiteral(e.X)
		if !ok {
			return "", false
		}
		right, ok := foldStringLiteral(e.Y)
		if !ok {
			return "", false
		}
		return left + right, true
	case *ast.ParenExpr:
		return foldStringLiteral(e.X)
	}
	return "", false
}

func duplicateFuncDecls(src string) string {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "input.go", src, parser.ParseComments)
	if err != nil {
		return ""
	}
	var b strings.Builder
	b.WriteString(src)
	copies := 0
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Body == nil || fn.Name == nil {
			continue
		}
		start := fset.Position(fn.Pos()).Offset
		end := fset.Position(fn.End()).Offset
		nameOff := fset.Position(fn.Name.Pos()).Offset
		if start < 0 || end > len(src) || nameOff < start || nameOff >= end {
			continue
		}
		text := src[start:nameOff] + fn.Name.Name + "Copy" + src[nameOff+len(fn.Name.Name):end]
		b.WriteString("\n\n")
		b.WriteString(text)
		b.WriteString("\n")
		copies++
	}
	if copies == 0 {
		return ""
	}
	return b.String()
}

func checkFixerMatchesRescanLoop[C any](t *testing.T, name string, fixer lastCandidateFixer[C], fixtures []string) {
	t.Helper()
	multi := 0
	newScans, oldScans := 0, 0
	for i, src := range fixtures {
		var gotApplied []C
		f := fixer
		f.applied = func(c C) { gotApplied = append(gotApplied, c) }
		f.scan = func(s string) ([]C, bool, error) {
			newScans++
			return fixer.scan(s)
		}
		gotSrc, gotCount, _ := f.run(src)
		ref := fixer
		ref.scan = func(s string) ([]C, bool, error) {
			oldScans++
			return fixer.scan(s)
		}
		wantSrc, wantCount, wantApplied := rescanEveryFixLoop(ref, src)
		if gotSrc != wantSrc || gotCount != wantCount {
			t.Fatalf("%s fixture %d: batched fixes differ from rescan loop (count %d vs %d)\n--- got\n%s\n--- want\n%s\n--- input\n%s", name, i, gotCount, wantCount, gotSrc, wantSrc, src)
		}
		if len(gotApplied) != len(wantApplied) {
			t.Fatalf("%s fixture %d: applied %d candidates, rescan loop applied %d", name, i, len(gotApplied), len(wantApplied))
		}
		if wantCount > 1 {
			multi++
		}
	}
	t.Logf("%s: %d fixtures, %d with multiple fixes, scans %d (rescan loop %d)", name, len(fixtures), multi, newScans, oldScans)
	if newScans >= oldScans {
		t.Errorf("%s: batched fixer scanned %d times, rescan loop %d; expected fewer", name, newScans, oldScans)
	}
	if multi == 0 {
		t.Errorf("%s: no fixture produced more than one fix; equivalence check is vacuous", name)
	}
}

func TestLastCandidateFixer_MatchesRescanEveryFixLoop(t *testing.T) {
	cases := []struct {
		name string
		run  func(t *testing.T, fixtures []string)
	}{
		{"unsafe", func(t *testing.T, fx []string) {
			checkFixerMatchesRescanLoop(t, "unsafe", unsafeSafetyFixer("input.go"), fx)
		}},
		{"numeric", func(t *testing.T, fx []string) {
			checkFixerMatchesRescanLoop(t, "numeric", numericSafetyFixer("input.go"), fx)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fixtures := harvestGoFixtures(t, tc.name+"_inspector_test.go")
			if len(fixtures) == 0 {
				t.Fatalf("no fixtures harvested for %s", tc.name)
			}
			tc.run(t, fixtures)
		})
	}
}

func TestLastCandidateFixer_RescansOnOverlapAndForNewFindings(t *testing.T) {
	type cand struct {
		start, end int
		text       string
	}
	scan := func(s string) ([]cand, bool, error) {
		var out []cand
		for i := 0; i+1 < len(s); i++ {
			if s[i] == 'a' && s[i+1] == 'a' {
				out = append(out, cand{start: i, end: i + 2, text: "b"})
			}
		}
		return out, true, nil
	}
	fixer := lastCandidateFixer[cand]{
		maxFixes: 64,
		scan:     scan,
		fixable:  func(cand) bool { return true },
		span:     func(_ string, c cand) (int, int, bool) { return c.start, c.end, true },
		apply: func(s string, c cand) (string, bool) {
			if c.end > len(s) || s[c.start:c.end] != "aa" {
				return s, false
			}
			return s[:c.start] + c.text + s[c.end:], true
		},
	}
	inputs := []string{"aaaa", "aaa", "xaayaaz", "aaaaaaaaab", "ab", ""}
	for _, in := range inputs {
		got, gotN, _ := fixer.run(in)
		want, wantN, _ := rescanEveryFixLoop(fixer, in)
		if got != want || gotN != wantN {
			t.Fatalf("input %q: got (%q,%d) want (%q,%d)", in, got, gotN, want, wantN)
		}
	}
}
