package goast

import (
	"bytes"
	"encoding/json"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

type StructFieldLayout struct {
	Name          string `json:"name"`
	TypeExpr      string `json:"typeExpr"`
	Tag           string `json:"tag,omitempty"`
	Size          int    `json:"size"`
	Align         int    `json:"align"`
	Offset        int    `json:"offset"`
	PaddingBefore int    `json:"paddingBefore"`
	embedded      bool
}

type StructLayoutReport struct {
	StructName      string                `json:"structName"`
	Arch            string                `json:"arch"`
	WordSize        int                   `json:"wordSize"`
	CurrentSize     int                   `json:"currentSize"`
	CurrentAlign    int                   `json:"currentAlign"`
	CurrentPadding  int                   `json:"currentPadding"`
	TailPadding     int                   `json:"tailPadding"`
	OptimizedSize   int                   `json:"optimizedSize"`
	SavedBytes      int                   `json:"savedBytes"`
	Fields          []StructFieldLayout   `json:"fields"`
	OptimizedFields []StructFieldLayout   `json:"optimizedFields"`
	EditsByPath     map[string][]TextEdit `json:"editsByPath,omitempty"`
	Error           string                `json:"error,omitempty"`
}

func InspectStructLayoutJSON(path string, src []byte, offset int, goarch string) string {
	report := InspectStructLayout(path, src, offset, goarch)
	b, err := json.Marshal(report)
	if err != nil {
		fallback, _ := json.Marshal(StructLayoutReport{
			Arch:            report.Arch,
			WordSize:        report.WordSize,
			Fields:          []StructFieldLayout{},
			OptimizedFields: []StructFieldLayout{},
			Error:           err.Error(),
		})
		return string(fallback)
	}
	return string(b)
}

func InspectStructLayout(path string, src []byte, offset int, goarch string) StructLayoutReport {
	arch := strings.TrimSpace(goarch)
	if arch == "" {
		arch = runtime.GOARCH
		if arch == "" {
			arch = "arm64"
		}
	}
	wordSize := 8
	switch arch {
	case "386", "arm", "mips", "mipsle", "wasm":
		wordSize = 4
	default:
		wordSize = 8
	}

	report := StructLayoutReport{
		Arch:            arch,
		WordSize:        wordSize,
		Fields:          []StructFieldLayout{},
		OptimizedFields: []StructFieldLayout{},
	}

	if len(src) == 0 && strings.TrimSpace(path) != "" {
		data, err := os.ReadFile(path)
		if err != nil {
			report.Error = "failed to read file: " + err.Error()
			return report
		}
		src = data
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, src, parser.ParseComments)
	if file == nil {
		if err != nil {
			report.Error = "failed to parse file: " + err.Error()
		} else {
			report.Error = "failed to parse file"
		}
		return report
	}

	tf := fset.File(file.Pos())
	if tf == nil {
		report.Error = "failed to locate token file"
		return report
	}

	if offset < 0 {
		offset = 0
	}
	if offset > tf.Size() {
		offset = tf.Size()
	}
	pos := tf.Pos(offset)

	targetName, targetStruct := locateStructForLayout(fset, file, pos)
	if targetStruct == nil {
		report.Error = "No struct found in current file"
		return report
	}
	report.StructName = targetName

	typeSpecsByName := collectTypeSpecs(file)
	rawFields := extractLayoutFields(fset, src, targetStruct, wordSize, typeSpecsByName)

	currentFields, currentSize, currentAlign, currentPadding, tailPadding := computeFieldOffsets(rawFields)
	report.Fields = currentFields
	report.CurrentSize = currentSize
	report.CurrentAlign = currentAlign
	report.CurrentPadding = currentPadding
	report.TailPadding = tailPadding

	sortedInput := make([]StructFieldLayout, len(rawFields))
	copy(sortedInput, rawFields)
	sort.SliceStable(sortedInput, func(i, j int) bool {
		if sortedInput[i].Align != sortedInput[j].Align {
			return sortedInput[i].Align > sortedInput[j].Align
		}
		return sortedInput[i].Size > sortedInput[j].Size
	})

	optFields, optSize, _, _, _ := computeFieldOffsets(sortedInput)
	report.OptimizedFields = optFields
	report.OptimizedSize = optSize
	report.SavedBytes = currentSize - optSize
	if report.SavedBytes < 0 {
		report.SavedBytes = 0
	}

	baseIndent := lineIndentationAt(fset, src, targetStruct.Pos())
	formattedStruct := formatOptimizedStructNode(optFields, baseIndent)
	if formattedStruct != "" {
		report.EditsByPath = map[string][]TextEdit{
			path: {
				{
					Range:   lspRange(fset, src, targetStruct.Pos(), targetStruct.End()),
					NewText: formattedStruct,
				},
			},
		}
	}

	return report
}

type layoutStructCandidate struct {
	name       string
	structType *ast.StructType
	startPos   token.Pos
	endPos     token.Pos
	startLine  int
	endLine    int
}

func locateStructForLayout(fset *token.FileSet, file *ast.File, pos token.Pos) (string, *ast.StructType) {
	var candidates []layoutStructCandidate

	ast.Inspect(file, func(n ast.Node) bool {
		gd, ok := n.(*ast.GenDecl)
		if !ok || gd.Tok != token.TYPE {
			return true
		}
		for _, spec := range gd.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok || ts.Name == nil {
				continue
			}
			st, ok := ts.Type.(*ast.StructType)
			if !ok {
				continue
			}
			sPos := gd.Pos()
			if len(gd.Specs) > 1 {
				sPos = ts.Pos()
			}
			ePos := ts.End()
			candidates = append(candidates, layoutStructCandidate{
				name:       ts.Name.Name,
				structType: st,
				startPos:   sPos,
				endPos:     ePos,
				startLine:  fset.Position(sPos).Line,
				endLine:    fset.Position(ePos).Line,
			})
		}
		return true
	})

	ast.Inspect(file, func(n ast.Node) bool {
		st, ok := n.(*ast.StructType)
		if !ok {
			return true
		}
		for _, c := range candidates {
			if c.structType == st {
				return true
			}
		}
		candidates = append(candidates, layoutStructCandidate{
			name:       "struct",
			structType: st,
			startPos:   st.Pos(),
			endPos:     st.End(),
			startLine:  fset.Position(st.Pos()).Line,
			endLine:    fset.Position(st.End()).Line,
		})
		return true
	})

	if len(candidates) == 0 {
		return "", nil
	}

	var bestEnclosing *layoutStructCandidate
	for i := range candidates {
		c := &candidates[i]
		if pos >= c.startPos && pos <= c.endPos {
			if bestEnclosing == nil || (c.structType.Pos() >= bestEnclosing.structType.Pos() && c.structType.End() <= bestEnclosing.structType.End()) {
				bestEnclosing = c
			}
		}
	}
	if bestEnclosing != nil {
		return bestEnclosing.name, bestEnclosing.structType
	}

	caretLine := fset.Position(pos).Line
	for i := range candidates {
		c := &candidates[i]
		if caretLine >= c.startLine && caretLine <= c.endLine {
			return c.name, c.structType
		}
	}

	return candidates[0].name, candidates[0].structType
}

func collectTypeSpecs(file *ast.File) map[string]*ast.TypeSpec {
	out := make(map[string]*ast.TypeSpec)
	ast.Inspect(file, func(n ast.Node) bool {
		ts, ok := n.(*ast.TypeSpec)
		if ok && ts.Name != nil && ts.Name.Name != "" {
			if _, exists := out[ts.Name.Name]; !exists {
				out[ts.Name.Name] = ts
			}
		}
		return true
	})
	return out
}

func extractLayoutFields(fset *token.FileSet, src []byte, st *ast.StructType, wordSize int, typeSpecs map[string]*ast.TypeSpec) []StructFieldLayout {
	out := make([]StructFieldLayout, 0)
	if st == nil || st.Fields == nil {
		return out
	}

	for _, field := range st.Fields.List {
		if field == nil || field.Type == nil {
			continue
		}
		typeExpr := exprString(fset, src, field.Type)
		tag := ""
		if field.Tag != nil {
			tag = field.Tag.Value
		}
		size, align := estimateTypeSizeAlign(field.Type, wordSize, typeSpecs, map[string]bool{})

		if len(field.Names) == 0 {
			out = append(out, StructFieldLayout{
				Name:     embeddedFieldName(field.Type, typeExpr),
				TypeExpr: typeExpr,
				Tag:      tag,
				Size:     size,
				Align:    align,
				embedded: true,
			})
			continue
		}

		for _, id := range field.Names {
			if id == nil {
				continue
			}
			out = append(out, StructFieldLayout{
				Name:     id.Name,
				TypeExpr: typeExpr,
				Tag:      tag,
				Size:     size,
				Align:    align,
			})
		}
	}

	return out
}

func embeddedFieldName(expr ast.Expr, fallback string) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return embeddedFieldName(t.X, fallback)
	case *ast.SelectorExpr:
		if t.Sel != nil {
			return t.Sel.Name
		}
	case *ast.IndexExpr:
		return embeddedFieldName(t.X, fallback)
	case *ast.IndexListExpr:
		return embeddedFieldName(t.X, fallback)
	}
	return fallback
}

func clampAlign(align, wordSize int) int {
	if align < 1 {
		return 1
	}
	if align > wordSize {
		return wordSize
	}
	return align
}

func estimateTypeSizeAlign(expr ast.Expr, wordSize int, typeSpecs map[string]*ast.TypeSpec, visited map[string]bool) (int, int) {
	if expr == nil {
		return wordSize, wordSize
	}

	switch t := expr.(type) {
	case *ast.ParenExpr:
		return estimateTypeSizeAlign(t.X, wordSize, typeSpecs, visited)

	case *ast.StarExpr, *ast.ChanType, *ast.MapType, *ast.FuncType:
		return wordSize, wordSize

	case *ast.InterfaceType:
		return 2 * wordSize, wordSize

	case *ast.ArrayType:
		if t.Len == nil {
			return 3 * wordSize, wordSize
		}
		elemSize, elemAlign := estimateTypeSizeAlign(t.Elt, wordSize, typeSpecs, visited)
		n := parseArrayLength(t.Len)
		if n < 0 {
			return elemSize, elemAlign
		}
		return n * elemSize, elemAlign

	case *ast.StructType:
		if t.Fields == nil || len(t.Fields.List) == 0 {
			return 0, 1
		}
		var subFields []StructFieldLayout
		for _, f := range t.Fields.List {
			if f == nil || f.Type == nil {
				continue
			}
			fSize, fAlign := estimateTypeSizeAlign(f.Type, wordSize, typeSpecs, visited)
			count := len(f.Names)
			if count == 0 {
				count = 1
			}
			for i := 0; i < count; i++ {
				subFields = append(subFields, StructFieldLayout{
					Size:  fSize,
					Align: fAlign,
				})
			}
		}
		if len(subFields) == 0 {
			return 0, 1
		}
		_, totalSize, structAlign, _, _ := computeFieldOffsets(subFields)
		return totalSize, structAlign

	case *ast.SelectorExpr:
		pkgIdent, _ := t.X.(*ast.Ident)
		pkgName := ""
		if pkgIdent != nil {
			pkgName = pkgIdent.Name
		}
		selName := ""
		if t.Sel != nil {
			selName = t.Sel.Name
		}
		fullName := pkgName + "." + selName
		switch fullName {
		case "time.Duration":
			return 8, clampAlign(8, wordSize)
		case "time.Time":
			return 24, clampAlign(8, wordSize)
		case "unsafe.Pointer":
			return wordSize, wordSize
		case "sync.Mutex", "sync.WaitGroup":
			return 8, 4
		case "atomic.Bool":
			return 1, 1
		case "atomic.Int32", "atomic.Uint32":
			return 4, 4
		case "atomic.Int64", "atomic.Uint64":
			return 8, clampAlign(8, wordSize)
		default:
			return wordSize, wordSize
		}

	case *ast.Ident:
		switch t.Name {
		case "bool", "int8", "uint8", "byte":
			return 1, 1
		case "int16", "uint16":
			return 2, 2
		case "int32", "uint32", "rune", "float32":
			return 4, 4
		case "int64", "uint64", "float64", "complex64":
			return 8, clampAlign(8, wordSize)
		case "complex128":
			return 16, clampAlign(8, wordSize)
		case "int", "uint", "uintptr":
			return wordSize, wordSize
		case "string":
			return 2 * wordSize, wordSize
		case "any", "error":
			return 2 * wordSize, wordSize
		default:
			if ts, ok := typeSpecs[t.Name]; ok && ts != nil && ts.Type != nil {
				if visited[t.Name] {
					return wordSize, wordSize
				}
				visited[t.Name] = true
				size, align := estimateTypeSizeAlign(ts.Type, wordSize, typeSpecs, visited)
				delete(visited, t.Name)
				return size, align
			}
			return wordSize, wordSize
		}

	case *ast.IndexExpr:
		return estimateTypeSizeAlign(t.X, wordSize, typeSpecs, visited)

	case *ast.IndexListExpr:
		return estimateTypeSizeAlign(t.X, wordSize, typeSpecs, visited)

	default:
		return wordSize, wordSize
	}
}

func parseArrayLength(expr ast.Expr) int {
	switch e := expr.(type) {
	case *ast.BasicLit:
		if e.Kind == token.INT {
			if v, err := strconv.Atoi(e.Value); err == nil && v >= 0 {
				return v
			}
		}
	case *ast.ParenExpr:
		return parseArrayLength(e.X)
	}
	return 0
}

func computeFieldOffsets(fields []StructFieldLayout) ([]StructFieldLayout, int, int, int, int) {
	if len(fields) == 0 {
		return []StructFieldLayout{}, 0, 1, 0, 0
	}

	laidOut := make([]StructFieldLayout, len(fields))
	offset := 0
	structAlign := 1
	sumPaddingBefore := 0

	for i, f := range fields {
		align := f.Align
		if align < 1 {
			align = 1
		}
		if align > structAlign {
			structAlign = align
		}
		padding := (align - (offset % align)) % align
		offset += padding
		f.PaddingBefore = padding
		f.Offset = offset
		f.Align = align
		laidOut[i] = f
		sumPaddingBefore += padding
		offset += f.Size
	}

	tailPadding := (structAlign - (offset % structAlign)) % structAlign
	totalSize := offset + tailPadding
	totalPadding := sumPaddingBefore + tailPadding

	return laidOut, totalSize, structAlign, totalPadding, tailPadding
}

func lineIndentationAt(fset *token.FileSet, src []byte, pos token.Pos) string {
	p := fset.Position(pos)
	lineStart := p.Offset - (p.Column - 1)
	if lineStart < 0 || lineStart >= len(src) {
		return ""
	}
	i := lineStart
	for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
		i++
	}
	return string(src[lineStart:i])
}

func formatOptimizedStructNode(fields []StructFieldLayout, baseIndent string) string {
	if len(fields) == 0 {
		return "struct{}"
	}

	var sb strings.Builder
	sb.WriteString("package p\n\ntype T struct {\n")
	for _, f := range fields {
		sb.WriteByte('\t')
		if f.embedded {
			sb.WriteString(f.TypeExpr)
		} else {
			sb.WriteString(f.Name)
			sb.WriteByte(' ')
			sb.WriteString(f.TypeExpr)
		}
		if f.Tag != "" {
			sb.WriteByte(' ')
			sb.WriteString(f.Tag)
		}
		sb.WriteByte('\n')
	}
	sb.WriteString("}\n")

	tmpFset := token.NewFileSet()
	tmpFile, err := parser.ParseFile(tmpFset, "", sb.String(), parser.ParseComments)
	if err == nil && tmpFile != nil {
		for _, decl := range tmpFile.Decls {
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
					var buf bytes.Buffer
					if err := format.Node(&buf, tmpFset, st); err == nil {
						formatted := buf.String()
						if baseIndent != "" {
							formatted = strings.ReplaceAll(formatted, "\n", "\n"+baseIndent)
						}
						return formatted
					}
				}
			}
		}
	}

	var raw strings.Builder
	raw.WriteString("struct {\n")
	for _, f := range fields {
		raw.WriteString(baseIndent)
		raw.WriteByte('\t')
		if f.embedded {
			raw.WriteString(f.TypeExpr)
		} else {
			raw.WriteString(f.Name)
			raw.WriteByte(' ')
			raw.WriteString(f.TypeExpr)
		}
		if f.Tag != "" {
			raw.WriteByte(' ')
			raw.WriteString(f.Tag)
		}
		raw.WriteByte('\n')
	}
	raw.WriteString(baseIndent)
	raw.WriteByte('}')
	return raw.String()
}
