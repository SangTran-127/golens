package database

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

const (
	RiskDeleteWithoutWhere = "deleteWithoutWhere"
	RiskUpdateWithoutWhere = "updateWithoutWhere"
	RiskTruncate           = "truncate"
	RiskDropTable          = "dropTable"
	RiskDropSchema         = "dropSchema"
	RiskDropDatabase       = "dropDatabase"
	RiskProductionWrite    = "productionWrite"
)

type txEffect uint8

const (
	txNone txEffect = iota
	txBegin
	txEnd
)

type classification struct {
	kind        string
	writes      bool
	risks       []string
	table       string
	returnsRows bool
	ddl         bool
	tx          txEffect
	session     bool
}

var readOnlyStarts = map[string]string{
	"SELECT": "select", "VALUES": "select", "TABLE": "select", "SHOW": "other", "DESCRIBE": "other", "DESC": "other",
	"FETCH": "other", "MOVE": "other", "CLOSE": "other", "DECLARE": "other", "CHECKSUM": "other", "HANDLER": "other",
}

var explainTargets = map[string]bool{
	"SELECT": true, "INSERT": true, "UPDATE": true, "DELETE": true, "WITH": true, "MERGE": true, "VALUES": true,
	"TABLE": true, "REPLACE": true, "CREATE": true, "DECLARE": true, "EXECUTE": true,
}

var ddlStarts = map[string]bool{
	"CREATE": true, "ALTER": true, "DROP": true, "RENAME": true, "COMMENT": true, "GRANT": true, "REVOKE": true, "TRUNCATE": true,
}

func words(src string, toks []token) (upper []string, depth []int) {
	d := 0
	for _, t := range toks {
		switch {
		case t.kind == tPunct && src[t.start] == '(':
			d++
		case t.kind == tPunct && src[t.start] == ')':
			if d > 0 {
				d--
			}
		}
		if t.kind == tWord {
			upper = append(upper, strings.ToUpper(t.text(src)))
		} else {
			upper = append(upper, "")
		}
		depth = append(depth, d)
	}
	return upper, depth
}

func identAfter(src string, toks []token, from int, skip ...string) string {
	for i := from; i < len(toks); i++ {
		t := toks[i]
		if t.kind == tWord {
			w := strings.ToUpper(t.text(src))
			skipped := false
			for _, s := range skip {
				if w == s {
					skipped = true
					break
				}
			}
			if skipped {
				continue
			}
		}
		if t.kind != tWord && t.kind != tQuoted {
			return ""
		}
		name := unquoteIdent(t.text(src))
		for i+2 < len(toks) && toks[i+1].kind == tPunct && src[toks[i+1].start] == '.' && (toks[i+2].kind == tWord || toks[i+2].kind == tQuoted) {
			name += "." + unquoteIdent(toks[i+2].text(src))
			i += 2
		}
		return name
	}
	return ""
}

func unquoteIdent(s string) string {
	if len(s) >= 2 {
		switch {
		case s[0] == '"' && s[len(s)-1] == '"':
			return strings.ReplaceAll(s[1:len(s)-1], `""`, `"`)
		case s[0] == '`' && s[len(s)-1] == '`':
			return strings.ReplaceAll(s[1:len(s)-1], "``", "`")
		case s[0] == '[' && s[len(s)-1] == ']':
			return s[1 : len(s)-1]
		}
	}
	return s
}

func classify(src string, toks []token, dialect string) classification {
	dialect = normalizeDialect(dialect)
	up, depth := words(src, toks)
	c := classification{kind: "other", writes: true}
	first := -1
	for i, t := range toks {
		if t.kind == tWord {
			first = i
			break
		}
		if !(t.kind == tPunct && src[t.start] == '(') {
			break
		}
	}
	if first < 0 {
		return c
	}
	hasAt0 := func(word string, from int) bool {
		for i := from; i < len(up); i++ {
			if up[i] == word && depth[i] == depth[first] {
				return true
			}
		}
		return false
	}
	w := up[first]
	switch {
	case w == "WITH":
		main := -1
		modifying := false
		for i := first + 1; i < len(up); i++ {
			switch up[i] {
			case "INSERT", "UPDATE", "DELETE", "MERGE":
				prev := ""
				if i > 0 {
					for j := i - 1; j >= 0; j-- {
						if up[j] != "" {
							prev = up[j]
							break
						}
						if toks[j].kind != tSpace && toks[j].kind != tComment {
							break
						}
					}
				}
				if prev == "FOR" || prev == "KEY" || prev == "ON" || prev == "DO" {
					continue
				}
				if depth[i] == depth[first] && main < 0 {
					main = i
				} else if depth[i] > depth[first] {
					modifying = true
				}
			case "SELECT", "VALUES", "TABLE":
				if depth[i] == depth[first] && main < 0 {
					main = i
				}
			}
		}
		if main >= 0 {
			c = classify(src, toks[main:], dialect)
		} else {
			c = classification{kind: "select", returnsRows: true}
		}
		if modifying {
			c.writes = true
			c.returnsRows = true
		}
		return c
	case w == "EXPLAIN":
		c = classification{kind: "explain", returnsRows: true}
		analyze := false
		for i := first + 1; i < len(up); i++ {
			if up[i] == "ANALYZE" || up[i] == "ANALYSE" {
				analyze = true
				continue
			}
			if depth[i] == depth[first] && explainTargets[up[i]] {
				inner := classify(src, toks[i:], dialect)
				if analyze && inner.writes {
					c.writes = true
					c.risks = inner.risks
					c.table = inner.table
				}
				break
			}
		}
		return c
	case readOnlyStarts[w] != "":
		c = classification{kind: readOnlyStarts[w], returnsRows: true}
		if w == "SELECT" && hasAt0("INTO", first+1) {
			c.writes = true
		}
		if w == "DECLARE" || w == "CLOSE" || w == "MOVE" {
			c.returnsRows = false
		}
		return c
	case w == "INSERT" || w == "REPLACE" || w == "UPSERT" || w == "MERGE" || w == "COPY" || w == "LOAD":
		c.kind = "insert"
		if w == "MERGE" || w == "COPY" || w == "LOAD" {
			c.kind = "other"
		}
		c.returnsRows = hasAt0("RETURNING", first+1)
		return c
	case w == "UPDATE" || w == "DELETE":
		c.kind = strings.ToLower(w)
		c.returnsRows = hasAt0("RETURNING", first+1)
		if w == "UPDATE" {
			c.table = identAfter(src, toks, first+1, "ONLY", "LOW_PRIORITY", "IGNORE", "OR", "ROLLBACK", "ABORT", "REPLACE", "FAIL")
			if !hasAt0("WHERE", first+1) {
				c.risks = []string{RiskUpdateWithoutWhere}
			}
		} else {
			c.table = identAfter(src, toks, first+1, "FROM", "ONLY", "LOW_PRIORITY", "QUICK", "IGNORE")
			if !hasAt0("WHERE", first+1) {
				c.risks = []string{RiskDeleteWithoutWhere}
			}
		}
		return c
	case ddlStarts[w]:
		c.kind = "ddl"
		c.ddl = true
		switch w {
		case "TRUNCATE":
			c.risks = []string{RiskTruncate}
			c.table = identAfter(src, toks, first+1, "TABLE", "ONLY")
		case "DROP":
			next := identAfter(src, toks, first+1, "TEMPORARY")
			switch strings.ToUpper(next) {
			case "TABLE":
				c.risks = []string{RiskDropTable}
			case "SCHEMA":
				c.risks = []string{RiskDropSchema}
			case "DATABASE":
				c.risks = []string{RiskDropDatabase}
			}
			if len(c.risks) > 0 {
				c.table = identAfter(src, toks, first+1, "TEMPORARY", "TABLE", "SCHEMA", "DATABASE", "IF", "EXISTS")
			}
		}
		return c
	case w == "BEGIN" || w == "START" || w == "SAVEPOINT" || w == "RELEASE":
		c = classification{kind: "transaction"}
		if w == "BEGIN" || w == "START" {
			c.tx = txBegin
		}
		if mentionsReadWrite(up) {
			c.writes = true
		}
		return c
	case w == "COMMIT" || w == "END" || w == "ROLLBACK" || w == "ABORT":
		c = classification{kind: "transaction", tx: txEnd}
		if w == "ROLLBACK" && hasAt0("TO", first+1) {
			c.tx = txNone
		}
		if (w == "COMMIT" || w == "ROLLBACK") && hasAt0("CHAIN", first+1) && !hasAt0("NO", first+1) {
			c.tx = txNone
		}
		return c
	case w == "SET" || w == "USE" || w == "RESET" || w == "DISCARD" || w == "LISTEN" || w == "UNLISTEN" || w == "DEALLOCATE" || w == "PREPARE":
		c = classification{kind: "session", session: true}
		if mentionsReadWrite(up) || touchesReadOnlySetting(src, toks) || (w == "RESET" && dialect == EngineMySQL) {
			c.writes = true
		}
		return c
	case w == "PRAGMA":
		c = classification{kind: "session", session: true, returnsRows: true}
		for _, t := range toks[first+1:] {
			if t.kind == tPunct && src[t.start] == '=' {
				c.writes = true
			}
		}
		if !c.writes && !readPragma(src, toks[first+1:]) {
			c.writes = true
		}
		return c
	}
	c.returnsRows = true
	return c
}

func mentionsReadWrite(up []string) bool {
	for i := 0; i+1 < len(up); i++ {
		if up[i] == "READ" {
			for j := i + 1; j < len(up); j++ {
				if up[j] == "" {
					continue
				}
				if up[j] == "WRITE" {
					return true
				}
				break
			}
		}
	}
	return false
}

func touchesReadOnlySetting(src string, toks []token) bool {
	for _, t := range toks {
		low := strings.ToLower(t.text(src))
		if strings.Contains(low, "read_only") || strings.Contains(low, "query_only") || strings.Contains(low, "session characteristics") {
			return true
		}
		if t.kind == tWord && strings.EqualFold(t.text(src), "CHARACTERISTICS") {
			return true
		}
	}
	return false
}

var readPragmas = map[string]bool{
	"TABLE_INFO": true, "TABLE_XINFO": true, "INDEX_LIST": true, "INDEX_INFO": true, "INDEX_XINFO": true,
	"FOREIGN_KEY_LIST": true, "DATABASE_LIST": true, "COMPILE_OPTIONS": true, "COLLATION_LIST": true,
	"FUNCTION_LIST": true, "PRAGMA_LIST": true, "MODULE_LIST": true, "TABLE_LIST": true, "INTEGRITY_CHECK": true,
	"QUICK_CHECK": true, "FOREIGN_KEY_CHECK": true, "SCHEMA_VERSION": true, "USER_VERSION": true, "PAGE_COUNT": true,
	"FREELIST_COUNT": true, "DATA_VERSION": true, "ENCODING": true, "PAGE_SIZE": true, "JOURNAL_MODE": true,
	"FOREIGN_KEYS": true, "QUERY_ONLY": true, "BUSY_TIMEOUT": true, "APPLICATION_ID": true, "AUTO_VACUUM": true,
	"CACHE_SIZE": true, "SYNCHRONOUS": true, "TEMP_STORE": true, "MMAP_SIZE": true, "LOCKING_MODE": true,
}

var pragmaArgReads = map[string]bool{
	"TABLE_INFO": true, "TABLE_XINFO": true, "INDEX_LIST": true, "INDEX_INFO": true, "INDEX_XINFO": true,
	"FOREIGN_KEY_LIST": true, "INTEGRITY_CHECK": true, "QUICK_CHECK": true, "FOREIGN_KEY_CHECK": true, "TABLE_LIST": true,
}

func readPragma(src string, toks []token) bool {
	name := ""
	hasArg := false
	for _, t := range toks {
		switch {
		case t.kind == tWord:
			name = strings.ToUpper(t.text(src))
		case t.kind == tPunct && src[t.start] == '(':
			hasArg = true
		}
		if hasArg {
			break
		}
	}
	if hasArg {
		return pragmaArgReads[name]
	}
	return readPragmas[name]
}

func statementHash(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func preview(text string) string {
	p := strings.Join(strings.Fields(text), " ")
	if len(p) > 80 {
		cut := 80
		for cut > 0 && p[cut]&0xC0 == 0x80 {
			cut--
		}
		p = p[:cut] + "…"
	}
	return p
}

func Statements(text, dialect string) []StatementInfo {
	out := []StatementInfo{}
	for i, st := range splitStatements(text, dialect) {
		c := classify(text, st.toks, dialect)
		risks := c.risks
		if risks == nil {
			risks = []string{}
		}
		out = append(out, StatementInfo{Index: i, StartByte: st.start, EndByte: st.end, Line: st.line, Kind: c.kind, Writes: c.writes, Risks: risks})
	}
	return out
}
