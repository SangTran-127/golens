package database

import (
	"strings"
)

type statement struct {
	start, end int
	spanStart  int
	spanEnd    int
	line       int
	toks       []token
}

func (s statement) text(src string) string { return src[s.start:s.end] }

func lineAt(src string, off int) int {
	return strings.Count(src[:off], "\n") + 1
}

func splitStatements(src, dialect string) []statement {
	dialect = normalizeDialect(dialect)
	toks := lex(src, dialect)
	var out []statement
	var cur []token
	spanStart := 0
	delim := ";"
	depth := 0
	blockable := false
	flush := func(spanEnd int) {
		if len(cur) > 0 {
			st := statement{start: cur[0].start, end: cur[len(cur)-1].end, spanStart: spanStart, spanEnd: spanEnd, toks: cur}
			out = append(out, st)
		}
		cur = nil
		depth = 0
		blockable = false
		spanStart = spanEnd
	}
	nextWord := func(i int) (token, bool) {
		for j := i + 1; j < len(toks); j++ {
			if toks[j].kind == tSpace || toks[j].kind == tComment {
				continue
			}
			return toks[j], true
		}
		return token{}, false
	}
	for i := 0; i < len(toks); i++ {
		t := toks[i]
		if t.kind == tSpace || t.kind == tComment {
			continue
		}
		if dialect == EngineMySQL && len(cur) == 0 && t.is(src, "DELIMITER") {
			nl := strings.IndexByte(src[t.end:], '\n')
			lineEnd := len(src)
			if nl >= 0 {
				lineEnd = t.end + nl
			}
			if d := strings.TrimSpace(src[t.end:lineEnd]); d != "" {
				delim = d
			}
			for i+1 < len(toks) && toks[i+1].start < lineEnd {
				i++
			}
			spanStart = lineEnd
			continue
		}
		if delim != ";" && t.kind != tString && t.kind != tQuoted && strings.HasPrefix(src[t.start:], delim) {
			end := t.start + len(delim)
			for i+1 < len(toks) && toks[i+1].start < end {
				i++
			}
			flush(end)
			continue
		}
		if t.kind == tSemicolon && delim == ";" && depth == 0 {
			flush(t.end)
			continue
		}
		if len(cur) == 0 {
			blockable = t.is(src, "CREATE")
		}
		cur = append(cur, t)
		if !blockable || t.kind != tWord || delim != ";" {
			continue
		}
		switch {
		case t.is(src, "BEGIN"):
			nw, ok := nextWord(i)
			switch dialect {
			case EnginePostgres:
				if ok && nw.is(src, "ATOMIC") {
					depth++
				}
			case EngineSQLite:
				if statementMentions(src, cur, "TRIGGER") {
					depth++
				}
			default:
				if statementMentions(src, cur, "PROCEDURE", "FUNCTION", "TRIGGER", "EVENT") {
					depth++
				}
			}
		case t.is(src, "CASE") && depth > 0:
			depth++
		case t.is(src, "END") && depth > 0:
			nw, ok := nextWord(i)
			if dialect == EngineMySQL && ok && (nw.is(src, "IF") || nw.is(src, "LOOP") || nw.is(src, "WHILE") || nw.is(src, "REPEAT")) {
				continue
			}
			depth--
		}
	}
	flush(len(src))
	for i := range out {
		out[i].line = lineAt(src, out[i].start)
	}
	return out
}

func statementMentions(src string, toks []token, words ...string) bool {
	for _, t := range toks {
		for _, w := range words {
			if t.is(src, w) {
				return true
			}
		}
	}
	return false
}

func statementAtCaret(stmts []statement, src string, caret int) int {
	for i, s := range stmts {
		if caret >= s.start && caret <= s.spanEnd {
			return i
		}
	}
	for i := len(stmts) - 1; i >= 0; i-- {
		s := stmts[i]
		if s.spanEnd <= caret && !strings.Contains(src[s.end:min(caret, len(src))], "\n") {
			return i
		}
	}
	for i, s := range stmts {
		if s.start >= caret {
			return i
		}
	}
	return len(stmts) - 1
}
