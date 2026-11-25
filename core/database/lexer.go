package database

import (
	"strings"
	"unicode/utf8"
)

type tokKind uint8

const (
	tSpace tokKind = iota
	tComment
	tWord
	tQuoted
	tString
	tNumber
	tPunct
	tSemicolon
	tParam
)

type token struct {
	kind       tokKind
	start, end int
}

func (t token) text(src string) string { return src[t.start:t.end] }

func (t token) is(src, word string) bool {
	return t.kind == tWord && strings.EqualFold(src[t.start:t.end], word)
}

func isWordStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

func isWordChar(c byte) bool {
	return isWordStart(c) || (c >= '0' && c <= '9') || c == '$'
}

func normalizeDialect(d string) string {
	switch strings.ToLower(d) {
	case "mysql", "mariadb":
		return EngineMySQL
	case "sqlite", "sqlite3":
		return EngineSQLite
	}
	return EnginePostgres
}

func lex(src, dialect string) []token {
	dialect = normalizeDialect(dialect)
	toks := make([]token, 0, len(src)/4+1)
	i, n := 0, len(src)
	for i < n {
		c := src[i]
		start := i
		kind := tPunct
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v':
			for i < n && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r' || src[i] == '\f' || src[i] == '\v') {
				i++
			}
			kind = tSpace
		case c == '-' && i+1 < n && src[i+1] == '-', c == '#' && dialect == EngineMySQL:
			for i < n && src[i] != '\n' {
				i++
			}
			kind = tComment
		case c == '/' && i+1 < n && src[i+1] == '*':
			i = skipBlockComment(src, i, dialect == EnginePostgres)
			kind = tComment
		case c == '\'':
			i = skipQuoted(src, i, '\'', dialect == EngineMySQL)
			kind = tString
		case (c == 'E' || c == 'e') && dialect == EnginePostgres && i+1 < n && src[i+1] == '\'':
			i = skipQuoted(src, i+1, '\'', true)
			kind = tString
		case c == '"':
			i = skipQuoted(src, i, '"', dialect == EngineMySQL)
			if dialect == EngineMySQL {
				kind = tString
			} else {
				kind = tQuoted
			}
		case c == '`' && dialect != EnginePostgres:
			i = skipQuoted(src, i, '`', false)
			kind = tQuoted
		case c == '[' && dialect == EngineSQLite:
			i++
			for i < n && src[i] != ']' {
				i++
			}
			if i < n {
				i++
			}
			kind = tQuoted
		case c == '$' && dialect == EnginePostgres:
			if end, ok := dollarQuote(src, i); ok {
				i = end
				kind = tString
			} else {
				i++
				for i < n && src[i] >= '0' && src[i] <= '9' {
					i++
				}
				kind = tParam
			}
		case c == ';':
			i++
			kind = tSemicolon
		case c >= '0' && c <= '9', c == '.' && i+1 < n && src[i+1] >= '0' && src[i+1] <= '9':
			i++
			for i < n && (isWordChar(src[i]) || src[i] == '.' || ((src[i] == '+' || src[i] == '-') && (src[i-1] == 'e' || src[i-1] == 'E'))) {
				i++
			}
			kind = tNumber
		case isWordStart(c):
			for i < n && isWordChar(src[i]) {
				if src[i] >= 0x80 {
					_, size := utf8.DecodeRuneInString(src[i:])
					i += size
				} else {
					i++
				}
			}
			kind = tWord
		case (c == '@' || (c == ':' && (i == 0 || src[i-1] != ':'))) && i+1 < n && isWordStart(src[i+1]):
			i++
			for i < n && isWordChar(src[i]) {
				i++
			}
			kind = tParam
		default:
			if c >= 0x80 {
				_, size := utf8.DecodeRuneInString(src[i:])
				i += size
			} else {
				i++
			}
		}
		toks = append(toks, token{kind: kind, start: start, end: i})
	}
	return toks
}

func skipBlockComment(src string, i int, nested bool) int {
	depth := 0
	n := len(src)
	for i < n {
		if i+1 < n && src[i] == '/' && src[i+1] == '*' {
			if depth == 0 || nested {
				depth++
			}
			i += 2
			continue
		}
		if i+1 < n && src[i] == '*' && src[i+1] == '/' {
			depth--
			i += 2
			if depth == 0 {
				return i
			}
			continue
		}
		i++
	}
	return n
}

func skipQuoted(src string, i int, q byte, backslash bool) int {
	n := len(src)
	i++
	for i < n {
		c := src[i]
		if backslash && c == '\\' {
			i += 2
			continue
		}
		if c == q {
			if i+1 < n && src[i+1] == q {
				i += 2
				continue
			}
			return i + 1
		}
		i++
	}
	return n
}

func dollarQuote(src string, i int) (int, bool) {
	j := i + 1
	for j < len(src) && src[j] != '$' {
		c := src[j]
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80 || (j > i+1 && c >= '0' && c <= '9')) {
			return 0, false
		}
		j++
	}
	if j >= len(src) {
		return 0, false
	}
	tag := src[i : j+1]
	k := strings.Index(src[j+1:], tag)
	if k < 0 {
		return len(src), true
	}
	return j + 1 + k + len(tag), true
}
