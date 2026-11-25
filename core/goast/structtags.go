package goast

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strconv"
	"strings"
	"unicode"
)

const (
	errJSONMustBeObjectOrArray = "JSON input must be an object or array of objects"
)

type StructTagRequest struct {
	Path      string   `json:"path"`
	Src       string   `json:"src"`
	Offset    int      `json:"offset"`
	Action    string   `json:"action"`
	Tags      []string `json:"tags"`
	Transform string   `json:"transform"`
	OmitEmpty bool     `json:"omitempty"`
}

type JSONToStructRequest struct {
	JSONText string `json:"jsonText"`
	TypeName string `json:"typeName"`
}

type JSONToStructResponse struct {
	GoCode string `json:"goCode,omitempty"`
	Error  string `json:"error,omitempty"`
}

type structTagPair struct {
	Key   string
	Value string
}

var commonInitialisms = map[string]string{
	"acl":   "ACL",
	"api":   "API",
	"ascii": "ASCII",
	"cpu":   "CPU",
	"css":   "CSS",
	"db":    "DB",
	"dns":   "DNS",
	"eof":   "EOF",
	"gpu":   "GPU",
	"guid":  "GUID",
	"html":  "HTML",
	"http":  "HTTP",
	"https": "HTTPS",
	"id":    "ID",
	"ip":    "IP",
	"json":  "JSON",
	"jwt":   "JWT",
	"lhs":   "LHS",
	"os":    "OS",
	"qps":   "QPS",
	"ram":   "RAM",
	"rhs":   "RHS",
	"rpc":   "RPC",
	"sla":   "SLA",
	"smtp":  "SMTP",
	"sql":   "SQL",
	"ssh":   "SSH",
	"tcp":   "TCP",
	"tls":   "TLS",
	"ttl":   "TTL",
	"udp":   "UDP",
	"ui":    "UI",
	"uid":   "UID",
	"uri":   "URI",
	"url":   "URL",
	"utf8":  "UTF8",
	"uuid":  "UUID",
	"vm":    "VM",
	"xml":   "XML",
	"xsrf":  "XSRF",
	"xss":   "XSS",
	"yaml":  "YAML",
}

func marshalStructTagError(msg string) string {
	b, _ := json.Marshal(GenerateCodeResponse{
		Error: msg,
	})
	return string(b)
}

func ModifyStructTags(reqJSON string) string {
	var req StructTagRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return marshalStructTagError("invalid request: " + err.Error())
	}

	var src []byte
	if req.Src != "" {
		src = []byte(req.Src)
	} else if strings.TrimSpace(req.Path) != "" {
		data, err := os.ReadFile(req.Path)
		if err != nil {
			return marshalStructTagError("failed to read file: " + err.Error())
		}
		src = data
	} else {
		return marshalStructTagError("missing source or file path")
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, req.Path, src, parser.ParseComments)
	if file == nil {
		if err != nil {
			return marshalStructTagError("failed to parse file: " + err.Error())
		}
		return marshalStructTagError("failed to parse file")
	}
	tf := fset.File(file.Pos())
	if tf == nil {
		return marshalStructTagError("failed to locate token file")
	}

	offset := req.Offset
	if offset < 0 {
		offset = 0
	}
	if offset > tf.Size() {
		offset = tf.Size()
	}
	pos := tf.Pos(offset)

	targetStruct := findTargetStructType(fset, file, pos)
	if targetStruct == nil {
		return marshalStructTagError("No struct found in current file")
	}

	action := strings.ToLower(strings.TrimSpace(req.Action))
	if action == "" {
		action = "add"
	}

	tags := make([]string, 0, len(req.Tags))
	for _, t := range req.Tags {
		trimmed := strings.TrimSpace(t)
		if trimmed != "" {
			tags = append(tags, trimmed)
		}
	}
	if action == "add" && len(tags) == 0 {
		tags = []string{"json"}
	}

	transform := strings.ToLower(strings.TrimSpace(req.Transform))
	if transform == "" {
		transform = "snake"
	}

	type tagPatch struct {
		start int
		end   int
		text  string
	}
	var patches []tagPatch

	if targetStruct.Fields != nil {
		for _, field := range targetStruct.Fields.List {
			if len(field.Names) == 0 || field.Names[0] == nil {
				continue
			}
			fieldName := field.Names[0].Name
			if fieldName == "" || fieldName == "_" {
				continue
			}

			var existingPairs []structTagPair
			if field.Tag != nil {
				existingPairs = parseStructTagLiteral(field.Tag.Value)
			}

			newTagLiteral := ""
			if action == "remove" {
				if len(tags) > 0 {
					removeSet := make(map[string]bool, len(tags))
					for _, k := range tags {
						removeSet[k] = true
					}
					var kept []structTagPair
					for _, pair := range existingPairs {
						if !removeSet[pair.Key] {
							kept = append(kept, pair)
						}
					}
					if len(kept) > 0 {
						newTagLiteral = formatStructTagPairs(kept)
					}
				}
			} else {
				transformed := transformFieldName(fieldName, transform)
				for _, k := range tags {
					if !isValidStructTagKey(k) {
						continue
					}
					val := transformed
					if req.OmitEmpty && k != "db" {
						val += ",omitempty"
					}
					existingPairs = upsertStructTagPair(existingPairs, k, val)
				}
				if len(existingPairs) > 0 {
					newTagLiteral = formatStructTagPairs(existingPairs)
				}
			}

			if field.Tag != nil {
				tagStart := fset.Position(field.Tag.Pos()).Offset
				tagEnd := fset.Position(field.Tag.End()).Offset
				if tagStart >= 0 && tagEnd >= tagStart && tagEnd <= len(src) {
					if newTagLiteral != field.Tag.Value {
						patches = append(patches, tagPatch{
							start: tagStart,
							end:   tagEnd,
							text:  newTagLiteral,
						})
					}
				}
			} else if newTagLiteral != "" && field.Type != nil {
				typeEnd := fset.Position(field.Type.End()).Offset
				if typeEnd >= 0 && typeEnd <= len(src) {
					patches = append(patches, tagPatch{
						start: typeEnd,
						end:   typeEnd,
						text:  " " + newTagLiteral,
					})
				}
			}
		}
	}

	patched := src
	if len(patches) > 0 {
		sort.Slice(patches, func(i, j int) bool {
			return patches[i].start > patches[j].start
		})
		outBytes := make([]byte, len(src))
		copy(outBytes, src)
		for _, p := range patches {
			var next []byte
			next = append(next, outBytes[:p.start]...)
			next = append(next, []byte(p.text)...)
			next = append(next, outBytes[p.end:]...)
			outBytes = next
		}
		patched = outBytes
	}

	formatted, fmtErr := format.Source(patched)
	if fmtErr != nil {
		formatted = patched
	}

	startPos := tf.Pos(0)
	endPos := tf.Pos(tf.Size())
	resp := GenerateCodeResponse{
		EditsByPath: map[string][]SigTextEdit{
			req.Path: {
				{
					Range:   lspRange(fset, src, startPos, endPos),
					NewText: string(formatted),
				},
			},
		},
	}
	b, _ := json.Marshal(resp)
	return string(b)
}

func findTargetStructType(fset *token.FileSet, file *ast.File, pos token.Pos) *ast.StructType {
	type candidate struct {
		st        *ast.StructType
		startPos  token.Pos
		endPos    token.Pos
		startLine int
		endLine   int
	}

	var candidates []candidate
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.TYPE {
			continue
		}
		for _, spec := range gd.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok {
				continue
			}
			if st, ok := ts.Type.(*ast.StructType); ok {
				sPos := gd.Pos()
				if len(gd.Specs) > 1 {
					sPos = ts.Pos()
				}
				ePos := ts.End()
				candidates = append(candidates, candidate{
					st:        st,
					startPos:  sPos,
					endPos:    ePos,
					startLine: fset.Position(sPos).Line,
					endLine:   fset.Position(ePos).Line,
				})
			}
		}
	}

	ast.Inspect(file, func(n ast.Node) bool {
		st, ok := n.(*ast.StructType)
		if !ok {
			return true
		}
		for _, c := range candidates {
			if c.st == st {
				return true
			}
		}
		candidates = append(candidates, candidate{
			st:        st,
			startPos:  st.Pos(),
			endPos:    st.End(),
			startLine: fset.Position(st.Pos()).Line,
			endLine:   fset.Position(st.End()).Line,
		})
		return true
	})

	if len(candidates) == 0 {
		return nil
	}

	var enclosing *candidate
	for i := range candidates {
		c := &candidates[i]
		if pos >= c.st.Pos() && pos <= c.st.End() {
			if enclosing == nil || (c.st.Pos() >= enclosing.st.Pos() && c.st.End() <= enclosing.st.End()) {
				enclosing = c
			}
		}
	}
	if enclosing != nil {
		return enclosing.st
	}

	for i := range candidates {
		c := &candidates[i]
		if pos >= c.startPos && pos <= c.endPos {
			return c.st
		}
	}

	targetLine := fset.Position(pos).Line
	bestIdx := 0
	bestDist := lineDistance(targetLine, candidates[0].startLine, candidates[0].endLine)
	for i := 1; i < len(candidates); i++ {
		dist := lineDistance(targetLine, candidates[i].startLine, candidates[i].endLine)
		if dist < bestDist {
			bestDist = dist
			bestIdx = i
		}
	}
	return candidates[bestIdx].st
}

func lineDistance(line, startLine, endLine int) int {
	if line < startLine {
		return startLine - line
	}
	if line > endLine {
		return line - endLine
	}
	return 0
}

func isValidStructTagKey(key string) bool {
	if key == "" {
		return false
	}
	for i := 0; i < len(key); i++ {
		c := key[i]
		if c <= ' ' || c == ':' || c == '"' || c == 0x7f {
			return false
		}
	}
	return true
}

func parseStructTagLiteral(rawLiteral string) []structTagPair {
	raw := strings.TrimSpace(rawLiteral)
	tag := raw
	if unquoted, err := strconv.Unquote(raw); err == nil {
		tag = unquoted
	} else if len(raw) >= 2 && ((raw[0] == '`' && raw[len(raw)-1] == '`') || (raw[0] == '"' && raw[len(raw)-1] == '"')) {
		tag = raw[1 : len(raw)-1]
	}

	var pairs []structTagPair
	for tag != "" {
		i := 0
		for i < len(tag) && (tag[i] == ' ' || tag[i] == '\t') {
			i++
		}
		tag = tag[i:]
		if tag == "" {
			break
		}

		i = 0
		for i < len(tag) && tag[i] > ' ' && tag[i] != ':' && tag[i] != '"' && tag[i] != 0x7f {
			i++
		}
		if i == 0 || i+1 >= len(tag) || tag[i] != ':' || tag[i+1] != '"' {
			break
		}
		key := tag[:i]
		tag = tag[i+1:]

		i = 1
		for i < len(tag) && tag[i] != '"' {
			if tag[i] == '\\' {
				i++
			}
			i++
		}
		if i >= len(tag) {
			break
		}
		valLiteral := tag[:i+1]
		val := tag[1:i]
		if unq, err := strconv.Unquote(valLiteral); err == nil {
			val = unq
		}
		tag = tag[i+1:]

		pairs = append(pairs, structTagPair{
			Key:   key,
			Value: val,
		})
	}
	return pairs
}

func upsertStructTagPair(pairs []structTagPair, key, value string) []structTagPair {
	for i := range pairs {
		if pairs[i].Key == key {
			pairs[i].Value = value
			return pairs
		}
	}
	return append(pairs, structTagPair{
		Key:   key,
		Value: value,
	})
}

func formatStructTagPairs(pairs []structTagPair) string {
	parts := make([]string, 0, len(pairs))
	for _, p := range pairs {
		if !isValidStructTagKey(p.Key) {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s:%s", p.Key, strconv.Quote(p.Value)))
	}
	joined := strings.Join(parts, " ")
	if joined == "" {
		return ""
	}
	if strings.ContainsAny(joined, "`\n\r") {
		return strconv.Quote(joined)
	}
	return "`" + joined + "`"
}

func splitIdentifierWords(ident string) []string {
	var words []string
	tokens := strings.FieldsFunc(ident, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	for _, tok := range tokens {
		runes := []rune(tok)
		if len(runes) == 0 {
			continue
		}
		start := 0
		for i := 1; i < len(runes); i++ {
			prev := runes[i-1]
			curr := runes[i]
			if unicode.IsUpper(curr) {
				if unicode.IsLower(prev) || unicode.IsDigit(prev) {
					words = append(words, string(runes[start:i]))
					start = i
					continue
				}
				if unicode.IsUpper(prev) && i+1 < len(runes) && unicode.IsLower(runes[i+1]) {
					words = append(words, string(runes[start:i]))
					start = i
					continue
				}
			}
		}
		words = append(words, string(runes[start:]))
	}
	return words
}

func transformFieldName(fieldName, transform string) string {
	words := splitIdentifierWords(fieldName)
	if len(words) == 0 {
		return fieldName
	}

	switch transform {
	case "camel":
		var sb strings.Builder
		for i, w := range words {
			lower := strings.ToLower(w)
			if i == 0 {
				sb.WriteString(lower)
			} else {
				runes := []rune(lower)
				runes[0] = unicode.ToUpper(runes[0])
				sb.WriteString(string(runes))
			}
		}
		return sb.String()

	case "pascal":
		var sb strings.Builder
		for _, w := range words {
			lower := strings.ToLower(w)
			if initWord, ok := commonInitialisms[lower]; ok {
				sb.WriteString(initWord)
			} else if isAllUpperWord(w) && len(w) > 1 {
				sb.WriteString(w)
			} else {
				runes := []rune(lower)
				runes[0] = unicode.ToUpper(runes[0])
				sb.WriteString(string(runes))
			}
		}
		return sb.String()

	case "kebab":
		lowered := make([]string, len(words))
		for i, w := range words {
			lowered[i] = strings.ToLower(w)
		}
		return strings.Join(lowered, "-")

	default:
		lowered := make([]string, len(words))
		for i, w := range words {
			lowered[i] = strings.ToLower(w)
		}
		return strings.Join(lowered, "_")
	}
}

func isAllUpperWord(w string) bool {
	hasLetter := false
	for _, r := range w {
		if unicode.IsLetter(r) {
			hasLetter = true
			if !unicode.IsUpper(r) {
				return false
			}
		}
	}
	return hasLetter
}

func marshalJSONToStructError(msg string) string {
	b, _ := json.Marshal(JSONToStructResponse{
		Error: msg,
	})
	return string(b)
}

func JSONToGoStruct(reqJSON string) string {
	var req JSONToStructRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return marshalJSONToStructError("invalid request: " + err.Error())
	}

	trimmedJSON := strings.TrimSpace(req.JSONText)
	if trimmedJSON == "" {
		return marshalJSONToStructError(errJSONMustBeObjectOrArray)
	}

	dec := json.NewDecoder(strings.NewReader(trimmedJSON))
	dec.UseNumber()

	var root any
	if err := dec.Decode(&root); err != nil {
		return marshalJSONToStructError("Invalid JSON: " + err.Error())
	}

	var objMap map[string]any
	switch v := root.(type) {
	case map[string]any:
		objMap = v
	case []any:
		merged := mergeObjectSlice(v)
		if merged == nil {
			return marshalJSONToStructError(errJSONMustBeObjectOrArray)
		}
		objMap = merged
	default:
		return marshalJSONToStructError(errJSONMustBeObjectOrArray)
	}

	typeName := sanitizeExportedIdent(req.TypeName, "AutoGenerated")
	structExpr := buildGoStructExpr(objMap)
	rawCode := fmt.Sprintf("type %s %s", typeName, structExpr)

	formatted, err := format.Source([]byte(rawCode))
	if err != nil {
		formatted = []byte(rawCode)
	}

	resp := JSONToStructResponse{
		GoCode: strings.TrimSpace(string(formatted)),
	}
	b, _ := json.Marshal(resp)
	return string(b)
}

type jsonConflictAny struct{}

func mergeJSONSampleValues(a, b any) any {
	if a == nil {
		return b
	}
	if b == nil {
		return a
	}
	if _, ok := a.(jsonConflictAny); ok {
		return a
	}
	if _, ok := b.(jsonConflictAny); ok {
		return b
	}
	if ma, okA := a.(map[string]any); okA {
		if mb, okB := b.(map[string]any); okB {
			merged := make(map[string]any, len(ma)+len(mb))
			for k, v := range ma {
				merged[k] = v
			}
			for k, v := range mb {
				if existing, exists := merged[k]; exists {
					merged[k] = mergeJSONSampleValues(existing, v)
				} else {
					merged[k] = v
				}
			}
			return merged
		}
		return jsonConflictAny{}
	}
	if sa, okA := a.([]any); okA {
		if sb, okB := b.([]any); okB {
			return append(append(make([]any, 0, len(sa)+len(sb)), sa...), sb...)
		}
	}
	ta := inferGoType(a)
	tb := inferGoType(b)
	if ta == tb {
		return a
	}
	if (ta == "int" && (tb == "float64" || tb == "uint64")) || ((ta == "float64" || ta == "uint64") && tb == "int") || (ta == "uint64" && tb == "float64") || (ta == "float64" && tb == "uint64") {
		if ta == "float64" || tb == "float64" {
			return float64(0)
		}
		return json.Number("18446744073709551615")
	}
	return jsonConflictAny{}
}

func mergeObjectSlice(items []any) map[string]any {
	var merged map[string]any
	foundObject := false
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		if !foundObject {
			merged = make(map[string]any, len(m))
			foundObject = true
		}
		for k, v := range m {
			existing, exists := merged[k]
			if !exists {
				merged[k] = v
			} else {
				merged[k] = mergeJSONSampleValues(existing, v)
			}
		}
	}
	if !foundObject {
		return nil
	}
	return merged
}

func sortJSONKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		ki := keys[i]
		kj := keys[j]
		if ki == "id" && kj != "id" {
			return true
		}
		if kj == "id" && ki != "id" {
			return false
		}
		if strings.EqualFold(ki, "id") && !strings.EqualFold(kj, "id") {
			return true
		}
		if strings.EqualFold(kj, "id") && !strings.EqualFold(ki, "id") {
			return false
		}
		return ki < kj
	})
	return keys
}

func sanitizeExportedIdent(raw string, fallback string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return fallback
	}
	words := splitIdentifierWords(trimmed)
	if len(words) == 0 {
		return fallback
	}
	var sb strings.Builder
	for _, w := range words {
		lower := strings.ToLower(w)
		if initWord, ok := commonInitialisms[lower]; ok {
			sb.WriteString(initWord)
		} else {
			runes := []rune(lower)
			runes[0] = unicode.ToUpper(runes[0])
			sb.WriteString(string(runes))
		}
	}
	out := sb.String()
	if out == "" {
		return fallback
	}
	firstRune := []rune(out)[0]
	if unicode.IsDigit(firstRune) {
		out = "Field" + out
	}
	return out
}

func buildGoStructExpr(obj map[string]any) string {
	if len(obj) == 0 {
		return "struct{}"
	}
	keys := sortJSONKeys(obj)
	usedFieldNames := make(map[string]bool, len(keys))
	var lines []string

	for _, k := range keys {
		fieldName := sanitizeExportedIdent(k, "Field")
		base := fieldName
		for suffix := 2; usedFieldNames[fieldName]; suffix++ {
			fieldName = fmt.Sprintf("%s%d", base, suffix)
		}
		usedFieldNames[fieldName] = true

		goType := inferGoType(obj[k])
		tagLiteral := formatStructTagPairs([]structTagPair{{Key: "json", Value: k}})
		lines = append(lines, fmt.Sprintf("\t%s %s %s", fieldName, goType, tagLiteral))
	}

	return "struct {\n" + strings.Join(lines, "\n") + "\n}"
}

func inferGoType(val any) string {
	if val == nil {
		return "any"
	}
	switch v := val.(type) {
	case jsonConflictAny:
		return "any"
	case string:
		return "string"
	case bool:
		return "bool"
	case json.Number:
		s := v.String()
		if strings.ContainsAny(s, ".eE") {
			return "float64"
		}
		if _, err := strconv.ParseInt(s, 10, 64); err == nil {
			return "int"
		}
		if _, err := strconv.ParseUint(s, 10, 64); err == nil {
			return "uint64"
		}
		return "float64"
	case float64:
		return "float64"
	case map[string]any:
		return buildGoStructExpr(v)
	case []any:
		return inferSliceGoType(v)
	default:
		return "any"
	}
}

func inferSliceGoType(items []any) string {
	if len(items) == 0 {
		return "[]any"
	}
	mergedObj := mergeObjectSlice(items)
	if mergedObj != nil {
		allObjectsOrNil := true
		for _, item := range items {
			if item == nil {
				continue
			}
			if _, ok := item.(map[string]any); !ok {
				allObjectsOrNil = false
				break
			}
		}
		if allObjectsOrNil {
			return "[]" + buildGoStructExpr(mergedObj)
		}
	}

	elemType := ""
	for _, item := range items {
		if item == nil {
			continue
		}
		t := inferGoType(item)
		if elemType == "" {
			elemType = t
			continue
		}
		if elemType == t {
			continue
		}
		if (elemType == "int" && t == "float64") || (elemType == "float64" && t == "int") {
			elemType = "float64"
			continue
		}
		return "[]any"
	}
	if elemType == "" {
		return "[]any"
	}
	return "[]" + elemType
}
