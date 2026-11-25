package lsp

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

func labels(items []completionItem, ranked []rankedItem) []string {
	out := make([]string, len(ranked))
	for i, r := range ranked {
		out[i] = items[r.index].Label
	}
	return out
}

func mkItems(labels ...string) []completionItem {
	items := make([]completionItem, len(labels))
	for i, l := range labels {
		items[i] = completionItem{Label: l, SortText: fmt.Sprintf("%05d", i)}
	}
	return items
}

func TestMatchTiers(t *testing.T) {
	cases := []struct {
		q, c string
		ok   bool
		tier int
		pos  []int
	}{
		{"Wr", "Write", true, tierExactCase, []int{0, 1}},
		{"wr", "WriteString", true, tierPrefix, []int{0, 1}},
		{"ws", "WriteString", true, tierWordStart, []int{0, 5}},
		{"wStr", "WriteString", true, tierWordStart, []int{0, 5, 6, 7}},
		{"rite", "WriteString", true, tierSubseq, []int{1, 2, 3, 4}},
		{"xyz", "WriteString", false, 0, nil},
		{"toolong", "to", false, 0, nil},
		{"nb", "new_buffer", true, tierWordStart, []int{0, 4}},
		{"", "anything", true, tierPrefix, nil},
	}
	for _, c := range cases {
		m, ok := matchCandidate(c.q, c.c)
		if ok != c.ok {
			t.Fatalf("%q~%q ok=%v want %v", c.q, c.c, ok, c.ok)
		}
		if !ok {
			continue
		}
		if tierOf(m.score) != c.tier {
			t.Errorf("%q~%q tier=%d want %d (score %d)", c.q, c.c, tierOf(m.score), c.tier, m.score)
		}
		if c.pos != nil && !reflect.DeepEqual(m.positions, c.pos) {
			t.Errorf("%q~%q positions=%v want %v", c.q, c.c, m.positions, c.pos)
		}
	}
}

func tierOf(score int) int {
	for tier := tierExactCase; tier >= tierSubseq; tier-- {
		if score > (tier-1)*1000 {
			return tier
		}
	}
	return 0
}

func TestRankingAfterTypingNarrowsInstantly(t *testing.T) {
	items := mkItems("b", "break", "bits", "bool", "Write", "WriteByte", "WriteRune", "WriteString", "Writer", "Reset")
	got := labels(items, rankItems(items, "Wr"))
	want := []string{"Write", "WriteByte", "WriteRune", "WriteString", "Writer"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Wr -> %v want %v", got, want)
	}
	got = labels(items, rankItems(items, "WrS"))
	if !reflect.DeepEqual(got, []string{"WriteString"}) {
		t.Fatalf("WrS -> %v", got)
	}
	for _, l := range labels(items, rankItems(items, "Wr")) {
		if l == "b" || l == "break" || l == "bool" {
			t.Fatalf("stale keyword %q survived filtering", l)
		}
	}
}

func TestRankingSortTextBreaksTies(t *testing.T) {
	items := []completionItem{
		{Label: "Println", SortText: "00002"},
		{Label: "Printf", SortText: "00001"},
		{Label: "Print", SortText: "00000"},
	}
	got := labels(items, rankItems(items, "Pr"))
	if !reflect.DeepEqual(got, []string{"Print", "Printf", "Println"}) {
		t.Fatalf("got %v", got)
	}
	items = []completionItem{{Label: "aXb", SortText: "1"}, {Label: "ab", SortText: "2"}}
	if got := labels(items, rankItems(items, "ab")); got[0] != "ab" {
		t.Fatalf("prefix must outrank sortText: %v", got)
	}
}

func TestRankingKeepsGoplsOrderWithoutLengthPenalty(t *testing.T) {
	items := []completionItem{
		{Label: "name", Kind: 5, SortText: "00000"},
		{Label: "naq", Kind: 9, SortText: "00001", AdditionalTextEdits: []textEdit{{NewText: "import \"github.com/go-playground/locales/naq\"\n"}}},
		{Label: "nakedret", Kind: 9, SortText: "00002", AdditionalTextEdits: []textEdit{{NewText: "import \"github.com/x/nakedret\"\n"}}},
		{Label: "nakedret", Kind: 9, SortText: "00003", AdditionalTextEdits: []textEdit{{NewText: "import \"github.com/x/nakedret\"\n"}}},
		{Label: "nat", Kind: 9, SortText: "00004", AdditionalTextEdits: []textEdit{{NewText: "import \"net/nat\"\n"}}},
		{Label: "nameOf", Kind: 3, SortText: "00005"},
	}
	got := labels(items, rankItems(items, "na"))
	if !reflect.DeepEqual(got, []string{"name", "naq", "nakedret", "nat", "nameOf"}) {
		t.Fatalf("unfiltered: %v", got)
	}
	g := moduleGraph{root: "/w", mods: []string{"example.com/app", "github.com/x"}, loaded: true}
	got = labels(items, rankItemsFor(items, "na", g.allowFunc("/w")))
	if !reflect.DeepEqual(got, []string{"name", "nakedret", "nat", "nameOf"}) {
		t.Fatalf("project filter and dedupe: %v", got)
	}
	if g.allowFunc("/other")("github.com/x/nakedret") {
		t.Fatal("graph of another root must not apply")
	}
	if !isStdlibPath("net/http") || isStdlibPath("github.com/a/b") {
		t.Fatal("stdlib detection")
	}
}

func TestDeprecatedSortsLast(t *testing.T) {
	items := []completionItem{{Label: "Old", SortText: "0", Deprecated: true}, {Label: "Other", SortText: "1"}}
	if got := labels(items, rankItems(items, "O")); got[0] != "Other" {
		t.Fatalf("got %v", got)
	}
	items = []completionItem{{Label: "Old", SortText: "0", Tags: []int{1}}, {Label: "Other", SortText: "1"}}
	if got := labels(items, rankItems(items, "O")); got[0] != "Other" {
		t.Fatalf("tag-deprecated: got %v", got)
	}
}

func TestFilterLatencyBudget(t *testing.T) {
	items := make([]completionItem, 1000)
	for i := range items {
		items[i] = completionItem{Label: fmt.Sprintf("SomeIdentifierNumber%dWithSuffix", i), SortText: fmt.Sprintf("%05d", i)}
	}
	start := time.Now()
	const runs = 20
	for i := 0; i < runs; i++ {
		rankItems(items, "sINW")
	}
	if per := time.Since(start) / runs; per > 2*time.Millisecond && !isRaceEnabled() {
		t.Fatalf("re-filter of 1000 items took %v (budget 2ms)", per)
	}
}

func TestDecideStateMachine(t *testing.T) {
	s := &completionSession{id: 1, path: "/a.go", anchor: 10, query: "Wr"}
	cases := []struct {
		name  string
		s     *completionSession
		path  string
		caret int
		query string
		want  completionAction
	}{
		{"typing inside session", s, "/a.go", 13, "Wri", actionShow},
		{"caret before anchor", s, "/a.go", 9, "", actionHide},
		{"non identifier typed", s, "/a.go", 14, "Wr(", actionHide},
		{"other document", s, "/b.go", 13, "Wri", actionRequery},
		{"no session", nil, "/a.go", 13, "Wri", actionRequery},
		{"incomplete list grows", &completionSession{path: "/a.go", anchor: 10, query: "W", incomplete: true}, "/a.go", 12, "Wr", actionShow},
		{"incomplete list unchanged", &completionSession{path: "/a.go", anchor: 10, query: "W", incomplete: true}, "/a.go", 11, "W", actionShow},
	}
	for _, c := range cases {
		if got := decide(c.s, c.path, c.caret, c.query); got != c.want {
			t.Errorf("%s: got %s want %s", c.name, got, c.want)
		}
	}
}

func TestStaleVersionDetection(t *testing.T) {
	d := &document{buf: NewFileBuffer([]byte("package main\n\nfunc f() { b.Wr }\n")), version: 5}
	if d.editedBefore(5, 26) {
		t.Fatal("no edits yet")
	}
	d.version++
	d.mark(28)
	if d.editedBefore(5, 26) {
		t.Fatal("typing after the anchor keeps the list valid")
	}
	d.version++
	d.mark(3)
	if !d.editedBefore(5, 26) {
		t.Fatal("an edit before the anchor makes the response stale")
	}
	for i := 0; i < editHistory+1; i++ {
		d.version++
		d.mark(100)
	}
	if !d.editedBefore(6, 26) {
		t.Fatal("history overflow must be treated as stale")
	}
}

func TestSessionFilterRowsAndCommit(t *testing.T) {
	raw := json.RawMessage(`{"isIncomplete":false,"items":[
	 {"label":"WriteString","kind":2,"detail":"func(s string) (n int, err error)","sortText":"00001","filterText":"WriteString","insertTextFormat":2,
	  "textEdit":{"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":4}},"newText":"WriteString(${1:s string})"},
	  "documentation":"WriteString appends the contents of s.\n\nMore text."},
	 {"label":"Write","kind":2,"detail":"func(p []byte) (n int, err error)","sortText":"00000","insertTextFormat":2,
	  "textEdit":{"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":4}},"newText":"Write(${1:p []byte})$0"}},
	 {"label":"Join","kind":3,"detail":"func(elems []string, sep string) string","sortText":"00002",
	  "labelDetails":{"detail":"(elems []string, sep string) string","description":"strings"},
	  "additionalTextEdits":[{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":0}},"newText":"import \"strings\"\n"}]},
	 {"label":"bool","kind":7,"sortText":"00003"}
	]}`)
	items, incomplete, err := parseCompletionList(raw)
	if err != nil || incomplete || len(items) != 4 {
		t.Fatalf("parse: %v %v %d", err, incomplete, len(items))
	}
	completions.mu.Lock()
	completions.session = &completionSession{id: 42, path: "/a.go", anchor: 2, items: items}
	completions.mu.Unlock()

	var res completionFilterResult
	_ = json.Unmarshal([]byte(FilterCompletion(42, "/a.go", 4, "Wr")), &res)
	if res.Action != "show" || len(res.Rows) != 2 || res.Rows[0].Label != "Write" {
		t.Fatalf("filter: %+v", res)
	}
	r := res.Rows[1]
	if r.Kind != "method" || r.Params != "(s string)" || r.Type != "(n int, err error)" || !reflect.DeepEqual(r.Matches, []int{0, 1}) {
		t.Fatalf("row: %+v", r)
	}
	_ = json.Unmarshal([]byte(FilterCompletion(42, "/a.go", 3, "J")), &res)
	if len(res.Rows) != 1 || res.Rows[0].Package != "strings" || res.Rows[0].Kind != "func" {
		t.Fatalf("unimported row: %+v", res.Rows)
	}
	_ = json.Unmarshal([]byte(FilterCompletion(42, "/a.go", 4, "zz")), &res)
	if res.Action != "show" || len(res.Rows) != 0 {
		t.Fatalf("no match keeps the session with zero rows: %+v", res)
	}
	_ = json.Unmarshal([]byte(FilterCompletion(42, "/a.go", 4, "Wr")), &res)
	if len(res.Rows) != 2 {
		t.Fatalf("backspace after a typo must bring rows back: %+v", res)
	}
	_ = json.Unmarshal([]byte(FilterCompletion(42, "/a.go", 1, "")), &res)
	if res.Action != "hide" {
		t.Fatalf("caret before the anchor ends the session: %+v", res)
	}
	_ = json.Unmarshal([]byte(FilterCompletion(7, "/a.go", 4, "Wr")), &res)
	if res.Action != "requery" {
		t.Fatalf("unknown session must requery: %+v", res)
	}

	var doc struct{ Signature, Doc string }
	_ = json.Unmarshal([]byte(CompletionDoc(42, 0)), &doc)
	if doc.Doc != "WriteString appends the contents of s." || doc.Signature == "" {
		t.Fatalf("doc: %+v", doc)
	}

	var c completionCommit
	_ = json.Unmarshal([]byte(CommitCompletion(42, 2, 3)), &c)
	if !c.OK || c.Text != "Join" || len(c.Additional) != 1 {
		t.Fatalf("commit unimported: %+v", c)
	}
	if _ = json.Unmarshal([]byte(CommitCompletion(42, 0, 4)), &c); c.OK {
		t.Fatal("session must end after commit")
	}
}

func TestIncompleteListFiltersLocallyAndRefreshesInBackground(t *testing.T) {
	items := mkItems("Write", "WriteByte", "WriteRune", "WriteString", "Reset", "Len", "Grow", "Cap", "String", "Truncate", "Writer", "WriteTo")
	s := &completionSession{id: 9, path: "/a.go", anchor: 2, incomplete: true, items: items}
	completions.mu.Lock()
	completions.session = s
	completions.mu.Unlock()
	var res completionFilterResult
	_ = json.Unmarshal([]byte(FilterCompletion(9, "/a.go", 3, "W")), &res)
	if res.Action != "show" || len(res.Rows) != 7 || !res.Refresh {
		t.Fatalf("incomplete list must show local rows and ask for a background refresh: %+v", res)
	}
	res = completionFilterResult{}
	_ = json.Unmarshal([]byte(FilterCompletion(9, "/a.go", 2, "")), &res)
	if res.Action != "show" || res.Refresh || len(res.Rows) != len(items) {
		t.Fatalf("unchanged query needs no refresh: %+v", res)
	}
	res = completionFilterResult{}
	_ = json.Unmarshal([]byte(FilterCompletion(9, "/a.go", 6, "rite")), &res)
	if res.Action != "show" || len(res.Rows) == 0 || res.Rows[0].Label != "Write" {
		t.Fatalf("subsequence filter keeps working locally: %+v", res)
	}
	completions.mu.Lock()
	completions.prev, completions.session = s, &completionSession{id: 10, path: "/a.go", anchor: 2, items: mkItems("Write")}
	completions.mu.Unlock()
	res = completionFilterResult{}
	_ = json.Unmarshal([]byte(FilterCompletion(9, "/a.go", 3, "W")), &res)
	if res.Action != "show" || len(res.Rows) == 0 {
		t.Fatalf("the replaced session keeps filtering until Swift adopts the refreshed one: %+v", res)
	}
}

func commitWith(t *testing.T, src string, item completionItem) string {
	t.Helper()
	freshStore(t)
	caret := strings.IndexByte(src, '|')
	content := src[:caret] + src[caret+1:]
	OpenDocument("/c.go", []byte(content))
	var snapLine, snapCol int
	docs.withDoc("/c.go", func(d *document) { snapLine, snapCol = d.buf.Position(caret) })
	completions.mu.Lock()
	completions.session = &completionSession{id: 77, path: "/c.go", version: 1, anchor: wordStart([]byte(content), caret), caret: caret, caretPos: lspPos{snapLine, snapCol}, items: []completionItem{item}}
	completions.mu.Unlock()
	var c completionCommit
	_ = json.Unmarshal([]byte(CommitCompletion(77, 0, caret)), &c)
	if !c.OK {
		t.Fatalf("commit failed: %+v", c)
	}
	return content[:c.Start] + c.Text + content[c.End:]
}

func edit(newText string, line, start, end int, replaceEnd int) completionItem {
	it := completionItem{Label: newText}
	it.TextEdit = &struct {
		Range   *lspRange `json:"range"`
		Insert  *lspRange `json:"insert"`
		Replace *lspRange `json:"replace"`
		NewText string    `json:"newText"`
	}{Insert: &lspRange{lspPos{line, start}, lspPos{line, end}}, Replace: &lspRange{lspPos{line, start}, lspPos{line, replaceEnd}}, NewText: newText}
	return it
}

func TestCommitUsesTheServerEditRange(t *testing.T) {
	got := commitWith(t, "package app\n\nimport \"example.com/go-ch|\"\n", edit("example.com/go-chi", 2, 8, 22, 22))
	if !strings.Contains(got, `import "example.com/go-chi"`) || strings.Contains(got, "go-go") {
		t.Fatalf("hyphenated import corrupted: %q", got)
	}
	got = commitWith(t, "package |\n", edit("package app", 0, 0, 8, 8))
	if got != "package app\n" {
		t.Fatalf("package clause corrupted: %q", got)
	}
	got = commitWith(t, "package p\n\nfunc f(u U) {\n\tu.Gre|et(\"hi\")\n}\n", edit("Greet", 3, 3, 6, 8))
	if !strings.Contains(got, "\tu.Greet(\"hi\")") {
		t.Fatalf("mid-word commit left the tail: %q", got)
	}
	plain := completionItem{Label: "Println"}
	got = commitWith(t, "package p\n\nfunc f() { fmt.Pri| }\n", plain)
	if !strings.Contains(got, "fmt.Println }") {
		t.Fatalf("fallback replaces the typed prefix: %q", got)
	}
}

func TestExpandSnippet(t *testing.T) {
	cases := []struct {
		in    string
		text  string
		stops []tabStop
		final int
	}{
		{"Write(${1:p []byte})$0", "Write(p []byte)", []tabStop{{1, 6, 8}}, 15},
		{"f(${1:a}, ${2:b})", "f(a, b)", []tabStop{{1, 2, 1}, {2, 5, 1}}, 7},
		{"for ${2:i} := range ${1:xs} {\n\t$0\n}", "for i := range xs {\n\t\n}", []tabStop{{1, 15, 2}, {2, 4, 1}}, 21},
		{"plain", "plain", []tabStop{}, 5},
		{`a\$b\}c`, "a$b}c", []tabStop{}, 5},
		{"g(${1})", "g()", []tabStop{{1, 2, 0}}, 3},
		{"x(${1:outer ${2:inner}})", "x(outer inner)", []tabStop{{1, 2, 11}, {2, 8, 5}}, 14},
		{"日本(${1:語})", "日本(語)", []tabStop{{1, 3, 1}}, 5},
		{"$", "$", []tabStop{}, 1},
	}
	for _, c := range cases {
		got := ExpandSnippet(c.in)
		if got.Text != c.text || !reflect.DeepEqual(got.Stops, c.stops) || got.Final != c.final {
			t.Errorf("%q -> %+v want text=%q stops=%v final=%d", c.in, got, c.text, c.stops, c.final)
		}
	}
}

func TestGoKindVocabulary(t *testing.T) {
	for kind, want := range map[int]string{3: "func", 2: "method", 6: "var", 21: "const", 5: "field", 7: "type", 8: "interface", 22: "struct", 9: "package", 14: "keyword", 15: "snippet"} {
		if got := goKind(kind); got != want {
			t.Errorf("kind %d -> %s want %s", kind, got, want)
		}
	}
}

func TestPostfixAliases(t *testing.T) {
	items := []completionItem{{Label: "ifnotnil!", SortText: "1"}, {Label: "iferr!", SortText: "2"}, {Label: "nnn", SortText: "0"}}
	if got := labels(items, rankItems(items, "nn")); len(got) == 0 || got[0] != "nnn" || got[1] != "ifnotnil!" {
		t.Fatalf("nn alias: %v", got)
	}
	if got := labels(items, rankItems(items, "rr")); len(got) != 1 || got[0] != "iferr!" {
		t.Fatalf("rr alias: %v", got)
	}
}

func TestUserOptionsMergeIntoSettings(t *testing.T) {
	SetUserOptions(map[string]bool{"shadow": true, "SA1000": false}, map[string]bool{"ignoredError": false})
	t.Cleanup(func() { SetUserOptions(nil, nil) })
	s := goplsSettings()
	a := s["analyses"].(map[string]bool)
	h := s["hints"].(map[string]bool)
	if !a["shadow"] || a["SA1000"] || !a["ST1005"] || h["ignoredError"] {
		t.Fatalf("settings %v %v", a, h)
	}
}

func TestInlayHintKindsOnByDefaultAndCanBeTurnedOff(t *testing.T) {
	SetUserOptions(nil, nil)
	t.Cleanup(func() { SetUserOptions(nil, nil) })
	h := goplsSettings()["hints"].(map[string]bool)
	for _, kind := range []string{"assignVariableTypes", "rangeVariableTypes", "parameterNames"} {
		if !h[kind] {
			t.Fatalf("%s off by default: %v", kind, h)
		}
	}
	SetUserOptions(nil, map[string]bool{"parameterNames": false})
	if h := goplsSettings()["hints"].(map[string]bool); h["parameterNames"] || !h["assignVariableTypes"] {
		t.Fatalf("turning off parameterNames: %v", h)
	}
}

func TestStatementKeywordsLeaveExpressionPositions(t *testing.T) {
	for src, want := range map[string]bool{
		"\ts.data[k] = v":    true,
		"\tfmt.Println(a, v": true,
		"\treturn v":         true,
		"\tfor k := v":       true,
		"\tv":                false,
		"\tmyreturn v":       false,
		"\tcase \"x\": v":    false,
	} {
		if got := inExpressionPosition([]byte(src), len(src)-1); got != want {
			t.Errorf("%q: expression position %v, want %v", src, got, want)
		}
	}
	items := []completionItem{{Label: "var", Kind: 14}, {Label: "v", Kind: 6}, {Label: "for!", Kind: 15}, {Label: "range", Kind: 14}, {Label: "func", Kind: 14}}
	var kept []string
	for _, it := range items {
		if !isStatementKeyword(it) {
			kept = append(kept, it.Label)
		}
	}
	if strings.Join(kept, ",") != "v,range,func" {
		t.Errorf("kept %v, want v,range,func", kept)
	}
}

func TestSynthesizePostfixCompletions(t *testing.T) {
	src := "package main\n\nfunc run(items []string, err error) {\n\titems.for\n}\n"
	caret := strings.Index(src, "items.for") + len("items.for")
	buf := NewFileBuffer([]byte(src))
	line, col := buf.Position(caret)

	items := synthesizePostfixCompletions([]byte(src), caret, lspPos{Line: line, Character: col})
	if len(items) != 10 {
		t.Fatalf("got %d postfix items, want 10", len(items))
	}

	wantLabels := []string{"var", "err", "nil", "notnil", "for", "fori", "len", "return", "not", "print"}
	for i, w := range wantLabels {
		if items[i].Label != w {
			t.Errorf("items[%d].Label = %q, want %q", i, items[i].Label, w)
		}
		if items[i].Kind != 15 || items[i].InsertFormat != 2 {
			t.Errorf("items[%d] Kind=%d InsertFormat=%d, want 15 and 2", i, items[i].Kind, items[i].InsertFormat)
		}
	}

	commentSrc := "package main\n// items.var\n"
	commentCaret := len(commentSrc) - 1
	cBuf := NewFileBuffer([]byte(commentSrc))
	cLine, cCol := cBuf.Position(commentCaret)
	if got := synthesizePostfixCompletions([]byte(commentSrc), commentCaret, lspPos{Line: cLine, Character: cCol}); len(got) != 0 {
		t.Errorf("expected 0 postfix items in comment, got %d", len(got))
	}

	importSrc := "package main\nimport \"example.com/a.\"\n"
	importCaret := strings.Index(importSrc, "a.") + 2
	iBuf := NewFileBuffer([]byte(importSrc))
	iLine, iCol := iBuf.Position(importCaret)
	if got := synthesizePostfixCompletions([]byte(importSrc), importCaret, lspPos{Line: iLine, Character: iCol}); len(got) != 0 {
		t.Errorf("expected 0 postfix items in import string, got %d", len(got))
	}
}

func TestCommitPostfixCompletions(t *testing.T) {
	cases := []struct {
		name  string
		src   string
		label string
		want  string
	}{
		{
			name:  "postfix var",
			src:   "package p\n\nfunc f() {\n\tcompute(1, 2).var|\n}\n",
			label: "var",
			want:  "package p\n\nfunc f() {\n\tv := compute(1, 2)\n}\n",
		},
		{
			name:  "postfix err",
			src:   "package p\n\nfunc f(err error) error {\n\terr.err|\n}\n",
			label: "err",
			want:  "package p\n\nfunc f(err error) error {\n\tif err != nil {\n\t\treturn err\n\t}\n}\n",
		},
		{
			name:  "postfix for",
			src:   "package p\n\nfunc f(items []string) {\n\titems.for|\n}\n",
			label: "for",
			want:  "package p\n\nfunc f(items []string) {\n\tfor _, v := range items {\n\t\t\n\t}\n}\n",
		},
		{
			name:  "postfix len",
			src:   "package p\n\nfunc f(items []string) {\n\tn := items.len|\n}\n",
			label: "len",
			want:  "package p\n\nfunc f(items []string) {\n\tn := len(items)\n}\n",
		},
		{
			name:  "postfix return",
			src:   "package p\n\nfunc f(val int) int {\n\tval.return|\n}\n",
			label: "return",
			want:  "package p\n\nfunc f(val int) int {\n\treturn val\n}\n",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			caret := strings.IndexByte(tc.src, '|')
			content := tc.src[:caret] + tc.src[caret+1:]
			buf := NewFileBuffer([]byte(content))
			line, col := buf.Position(caret)
			postfixItems := synthesizePostfixCompletions([]byte(content), caret, lspPos{Line: line, Character: col})
			var target *completionItem
			for i := range postfixItems {
				if postfixItems[i].Label == tc.label {
					target = &postfixItems[i]
					break
				}
			}
			if target == nil {
				t.Fatalf("postfix item %q not found", tc.label)
			}
			got := commitWith(t, tc.src, *target)
			if got != tc.want {
				t.Errorf("got:\n%s\nwant:\n%s", got, tc.want)
			}
		})
	}
}

func TestIndentSnippetFollowsTheLine(t *testing.T) {
	exp := ExpandSnippet("if err != nil {\n\t$0\n}")
	got := indentSnippet(exp, "\t")
	if got.Text != "if err != nil {\n\t\t\n\t}" {
		t.Fatalf("text %q", got.Text)
	}
	if want := len("if err != nil {\n\t\t"); got.Final != want {
		t.Fatalf("final %d want %d", got.Final, want)
	}
	two := indentSnippet(ExpandSnippet("for ${1:i} := range ${2:x} {\n\n}"), "    ")
	if two.Text != "for i := range x {\n\n    }" || two.Stops[0].Start != 4 || two.Stops[1].Start != 15 {
		t.Fatalf("blank line or stops wrong: %q %+v", two.Text, two.Stops)
	}
	if lineIndent([]byte("a\n\t\terr.nn"), 9) != "\t\t" || lineIndent([]byte("x"), 0) != "" {
		t.Fatal("lineIndent")
	}
	if same := indentSnippet(exp, ""); same.Text != exp.Text {
		t.Fatal("empty indent must not change the text")
	}
}
