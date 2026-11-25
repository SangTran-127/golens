package analysis

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"unicode"
)

const (
	defaultSerialInputFile = "input.go"
)

type SerialSafetyInspectRequest struct {
	Content  string `json:"content"`
	FilePath string `json:"filePath"`
}

type SerialSafetyIssueItem struct {
	ID                 string `json:"id"`
	Category           string `json:"category"`
	Severity           string `json:"severity"`
	Line               int    `json:"line"`
	Column             int    `json:"column"`
	StructName         string `json:"structName"`
	FieldName          string `json:"fieldName"`
	Expr               string `json:"expr"`
	Message            string `json:"message"`
	Suggestion         string `json:"suggestion"`
	FixTitle           string `json:"fixTitle"`
	ReplacementPreview string `json:"replacementPreview"`
	CanAutoFix         bool   `json:"canAutoFix"`
}

type SerialSafetyInspectResponse struct {
	Issues                []SerialSafetyIssueItem `json:"issues"`
	UnexportedTagCount    int                     `json:"unexportedTagCount"`
	SensitiveExposedCount int                     `json:"sensitiveExposedCount"`
	DuplicateTagCount     int                     `json:"duplicateTagCount"`
	Error                 string                  `json:"error,omitempty"`
}

type FileEditPlan struct {
	FilePath   string `json:"filePath"`
	NewContent string `json:"newContent"`
}

type SerialSafetyFixRequest struct {
	Content     string            `json:"content"`
	FilePath    string            `json:"filePath"`
	IssueID     string            `json:"issueID"`
	All         bool              `json:"all"`
	OpenBuffers map[string]string `json:"openBuffers,omitempty"`
}

type SerialSafetyFixResponse struct {
	NewContent string         `json:"newContent"`
	FixedCount int            `json:"fixedCount"`
	FileEdits  []FileEditPlan `json:"fileEdits,omitempty"`
	Error      string         `json:"error,omitempty"`
}

type serialSafetyInternalIssue struct {
	item        SerialSafetyIssueItem
	startOffset int
	endOffset   int
	replacement string
}

var (
	serialJSONTagKeyRegex = regexp.MustCompile(`(^|\s)json:"[^"]*"`)
	serialAnyTagKeyRegex  = regexp.MustCompile(`(^|\s)(json|yaml|xml|db):"[^"]*"`)

	serialSensitiveKeywords = []string{
		"password",
		"passwd",
		"secret",
		"token",
		"apikey",
		"privatekey",
		"accesstoken",
		"refreshtoken",
		"clientsecret",
	}
)

func InspectSerializationSafety(reqJSON string) string {
	resp := SerialSafetyInspectResponse{
		Issues: []SerialSafetyIssueItem{},
	}

	var req SerialSafetyInspectRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		resp.Error = err.Error()
		return marshalSerialInspectResponse(resp)
	}
	if strings.TrimSpace(req.FilePath) == "" {
		var alt struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil && strings.TrimSpace(alt.Path) != "" {
			req.FilePath = alt.Path
		}
	}

	src, filePath, err := resolveSerialSource(req.Content, req.FilePath)
	if err != nil {
		resp.Error = err.Error()
		return marshalSerialInspectResponse(resp)
	}
	if strings.TrimSpace(src) == "" {
		return marshalSerialInspectResponse(resp)
	}

	internalIssues, parseErr := analyzeSerializationSafetySource(filePath, src)
	if parseErr != nil && len(internalIssues) == 0 {
		resp.Error = parseErr.Error()
		return marshalSerialInspectResponse(resp)
	}

	for _, entry := range internalIssues {
		resp.Issues = append(resp.Issues, entry.item)
		switch entry.item.Category {
		case "unexported_tagged_field":
			resp.UnexportedTagCount++
		case "sensitive_field_exposed":
			resp.SensitiveExposedCount++
		case "duplicate_json_tag":
			resp.DuplicateTagCount++
		}
	}

	return marshalSerialInspectResponse(resp)
}

func ApplySerializationSafetyFix(reqJSON string) string {
	var req SerialSafetyFixRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return marshalSerialFixResponse(SerialSafetyFixResponse{
			Error: err.Error(),
		})
	}
	if strings.TrimSpace(req.FilePath) == "" {
		var alt struct {
			Path string `json:"path"`
		}
		if err := json.Unmarshal([]byte(reqJSON), &alt); err == nil && strings.TrimSpace(alt.Path) != "" {
			req.FilePath = alt.Path
		}
	}

	src, filePath, err := resolveSerialSource(req.Content, req.FilePath)
	if err != nil {
		return marshalSerialFixResponse(SerialSafetyFixResponse{
			NewContent: req.Content,
			Error:      err.Error(),
		})
	}
	if strings.TrimSpace(src) == "" {
		return marshalSerialFixResponse(SerialSafetyFixResponse{
			NewContent: src,
			FixedCount: 0,
		})
	}

	internalIssues, parseErr := analyzeSerializationSafetySource(filePath, src)
	if parseErr != nil && len(internalIssues) == 0 {
		return marshalSerialFixResponse(SerialSafetyFixResponse{
			NewContent: src,
			Error:      parseErr.Error(),
		})
	}

	targetID := strings.TrimSpace(req.IssueID)
	var selected []serialSafetyInternalIssue

	for _, entry := range internalIssues {
		if !entry.item.CanAutoFix {
			continue
		}
		if req.All {
			selected = append(selected, entry)
		} else if targetID != "" && entry.item.ID == targetID {
			selected = append(selected, entry)
			break
		}
	}

	if len(selected) == 0 {
		if !req.All && targetID != "" {
			return marshalSerialFixResponse(SerialSafetyFixResponse{
				NewContent: src,
				FixedCount: 0,
				Error:      fmt.Sprintf("serialization safety issue %q not found", targetID),
			})
		}
		return marshalSerialFixResponse(SerialSafetyFixResponse{
			NewContent: src,
			FixedCount: 0,
		})
	}

	seenSpan := make(map[string]bool)
	var edits []serialSpanEdit
	fixedCount := 0
	renamedFields := make(map[string]map[string]string)

	for _, entry := range selected {
		if entry.startOffset < 0 || entry.endOffset < entry.startOffset || entry.endOffset > len(src) {
			continue
		}
		fixedCount++
		if entry.item.Category == "unexported_tagged_field" &&
			entry.item.StructName != "" &&
			entry.item.FieldName != "" &&
			entry.replacement != "" {
			if renamedFields[entry.item.StructName] == nil {
				renamedFields[entry.item.StructName] = make(map[string]string)
			}
			renamedFields[entry.item.StructName][entry.item.FieldName] = entry.replacement
		}
		spanKey := fmt.Sprintf("%d:%d", entry.startOffset, entry.endOffset)
		if seenSpan[spanKey] {
			continue
		}
		seenSpan[spanKey] = true
		edits = append(edits, serialSpanEdit{
			start:       entry.startOffset,
			end:         entry.endOffset,
			replacement: entry.replacement,
		})
	}

	var siblingEdits []FileEditPlan
	if len(renamedFields) > 0 {
		primaryRefEdits, sibPlans, refErr := collectPackageSerialFieldRenameEdits(
			filePath,
			src,
			renamedFields,
			req.OpenBuffers,
		)
		if refErr != nil {
			return marshalSerialFixResponse(SerialSafetyFixResponse{
				NewContent: src,
				Error:      refErr.Error(),
			})
		}
		for _, ed := range primaryRefEdits {
			spanKey := fmt.Sprintf("%d:%d", ed.start, ed.end)
			if seenSpan[spanKey] {
				continue
			}
			seenSpan[spanKey] = true
			edits = append(edits, ed)
		}
		siblingEdits = sibPlans
	}

	updated := applySerialSpanEdits(src, edits)

	if formatted, fmtErr := format.Source([]byte(updated)); fmtErr == nil {
		updated = string(formatted)
	}

	var fileEdits []FileEditPlan
	if filePath != "" && filePath != defaultSerialInputFile && updated != src {
		fileEdits = append(fileEdits, FileEditPlan{
			FilePath:   filePath,
			NewContent: updated,
		})
	}
	fileEdits = append(fileEdits, siblingEdits...)

	return marshalSerialFixResponse(SerialSafetyFixResponse{
		NewContent: updated,
		FixedCount: fixedCount,
		FileEdits:  fileEdits,
	})
}

type serialSpanEdit struct {
	start       int
	end         int
	replacement string
}

func applySerialSpanEdits(src string, edits []serialSpanEdit) string {
	if len(edits) == 0 {
		return src
	}
	sorted := make([]serialSpanEdit, len(edits))
	copy(sorted, edits)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].start != sorted[j].start {
			return sorted[i].start > sorted[j].start
		}
		return sorted[i].end > sorted[j].end
	})

	updated := src
	var buf bytes.Buffer
	lastStart := len(updated) + 1
	for _, ed := range sorted {
		if ed.start < 0 || ed.end < ed.start || ed.end > len(updated) || ed.end > lastStart {
			continue
		}
		buf.Reset()
		buf.WriteString(updated[:ed.start])
		buf.WriteString(ed.replacement)
		buf.WriteString(updated[ed.end:])
		updated = buf.String()
		lastStart = ed.start
	}
	return updated
}

func lookupOpenBufferContent(openBuffers map[string]string, targetPath string) (string, bool) {
	if len(openBuffers) == 0 || targetPath == "" {
		return "", false
	}
	if v, ok := openBuffers[targetPath]; ok {
		return v, true
	}
	for k, v := range openBuffers {
		if sameSyncFilePath(k, targetPath) {
			return v, true
		}
	}
	return "", false
}

func resolveSerialSource(content, filePath string) (string, string, error) {
	trimmedPath := strings.TrimSpace(filePath)
	if content != "" {
		if trimmedPath == "" {
			trimmedPath = defaultSerialInputFile
		}
		return content, trimmedPath, nil
	}
	if trimmedPath == "" {
		return "", defaultSerialInputFile, nil
	}
	data, err := os.ReadFile(trimmedPath)
	if err != nil {
		return "", trimmedPath, err
	}
	return string(data), trimmedPath, nil
}

func samePackageNamedStruct(t types.Type, pkg *types.Package) string {
	if t == nil {
		return ""
	}
	if ptr, ok := t.(*types.Pointer); ok {
		t = ptr.Elem()
	}
	named, ok := t.(*types.Named)
	if !ok || named.Obj() == nil {
		return ""
	}
	if pkg != nil && named.Obj().Pkg() != nil && named.Obj().Pkg() != pkg {
		return ""
	}
	if _, ok := named.Underlying().(*types.Struct); !ok {
		return ""
	}
	return named.Obj().Name()
}

func collectPackageSerialFieldRenameEdits(
	filePath string,
	primarySrc string,
	renamedFields map[string]map[string]string,
	openBuffers map[string]string,
) ([]serialSpanEdit, []FileEditPlan, error) {
	return collectPackageSerialFieldRenameEditsWithImporter(samePackageOnlyImporter{}, filePath, primarySrc, renamedFields, openBuffers)
}

func collectPackageSerialFieldRenameEditsWithImporter(
	imp types.Importer,
	filePath string,
	primarySrc string,
	renamedFields map[string]map[string]string,
	openBuffers map[string]string,
) ([]serialSpanEdit, []FileEditPlan, error) {
	fset := token.NewFileSet()
	primaryAST, err := parser.ParseFile(fset, filePath, primarySrc, parser.ParseComments)
	if err != nil || primaryAST == nil {
		return nil, nil, nil
	}

	type parsedSibling struct {
		path string
		src  string
		file *ast.File
	}
	var siblings []parsedSibling
	pkgFiles := []*ast.File{primaryAST}

	if filePath != "" && filePath != defaultSerialInputFile {
		if fileInfo, fileStatErr := os.Stat(filePath); fileStatErr == nil && !fileInfo.IsDir() {
			dir := filepath.Dir(filePath)
			if info, statErr := os.Stat(dir); statErr == nil && info.IsDir() {
				entries, readErr := os.ReadDir(dir)
				if readErr != nil {
					return nil, nil, fmt.Errorf("failed to read package directory %s: %w", dir, readErr)
				}
				for _, entry := range entries {
					if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".go") {
						continue
					}
					sibPath := filepath.Join(dir, entry.Name())
					if sameSyncFilePath(sibPath, filePath) {
						continue
					}
					var sibSrc string
					if bufContent, ok := lookupOpenBufferContent(openBuffers, sibPath); ok {
						sibSrc = bufContent
					} else {
						sibBytes, rErr := os.ReadFile(sibPath)
						if rErr != nil {
							return nil, nil, fmt.Errorf("failed to read sibling file %s: %w", sibPath, rErr)
						}
						sibSrc = string(sibBytes)
					}
					sibAST, sibParseErr := parser.ParseFile(fset, sibPath, sibSrc, parser.ParseComments)
					if sibParseErr != nil || sibAST == nil {
						continue
					}
					if primaryAST.Name != nil && sibAST.Name != nil && sibAST.Name.Name != primaryAST.Name.Name {
						continue
					}
					siblings = append(siblings, parsedSibling{
						path: sibPath,
						src:  sibSrc,
						file: sibAST,
					})
					pkgFiles = append(pkgFiles, sibAST)
				}
			}
		}
	}

	typeInfo := &types.Info{
		Defs:       make(map[*ast.Ident]types.Object),
		Uses:       make(map[*ast.Ident]types.Object),
		Selections: make(map[*ast.SelectorExpr]*types.Selection),
		Types:      make(map[ast.Expr]types.TypeAndValue),
	}
	conf := types.Config{
		Importer: imp,
		Error:    func(error) {},
	}
	pkgName := "pkg"
	if primaryAST.Name != nil && primaryAST.Name.Name != "" {
		pkgName = primaryAST.Name.Name
	}
	checkedPkg, _ := conf.Check(pkgName, fset, pkgFiles, typeInfo)

	targetFieldObjs := make(map[types.Object]string)
	ast.Inspect(primaryAST, func(n ast.Node) bool {
		ts, ok := n.(*ast.TypeSpec)
		if !ok || ts.Name == nil {
			return true
		}
		st, ok := ts.Type.(*ast.StructType)
		if !ok || st.Fields == nil {
			return true
		}
		fieldMap := renamedFields[ts.Name.Name]
		if len(fieldMap) == 0 {
			return true
		}
		for _, field := range st.Fields.List {
			for _, id := range field.Names {
				if id == nil || id.Name == "" {
					continue
				}
				if newName, exists := fieldMap[id.Name]; exists && newName != "" {
					if obj := typeInfo.Defs[id]; obj != nil {
						targetFieldObjs[obj] = newName
					}
				}
			}
		}
		return true
	})

	collectEditsForFile := func(astFile *ast.File, fileSrc string) []serialSpanEdit {
		baseOffset := fset.File(astFile.Pos()).Base()
		seenOffsets := make(map[int]bool)
		var refEdits []serialSpanEdit

		addIdentEdit := func(ident *ast.Ident, newName string) {
			if ident == nil || newName == "" || ident.Name == newName {
				return
			}
			startOff := int(ident.Pos()) - baseOffset
			endOff := int(ident.End()) - baseOffset
			if startOff < 0 || endOff <= startOff || endOff > len(fileSrc) || seenOffsets[startOff] {
				return
			}
			seenOffsets[startOff] = true
			refEdits = append(refEdits, serialSpanEdit{
				start:       startOff,
				end:         endOff,
				replacement: newName,
			})
		}

		ast.Inspect(astFile, func(n ast.Node) bool {
			switch node := n.(type) {
			case *ast.CompositeLit:
				compStructName := ""
				if tv, ok := typeInfo.Types[node]; ok && tv.Type != nil {
					compStructName = samePackageNamedStruct(tv.Type, checkedPkg)
				}
				for _, elt := range node.Elts {
					kv, ok := elt.(*ast.KeyValueExpr)
					if !ok {
						continue
					}
					keyIdent, ok := kv.Key.(*ast.Ident)
					if !ok || keyIdent.Name == "" {
						continue
					}
					if obj := typeInfo.Uses[keyIdent]; obj != nil {
						if newName, exists := targetFieldObjs[obj]; exists {
							addIdentEdit(keyIdent, newName)
						}
						continue
					}
					if compStructName != "" && renamedFields[compStructName] != nil {
						if newName := renamedFields[compStructName][keyIdent.Name]; newName != "" {
							addIdentEdit(keyIdent, newName)
						}
					}
				}
			case *ast.SelectorExpr:
				if node.Sel == nil || node.Sel.Name == "" {
					return true
				}
				if sel := typeInfo.Selections[node]; sel != nil && sel.Obj() != nil {
					if newName, exists := targetFieldObjs[sel.Obj()]; exists {
						addIdentEdit(node.Sel, newName)
					}
					return true
				}
				if obj := typeInfo.Uses[node.Sel]; obj != nil {
					if newName, exists := targetFieldObjs[obj]; exists {
						addIdentEdit(node.Sel, newName)
					}
					return true
				}
				if tv, ok := typeInfo.Types[node.X]; ok && tv.Type != nil {
					sName := samePackageNamedStruct(tv.Type, checkedPkg)
					if sName != "" && renamedFields[sName] != nil {
						if newName := renamedFields[sName][node.Sel.Name]; newName != "" {
							addIdentEdit(node.Sel, newName)
						}
					}
				}
			}
			return true
		})

		return refEdits
	}

	primaryRefEdits := collectEditsForFile(primaryAST, primarySrc)

	var siblingPlans []FileEditPlan
	for _, sib := range siblings {
		sibEdits := collectEditsForFile(sib.file, sib.src)
		if len(sibEdits) == 0 {
			continue
		}
		sibUpdated := applySerialSpanEdits(sib.src, sibEdits)
		if sibUpdated != sib.src {
			if formatted, fmtErr := format.Source([]byte(sibUpdated)); fmtErr == nil {
				sibUpdated = string(formatted)
			}
			siblingPlans = append(siblingPlans, FileEditPlan{
				FilePath:   sib.path,
				NewContent: sibUpdated,
			})
		}
	}

	return primaryRefEdits, siblingPlans, nil
}

func analyzeSerializationSafetySource(filePath, src string) ([]serialSafetyInternalIssue, error) {
	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, filePath, src, parser.ParseComments)
	if astFile == nil {
		return nil, err
	}

	var issues []serialSafetyInternalIssue
	visitedStructs := make(map[*ast.StructType]bool)

	inspectStruct := func(structName string, st *ast.StructType) {
		if st == nil || st.Fields == nil || visitedStructs[st] {
			return
		}
		visitedStructs[st] = true
		if structName == "" {
			structName = "anonymous"
		}

		type jsonTaggedField struct {
			field          *ast.Field
			ident          *ast.Ident
			fieldName      string
			line           int
			col            int
			jsonFullVal    string
			jsonKey        string
			jsonOptions    string
			rawTagLit      string
			fieldStartOff  int
			fieldEndOff    int
			tagStartOff    int
			tagEndOff      int
			fieldExprSlice string
		}

		var jsonFields []jsonTaggedField

		for _, field := range st.Fields.List {
			if field == nil || len(field.Names) == 0 {
				continue
			}

			fieldStartOff := fset.Position(field.Pos()).Offset
			fieldEndOff := fset.Position(field.End()).Offset
			fieldExprSlice := ""
			if fieldStartOff >= 0 && fieldEndOff >= fieldStartOff && fieldEndOff <= len(src) {
				fieldExprSlice = strings.TrimSpace(src[fieldStartOff:fieldEndOff])
			}

			rawTagLit := ""
			unquotedTag := ""
			tagStartOff := -1
			tagEndOff := -1
			if field.Tag != nil {
				rawTagLit = field.Tag.Value
				unquotedTag = unquoteStructTagLiteral(rawTagLit)
				tagStartOff = fset.Position(field.Tag.Pos()).Offset
				tagEndOff = fset.Position(field.Tag.End()).Offset
			}

			hasSerialTag := hasSerializationStructTag(unquotedTag)
			jsonVal, hasJSONTag := lookupStructTagValue(unquotedTag, "json")

			for _, ident := range field.Names {
				if ident == nil || ident.Name == "" || ident.Name == "_" {
					continue
				}
				fieldName := ident.Name
				pos := fset.Position(ident.Pos())
				identStartOff := pos.Offset
				identEndOff := fset.Position(ident.End()).Offset

				if isUnexportedFieldName(fieldName) {
					if hasSerialTag {
						exportedName := capitalizeFirstRune(fieldName)
						preview := fieldExprSlice
						if identStartOff >= fieldStartOff && identEndOff <= fieldEndOff && fieldEndOff <= len(src) {
							preview = strings.TrimSpace(
								src[fieldStartOff:identStartOff] + exportedName + src[identEndOff:fieldEndOff],
							)
						}
						id := fmt.Sprintf("unexported_tagged_field:%d:%d:%s.%s", pos.Line, pos.Column, structName, fieldName)
						issues = append(issues, serialSafetyInternalIssue{
							item: SerialSafetyIssueItem{
								ID:                 id,
								Category:           "unexported_tagged_field",
								Severity:           "error",
								Line:               pos.Line,
								Column:             pos.Column,
								StructName:         structName,
								FieldName:          fieldName,
								Expr:               fieldExprSlice,
								Message:            fmt.Sprintf("Unexported field %q in struct %q has struct tag %s that encoding/json and reflection serializers silently ignore", fieldName, structName, rawTagLit),
								Suggestion:         fmt.Sprintf("Export field %q as %q so reflection-based serializers can access it", fieldName, exportedName),
								FixTitle:           fmt.Sprintf("Export field as %s", exportedName),
								ReplacementPreview: preview,
								CanAutoFix:         true,
							},
							startOffset: identStartOff,
							endOffset:   identEndOff,
							replacement: exportedName,
						})
					}
					continue
				}

				if isSensitiveCredentialFieldName(fieldName) {
					if !hasJSONTag || strings.TrimSpace(jsonVal) != "-" {
						var editStart, editEnd int
						var editReplacement string
						var preview string

						if field.Tag == nil {
							typeEndOff := fset.Position(field.Type.End()).Offset
							editStart = typeEndOff
							editEnd = typeEndOff
							editReplacement = " `json:\"-\"`"
							if typeEndOff >= fieldStartOff && typeEndOff <= len(src) {
								preview = strings.TrimSpace(src[fieldStartOff:typeEndOff] + editReplacement)
							} else {
								preview = fieldExprSlice + editReplacement
							}
						} else {
							newTagLit := upsertJSONStructTagLiteral(rawTagLit, "-")
							editStart = tagStartOff
							editEnd = tagEndOff
							editReplacement = newTagLit
							if tagStartOff >= fieldStartOff && tagEndOff <= fieldEndOff && fieldEndOff <= len(src) {
								preview = strings.TrimSpace(
									src[fieldStartOff:tagStartOff] + newTagLit + src[tagEndOff:fieldEndOff],
								)
							} else {
								preview = fieldExprSlice
							}
						}

						id := fmt.Sprintf("sensitive_field_exposed:%d:%d:%s.%s", pos.Line, pos.Column, structName, fieldName)
						issues = append(issues, serialSafetyInternalIssue{
							item: SerialSafetyIssueItem{
								ID:                 id,
								Category:           "sensitive_field_exposed",
								Severity:           "error",
								Line:               pos.Line,
								Column:             pos.Column,
								StructName:         structName,
								FieldName:          fieldName,
								Expr:               fieldExprSlice,
								Message:            fmt.Sprintf("Exported sensitive field %q in struct %q is exposed during JSON serialization without `json:\"-\"`", fieldName, structName),
								Suggestion:         fmt.Sprintf("Set struct tag on %q to `json:\"-\"` so sensitive credentials are never serialized", fieldName),
								FixTitle:           "Redact field with `json:\"-\"`",
								ReplacementPreview: preview,
								CanAutoFix:         true,
							},
							startOffset: editStart,
							endOffset:   editEnd,
							replacement: editReplacement,
						})
						continue
					}
				}

				if hasJSONTag && field.Tag != nil {
					jsonKey, jsonOpts := splitJSONTagKeyAndOptions(jsonVal)
					if jsonKey != "" && jsonKey != "-" {
						jsonFields = append(jsonFields, jsonTaggedField{
							field:          field,
							ident:          ident,
							fieldName:      fieldName,
							line:           pos.Line,
							col:            pos.Column,
							jsonFullVal:    jsonVal,
							jsonKey:        jsonKey,
							jsonOptions:    jsonOpts,
							rawTagLit:      rawTagLit,
							fieldStartOff:  fieldStartOff,
							fieldEndOff:    fieldEndOff,
							tagStartOff:    tagStartOff,
							tagEndOff:      tagEndOff,
							fieldExprSlice: fieldExprSlice,
						})
					}
				}
			}
		}

		byKey := make(map[string][]jsonTaggedField)
		var keyOrder []string
		for _, jf := range jsonFields {
			if _, exists := byKey[jf.jsonKey]; !exists {
				keyOrder = append(keyOrder, jf.jsonKey)
			}
			byKey[jf.jsonKey] = append(byKey[jf.jsonKey], jf)
		}

		usedKeys := make(map[string]bool)
		for _, k := range keyOrder {
			usedKeys[k] = true
		}

		for _, key := range keyOrder {
			group := byKey[key]
			if len(group) < 2 {
				continue
			}

			primaryIdx := 0
			if len(group) == 2 {
				snake0 := toSerialSnakeCase(group[0].fieldName)
				snake1 := toSerialSnakeCase(group[1].fieldName)
				if snake1 == key && snake0 != key {
					primaryIdx = 1
				}
			}
			primaryField := group[primaryIdx]

			for idx, dup := range group {
				if idx == primaryIdx {
					continue
				}
				newKey := toSerialSnakeCase(dup.fieldName)
				if newKey == "" || newKey == key || usedKeys[newKey] {
					alt := strings.ToLower(dup.fieldName)
					if alt != "" && alt != key && !usedKeys[alt] {
						newKey = alt
					} else {
						newKey = fmt.Sprintf("%s_%d", toSerialSnakeCase(dup.fieldName), idx+1)
					}
				}
				usedKeys[newKey] = true

				newJSONVal := newKey + dup.jsonOptions
				newTagLit := upsertJSONStructTagLiteral(dup.rawTagLit, newJSONVal)
				preview := dup.fieldExprSlice
				if dup.tagStartOff >= dup.fieldStartOff && dup.tagEndOff <= dup.fieldEndOff && dup.fieldEndOff <= len(src) {
					preview = strings.TrimSpace(
						src[dup.fieldStartOff:dup.tagStartOff] + newTagLit + src[dup.tagEndOff:dup.fieldEndOff],
					)
				}

				id := fmt.Sprintf("duplicate_json_tag:%d:%d:%s.%s", dup.line, dup.col, structName, dup.fieldName)
				issues = append(issues, serialSafetyInternalIssue{
					item: SerialSafetyIssueItem{
						ID:                 id,
						Category:           "duplicate_json_tag",
						Severity:           "error",
						Line:               dup.line,
						Column:             dup.col,
						StructName:         structName,
						FieldName:          dup.fieldName,
						Expr:               dup.fieldExprSlice,
						Message:            fmt.Sprintf("Field %q in struct %q has duplicate json tag %q (collides with field %q), causing encoding/json to drop both fields", dup.fieldName, structName, key, primaryField.fieldName),
						Suggestion:         fmt.Sprintf("Rename json tag on %q from %q to %q", dup.fieldName, key, newKey),
						FixTitle:           fmt.Sprintf("Update json tag to %q", newKey),
						ReplacementPreview: preview,
						CanAutoFix:         true,
					},
					startOffset: dup.tagStartOff,
					endOffset:   dup.tagEndOff,
					replacement: newTagLit,
				})
			}
		}
	}

	ast.Inspect(astFile, func(n ast.Node) bool {
		ts, ok := n.(*ast.TypeSpec)
		if !ok || ts.Name == nil {
			return true
		}
		if st, isStruct := ts.Type.(*ast.StructType); isStruct {
			inspectStruct(ts.Name.Name, st)
		}
		return true
	})

	ast.Inspect(astFile, func(n ast.Node) bool {
		st, ok := n.(*ast.StructType)
		if ok && !visitedStructs[st] {
			inspectStruct("anonymous", st)
		}
		return true
	})

	sort.SliceStable(issues, func(i, j int) bool {
		if issues[i].item.Line != issues[j].item.Line {
			return issues[i].item.Line < issues[j].item.Line
		}
		if issues[i].item.Column != issues[j].item.Column {
			return issues[i].item.Column < issues[j].item.Column
		}
		return issues[i].item.Category < issues[j].item.Category
	})

	return issues, nil
}

func unquoteStructTagLiteral(rawLit string) string {
	trimmed := strings.TrimSpace(rawLit)
	if trimmed == "" {
		return ""
	}
	if unquoted, err := strconv.Unquote(trimmed); err == nil {
		return unquoted
	}
	return strings.Trim(trimmed, "`\"")
}

func hasSerializationStructTag(unquotedTag string) bool {
	if strings.TrimSpace(unquotedTag) == "" {
		return false
	}
	st := reflect.StructTag(unquotedTag)
	for _, key := range []string{"json", "yaml", "xml", "db"} {
		if _, ok := st.Lookup(key); ok {
			return true
		}
	}
	return serialAnyTagKeyRegex.MatchString(unquotedTag)
}

var structTagValuePatterns sync.Map

func structTagValuePattern(key string) *regexp.Regexp {
	if cached, ok := structTagValuePatterns.Load(key); ok {
		return cached.(*regexp.Regexp)
	}
	pattern := regexp.MustCompile(`(?:^|\s)` + regexp.QuoteMeta(key) + `:"([^"]*)"`)
	actual, _ := structTagValuePatterns.LoadOrStore(key, pattern)
	return actual.(*regexp.Regexp)
}

func lookupStructTagValue(unquotedTag, key string) (string, bool) {
	if strings.TrimSpace(unquotedTag) == "" {
		return "", false
	}
	st := reflect.StructTag(unquotedTag)
	if val, ok := st.Lookup(key); ok {
		return val, true
	}
	if m := structTagValuePattern(key).FindStringSubmatch(unquotedTag); len(m) == 2 {
		return m[1], true
	}
	return "", false
}

func splitJSONTagKeyAndOptions(jsonTagVal string) (string, string) {
	if idx := strings.IndexByte(jsonTagVal, ','); idx >= 0 {
		return strings.TrimSpace(jsonTagVal[:idx]), jsonTagVal[idx:]
	}
	return strings.TrimSpace(jsonTagVal), ""
}

func upsertJSONStructTagLiteral(rawTagLit, newJSONVal string) string {
	unquoted := strings.TrimSpace(unquoteStructTagLiteral(rawTagLit))
	replacementTag := fmt.Sprintf(`json:%q`, newJSONVal)

	if unquoted == "" {
		return "`" + replacementTag + "`"
	}

	if serialJSONTagKeyRegex.MatchString(unquoted) {
		updated := serialJSONTagKeyRegex.ReplaceAllStringFunc(unquoted, func(match string) string {
			if strings.HasPrefix(match, " ") || strings.HasPrefix(match, "\t") {
				return match[:1] + replacementTag
			}
			return replacementTag
		})
		return "`" + updated + "`"
	}

	return "`" + replacementTag + " " + unquoted + "`"
}

func isUnexportedFieldName(name string) bool {
	for _, r := range name {
		return unicode.IsLower(r)
	}
	return false
}

func capitalizeFirstRune(name string) string {
	runes := []rune(name)
	if len(runes) == 0 {
		return name
	}
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}

func isSensitiveCredentialFieldName(fieldName string) bool {
	trimmed := strings.TrimSpace(fieldName)
	if trimmed == "" || trimmed == "_" {
		return false
	}
	lower := strings.ToLower(trimmed)
	compact := strings.ReplaceAll(lower, "_", "")
	for _, kw := range serialSensitiveKeywords {
		if strings.Contains(lower, kw) || strings.Contains(compact, kw) {
			return true
		}
	}
	return false
}

func toSerialSnakeCase(ident string) string {
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
	if len(words) == 0 {
		return strings.ToLower(ident)
	}
	for i := range words {
		words[i] = strings.ToLower(words[i])
	}
	return strings.Join(words, "_")
}

func marshalSerialInspectResponse(resp SerialSafetyInspectResponse) string {
	if resp.Issues == nil {
		resp.Issues = []SerialSafetyIssueItem{}
	}
	data, err := json.Marshal(resp)
	if err != nil {
		return `{"issues":[],"unexportedTagCount":0,"sensitiveExposedCount":0,"duplicateTagCount":0,"error":"marshal error"}`
	}
	return string(data)
}

func marshalSerialFixResponse(resp SerialSafetyFixResponse) string {
	data, err := json.Marshal(resp)
	if err != nil {
		return `{"newContent":"","fixedCount":0,"error":"marshal error"}`
	}
	return string(data)
}

type samePackageOnlyImporter struct{}

func (samePackageOnlyImporter) Import(path string) (*types.Package, error) {
	name := path
	if idx := strings.LastIndex(name, "/"); idx >= 0 {
		name = name[idx+1:]
	}
	pkg := types.NewPackage(path, name)
	pkg.MarkComplete()
	return pkg, nil
}
