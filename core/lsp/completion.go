package lsp

import (
	"bytes"
	"encoding/json"
	"errors"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

const (
	detailPostfixIfPrefix = "Postfix: if "
)

const (
	maxCompletionRows  = 200
	maxCompletionQuery = 256
	maxDocBytes        = 2048
)

type completionItem struct {
	Label        string `json:"label"`
	Kind         int    `json:"kind"`
	Detail       string `json:"detail"`
	SortText     string `json:"sortText"`
	FilterText   string `json:"filterText"`
	InsertText   string `json:"insertText"`
	InsertFormat int    `json:"insertTextFormat"`
	Deprecated   bool   `json:"deprecated"`
	Tags         []int  `json:"tags"`
	LabelDetails *struct {
		Detail      string `json:"detail"`
		Description string `json:"description"`
	} `json:"labelDetails"`
	TextEdit *struct {
		Range   *lspRange `json:"range"`
		Insert  *lspRange `json:"insert"`
		Replace *lspRange `json:"replace"`
		NewText string    `json:"newText"`
	} `json:"textEdit"`
	AdditionalTextEdits []textEdit      `json:"additionalTextEdits"`
	Documentation       json.RawMessage `json:"documentation"`
}

func (it *completionItem) deprecated() bool {
	if it.Deprecated {
		return true
	}
	for _, t := range it.Tags {
		if t == 1 {
			return true
		}
	}
	return false
}

func (it *completionItem) filterKey() string {
	if it.FilterText != "" && !strings.ContainsAny(it.FilterText, "($") {
		return it.FilterText
	}
	return it.Label
}

type completionSession struct {
	id         int64
	root       string
	path       string
	version    int32
	anchor     int
	caret      int
	caretPos   lspPos
	query      string
	incomplete bool
	items      []completionItem
}

var completions struct {
	mu      sync.Mutex
	nextID  int64
	session *completionSession
	prev    *completionSession
}

func lookupSessionLocked(id int64) *completionSession {
	for _, s := range []*completionSession{completions.session, completions.prev} {
		if s != nil && s.id == id {
			return s
		}
	}
	return nil
}

func endSessionsLocked() {
	completions.session, completions.prev = nil, nil
}

func isIdentByte(c byte) bool {
	return c == '_' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= utf8.RuneSelf
}

func wordStart(content []byte, caret int) int {
	i := caret
	for i > 0 && isIdentByte(content[i-1]) {
		i--
	}
	return i
}

type completionStart struct {
	OK         bool   `json:"ok"`
	Error      string `json:"error,omitempty"`
	Stale      bool   `json:"stale,omitempty"`
	Session    int64  `json:"session,omitempty"`
	Anchor     int    `json:"anchor"`
	Incomplete bool   `json:"incomplete,omitempty"`
	Count      int    `json:"count"`
}

func jsonString(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

func StartCompletion(path string, caret int, triggerKind int, triggerChar string) string {
	snap, ok := docs.snapshot(path, caret)
	if !ok {
		return jsonString(completionStart{Error: "language server not ready"})
	}
	root := RootForPath(path)
	projectModules.refresh(root)
	anchor := caret
	docs.withDoc(path, func(d *document) {
		if caret <= len(d.buf.Content) {
			anchor = wordStart(d.buf.Content, caret)
		}
	})
	params := positionParams(snap)
	if triggerKind > 0 {
		ctx := map[string]any{"triggerKind": triggerKind}
		if triggerChar != "" {
			ctx["triggerCharacter"] = triggerChar
		}
		params["context"] = ctx
	}
	const m = "textDocument/completion"
	raw, err := snap.srv.c.call(m, params, snap.srv.budget(m), "completion")
	if err != nil {
		if errors.Is(err, errCancelled) {
			return jsonString(completionStart{Stale: true})
		}
		logRequestError("completion", err)
		return jsonString(completionStart{Error: err.Error()})
	}
	items, incomplete, err := parseCompletionList(raw)
	if err != nil {
		return jsonString(completionStart{Error: err.Error()})
	}
	docs.withDoc(path, func(d *document) {
		if anchor <= len(d.buf.Content) && inExpressionPosition(d.buf.Content, anchor) {
			items = slices.DeleteFunc(items, isStatementKeyword)
		}
		if d.lang == "go" || strings.HasSuffix(path, ".go") {
			items = append(items, synthesizePostfixCompletions(d.buf.Content, caret, lspPos{snap.line, snap.col})...)
		}
	})
	stale := true
	docs.withDoc(path, func(d *document) { stale = d.editedBefore(snap.version, anchor) })
	if stale {
		return jsonString(completionStart{Stale: true})
	}
	completions.mu.Lock()
	completions.nextID++
	s := &completionSession{id: completions.nextID, root: root, caret: caret, caretPos: lspPos{snap.line, snap.col}, path: path, version: snap.version, anchor: anchor, incomplete: incomplete, items: items}
	docs.withDoc(path, func(d *document) {
		if caret <= len(d.buf.Content) {
			s.query = string(d.buf.Content[anchor:caret])
		}
	})
	completions.prev, completions.session = completions.session, s
	completions.mu.Unlock()
	return jsonString(completionStart{OK: true, Session: s.id, Anchor: anchor, Incomplete: incomplete, Count: len(items)})
}

var statementKeywords = map[string]bool{"break": true, "case": true, "const": true, "continue": true, "default": true,
	"defer": true, "else": true, "fallthrough": true, "for": true, "go": true, "goto": true, "if": true, "import": true,
	"package": true, "return": true, "select": true, "switch": true, "type": true, "var": true}

func isStatementKeyword(it completionItem) bool {
	return (it.Kind == 14 || it.Kind == 15) && statementKeywords[strings.TrimSuffix(it.Label, "!")]
}

func inExpressionPosition(src []byte, anchor int) bool {
	i := anchor - 1
	for i >= 0 && (src[i] == ' ' || src[i] == '\t') {
		i--
	}
	if i < 0 {
		return false
	}
	if strings.IndexByte("=([,+-*/%&|^<>!", src[i]) >= 0 {
		return true
	}
	return bytes.HasSuffix(src[:i+1], []byte("return")) && (i < 6 || !isIdentByte(src[i-6]))
}

func synthesizePostfixCompletions(content []byte, caret int, caretPos lspPos) []completionItem {
	if caret < 0 || caret > len(content) {
		return nil
	}
	anchor := wordStart(content, caret)
	if anchor <= 0 || content[anchor-1] != '.' {
		return nil
	}
	if anchor >= 2 && content[anchor-2] == '.' {
		return nil
	}

	lineStart := anchor - 1
	for lineStart > 0 && content[lineStart-1] != '\n' {
		lineStart--
	}
	prefix := content[lineStart : anchor-1]
	trimmedLeft := bytes.TrimLeft(prefix, " \t")
	if len(trimmedLeft) == 0 {
		return nil
	}
	if bytes.HasPrefix(trimmedLeft, []byte("//")) ||
		bytes.HasPrefix(trimmedLeft, []byte("/*")) ||
		bytes.HasPrefix(trimmedLeft, []byte("import ")) ||
		bytes.HasPrefix(trimmedLeft, []byte("import\t")) ||
		bytes.HasPrefix(trimmedLeft, []byte("import(")) ||
		bytes.HasPrefix(trimmedLeft, []byte("package ")) ||
		bytes.HasPrefix(trimmedLeft, []byte("package\t")) {
		return nil
	}

	inDoubleQuote := false
	inBacktick := false
	inRune := false
	for i := 0; i < len(prefix); i++ {
		c := prefix[i]
		if inDoubleQuote {
			if c == '\\' {
				i++
				continue
			}
			if c == '"' {
				inDoubleQuote = false
			}
			continue
		}
		if inRune {
			if c == '\\' {
				i++
				continue
			}
			if c == '\'' {
				inRune = false
			}
			continue
		}
		if inBacktick {
			if c == '`' {
				inBacktick = false
			}
			continue
		}
		if c == '/' && i+1 < len(prefix) && prefix[i+1] == '/' {
			return nil
		}
		if c == '"' {
			inDoubleQuote = true
		} else if c == '\'' {
			inRune = true
		} else if c == '`' {
			inBacktick = true
		}
	}
	if inDoubleQuote || inBacktick || inRune {
		return nil
	}

	i := len(prefix)
	for i > 0 {
		c := prefix[i-1]
		if isIdentByte(c) || c == '.' {
			i--
			continue
		}
		if c == ')' || c == ']' || c == '}' {
			open := matchBracketBackward(prefix, i-1)
			if open < 0 {
				break
			}
			i = open
			continue
		}
		break
	}

	exprBytes := prefix[i:]
	for len(exprBytes) > 0 && exprBytes[0] == '.' {
		exprBytes = exprBytes[1:]
		i++
	}
	if len(exprBytes) == 0 {
		return nil
	}
	if exprBytes[0] >= '0' && exprBytes[0] <= '9' {
		return nil
	}
	expr := strings.TrimSpace(string(exprBytes))
	if expr == "" || statementKeywords[expr] {
		return nil
	}

	exprStart := lineStart + i
	startCol := caretPos.Character - utf16Len(content[exprStart:caret])
	if startCol < 0 {
		startCol = utf16Len(content[lineStart:exprStart])
	}
	repRange := lspRange{
		Start: lspPos{Line: caretPos.Line, Character: startCol},
		End:   lspPos{Line: caretPos.Line, Character: caretPos.Character},
	}

	templates := []struct {
		label   string
		detail  string
		newText string
	}{
		{"var", "Postfix: assign to variable := " + expr, "${1:v} := " + expr + "$0"},
		{"err", detailPostfixIfPrefix + expr + " != nil { return ... }", "if " + expr + " != nil {\n\treturn ${1:" + expr + "}\n}$0"},
		{"nil", detailPostfixIfPrefix + expr + " == nil", "if " + expr + " == nil {\n\t$0\n}"},
		{"notnil", detailPostfixIfPrefix + expr + " != nil", "if " + expr + " != nil {\n\t$0\n}"},
		{"for", "Postfix: for _, v := range " + expr, "for ${1:_}, ${2:v} := range " + expr + " {\n\t$0\n}"},
		{"fori", "Postfix: for i := 0; i < len(" + expr + "); i++", "for ${1:i} := 0; ${1:i} < len(" + expr + "); ${1:i}++ {\n\t$0\n}"},
		{"len", "Postfix: len(" + expr + ")", "len(" + expr + ")$0"},
		{"return", "Postfix: return " + expr, "return " + expr + "$0"},
		{"not", "Postfix: !" + expr, "!" + expr + "$0"},
		{"print", "Postfix: fmt.Println(" + expr + ")", "fmt.Println(" + expr + ")$0"},
	}

	out := make([]completionItem, len(templates))
	for idx, tmpl := range templates {
		r := repRange
		sortSuffix := strconv.Itoa(idx)
		if idx < 10 {
			sortSuffix = "0" + sortSuffix
		}
		it := completionItem{
			Label:        tmpl.label,
			Kind:         15,
			Detail:       tmpl.detail,
			SortText:     "999" + sortSuffix,
			FilterText:   tmpl.label,
			InsertFormat: 2,
		}
		it.TextEdit = &struct {
			Range   *lspRange `json:"range"`
			Insert  *lspRange `json:"insert"`
			Replace *lspRange `json:"replace"`
			NewText string    `json:"newText"`
		}{
			Range:   &r,
			Insert:  &r,
			Replace: &r,
			NewText: tmpl.newText,
		}
		out[idx] = it
	}
	return out
}

func matchBracketBackward(b []byte, closeIdx int) int {
	depth := 0
	for j := closeIdx; j >= 0; j-- {
		c := b[j]
		if c == '"' || c == '\'' || c == '`' {
			quote := c
			j--
			for j >= 0 {
				if b[j] == quote && (quote == '`' || j == 0 || b[j-1] != '\\') {
					break
				}
				j--
			}
			continue
		}
		switch c {
		case ')', ']', '}':
			depth++
		case '(', '[', '{':
			depth--
			if depth == 0 {
				return j
			}
		}
	}
	return -1
}

func parseCompletionList(raw json.RawMessage) ([]completionItem, bool, error) {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" {
		return nil, false, nil
	}
	if trimmed[0] == '[' {
		var items []completionItem
		err := json.Unmarshal(raw, &items)
		return items, false, err
	}
	var list struct {
		IsIncomplete bool             `json:"isIncomplete"`
		Items        []completionItem `json:"items"`
	}
	err := json.Unmarshal(raw, &list)
	return list.Items, list.IsIncomplete, err
}

func CancelCompletion() {
	completions.mu.Lock()
	endSessionsLocked()
	completions.mu.Unlock()
	if srv := current(); srv != nil {
		srv.c.mu.Lock()
		if id, ok := srv.c.keyed["completion"]; ok {
			srv.c.cancelLocked(id)
		}
		srv.c.mu.Unlock()
	}
}

type matchResult struct {
	score     int
	positions []int
}

const (
	tierExactCase = 4
	tierPrefix    = 3
	tierWordStart = 2
	tierSubseq    = 1
)

func isWordBoundary(label []rune, i int) bool {
	if i == 0 {
		return true
	}
	prev, cur := label[i-1], label[i]
	if prev == '_' || prev == '.' {
		return true
	}
	return unicode.IsUpper(cur) && !unicode.IsUpper(prev) || unicode.IsDigit(cur) && !unicode.IsDigit(prev)
}

type candidateMatcher struct {
	query   string
	q       []rune
	lq      []rune
	buf     []rune
	memo    []uint32
	memoGen uint32
}

func newCandidateMatcher(query string) *candidateMatcher {
	q := []rune(query)
	lq := make([]rune, len(q))
	for i, r := range q {
		lq[i] = lowerRune(r)
	}
	return &candidateMatcher{query: query, q: q, lq: lq}
}

func lowerRune(r rune) rune {
	if r < 0x80 {
		if 'A' <= r && r <= 'Z' {
			return r + ('a' - 'A')
		}
		return r
	}
	return unicode.ToLower(r)
}

func matchCandidate(query, candidate string) (matchResult, bool) {
	return newCandidateMatcher(query).match(candidate)
}

func (m *candidateMatcher) isSubsequence(candidate string) bool {
	lq := m.lq
	j := 0
	for i := 0; i < len(candidate) && j < len(lq); i++ {
		b := candidate[i]
		if b < 0x80 {
			if 'A' <= b && b <= 'Z' {
				b += 'a' - 'A'
			}
			if rune(b) == lq[j] {
				j++
			}
			continue
		}
		for _, r := range candidate[i:] {
			if j == len(lq) {
				break
			}
			if lowerRune(r) == lq[j] {
				j++
			}
		}
		break
	}
	return j == len(lq)
}

func (m *candidateMatcher) match(candidate string) (matchResult, bool) {
	if m.query == "" {
		return matchResult{score: tierPrefix * 1000}, true
	}
	q, lq := m.q, m.lq
	if len(candidate) < len(q) || !m.isSubsequence(candidate) {
		return matchResult{}, false
	}
	c := m.buf[:0]
	for _, r := range candidate {
		c = append(c, r)
	}
	m.buf = c
	if len(q) > len(c) {
		return matchResult{}, false
	}
	prefix := true
	exactCase := true
	for i := range q {
		if lowerRune(c[i]) != lq[i] {
			prefix = false
			break
		}
		if c[i] != q[i] {
			exactCase = false
		}
	}
	if prefix {
		pos := make([]int, len(q))
		for i := range pos {
			pos[i] = i
		}
		tier := tierPrefix
		if exactCase {
			tier = tierExactCase
		}
		return matchResult{score: tier * 1000, positions: pos}, true
	}
	if pos, ok := m.wordStartMatch(c); ok {
		return matchResult{score: tierWordStart * 1000, positions: pos}, true
	}
	pos := make([]int, 0, len(q))
	j := 0
	for i := 0; i < len(c) && j < len(lq); i++ {
		if lowerRune(c[i]) == lq[j] {
			pos = append(pos, i)
			j++
		}
	}
	if j < len(lq) {
		return matchResult{}, false
	}
	return matchResult{score: tierSubseq * 1000, positions: pos}, true
}

func (m *candidateMatcher) wordStartMatch(c []rune) ([]int, bool) {
	if len(c) > 128 {
		return nil, false
	}
	lq := m.lq
	stride := len(c) + 1
	size := (len(lq) + 1) * stride
	if cap(m.memo) < size {
		m.memo = make([]uint32, size)
		m.memoGen = 0
	}
	memo := m.memo[:size]
	m.memoGen++
	if m.memoGen == 0 {
		clear(m.memo)
		m.memoGen = 1
	}
	ws := wordStartSearch{lq: lq, c: c, memo: memo, gen: m.memoGen, stride: stride, pos: make([]int, 0, len(lq))}
	if ws.try(0, 0) {
		return ws.pos, true
	}
	return nil, false
}

type wordStartSearch struct {
	lq     []rune
	c      []rune
	memo   []uint32
	gen    uint32
	stride int
	pos    []int
}

func (w *wordStartSearch) try(qi, ci int) bool {
	if qi == len(w.lq) {
		return true
	}
	key := qi*w.stride + ci
	if w.memo[key] == w.gen {
		return false
	}
	for i := ci; i < len(w.c); i++ {
		if lowerRune(w.c[i]) != w.lq[qi] {
			continue
		}
		contiguous := len(w.pos) > 0 && w.pos[len(w.pos)-1] == i-1
		if !contiguous && !isWordBoundary(w.c, i) {
			continue
		}
		w.pos = append(w.pos, i)
		if w.try(qi+1, i+1) {
			return true
		}
		w.pos = w.pos[:len(w.pos)-1]
	}
	w.memo[key] = w.gen
	return false
}

type rankedItem struct {
	index int
	match matchResult
}

func strongMatch(m matchResult) bool { return m.score >= tierWordStart*1000 }

func (it *completionItem) unimportedPath() string {
	return importPath(it.AdditionalTextEdits)
}

func rankItems(items []completionItem, query string) []rankedItem {
	return rankItemsFor(items, query, nil)
}

var postfixAliases = map[string]string{"nn": "ifnotnil", "rr": "iferr"}

func matchItem(m *candidateMatcher, it *completionItem) (matchResult, bool) {
	if target, ok := postfixAliases[m.query]; ok && strings.TrimSuffix(it.Label, "!") == target {
		return matchResult{score: tierPrefix * 1000}, true
	}
	return m.match(it.filterKey())
}

func rankItemsFor(items []completionItem, query string, allowed func(string) bool) []rankedItem {
	out := make([]rankedItem, 0, len(items))
	type dedupeKey struct {
		label, imp string
		kind       int
	}
	var seen map[dedupeKey]bool
	matcher := newCandidateMatcher(query)
	for i := range items {
		it := &items[i]
		m, ok := matchItem(matcher, it)
		if !ok {
			continue
		}
		imp := ""
		if len(it.AdditionalTextEdits) > 0 {
			imp = it.unimportedPath()
			if imp != "" && allowed != nil && !allowed(imp) {
				continue
			}
		}
		if seen == nil {
			seen = make(map[dedupeKey]bool, len(items))
		}
		key := dedupeKey{it.Label, imp, it.Kind}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, rankedItem{i, m})
	}
	sort.SliceStable(out, func(a, b int) bool {
		ia, ib := &items[out[a].index], &items[out[b].index]
		if da, db := ia.deprecated(), ib.deprecated(); da != db {
			return !da
		}
		if sa, sb := strongMatch(out[a].match), strongMatch(out[b].match); sa != sb {
			return sa
		}
		if ea, eb := out[a].match.score == tierExactCase*1000, out[b].match.score == tierExactCase*1000; ea != eb {
			return ea
		}
		if ia.SortText != ib.SortText {
			return ia.SortText < ib.SortText
		}
		return ia.Label < ib.Label
	})
	return out
}

type completionAction string

const (
	actionShow    completionAction = "show"
	actionRequery completionAction = "requery"
	actionHide    completionAction = "hide"
)

func validQuery(q string) bool {
	if len(q) > maxCompletionQuery {
		return false
	}
	for i := 0; i < len(q); i++ {
		if !isIdentByte(q[i]) {
			return false
		}
	}
	return true
}

func decide(s *completionSession, path string, caret int, query string) completionAction {
	if s == nil || s.path != path {
		return actionRequery
	}
	if caret < s.anchor || !validQuery(query) {
		return actionHide
	}
	return actionShow
}

const refreshBelowRows = 10

func needsRefresh(s *completionSession, query string, rows int) bool {
	return s.incomplete && query != s.query && rows < refreshBelowRows
}

type completionRow struct {
	Index      int    `json:"i"`
	Label      string `json:"label"`
	Kind       string `json:"kind"`
	Params     string `json:"params,omitempty"`
	Type       string `json:"type,omitempty"`
	Package    string `json:"pkg,omitempty"`
	Matches    []int  `json:"m,omitempty"`
	Deprecated bool   `json:"dep,omitempty"`
}

type completionFilterResult struct {
	Action  string          `json:"action"`
	Refresh bool            `json:"refresh,omitempty"`
	Total   int             `json:"total"`
	Rows    []completionRow `json:"rows"`
}

func FilterCompletion(sessionID int64, path string, caret int, query string) string {
	completions.mu.Lock()
	s := lookupSessionLocked(sessionID)
	completions.mu.Unlock()
	act := decide(s, path, caret, query)
	res := completionFilterResult{Action: string(act), Rows: []completionRow{}}
	if act == actionHide || s == nil {
		return jsonString(res)
	}
	ranked := rankItemsFor(s.items, query, projectModules.allowFunc(s.root))
	res.Total = len(ranked)
	res.Refresh = needsRefresh(s, query, len(ranked))
	for _, r := range ranked[:min(len(ranked), maxCompletionRows)] {
		res.Rows = append(res.Rows, makeRow(&s.items[r.index], r))
	}
	return jsonString(res)
}

func goKind(kind int) string {
	switch kind {
	case 2:
		return "method"
	case 3, 4:
		return "func"
	case 5, 10:
		return "field"
	case 6, 12:
		return "var"
	case 7, 13, 25:
		return "type"
	case 8:
		return "interface"
	case 9:
		return "package"
	case 14:
		return "keyword"
	case 15:
		return "snippet"
	case 20, 21:
		return "const"
	case 22:
		return "struct"
	}
	return "var"
}

func splitSignature(sig string) (params, result string) {
	sig = strings.TrimSpace(sig)
	if !strings.HasPrefix(sig, "(") {
		return "", sig
	}
	depth := 0
	for i, r := range sig {
		switch r {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				return sig[:i+1], strings.TrimSpace(sig[i+1:])
			}
		}
	}
	return sig, ""
}

func utf16Positions(label string, runePos []int) []int {
	if len(runePos) == 0 {
		return nil
	}
	out := make([]int, 0, len(runePos))
	u, ri, pi := 0, 0, 0
	for _, r := range label {
		if pi < len(runePos) && runePos[pi] == ri {
			out = append(out, u)
			pi++
		}
		u += utf16.RuneLen(r)
		ri++
	}
	return out
}

func importPath(edits []textEdit) string {
	for _, e := range edits {
		if i := strings.IndexByte(e.NewText, '"'); i >= 0 {
			rest := e.NewText[i+1:]
			if j := strings.IndexByte(rest, '"'); j >= 0 {
				return rest[:j]
			}
		}
	}
	return ""
}

func makeRow(it *completionItem, r rankedItem) completionRow {
	row := completionRow{Index: r.index, Label: it.Label, Kind: goKind(it.Kind), Deprecated: it.deprecated()}
	if strings.HasPrefix(it.Label, it.filterKey()) {
		row.Matches = utf16Positions(it.Label, r.match.positions)
	}
	detail := it.Detail
	if it.LabelDetails != nil {
		row.Package = it.LabelDetails.Description
		if it.LabelDetails.Detail != "" {
			detail = it.LabelDetails.Detail
		}
	}
	switch row.Kind {
	case "func", "method":
		row.Params, row.Type = splitSignature(strings.TrimPrefix(strings.TrimSpace(detail), "func"))
	case "package", "keyword":
	default:
		row.Type = strings.TrimSpace(detail)
	}
	if row.Package == "" && len(it.AdditionalTextEdits) > 0 {
		row.Package = importPath(it.AdditionalTextEdits)
	}
	return row
}

func documentationText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var mc struct {
		Value string `json:"value"`
	}
	_ = json.Unmarshal(raw, &mc)
	return mc.Value
}

func firstParagraph(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.Index(s, "\n\n"); i >= 0 {
		s = s[:i]
	}
	return truncate(strings.ReplaceAll(s, "\n", " "), maxDocBytes)
}

func withSession(sessionID int64, index int, fn func(it *completionItem)) bool {
	completions.mu.Lock()
	defer completions.mu.Unlock()
	s := lookupSessionLocked(sessionID)
	if s == nil || index < 0 || index >= len(s.items) {
		return false
	}
	fn(&s.items[index])
	return true
}

func CompletionDoc(sessionID int64, index int) string {
	var out struct {
		Signature string `json:"signature"`
		Doc       string `json:"doc"`
	}
	withSession(sessionID, index, func(it *completionItem) {
		out.Signature = strings.TrimSpace(it.Detail)
		if it.LabelDetails != nil && it.LabelDetails.Detail != "" {
			kind := goKind(it.Kind)
			prefix := ""
			if pkg := it.LabelDetails.Description; pkg != "" {
				prefix = pkg + "."
			}
			if kind == "func" || kind == "method" {
				out.Signature = "func " + prefix + it.Label + it.LabelDetails.Detail
			} else {
				out.Signature = prefix + it.Label + " " + strings.TrimSpace(it.LabelDetails.Detail)
			}
		}
		out.Doc = firstParagraph(documentationText(it.Documentation))
	})
	return jsonString(out)
}

type TabStop struct {
	Index  int `json:"index"`
	Start  int `json:"start"`
	Length int `json:"length"`
}

type tabStop = TabStop

type ExpandedSnippet struct {
	Text  string    `json:"text"`
	Stops []TabStop `json:"stops"`
	Final int       `json:"final"`
}

type expandedSnippet = ExpandedSnippet

func ExpandSnippet(s string) ExpandedSnippet {
	var b strings.Builder
	var stops []tabStop
	final := -1
	u := 0
	write := func(str string) {
		b.WriteString(str)
		for _, r := range str {
			u += utf16.RuneLen(r)
		}
	}
	var parse func(s string, depth int) string
	parse = func(s string, depth int) string {
		for len(s) > 0 {
			c := s[0]
			switch {
			case c == '\\' && len(s) > 1 && strings.IndexByte(`$}\`, s[1]) >= 0:
				write(s[1:2])
				s = s[2:]
			case c == '}' && depth > 0:
				return s[1:]
			case c == '$' && len(s) > 1 && s[1] >= '0' && s[1] <= '9':
				j := 1
				for j < len(s) && s[j] >= '0' && s[j] <= '9' {
					j++
				}
				n, _ := strconv.Atoi(s[1:j])
				if n == 0 {
					final = u
				} else {
					stops = append(stops, tabStop{n, u, 0})
				}
				s = s[j:]
			case c == '$' && len(s) > 2 && s[1] == '{' && s[2] >= '0' && s[2] <= '9':
				j := 2
				for j < len(s) && s[j] >= '0' && s[j] <= '9' {
					j++
				}
				n, _ := strconv.Atoi(s[2:j])
				start := u
				rest := s[j:]
				switch {
				case strings.HasPrefix(rest, ":"):
					rest = parse(rest[1:], depth+1)
				case strings.HasPrefix(rest, "}"):
					rest = rest[1:]
				default:
					write(s[:j])
					s = rest
					continue
				}
				if n == 0 {
					final = start
				} else {
					stops = append(stops, tabStop{n, start, u - start})
				}
				s = rest
			default:
				_, size := utf8.DecodeRuneInString(s)
				write(s[:size])
				s = s[size:]
			}
		}
		return s
	}
	parse(s, 0)
	if final < 0 {
		final = u
	}
	sort.SliceStable(stops, func(i, j int) bool { return stops[i].Index < stops[j].Index })
	if stops == nil {
		stops = []tabStop{}
	}
	return expandedSnippet{Text: b.String(), Stops: stops, Final: final}
}

type completionCommit struct {
	OK         bool       `json:"ok"`
	Start      int        `json:"start"`
	End        int        `json:"end"`
	Text       string     `json:"text"`
	Stops      []tabStop  `json:"stops"`
	Final      int        `json:"final"`
	Additional []textEdit `json:"additional"`
}

func editRange(it *completionItem, midWord bool) *lspRange {
	if it.TextEdit == nil {
		return nil
	}
	if midWord && it.TextEdit.Replace != nil {
		return it.TextEdit.Replace
	}
	if it.TextEdit.Insert != nil {
		return it.TextEdit.Insert
	}
	return it.TextEdit.Range
}

func lineEnd(content []byte, from int) int {
	for i := from; i < len(content); i++ {
		if content[i] == '\n' {
			return i
		}
	}
	return len(content)
}

func commitRange(s *completionSession, it *completionItem, caret int) (start, end int, callFollows bool) {
	start, end = s.anchor, caret
	docs.withDoc(s.path, func(d *document) {
		content := d.buf.Content
		defer func() { callFollows = end < len(content) && content[end] == '(' }()
		if caret < s.anchor || caret > len(content) {
			start, end = caret, caret
			return
		}
		midWord := caret < len(content) && isIdentByte(content[caret])
		r := editRange(it, midWord)
		if r == nil {
			return
		}
		rs := d.buf.Offset(r.Start.Line, r.Start.Character)
		if rs > caret || r.Start.Line != s.caretPos.Line || d.editedBefore(s.version, rs) {
			return
		}
		tail := 0
		if r.End.Line == s.caretPos.Line && r.End.Character > s.caretPos.Character {
			tail = utf16OffsetToByteOffset(content[caret:lineEnd(content, caret)], r.End.Character-s.caretPos.Character)
		}
		start, end = rs, caret+tail
	})
	return start, end, callFollows
}

func dropCallSuffix(out *completionCommit) {
	i := strings.IndexByte(out.Text, '(')
	if i <= 0 {
		return
	}
	cut := utf16Len([]byte(out.Text[:i]))
	out.Text = out.Text[:i]
	kept := out.Stops[:0]
	for _, st := range out.Stops {
		if st.Start+st.Length <= cut {
			kept = append(kept, st)
		}
	}
	out.Stops = kept
	out.Final = cut
}

func lineIndent(content []byte, offset int) string {
	offset = min(max(offset, 0), len(content))
	start := offset
	for start > 0 && content[start-1] != '\n' {
		start--
	}
	end := start
	for end < len(content) && (content[end] == ' ' || content[end] == '\t') {
		end++
	}
	return string(content[start:end])
}

func indentSnippet(exp ExpandedSnippet, indent string) ExpandedSnippet {
	if indent == "" || !strings.Contains(exp.Text, "\n") {
		return exp
	}
	stopAt := map[int]bool{}
	for _, st := range exp.Stops {
		stopAt[st.Start] = true
	}
	if exp.Final >= 0 {
		stopAt[exp.Final] = true
	}
	var b strings.Builder
	var inserts []int
	u := 0
	for i, r := range exp.Text {
		b.WriteRune(r)
		u += utf16.RuneLen(r)
		if r != '\n' {
			continue
		}
		rest := exp.Text[i+1:]
		if (rest == "" || rest[0] == '\n') && !stopAt[u] {
			continue
		}
		b.WriteString(indent)
		inserts = append(inserts, u)
	}
	shift := func(pos int) int {
		n := 0
		for _, at := range inserts {
			if at <= pos {
				n += len(indent)
			}
		}
		return pos + n
	}
	stops := make([]tabStop, len(exp.Stops))
	for i, st := range exp.Stops {
		stops[i] = tabStop{Index: st.Index, Start: shift(st.Start), Length: st.Length}
	}
	final := exp.Final
	if final >= 0 {
		final = shift(final)
	}
	return ExpandedSnippet{Text: b.String(), Stops: stops, Final: final}
}

func CommitCompletion(sessionID int64, index int, caret int) string {
	var out completionCommit
	callFollows := false
	withSession(sessionID, index, func(it *completionItem) {
		out.Start, out.End, callFollows = commitRange(lookupSessionLocked(sessionID), it, caret)
		text := it.InsertText
		if it.TextEdit != nil {
			text = it.TextEdit.NewText
		}
		if text == "" {
			text = it.Label
		}
		if it.InsertFormat == 2 {
			exp := ExpandSnippet(text)
			out.Text, out.Stops, out.Final = exp.Text, exp.Stops, exp.Final
		} else {
			out.Text, out.Stops, out.Final = text, []tabStop{}, -1
		}
		if strings.Contains(out.Text, "\n") {
			docs.withDoc(lookupSessionLocked(sessionID).path, func(d *document) {
				exp := indentSnippet(ExpandedSnippet{Text: out.Text, Stops: out.Stops, Final: out.Final}, lineIndent(d.buf.Content, out.Start))
				out.Text, out.Stops, out.Final = exp.Text, exp.Stops, exp.Final
			})
		}
		out.Additional = it.AdditionalTextEdits
		if out.Additional == nil {
			out.Additional = []textEdit{}
		}
		out.OK = true
		if k := goKind(it.Kind); callFollows && (k == "func" || k == "method") {
			dropCallSuffix(&out)
		}
	})
	completions.mu.Lock()
	endSessionsLocked()
	completions.mu.Unlock()
	return jsonString(out)
}
