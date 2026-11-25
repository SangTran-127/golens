package database

import (
	"sort"
	"strconv"
	"strings"
)

type ParamValue struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	IsNull bool   `json:"isNull"`
	Secret bool   `json:"secret,omitempty"`
}

type Parameter struct {
	Name      string      `json:"name"`
	Positions []ByteRange `json:"positions"`
	TypeHint  string      `json:"typeHint"`
	Nullable  bool        `json:"nullable,omitempty"`
}

type ParametersResult struct {
	Parameters []Parameter `json:"parameters"`
}

type paramUse struct {
	name       string
	start, end int
	typeHint   string
	nullable   bool
}

var paramlessStarts = map[string]bool{"PREPARE": true}

func significant(toks []token) []token {
	out := make([]token, 0, len(toks))
	for _, t := range toks {
		if t.kind != tSpace && t.kind != tComment {
			out = append(out, t)
		}
	}
	return out
}

func punctIs(src string, t token, c byte) bool {
	return t.kind == tPunct && t.end-t.start == 1 && src[t.start] == c
}

func findParams(src, dialect string) []paramUse {
	return findParamsIn(src, lex(src, dialect), dialect)
}

func findParamsIn(src string, toks []token, dialect string) []paramUse {
	dialect = normalizeDialect(dialect)
	sig := significant(toks)
	if len(sig) > 0 && sig[0].kind == tWord {
		w := strings.ToUpper(sig[0].text(src))
		if paramlessStarts[w] || ddlStarts[w] {
			return nil
		}
	}
	var out []paramUse
	ordinal := 0
	brackets := 0
	for i := 0; i < len(sig); i++ {
		t := sig[i]
		switch {
		case punctIs(src, t, '['):
			brackets++
			continue
		case punctIs(src, t, ']'):
			if brackets > 0 {
				brackets--
			}
			continue
		}
		use := paramUse{start: t.start, end: t.end}
		last := i
		switch {
		case t.kind == tWord && strings.EqualFold(t.text(src), "sqlc") && sqlcMacro(src, sig, i) != "":
			macro := sqlcMacro(src, sig, i)
			use.name = "@" + strings.Trim(sig[i+4].text(src), "'\"`[]")
			use.end = sig[i+5].end
			use.nullable = macro == "NARG"
			last = i + 5
		case t.kind == tParam:
			text := t.text(src)
			switch {
			case text[0] == '$':
				if dialect != EnginePostgres {
					continue
				}
			case text[0] == '@':
				if dialect == EngineMySQL {
					continue
				}
			case text[0] == ':':
				if brackets > 0 {
					continue
				}
			}
			use.name = text
		case punctIs(src, t, '?') && dialect != EnginePostgres:
			if i+1 < len(sig) && sig[i+1].kind == tNumber && sig[i+1].start == t.end {
				use.name = "?" + sig[i+1].text(src)
				use.end = sig[i+1].end
				last = i + 1
			} else {
				ordinal++
				use.name = "?" + strconv.Itoa(ordinal)
			}
		case punctIs(src, t, '$') && dialect == EngineSQLite && i+1 < len(sig) && sig[i+1].kind == tWord && sig[i+1].start == t.end:
			use.name = "$" + sig[i+1].text(src)
			use.end = sig[i+1].end
			last = i + 1
		default:
			continue
		}
		use.typeHint = typeHintAfter(src, sig, last, i)
		out = append(out, use)
		i = last
	}
	return out
}

func sqlcMacro(src string, sig []token, i int) string {
	if i+5 >= len(sig) {
		return ""
	}
	if !punctIs(src, sig[i+1], '.') || sig[i+2].kind != tWord || !punctIs(src, sig[i+3], '(') || !punctIs(src, sig[i+5], ')') {
		return ""
	}
	macro := strings.ToUpper(sig[i+2].text(src))
	if macro != "ARG" && macro != "NARG" && macro != "SLICE" {
		return ""
	}
	if k := sig[i+4].kind; k != tWord && k != tQuoted && k != tString {
		return ""
	}
	return macro
}

func typeHintAfter(src string, sig []token, last, first int) string {
	if last+3 < len(sig) && punctIs(src, sig[last+1], ':') && punctIs(src, sig[last+2], ':') {
		return typeName(src, sig, last+3)
	}
	if first >= 2 && punctIs(src, sig[first-1], '(') && sig[first-2].is(src, "CAST") && last+2 < len(sig) && sig[last+1].is(src, "AS") {
		return typeName(src, sig, last+2)
	}
	return ""
}

func typeName(src string, sig []token, from int) string {
	if from >= len(sig) || (sig[from].kind != tWord && sig[from].kind != tQuoted) {
		return ""
	}
	start, end := sig[from].start, sig[from].end
	depth := 0
	for i := from + 1; i < len(sig); i++ {
		t := sig[i]
		switch {
		case depth > 0:
			if punctIs(src, t, '(') {
				depth++
			} else if punctIs(src, t, ')') {
				depth--
			}
		case punctIs(src, t, '('):
			depth++
		case punctIs(src, t, '[') || punctIs(src, t, ']') || punctIs(src, t, '.'):
		case t.kind == tWord && (t.is(src, "PRECISION") || t.is(src, "VARYING") || t.is(src, "WITH") || t.is(src, "WITHOUT") || t.is(src, "TIME") || t.is(src, "ZONE")):
		case (t.kind == tWord || t.kind == tQuoted) && i > from && punctIs(src, sig[i-1], '.'):
		default:
			return strings.Join(strings.Fields(src[start:end]), " ")
		}
		end = t.end
	}
	return strings.Join(strings.Fields(src[start:end]), " ")
}

func Parameters(text, dialect string, startByte, endByte int) ParametersResult {
	if startByte < 0 || startByte > len(text) {
		startByte = 0
	}
	if endByte <= startByte || endByte > len(text) {
		endByte = len(text)
	}
	out := ParametersResult{Parameters: []Parameter{}}
	index := map[string]int{}
	for _, st := range splitStatements(text, dialect) {
		if st.end <= startByte || st.start >= endByte {
			continue
		}
		for _, u := range findParamsIn(text, st.toks, dialect) {
			if u.start < startByte || u.end > endByte {
				continue
			}
			i, ok := index[u.name]
			if !ok {
				i = len(out.Parameters)
				index[u.name] = i
				out.Parameters = append(out.Parameters, Parameter{Name: u.name, Positions: []ByteRange{}})
			}
			p := &out.Parameters[i]
			p.Positions = append(p.Positions, ByteRange{StartByte: u.start, EndByte: u.end})
			if p.TypeHint == "" {
				p.TypeHint = u.typeHint
			}
			p.Nullable = p.Nullable || u.nullable
		}
	}
	return out
}

type offsetMap struct {
	edits []rewriteEdit
}

type rewriteEdit struct {
	origStart, origEnd int
	newStart, newEnd   int
}

func (m offsetMap) original(off int) int {
	delta := 0
	for _, e := range m.edits {
		if off < e.newStart {
			break
		}
		if off < e.newEnd {
			return e.origStart
		}
		delta = e.origEnd - e.newEnd
	}
	return off + delta
}

type boundSQL struct {
	sql     string
	args    []any
	names   []string
	missing []string
	offsets offsetMap
}

func usedParams(b boundSQL, values []ParamValue) []ParamValue {
	var out []ParamValue
	for _, n := range b.names {
		for _, v := range values {
			if v.Name == n {
				out = append(out, v)
				break
			}
		}
	}
	return out
}

func bindParams(text, dialect string, values []ParamValue) boundSQL {
	dialect = normalizeDialect(dialect)
	uses := findParams(text, dialect)
	if len(uses) == 0 {
		return boundSQL{sql: text}
	}
	byName := map[string]ParamValue{}
	for _, v := range values {
		byName[v.Name] = v
	}
	var b strings.Builder
	out := boundSQL{}
	numbered := map[string]int{}
	seenMissing := map[string]bool{}
	prev := 0
	for _, u := range uses {
		v, ok := byName[u.name]
		if !seenMissing[u.name] && !containsString(out.names, u.name) {
			out.names = append(out.names, u.name)
		}
		if !ok && !seenMissing[u.name] {
			seenMissing[u.name] = true
			out.missing = append(out.missing, u.name)
		}
		b.WriteString(text[prev:u.start])
		newStart := b.Len()
		if dialect == EnginePostgres {
			n, seen := numbered[u.name]
			if !seen {
				out.args = append(out.args, paramArg(v, dialect))
				n = len(out.args)
				numbered[u.name] = n
			}
			b.WriteString("$" + strconv.Itoa(n))
		} else {
			out.args = append(out.args, paramArg(v, dialect))
			b.WriteByte('?')
		}
		out.offsets.edits = append(out.offsets.edits, rewriteEdit{origStart: u.start, origEnd: u.end, newStart: newStart, newEnd: b.Len()})
		prev = u.end
	}
	b.WriteString(text[prev:])
	out.sql = b.String()
	return out
}

func containsString(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func paramArg(v ParamValue, dialect string) any {
	if v.IsNull {
		return nil
	}
	if dialect == EngineSQLite {
		if n, err := strconv.ParseInt(v.Value, 10, 64); err == nil && strconv.FormatInt(n, 10) == v.Value {
			return n
		}
		if f, err := strconv.ParseFloat(v.Value, 64); err == nil && strconv.FormatFloat(f, 'f', -1, 64) == v.Value {
			return f
		}
	}
	return v.Value
}

func missingParamsError(names []string) *Error {
	sort.Strings(names)
	what := "the parameter " + names[0]
	if len(names) > 1 {
		what = "the parameters " + strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
	}
	return newError("needsParameters", "Enter a value for "+what+" to run this statement.")
}
