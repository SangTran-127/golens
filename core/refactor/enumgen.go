package refactor

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type EnumTypeInfo struct {
	Name           string   `json:"name"`
	UnderlyingType string   `json:"underlyingType"`
	Line           int      `json:"line"`
	Values         []string `json:"values"`
}

type ListEnumTypesRequest struct {
	Content    string `json:"content"`
	CursorLine int    `json:"cursorLine"`
}

type ListEnumTypesResult struct {
	Enums        []EnumTypeInfo `json:"enums"`
	SelectedEnum string         `json:"selectedEnum"`
	Error        string         `json:"error,omitempty"`
}

type GenerateEnumRequest struct {
	Content               string `json:"content"`
	EnumName              string `json:"enumName"`
	CursorLine            int    `json:"cursorLine"`
	TrimTypePrefix        bool   `json:"trimTypePrefix"`
	LowercaseStrings      bool   `json:"lowercaseStrings"`
	GenerateParse         bool   `json:"generateParse"`
	GenerateTextMarshaler bool   `json:"generateTextMarshaler"`
	GenerateIsValid       bool   `json:"generateIsValid"`
}

type GenerateEnumResult struct {
	EnumName      string `json:"enumName"`
	GeneratedCode string `json:"generatedCode"`
	NewContent    string `json:"newContent"`
	InsertLine    int    `json:"insertLine"`
	ValueCount    int    `json:"valueCount"`
	Error         string `json:"error,omitempty"`
}

type discoveredSingleFileEnum struct {
	info              EnumTypeInfo
	structName        string
	hasExplicitType   bool
	hasExplicitConsts bool
	aliasConsts       map[string]bool
	spans             []enumLineSpan
}

func ListEnumTypes(reqJSON string) string {
	var req ListEnumTypesRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		res := ListEnumTypesResult{
			Enums: []EnumTypeInfo{},
			Error: fmt.Sprintf("invalid request JSON: %v", err),
		}
		b, _ := json.Marshal(res)
		return string(b)
	}

	enums, selected, err := discoverSingleFileEnums(req.Content, req.CursorLine)
	if err != nil {
		res := ListEnumTypesResult{
			Enums: []EnumTypeInfo{},
			Error: err.Error(),
		}
		b, _ := json.Marshal(res)
		return string(b)
	}

	infos := make([]EnumTypeInfo, 0, len(enums))
	for _, e := range enums {
		infos = append(infos, e.info)
	}

	res := ListEnumTypesResult{
		Enums:        infos,
		SelectedEnum: selected,
	}
	b, _ := json.Marshal(res)
	return string(b)
}

func GenerateEnumMethods(reqJSON string) string {
	var req GenerateEnumRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		res := GenerateEnumResult{
			Error: fmt.Sprintf("invalid request JSON: %v", err),
		}
		b, _ := json.Marshal(res)
		return string(b)
	}

	enums, selectedName, err := discoverSingleFileEnums(req.Content, req.CursorLine)
	if err != nil {
		res := GenerateEnumResult{
			Error: err.Error(),
		}
		b, _ := json.Marshal(res)
		return string(b)
	}

	var target *discoveredSingleFileEnum
	wanted := strings.TrimSpace(req.EnumName)
	if wanted != "" {
		for i := range enums {
			if enums[i].info.Name == wanted || enums[i].structName == wanted {
				target = &enums[i]
				break
			}
		}
		if target == nil {
			for i := range enums {
				if strings.EqualFold(enums[i].info.Name, wanted) || strings.EqualFold(enums[i].structName, wanted) {
					target = &enums[i]
					break
				}
			}
		}
		if target == nil {
			synth := discoveredSingleFileEnum{
				info: EnumTypeInfo{
					Name:           wanted,
					UnderlyingType: "int",
					Line:           1,
					Values: []string{
						wanted + "Unknown",
						wanted + "Active",
						wanted + "Pending",
					},
				},
				hasExplicitType:   false,
				hasExplicitConsts: false,
			}
			target = &synth
		}
	} else {
		for i := range enums {
			if enums[i].info.Name == selectedName {
				target = &enums[i]
				break
			}
		}
		if target == nil && len(enums) > 0 {
			target = &enums[0]
		}
	}

	if target == nil {
		res := GenerateEnumResult{
			Error: "no enum type found in source",
		}
		b, _ := json.Marshal(res)
		return string(b)
	}

	generatedCode := buildFullEnumCode(*target, req)
	trimmedOrig := removeExistingEnumDecls(req.Content, target.info.Name, generatedCode)
	trimmedOrig = strings.TrimRight(trimmedOrig, " \t\r\n")
	insertLine := 1
	if trimmedOrig != "" {
		insertLine = strings.Count(trimmedOrig, "\n") + 3
	}

	combined := generatedCode + "\n"
	if trimmedOrig != "" {
		combined = trimmedOrig + "\n\n" + generatedCode + "\n"
	}
	var reqImports []string
	if strings.Contains(generatedCode, "fmt.") {
		reqImports = append(reqImports, "fmt")
	}
	withImports := ensureRequiredImports(combined, reqImports)
	newContent := withImports
	if formatted, fmtErr := format.Source([]byte(withImports)); fmtErr == nil {
		newContent = string(formatted)
	}

	res := GenerateEnumResult{
		EnumName:      target.info.Name,
		GeneratedCode: generatedCode,
		NewContent:    newContent,
		InsertLine:    insertLine,
		ValueCount:    len(target.info.Values),
	}
	b, _ := json.Marshal(res)
	return string(b)
}

func discoverSingleFileEnums(content string, cursorLine int) ([]discoveredSingleFileEnum, string, error) {
	if strings.TrimSpace(content) == "" {
		return nil, "", fmt.Errorf("empty Go source content")
	}

	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "input.go", content, parser.ParseComments)
	if err != nil && f == nil {
		return nil, "", fmt.Errorf("failed to parse Go file: %v", err)
	}

	var enums []discoveredSingleFileEnum
	enumIndexByName := map[string]int{}

	type structDeclSpan struct {
		name      string
		startLine int
		endLine   int
	}
	var structs []structDeclSpan

	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.TYPE {
			continue
		}
		for _, spec := range gd.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok || ts.Name == nil || ts.Name.Name == "" || ts.Assign.IsValid() {
				continue
			}
			if ts.TypeParams != nil && len(ts.TypeParams.List) > 0 {
				continue
			}
			startLn := fset.Position(ts.Pos()).Line
			endLn := fset.Position(ts.End()).Line
			if len(gd.Specs) == 1 {
				startLn = fset.Position(gd.Pos()).Line
				endLn = fset.Position(gd.End()).Line
			}

			switch t := ts.Type.(type) {
			case *ast.Ident:
				if isSupportedEnumUnderlyingType(t.Name) {
					idx := len(enums)
					enums = append(enums, discoveredSingleFileEnum{
						info: EnumTypeInfo{
							Name:           ts.Name.Name,
							UnderlyingType: t.Name,
							Line:           fset.Position(ts.Pos()).Line,
							Values:         []string{},
						},
						hasExplicitType:   true,
						hasExplicitConsts: false,
						spans: []enumLineSpan{
							{startLine: startLn, endLine: endLn},
						},
					})
					if _, exists := enumIndexByName[ts.Name.Name]; !exists {
						enumIndexByName[ts.Name.Name] = idx
					}
				}
			case *ast.StructType:
				structs = append(structs, structDeclSpan{
					name:      ts.Name.Name,
					startLine: fset.Position(ts.Pos()).Line,
					endLine:   endLn,
				})
			}
		}
	}

	matchPrefixEnum := func(constName string) string {
		best := ""
		for i := range enums {
			en := enums[i].info.Name
			if strings.HasPrefix(constName, en) && len(constName) > len(en) {
				if len(en) > len(best) {
					best = en
				}
			}
		}
		return best
	}

	lastEnumTypeInFile := ""
	seenConstForEnum := map[string]map[string]bool{}
	seenValueForEnum := map[string]map[string]string{}
	constValueByName := map[string]string{}

	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}
		if gd.Tok == token.TYPE {
			for _, spec := range gd.Specs {
				if ts, ok := spec.(*ast.TypeSpec); ok && ts.Name != nil {
					if _, exists := enumIndexByName[ts.Name.Name]; exists {
						lastEnumTypeInFile = ts.Name.Name
					}
				}
			}
			continue
		}
		if gd.Tok != token.CONST {
			continue
		}

		constStartLn := fset.Position(gd.Pos()).Line
		constEndLn := fset.Position(gd.End()).Line
		currentType := ""
		blockEnumType := ""
		var inheritedValues []ast.Expr

		for specIdx, spec := range gd.Specs {
			vs, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			activeValues := vs.Values
			if len(activeValues) > 0 {
				inheritedValues = activeValues
			} else {
				activeValues = inheritedValues
			}

			specType := ""
			if vs.Type != nil {
				if ident, ok := vs.Type.(*ast.Ident); ok {
					specType = ident.Name
				}
				currentType = specType
			} else if len(vs.Values) > 0 {
				inferred := ""
				if call, ok := vs.Values[0].(*ast.CallExpr); ok {
					if funIdent, ok := call.Fun.(*ast.Ident); ok {
						if _, exists := enumIndexByName[funIdent.Name]; exists {
							inferred = funIdent.Name
						}
					}
				}
				if inferred != "" {
					specType = inferred
					currentType = inferred
				} else if blockEnumType != "" && usesIotaExpr(vs.Values[0]) {
					specType = blockEnumType
					currentType = blockEnumType
				} else {
					currentType = ""
				}
			} else {
				specType = currentType
			}

			if specType == "" {
				for _, ident := range vs.Names {
					if ident == nil || ident.Name == "" || ident.Name == "_" {
						continue
					}
					if matched := matchPrefixEnum(ident.Name); matched != "" {
						specType = matched
						if len(vs.Values) > 0 && usesIotaExpr(vs.Values[0]) {
							currentType = matched
						}
						break
					}
				}
			}

			if specType == "" && lastEnumTypeInFile != "" && len(vs.Values) > 0 && usesIotaExpr(vs.Values[0]) {
				specType = lastEnumTypeInFile
				currentType = lastEnumTypeInFile
			}

			if specType != "" {
				if _, exists := enumIndexByName[specType]; exists && blockEnumType == "" {
					blockEnumType = specType
				}
			}

			enumIdx, exists := enumIndexByName[specType]
			if !exists {
				continue
			}

			if seenConstForEnum[specType] == nil {
				seenConstForEnum[specType] = map[string]bool{}
			}
			if seenValueForEnum[specType] == nil {
				seenValueForEnum[specType] = map[string]string{}
			}
			if enums[enumIdx].aliasConsts == nil {
				enums[enumIdx].aliasConsts = map[string]bool{}
			}
			for nameIdx, ident := range vs.Names {
				if ident == nil || ident.Name == "" || ident.Name == "_" {
					continue
				}
				var valExpr ast.Expr
				if nameIdx < len(activeValues) {
					valExpr = activeValues[nameIdx]
				} else if len(activeValues) == 1 {
					valExpr = activeValues[0]
				}
				valKey := resolveEnumConstValueKey(fset, specType, valExpr, specIdx, constValueByName)
				if valKey != "" {
					constValueByName[ident.Name] = valKey
				}
				if !seenConstForEnum[specType][ident.Name] {
					seenConstForEnum[specType][ident.Name] = true
					if valKey != "" {
						if prevConst, dup := seenValueForEnum[specType][valKey]; dup && prevConst != ident.Name {
							enums[enumIdx].aliasConsts[ident.Name] = true
						} else {
							seenValueForEnum[specType][valKey] = ident.Name
						}
					}
					enums[enumIdx].info.Values = append(enums[enumIdx].info.Values, ident.Name)
					enums[enumIdx].hasExplicitConsts = true
				}
			}
			enums[enumIdx].spans = append(enums[enumIdx].spans, enumLineSpan{
				startLine: constStartLn,
				endLine:   constEndLn,
			})
		}
	}

	for i := range enums {
		if len(enums[i].info.Values) == 0 {
			name := enums[i].info.Name
			enums[i].info.Values = []string{
				name + "Unknown",
				name + "Active",
				name + "Pending",
			}
			enums[i].hasExplicitConsts = false
		}
	}

	if len(enums) == 0 {
		if len(structs) > 0 {
			for _, st := range structs {
				enumName := st.name + "Status"
				if strings.HasSuffix(st.name, "Status") {
					enumName = st.name + "State"
				}
				enums = append(enums, discoveredSingleFileEnum{
					info: EnumTypeInfo{
						Name:           enumName,
						UnderlyingType: "int",
						Line:           st.startLine,
						Values: []string{
							enumName + "Unknown",
							enumName + "Active",
							enumName + "Pending",
						},
					},
					structName:        st.name,
					hasExplicitType:   false,
					hasExplicitConsts: false,
					spans: []enumLineSpan{
						{startLine: st.startLine, endLine: st.endLine},
					},
				})
			}
		} else {
			enums = append(enums, discoveredSingleFileEnum{
				info: EnumTypeInfo{
					Name:           "Status",
					UnderlyingType: "int",
					Line:           1,
					Values: []string{
						"StatusUnknown",
						"StatusActive",
						"StatusPending",
					},
				},
				hasExplicitType:   false,
				hasExplicitConsts: false,
				spans: []enumLineSpan{
					{startLine: 1, endLine: 1},
				},
			})
		}
	}

	selected := ""
	if cursorLine > 0 {
		for _, e := range enums {
			for _, sp := range e.spans {
				if cursorLine >= sp.startLine && cursorLine <= sp.endLine {
					selected = e.info.Name
					break
				}
			}
			if selected != "" {
				break
			}
		}
	}
	if selected == "" && cursorLine > 0 {
		bestDist := int(^uint(0) >> 1)
		for _, e := range enums {
			for _, sp := range e.spans {
				dist := minLineDist(cursorLine, sp.startLine, sp.endLine)
				if dist < bestDist {
					bestDist = dist
					selected = e.info.Name
				}
			}
		}
	}
	if selected == "" {
		for _, e := range enums {
			if e.hasExplicitConsts {
				selected = e.info.Name
				break
			}
		}
	}
	if selected == "" && len(enums) > 0 {
		selected = enums[0].info.Name
	}

	return enums, selected, nil
}

func formatEnumConstLabel(enumName, constName string, trimTypePrefix, lowercaseStrings bool) string {
	label := constName
	if trimTypePrefix && strings.HasPrefix(label, enumName) && len(label) > len(enumName) {
		trimmed := strings.TrimPrefix(label, enumName)
		trimmed = strings.TrimLeft(trimmed, "_")
		if trimmed != "" {
			label = trimmed
		}
	}
	if lowercaseStrings {
		label = strings.ToLower(label)
	}
	return label
}

func safeEnumIdent(base string, used map[string]bool, fallbacks ...string) string {
	if !used[base] {
		return base
	}
	for _, fb := range fallbacks {
		if !used[fb] {
			return fb
		}
	}
	for suffix := 2; ; suffix++ {
		cand := fmt.Sprintf("%s%d", base, suffix)
		if !used[cand] {
			return cand
		}
	}
}

func removeExistingEnumDecls(src string, enumName string, generatedCode string) string {
	if strings.TrimSpace(src) == "" || enumName == "" {
		return src
	}
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "input.go", src, parser.ParseComments)
	if err != nil || file == nil {
		return src
	}
	regenerated := map[string]bool{}
	if gen, genErr := parser.ParseFile(token.NewFileSet(), "gen.go", "package p\n"+generatedCode, parser.SkipObjectResolution); genErr == nil {
		for _, decl := range gen.Decls {
			if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name != nil {
				regenerated[fd.Name.Name] = true
			}
		}
	}
	type span struct{ start, end int }
	var spans []span
	for _, decl := range file.Decls {
		fd, ok := decl.(*ast.FuncDecl)
		if !ok || fd.Name == nil {
			continue
		}
		match := regenerated[fd.Name.Name]
		if fd.Recv != nil && len(fd.Recv.List) > 0 {
			match = match && extractReceiverTypeName(fd.Recv.List[0].Type) == enumName
		}
		if match {
			startPos := fd.Pos()
			if fd.Doc != nil {
				startPos = fd.Doc.Pos()
			}
			s := fset.Position(startPos).Offset
			e := fset.Position(fd.End()).Offset
			if s >= 0 && e >= s && e <= len(src) {
				spans = append(spans, span{start: s, end: e})
			}
		}
	}
	if len(spans) == 0 {
		return src
	}
	sort.Slice(spans, func(i, j int) bool {
		return spans[i].start > spans[j].start
	})
	out := src
	for _, sp := range spans {
		out = out[:sp.start] + out[sp.end:]
	}
	return out
}

func buildFullEnumCode(target discoveredSingleFileEnum, req GenerateEnumRequest) string {
	enumName := target.info.Name
	underlyingType := target.info.UnderlyingType
	if underlyingType == "" {
		underlyingType = "int"
	}
	values := target.info.Values
	if len(values) == 0 {
		values = []string{
			enumName + "Unknown",
			enumName + "Active",
			enumName + "Pending",
		}
	}

	type mappedConst struct {
		name    string
		label   string
		isAlias bool
	}
	mapped := make([]mappedConst, 0, len(values))
	for _, v := range values {
		isAlias := false
		if target.aliasConsts != nil && target.aliasConsts[v] {
			isAlias = true
		}
		mapped = append(mapped, mappedConst{
			name:    v,
			label:   formatEnumConstLabel(enumName, v, req.TrimTypePrefix, req.LowercaseStrings),
			isAlias: isAlias,
		})
	}

	var blocks []string

	if !target.hasExplicitType {
		blocks = append(blocks, fmt.Sprintf("type %s %s", enumName, underlyingType))
	}

	if !target.hasExplicitConsts {
		var constBuf bytes.Buffer
		constBuf.WriteString("const (\n")
		for i, c := range mapped {
			if underlyingType == "string" {
				_, _ = fmt.Fprintf(&constBuf, "\t%s %s = %q\n", c.name, enumName, c.label)
			} else if i == 0 {
				_, _ = fmt.Fprintf(&constBuf, "\t%s %s = iota\n", c.name, enumName)
			} else {
				_, _ = fmt.Fprintf(&constBuf, "\t%s\n", c.name)
			}
		}
		constBuf.WriteString(")")
		blocks = append(blocks, constBuf.String())
	}

	usedNames := map[string]bool{enumName: true}
	for _, c := range mapped {
		usedNames[c.name] = true
	}
	recvVar := safeEnumIdent("e", usedNames, "v", "val", "enumVal")
	strParam := safeEnumIdent("s", usedNames, "raw", "input", "strVal")
	textParam := safeEnumIdent("text", usedNames, "rawText", "data")
	valLocal := safeEnumIdent("val", usedNames, "parsed", "parsedVal")
	errLocal := safeEnumIdent("err", usedNames, "parseErr")

	var strBuf bytes.Buffer
	_, _ = fmt.Fprintf(&strBuf, "func (%s %s) String() string {\n", recvVar, enumName)
	_, _ = fmt.Fprintf(&strBuf, "\tswitch %s {\n", recvVar)
	for _, c := range mapped {
		if c.isAlias {
			continue
		}
		_, _ = fmt.Fprintf(&strBuf, "\tcase %s:\n", c.name)
		_, _ = fmt.Fprintf(&strBuf, "\t\treturn %q\n", c.label)
	}
	_, _ = fmt.Fprintf(&strBuf, "\tdefault:\n")
	castType := underlyingType
	if castType == "" {
		castType = "int"
	}
	if castType == "string" {
		_, _ = fmt.Fprintf(&strBuf, "\t\treturn string(%s)\n", recvVar)
	} else {
		_, _ = fmt.Fprintf(&strBuf, "\t\treturn fmt.Sprintf(\"%s(%%v)\", %s(%s))\n", enumName, castType, recvVar)
	}
	_, _ = fmt.Fprintf(&strBuf, "\t}\n")
	_, _ = fmt.Fprintf(&strBuf, "}")
	blocks = append(blocks, strBuf.String())

	if req.GenerateIsValid {
		var validBuf bytes.Buffer
		var nonAliasValues []string
		for _, c := range mapped {
			if !c.isAlias {
				nonAliasValues = append(nonAliasValues, c.name)
			}
		}
		if len(nonAliasValues) == 0 {
			nonAliasValues = values
		}
		_, _ = fmt.Fprintf(&validBuf, "func (%s %s) IsValid() bool {\n", recvVar, enumName)
		if len(nonAliasValues) > 0 {
			_, _ = fmt.Fprintf(&validBuf, "\tswitch %s {\n", recvVar)
			_, _ = fmt.Fprintf(&validBuf, "\tcase %s:\n", strings.Join(nonAliasValues, ", "))
			_, _ = fmt.Fprintf(&validBuf, "\t\treturn true\n")
			_, _ = fmt.Fprintf(&validBuf, "\tdefault:\n")
			_, _ = fmt.Fprintf(&validBuf, "\t\treturn false\n")
			_, _ = fmt.Fprintf(&validBuf, "\t}\n")
		} else {
			_, _ = fmt.Fprintf(&validBuf, "\treturn false\n")
		}
		_, _ = fmt.Fprintf(&validBuf, "}")
		blocks = append(blocks, validBuf.String())
	}

	if req.GenerateParse {
		var parseBuf bytes.Buffer
		_, _ = fmt.Fprintf(&parseBuf, "func Parse%s(%s string) (%s, error) {\n", enumName, strParam, enumName)
		_, _ = fmt.Fprintf(&parseBuf, "\tswitch %s {\n", strParam)
		seenLabels := map[string]bool{}
		for _, c := range mapped {
			if seenLabels[c.label] {
				continue
			}
			seenLabels[c.label] = true
			_, _ = fmt.Fprintf(&parseBuf, "\tcase %q:\n", c.label)
			_, _ = fmt.Fprintf(&parseBuf, "\t\treturn %s, nil\n", c.name)
		}
		_, _ = fmt.Fprintf(&parseBuf, "\tdefault:\n")
		zeroVal := "0"
		if underlyingType == "string" {
			zeroVal = `""`
		}
		_, _ = fmt.Fprintf(&parseBuf, "\t\treturn %s, fmt.Errorf(\"invalid %s: %%q\", %s)\n", zeroVal, enumName, strParam)
		_, _ = fmt.Fprintf(&parseBuf, "\t}\n")
		_, _ = fmt.Fprintf(&parseBuf, "}")
		blocks = append(blocks, parseBuf.String())
	}

	if req.GenerateTextMarshaler {
		var marshalBuf bytes.Buffer
		_, _ = fmt.Fprintf(&marshalBuf, "func (%s %s) MarshalText() ([]byte, error) {\n", recvVar, enumName)
		_, _ = fmt.Fprintf(&marshalBuf, "\treturn []byte(%s.String()), nil\n", recvVar)
		_, _ = fmt.Fprintf(&marshalBuf, "}\n\n")
		_, _ = fmt.Fprintf(&marshalBuf, "func (%s *%s) UnmarshalText(%s []byte) error {\n", recvVar, enumName, textParam)
		if req.GenerateParse {
			_, _ = fmt.Fprintf(&marshalBuf, "\t%s, %s := Parse%s(string(%s))\n", valLocal, errLocal, enumName, textParam)
			_, _ = fmt.Fprintf(&marshalBuf, "\tif %s != nil {\n", errLocal)
			_, _ = fmt.Fprintf(&marshalBuf, "\t\treturn %s\n", errLocal)
			_, _ = fmt.Fprintf(&marshalBuf, "\t}\n")
			_, _ = fmt.Fprintf(&marshalBuf, "\t*%s = %s\n", recvVar, valLocal)
			_, _ = fmt.Fprintf(&marshalBuf, "\treturn nil\n")
		} else {
			_, _ = fmt.Fprintf(&marshalBuf, "\tswitch string(%s) {\n", textParam)
			seenLabels := map[string]bool{}
			for _, c := range mapped {
				if seenLabels[c.label] {
					continue
				}
				seenLabels[c.label] = true
				_, _ = fmt.Fprintf(&marshalBuf, "\tcase %q:\n", c.label)
				_, _ = fmt.Fprintf(&marshalBuf, "\t\t*%s = %s\n", recvVar, c.name)
				_, _ = fmt.Fprintf(&marshalBuf, "\t\treturn nil\n")
			}
			_, _ = fmt.Fprintf(&marshalBuf, "\tdefault:\n")
			_, _ = fmt.Fprintf(&marshalBuf, "\t\treturn fmt.Errorf(\"invalid %s: %%q\", string(%s))\n", enumName, textParam)
			_, _ = fmt.Fprintf(&marshalBuf, "\t}\n")
		}
		_, _ = fmt.Fprintf(&marshalBuf, "}")
		blocks = append(blocks, marshalBuf.String())
	}

	raw := strings.Join(blocks, "\n\n")
	if formatted, err := format.Source([]byte(raw)); err == nil {
		return strings.TrimSpace(string(formatted))
	}
	return raw
}

type EnumConstItem struct {
	Name    string `json:"name"`
	Label   string `json:"label"`
	IsAlias bool   `json:"isAlias,omitempty"`
}

type EnumMethodsPlan struct {
	PackageName    string          `json:"packageName"`
	TargetEnum     string          `json:"targetEnum"`
	UnderlyingType string          `json:"underlyingType"`
	AvailableEnums []string        `json:"availableEnums"`
	Constants      []EnumConstItem `json:"constants"`
	TrimPrefix     bool            `json:"trimPrefix"`
	IncludeParse   bool            `json:"includeParse"`
	IncludeIsValid bool            `json:"includeIsValid"`
	IncludeValues  bool            `json:"includeValues"`
	PreviewCode    string          `json:"previewCode"`
	NewContent     string          `json:"newContent"`
	TargetFile     string          `json:"targetFile"`
	Error          string          `json:"error,omitempty"`
}

type enumLineSpan struct {
	startLine int
	endLine   int
}

type parsedEnumTypeInfo struct {
	name           string
	underlyingType string
	pkgName        string
	filePath       string
	fset           *token.FileSet
	file           *ast.File
	src            []byte
	startLine      int
	endLine        int
	declEndOff     int
	isTarget       bool
	constNames     []string
	constSeen      map[string]bool
	constAliases   map[string]bool
	constValueSeen map[string]string
	spans          []enumLineSpan
}

type parsedPackageFile struct {
	filePath string
	fset     *token.FileSet
	file     *ast.File
	src      []byte
	isTarget bool
}

func isSupportedEnumUnderlyingType(typeName string) bool {
	switch strings.TrimSpace(typeName) {
	case "int", "int8", "int16", "int32", "int64",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"byte", "rune", "string":
		return true
	default:
		return false
	}
}

func InspectEnumMethods(
	dir, filePath, content string,
	line, col int,
	typeName string,
	trimPrefix, includeParse, includeIsValid, includeValues bool,
) (EnumMethodsPlan, error) {
	_ = col
	plan := EnumMethodsPlan{
		AvailableEnums: []string{},
		Constants:      []EnumConstItem{},
		TrimPrefix:     trimPrefix,
		IncludeParse:   includeParse,
		IncludeIsValid: includeIsValid,
		IncludeValues:  includeValues,
	}

	cleanFile := ""
	if strings.TrimSpace(filePath) != "" {
		cleanFile = filepath.Clean(filePath)
	}
	cleanDir := ""
	if strings.TrimSpace(dir) != "" {
		cleanDir = filepath.Clean(dir)
	}
	if cleanDir == "" && cleanFile != "" {
		cleanDir = filepath.Dir(cleanFile)
	}

	if content == "" && cleanFile != "" {
		if data, err := readSourceFile(cleanFile); err == nil {
			content = string(data)
		}
	}

	var parsedFiles []*parsedPackageFile
	var defaultPkgName string
	var targetFileSrc []byte
	if strings.TrimSpace(content) != "" {
		targetFileSrc = []byte(content)
	}

	addParsedFile := func(fset *token.FileSet, f *ast.File, src []byte, fp string, isTarget bool) {
		if f == nil || f.Name == nil {
			return
		}
		pkg := f.Name.Name
		if isTarget {
			defaultPkgName = pkg
			if len(targetFileSrc) == 0 {
				targetFileSrc = src
			}
		} else if defaultPkgName == "" || (strings.HasSuffix(defaultPkgName, "_test") && !strings.HasSuffix(pkg, "_test")) {
			defaultPkgName = pkg
		} else if pkg != defaultPkgName && strings.TrimSuffix(pkg, "_test") != strings.TrimSuffix(defaultPkgName, "_test") {
			return
		}
		if !isTarget && !buildTagsCompatible(targetFileSrc, src) {
			return
		}
		parsedFiles = append(parsedFiles, &parsedPackageFile{
			filePath: fp,
			fset:     fset,
			file:     f,
			src:      src,
			isTarget: isTarget,
		})
	}

	if strings.TrimSpace(content) != "" {
		srcBytes := []byte(content)
		fset := token.NewFileSet()
		parseName := cleanFile
		if parseName == "" {
			parseName = "input.go"
		}
		f, err := parser.ParseFile(fset, parseName, srcBytes, parser.ParseComments)
		if err != nil && f == nil {
			plan.Error = fmt.Sprintf("failed to parse Go source: %v", err)
			return plan, err
		}
		addParsedFile(fset, f, srcBytes, cleanFile, true)
	}

	var searchDirs []string
	if cleanFile != "" {
		fileDir := filepath.Dir(cleanFile)
		if info, err := os.Stat(fileDir); err == nil && info.IsDir() {
			searchDirs = append(searchDirs, fileDir)
		}
	}
	if cleanDir != "" {
		if info, err := os.Stat(cleanDir); err == nil && info.IsDir() {
			already := false
			for _, d := range searchDirs {
				if sameFilePath(d, cleanDir) {
					already = true
					break
				}
			}
			if !already {
				searchDirs = append(searchDirs, cleanDir)
			}
		}
	}

	seenFiles := map[string]bool{}
	if cleanFile != "" && strings.TrimSpace(content) != "" {
		if abs, err := filepath.Abs(cleanFile); err == nil {
			seenFiles[abs] = true
		}
		seenFiles[cleanFile] = true
	}

	for _, sdir := range searchDirs {
		goFiles := collectPackageGoFiles(sdir, cleanFile)
		for _, gf := range goFiles {
			if cleanFile != "" && strings.TrimSpace(content) != "" && sameFilePath(gf, cleanFile) {
				continue
			}
			if seenFiles[gf] {
				continue
			}
			seenFiles[gf] = true
			otherSrc, err := readSourceFile(gf)
			if err != nil || len(otherSrc) == 0 {
				continue
			}
			otherFset := token.NewFileSet()
			otherFile, err := parser.ParseFile(otherFset, gf, otherSrc, parser.ParseComments)
			if err != nil || otherFile == nil {
				continue
			}
			isTarget := cleanFile != "" && sameFilePath(gf, cleanFile)
			addParsedFile(otherFset, otherFile, otherSrc, gf, isTarget)
		}
	}

	var allEnums []*parsedEnumTypeInfo
	enumByName := map[string]*parsedEnumTypeInfo{}

	for _, pf := range parsedFiles {
		pkg := pf.file.Name.Name
		for _, decl := range pf.file.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.TYPE {
				continue
			}
			declEnd := pf.fset.Position(gd.End()).Offset
			for _, spec := range gd.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok || ts.Name == nil || ts.Name.Name == "" || ts.Assign.IsValid() {
					continue
				}
				if ts.TypeParams != nil && len(ts.TypeParams.List) > 0 {
					continue
				}
				ident, ok := ts.Type.(*ast.Ident)
				if !ok || !isSupportedEnumUnderlyingType(ident.Name) {
					continue
				}
				startLn := pf.fset.Position(ts.Pos()).Line
				endLn := pf.fset.Position(ts.End()).Line
				if len(gd.Specs) == 1 {
					startLn = pf.fset.Position(gd.Pos()).Line
					if gd.Doc != nil {
						startLn = pf.fset.Position(gd.Doc.Pos()).Line
					}
					endLn = pf.fset.Position(gd.End()).Line
				}
				info := &parsedEnumTypeInfo{
					name:           ts.Name.Name,
					underlyingType: ident.Name,
					pkgName:        pkg,
					filePath:       pf.filePath,
					fset:           pf.fset,
					file:           pf.file,
					src:            pf.src,
					startLine:      startLn,
					endLine:        endLn,
					declEndOff:     declEnd,
					isTarget:       pf.isTarget,
					constNames:     []string{},
					constSeen:      map[string]bool{},
					constAliases:   map[string]bool{},
					constValueSeen: map[string]string{},
					spans: []enumLineSpan{
						{startLine: startLn, endLine: endLn},
					},
				}
				allEnums = append(allEnums, info)
				if existing, exists := enumByName[info.name]; !exists {
					enumByName[info.name] = info
				} else if pf.isTarget && !existing.isTarget {
					enumByName[info.name] = info
				}
			}
		}
	}

	matchEnumPrefix := func(constName string) *parsedEnumTypeInfo {
		var best *parsedEnumTypeInfo
		for _, info := range allEnums {
			if strings.HasPrefix(constName, info.name) && len(constName) > len(info.name) {
				if best == nil || len(info.name) > len(best.name) {
					best = enumByName[info.name]
				}
			}
		}
		return best
	}

	constValueByName := map[string]string{}

	for _, pf := range parsedFiles {
		var lastTypeInFile *parsedEnumTypeInfo
		for _, decl := range pf.file.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok {
				continue
			}
			if gd.Tok == token.TYPE {
				for _, spec := range gd.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if ok && ts.Name != nil {
						if info, exists := enumByName[ts.Name.Name]; exists {
							lastTypeInFile = info
						}
					}
				}
				continue
			}
			if gd.Tok != token.CONST {
				continue
			}

			constDeclEnd := pf.fset.Position(gd.End()).Offset
			constStartLn := pf.fset.Position(gd.Pos()).Line
			constEndLn := pf.fset.Position(gd.End()).Line

			currentType := ""
			blockEnumType := ""
			var inheritedValues []ast.Expr

			for specIdx, spec := range gd.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				activeValues := vs.Values
				if len(activeValues) > 0 {
					inheritedValues = activeValues
				} else {
					activeValues = inheritedValues
				}

				specType := ""
				if vs.Type != nil {
					if ident, ok := vs.Type.(*ast.Ident); ok {
						specType = ident.Name
					}
					currentType = specType
				} else if len(vs.Values) > 0 {
					inferred := ""
					if call, ok := vs.Values[0].(*ast.CallExpr); ok {
						if funIdent, ok := call.Fun.(*ast.Ident); ok {
							if _, exists := enumByName[funIdent.Name]; exists {
								inferred = funIdent.Name
							}
						}
					}
					if inferred != "" {
						specType = inferred
						currentType = inferred
					} else if blockEnumType != "" && usesIotaExpr(vs.Values[0]) {
						specType = blockEnumType
						currentType = blockEnumType
					} else {
						currentType = ""
					}
				} else {
					specType = currentType
				}

				if specType == "" {
					for _, ident := range vs.Names {
						if ident == nil || ident.Name == "" || ident.Name == "_" {
							continue
						}
						if matched := matchEnumPrefix(ident.Name); matched != nil {
							specType = matched.name
							if len(vs.Values) > 0 && usesIotaExpr(vs.Values[0]) {
								currentType = matched.name
							}
							break
						}
					}
				}

				if specType == "" && lastTypeInFile != nil && len(vs.Values) > 0 && usesIotaExpr(vs.Values[0]) {
					specType = lastTypeInFile.name
					currentType = lastTypeInFile.name
				}

				if specType != "" {
					if _, exists := enumByName[specType]; exists && blockEnumType == "" {
						blockEnumType = specType
					}
				}

				info, exists := enumByName[specType]
				if !exists || info == nil {
					continue
				}

				for nameIdx, ident := range vs.Names {
					if ident == nil || ident.Name == "" || ident.Name == "_" {
						continue
					}
					var valExpr ast.Expr
					if nameIdx < len(activeValues) {
						valExpr = activeValues[nameIdx]
					} else if len(activeValues) == 1 {
						valExpr = activeValues[0]
					}
					valKey := resolveEnumConstValueKey(pf.fset, specType, valExpr, specIdx, constValueByName)
					if valKey != "" {
						constValueByName[ident.Name] = valKey
					}
					if !info.constSeen[ident.Name] {
						info.constSeen[ident.Name] = true
						if valKey != "" {
							if prevConst, dup := info.constValueSeen[valKey]; dup && prevConst != ident.Name {
								info.constAliases[ident.Name] = true
							} else {
								info.constValueSeen[valKey] = ident.Name
							}
						}
						info.constNames = append(info.constNames, ident.Name)
					}
				}

				info.spans = append(info.spans, enumLineSpan{
					startLine: constStartLn,
					endLine:   constEndLn,
				})
				if sameFilePath(info.filePath, pf.filePath) || (info.isTarget && pf.isTarget) {
					if constDeclEnd > info.declEndOff {
						info.declEndOff = constDeclEnd
					}
				}
			}
		}
	}

	if len(allEnums) == 0 {
		err := fmt.Errorf("no enum types found in file or package")
		plan.Error = err.Error()
		return plan, err
	}

	var enumsWithConsts []string
	var allEnumNames []string
	seenEnumName := map[string]bool{}
	for _, info := range allEnums {
		if seenEnumName[info.name] {
			continue
		}
		seenEnumName[info.name] = true
		canonical := enumByName[info.name]
		allEnumNames = append(allEnumNames, canonical.name)
		if len(canonical.constNames) > 0 {
			enumsWithConsts = append(enumsWithConsts, canonical.name)
		}
	}
	if len(enumsWithConsts) > 0 {
		plan.AvailableEnums = enumsWithConsts
	} else {
		plan.AvailableEnums = allEnumNames
	}

	var selected *parsedEnumTypeInfo
	reqType := strings.TrimSpace(typeName)
	if reqType != "" {
		if match, ok := enumByName[reqType]; ok {
			selected = match
		} else {
			for _, cand := range allEnums {
				if strings.EqualFold(cand.name, reqType) {
					selected = enumByName[cand.name]
					break
				}
			}
			if selected == nil {
				err := fmt.Errorf("enum type %q not found in package", reqType)
				plan.Error = err.Error()
				return plan, err
			}
		}
	}

	if selected == nil && line > 0 {
		for _, cand := range allEnums {
			canonical := enumByName[cand.name]
			if !canonical.isTarget {
				continue
			}
			for _, sp := range canonical.spans {
				if line >= sp.startLine && line <= sp.endLine {
					selected = canonical
					break
				}
			}
			if selected != nil {
				break
			}
		}
	}

	if selected == nil && line > 0 {
		bestDist := int(^uint(0) >> 1)
		for _, cand := range allEnums {
			canonical := enumByName[cand.name]
			if !canonical.isTarget || len(canonical.constNames) == 0 {
				continue
			}
			for _, sp := range canonical.spans {
				dist := minLineDist(line, sp.startLine, sp.endLine)
				if dist < bestDist {
					bestDist = dist
					selected = canonical
				}
			}
		}
	}

	if selected == nil {
		for _, cand := range allEnums {
			canonical := enumByName[cand.name]
			if canonical.isTarget && len(canonical.constNames) > 0 {
				selected = canonical
				break
			}
		}
	}

	if selected == nil {
		for _, cand := range allEnums {
			canonical := enumByName[cand.name]
			if len(canonical.constNames) > 0 {
				selected = canonical
				break
			}
		}
	}

	if selected == nil {
		for _, cand := range allEnums {
			canonical := enumByName[cand.name]
			if canonical.isTarget {
				selected = canonical
				break
			}
		}
	}

	if selected == nil {
		selected = enumByName[allEnums[0].name]
	}

	alreadyInAvailable := false
	for _, n := range plan.AvailableEnums {
		if n == selected.name {
			alreadyInAvailable = true
			break
		}
	}
	if !alreadyInAvailable {
		plan.AvailableEnums = append(plan.AvailableEnums, selected.name)
	}

	pkgName := selected.pkgName
	if pkgName == "" {
		pkgName = defaultPkgName
	}

	constants := buildEnumConstItems(selected.name, selected.constNames, selected.constAliases, trimPrefix)
	previewCode := buildEnumMethodsCode(
		selected.name,
		selected.underlyingType,
		constants,
		includeParse,
		includeIsValid,
		includeValues,
	)
	newContent := buildUpdatedFileWithEnumMethods(
		selected,
		includeParse,
		previewCode,
	)

	targetFile := selected.filePath
	if targetFile == "" {
		targetFile = cleanFile
	}

	plan.PackageName = pkgName
	plan.TargetEnum = selected.name
	plan.UnderlyingType = selected.underlyingType
	plan.Constants = constants
	plan.PreviewCode = previewCode
	plan.NewContent = newContent
	plan.TargetFile = targetFile
	return plan, nil
}

func usesIotaExpr(expr ast.Expr) bool {
	if expr == nil {
		return false
	}
	found := false
	ast.Inspect(expr, func(n ast.Node) bool {
		if ident, ok := n.(*ast.Ident); ok && ident.Name == "iota" {
			found = true
			return false
		}
		return true
	})
	return found
}

func minLineDist(line, startLine, endLine int) int {
	if line >= startLine && line <= endLine {
		return 0
	}
	if line < startLine {
		return startLine - line
	}
	return line - endLine
}

func buildEnumConstItems(enumName string, constNames []string, constAliases map[string]bool, trimPrefix bool) []EnumConstItem {
	items := make([]EnumConstItem, 0, len(constNames))
	for _, cName := range constNames {
		label := cName
		if trimPrefix && strings.HasPrefix(cName, enumName) && len(cName) > len(enumName) {
			suffix := strings.TrimPrefix(cName, enumName)
			suffix = strings.TrimLeft(suffix, "_")
			if suffix != "" {
				label = suffix
			}
		}
		isAlias := false
		if constAliases != nil && constAliases[cName] {
			isAlias = true
		}
		items = append(items, EnumConstItem{
			Name:    cName,
			Label:   label,
			IsAlias: isAlias,
		})
	}
	return items
}

func resolveEnumConstValueKey(
	fset *token.FileSet,
	enumName string,
	expr ast.Expr,
	iotaVal int,
	prevValues map[string]string,
) string {
	if expr == nil {
		return ""
	}
	for {
		if paren, ok := expr.(*ast.ParenExpr); ok {
			expr = paren.X
			continue
		}
		if call, ok := expr.(*ast.CallExpr); ok && len(call.Args) == 1 {
			if funIdent, ok := call.Fun.(*ast.Ident); ok && funIdent.Name == enumName {
				expr = call.Args[0]
				continue
			}
		}
		break
	}

	switch e := expr.(type) {
	case *ast.BasicLit:
		return strings.TrimSpace(e.Value)
	case *ast.Ident:
		if e.Name == "iota" {
			return strconv.Itoa(iotaVal)
		}
		if prevValues != nil {
			if prev, ok := prevValues[e.Name]; ok && prev != "" {
				return prev
			}
		}
		return e.Name
	case *ast.UnaryExpr:
		inner := resolveEnumConstValueKey(fset, enumName, e.X, iotaVal, prevValues)
		if inner == "" {
			return ""
		}
		switch e.Op {
		case token.ADD:
			return inner
		case token.SUB:
			if v, err := strconv.ParseInt(inner, 0, 64); err == nil {
				return strconv.FormatInt(-v, 10)
			}
			return "-" + inner
		default:
			return e.Op.String() + inner
		}
	case *ast.BinaryExpr:
		left := resolveEnumConstValueKey(fset, enumName, e.X, iotaVal, prevValues)
		right := resolveEnumConstValueKey(fset, enumName, e.Y, iotaVal, prevValues)
		if left == "" || right == "" {
			return ""
		}
		lv, lErr := strconv.ParseInt(left, 0, 64)
		rv, rErr := strconv.ParseInt(right, 0, 64)
		if lErr == nil && rErr == nil {
			switch e.Op {
			case token.ADD:
				return strconv.FormatInt(lv+rv, 10)
			case token.SUB:
				return strconv.FormatInt(lv-rv, 10)
			case token.MUL:
				return strconv.FormatInt(lv*rv, 10)
			case token.QUO:
				if rv != 0 {
					return strconv.FormatInt(lv/rv, 10)
				}
			case token.REM:
				if rv != 0 {
					return strconv.FormatInt(lv%rv, 10)
				}
			case token.SHL:
				if rv >= 0 && rv < 62 {
					return strconv.FormatInt(lv<<uint(rv), 10)
				}
			case token.SHR:
				if rv >= 0 && rv < 62 {
					return strconv.FormatInt(lv>>uint(rv), 10)
				}
			case token.OR:
				return strconv.FormatInt(lv|rv, 10)
			case token.AND:
				return strconv.FormatInt(lv&rv, 10)
			case token.XOR:
				return strconv.FormatInt(lv^rv, 10)
			default:
			}
		}
		return fmt.Sprintf("(%s%s%s)", left, e.Op.String(), right)
	default:
		if fset != nil {
			var buf bytes.Buffer
			if err := printer.Fprint(&buf, fset, expr); err == nil {
				return strings.TrimSpace(buf.String())
			}
		}
		return ""
	}
}

func buildEnumMethodsCode(
	enumName string,
	underlyingType string,
	constants []EnumConstItem,
	includeParse bool,
	includeIsValid bool,
	includeValues bool,
) string {
	usedNames := map[string]bool{enumName: true}
	for _, c := range constants {
		usedNames[c.Name] = true
	}
	recvVar := safeEnumIdent("e", usedNames, "v", "val", "enumVal")
	strParam := safeEnumIdent("s", usedNames, "raw", "input", "strVal")

	var blocks []string

	var strBuf bytes.Buffer
	_, _ = fmt.Fprintf(&strBuf, "func (%s %s) String() string {\n", recvVar, enumName)
	_, _ = fmt.Fprintf(&strBuf, "\tswitch %s {\n", recvVar)
	for _, c := range constants {
		if c.IsAlias {
			continue
		}
		_, _ = fmt.Fprintf(&strBuf, "\tcase %s:\n", c.Name)
		_, _ = fmt.Fprintf(&strBuf, "\t\treturn %q\n", c.Label)
	}
	_, _ = fmt.Fprintf(&strBuf, "\tdefault:\n")
	castType := underlyingType
	if castType == "" {
		castType = "int"
	}
	if castType == "string" {
		_, _ = fmt.Fprintf(&strBuf, "\t\treturn string(%s)\n", recvVar)
	} else {
		_, _ = fmt.Fprintf(&strBuf, "\t\treturn fmt.Sprintf(\"%s(%%v)\", %s(%s))\n", enumName, castType, recvVar)
	}
	_, _ = fmt.Fprintf(&strBuf, "\t}\n")
	_, _ = fmt.Fprintf(&strBuf, "}")
	blocks = append(blocks, strBuf.String())

	if includeParse {
		var parseBuf bytes.Buffer
		_, _ = fmt.Fprintf(&parseBuf, "func Parse%s(%s string) (%s, error) {\n", enumName, strParam, enumName)
		_, _ = fmt.Fprintf(&parseBuf, "\tswitch %s {\n", strParam)
		seenParseKeys := map[string]bool{}
		for _, c := range constants {
			var caseLits []string
			if !seenParseKeys[c.Label] {
				seenParseKeys[c.Label] = true
				caseLits = append(caseLits, fmt.Sprintf("%q", c.Label))
			}
			if c.Label != c.Name && !seenParseKeys[c.Name] {
				seenParseKeys[c.Name] = true
				caseLits = append(caseLits, fmt.Sprintf("%q", c.Name))
			}
			if len(caseLits) == 0 {
				continue
			}
			_, _ = fmt.Fprintf(&parseBuf, "\tcase %s:\n", strings.Join(caseLits, ", "))
			_, _ = fmt.Fprintf(&parseBuf, "\t\treturn %s, nil\n", c.Name)
		}
		_, _ = fmt.Fprintf(&parseBuf, "\tdefault:\n")
		zeroExpr := fmt.Sprintf("%s(0)", enumName)
		if underlyingType == "string" {
			zeroExpr = fmt.Sprintf("%s(\"\")", enumName)
		}
		_, _ = fmt.Fprintf(&parseBuf, "\t\treturn %s, fmt.Errorf(\"invalid %s: %%q\", %s)\n", zeroExpr, enumName, strParam)
		_, _ = fmt.Fprintf(&parseBuf, "\t}\n")
		_, _ = fmt.Fprintf(&parseBuf, "}")
		blocks = append(blocks, parseBuf.String())
	}

	if includeIsValid {
		var validBuf bytes.Buffer
		_, _ = fmt.Fprintf(&validBuf, "func (%s %s) IsValid() bool {\n", recvVar, enumName)
		if len(constants) > 0 {
			names := make([]string, 0, len(constants))
			for _, c := range constants {
				if c.IsAlias {
					continue
				}
				names = append(names, c.Name)
			}
			if len(names) == 0 {
				for _, c := range constants {
					names = append(names, c.Name)
				}
			}
			_, _ = fmt.Fprintf(&validBuf, "\tswitch %s {\n", recvVar)
			_, _ = fmt.Fprintf(&validBuf, "\tcase %s:\n", strings.Join(names, ", "))
			_, _ = fmt.Fprintf(&validBuf, "\t\treturn true\n")
			_, _ = fmt.Fprintf(&validBuf, "\tdefault:\n")
			_, _ = fmt.Fprintf(&validBuf, "\t\treturn false\n")
			_, _ = fmt.Fprintf(&validBuf, "\t}\n")
		} else {
			_, _ = fmt.Fprintf(&validBuf, "\treturn false\n")
		}
		_, _ = fmt.Fprintf(&validBuf, "}")
		blocks = append(blocks, validBuf.String())
	}

	if includeValues {
		var valsBuf bytes.Buffer
		names := make([]string, 0, len(constants))
		for _, c := range constants {
			if c.IsAlias {
				continue
			}
			names = append(names, c.Name)
		}
		if len(names) == 0 {
			for _, c := range constants {
				names = append(names, c.Name)
			}
		}
		_, _ = fmt.Fprintf(&valsBuf, "func All%sValues() []%s {\n", enumName, enumName)
		_, _ = fmt.Fprintf(&valsBuf, "\treturn []%s{%s}\n", enumName, strings.Join(names, ", "))
		_, _ = fmt.Fprintf(&valsBuf, "}")
		blocks = append(blocks, valsBuf.String())
	}

	return strings.Join(blocks, "\n\n")
}

func buildUpdatedFileWithEnumMethods(
	selected *parsedEnumTypeInfo,
	includeParse bool,
	previewCode string,
) string {
	if selected == nil || len(selected.src) == 0 {
		return previewCode
	}

	srcStr := string(selected.src)
	fset := selected.fset
	file := selected.file
	enumName := selected.name
	parseFuncName := "Parse" + enumName
	valuesFuncName := "All" + enumName + "Values"

	type byteSpan struct {
		start int
		end   int
	}
	var removeSpans []byteSpan

	if file != nil && fset != nil {
		for _, decl := range file.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if !ok || fd.Name == nil {
				continue
			}
			shouldRemove := false
			if fd.Recv != nil && len(fd.Recv.List) > 0 {
				recvType := extractReceiverTypeName(fd.Recv.List[0].Type)
				if recvType == enumName && (fd.Name.Name == "String" || fd.Name.Name == "IsValid") {
					shouldRemove = true
				}
			} else if fd.Recv == nil {
				if fd.Name.Name == parseFuncName || fd.Name.Name == valuesFuncName {
					shouldRemove = true
				}
			}
			if shouldRemove {
				startPos := fd.Pos()
				if fd.Doc != nil {
					startPos = fd.Doc.Pos()
				}
				startOff := fset.Position(startPos).Offset
				endOff := fset.Position(fd.End()).Offset
				if startOff >= 0 && endOff >= startOff && endOff <= len(srcStr) {
					removeSpans = append(removeSpans, byteSpan{start: startOff, end: endOff})
				}
			}
		}
	}

	insertOff := selected.declEndOff
	if insertOff < 0 || insertOff > len(srcStr) {
		insertOff = len(srcStr)
	}
	for insertOff < len(srcStr) && srcStr[insertOff] != '\n' {
		insertOff++
	}

	if len(removeSpans) > 0 {
		sort.Slice(removeSpans, func(i, j int) bool {
			return removeSpans[i].start > removeSpans[j].start
		})
		for _, sp := range removeSpans {
			srcStr = srcStr[:sp.start] + srcStr[sp.end:]
			if sp.end <= insertOff {
				insertOff -= sp.end - sp.start
			} else if sp.start < insertOff {
				insertOff = sp.start
			}
		}
		if insertOff < 0 {
			insertOff = 0
		}
		if insertOff > len(srcStr) {
			insertOff = len(srcStr)
		}
	}

	withMethods := srcStr[:insertOff] + "\n\n" + previewCode + srcStr[insertOff:]

	var requiredImports []string
	if strings.Contains(previewCode, "fmt.") {
		requiredImports = append(requiredImports, "fmt")
	}

	withImports := ensureRequiredImports(withMethods, requiredImports)
	if formatted, err := format.Source([]byte(withImports)); err == nil {
		return string(formatted)
	}
	return withImports
}
