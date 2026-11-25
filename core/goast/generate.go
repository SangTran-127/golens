package goast

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	goTestFileSuffix       = "_test.go"
	errNoStructFoundInFile = "no struct found in file"
)

type GenerateCodeRequest struct {
	Kind         string            `json:"kind"`
	Action       string            `json:"action,omitempty"`
	Path         string            `json:"path"`
	Offset       int               `json:"offset"`
	TargetName   string            `json:"targetName,omitempty"`
	Target       string            `json:"target,omitempty"`
	WorkspaceDir string            `json:"workspaceDir,omitempty"`
	Buffers      map[string]string `json:"buffers,omitempty"`
}

type GenerateCodeResponse struct {
	EditsByPath map[string][]SigTextEdit `json:"editsByPath,omitempty"`
	TargetPath  string                   `json:"targetPath,omitempty"`
	Error       string                   `json:"error,omitempty"`
}

type InterfaceCandidate struct {
	Name       string   `json:"name"`
	Package    string   `json:"package"`
	Methods    []string `json:"methods"`
	TypeParams []string `json:"typeParams,omitempty"`
	ImportPath string   `json:"importPath,omitempty"`
}

var goastStdlibPkgs = map[string]string{
	"io":       "io",
	"fmt":      "fmt",
	"sort":     "sort",
	"http":     "net/http",
	"encoding": "encoding",
	"json":     "encoding/json",
	"sql":      "database/sql",
	"driver":   "database/sql/driver",
	"context":  "context",
	"time":     "time",
	"bytes":    "bytes",
	"strings":  "strings",
	"sync":     "sync",
	"errors":   "errors",
	"url":      "net/url",
}

type structFieldInfo struct {
	name string
	typ  string
}

type structTarget struct {
	genDecl    *ast.GenDecl
	typeSpec   *ast.TypeSpec
	structType *ast.StructType
}

var stdlibInterfaces = []InterfaceCandidate{
	{
		Name:    "io.Reader",
		Package: "io",
		Methods: []string{"Read(p []byte) (n int, err error)"},
	},
	{
		Name:    "io.Writer",
		Package: "io",
		Methods: []string{"Write(p []byte) (n int, err error)"},
	},
	{
		Name:    "io.Closer",
		Package: "io",
		Methods: []string{"Close() error"},
	},
	{
		Name:    "io.ReadWriter",
		Package: "io",
		Methods: []string{"Read(p []byte) (n int, err error)", "Write(p []byte) (n int, err error)"},
	},
	{
		Name:    "fmt.Stringer",
		Package: "fmt",
		Methods: []string{"String() string"},
	},
	{
		Name:    "error",
		Package: "builtin",
		Methods: []string{"Error() string"},
	},
	{
		Name:    "sort.Interface",
		Package: "sort",
		Methods: []string{"Len() int", "Less(i int, j int) bool", "Swap(i int, j int)"},
	},
	{
		Name:    "http.Handler",
		Package: "net/http",
		Methods: []string{"ServeHTTP(w http.ResponseWriter, r *http.Request)"},
	},
	{
		Name:    "encoding.TextMarshaler",
		Package: "encoding",
		Methods: []string{"MarshalText() (text []byte, err error)"},
	},
	{
		Name:    "encoding.TextUnmarshaler",
		Package: "encoding",
		Methods: []string{"UnmarshalText(text []byte) error"},
	},
	{
		Name:    "json.Marshaler",
		Package: "encoding/json",
		Methods: []string{"MarshalJSON() ([]byte, error)"},
	},
	{
		Name:    "json.Unmarshaler",
		Package: "encoding/json",
		Methods: []string{"UnmarshalJSON(data []byte) error"},
	},
	{
		Name:    "sql.Scanner",
		Package: "database/sql",
		Methods: []string{"Scan(src any) error"},
	},
	{
		Name:    "driver.Valuer",
		Package: "database/sql/driver",
		Methods: []string{"Value() (driver.Value, error)"},
	},
}

func GenerateCode(reqJSON string) string {
	var req GenerateCodeRequest
	if err := json.Unmarshal([]byte(reqJSON), &req); err != nil {
		return marshalError("invalid request: " + err.Error())
	}
	if strings.TrimSpace(req.Path) == "" {
		return marshalError("missing file path")
	}

	kind := strings.TrimSpace(req.Kind)
	if kind == "" {
		kind = strings.TrimSpace(req.Action)
	}
	req.Kind = kind
	if strings.TrimSpace(req.TargetName) == "" && strings.TrimSpace(req.Target) != "" {
		req.TargetName = strings.TrimSpace(req.Target)
	}

	readSource := func(p string) ([]byte, error) {
		if req.Buffers != nil {
			if buf, ok := req.Buffers[p]; ok {
				return []byte(buf), nil
			}
		}
		return os.ReadFile(p)
	}

	src, err := readSource(req.Path)
	if err != nil {
		return marshalError("failed to read file: " + err.Error())
	}

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, req.Path, src, parser.ParseComments)
	if file == nil {
		if err != nil {
			return marshalError("failed to parse file: " + err.Error())
		}
		return marshalError("failed to parse file")
	}
	tf := fset.File(file.Pos())
	if tf == nil {
		return marshalError("failed to locate token file")
	}

	offset := req.Offset
	if offset < 0 {
		offset = 0
	}
	if offset > tf.Size() {
		offset = tf.Size()
	}
	pos := tf.Pos(offset)

	target, enclosingFn, recvTypeName := locateTargetStruct(file, pos)

	switch req.Kind {
	case "constructor":
		if target == nil {
			return marshalError(errNoStructFoundInFile)
		}
		return generateConstructor(req.Path, fset, file, src, target)

	case "extract_interface":
		typeName := ""
		var insertPos token.Pos
		if target != nil {
			typeName = target.typeSpec.Name.Name
			insertPos = declStartPos(target.genDecl.Doc, target.genDecl.Pos())
		} else if enclosingFn != nil && recvTypeName != "" {
			typeName = recvTypeName
			insertPos = declStartPos(enclosingFn.Doc, enclosingFn.Pos())
		} else {
			return marshalError("no target type found for interface extraction")
		}
		return generateExtractInterface(req, fset, src, file, typeName, insertPos, readSource)

	case "implement_interface":
		typeName := ""
		var typeParams *ast.FieldList
		endPos := tf.Pos(tf.Size())
		if target != nil {
			typeName = target.typeSpec.Name.Name
			typeParams = target.typeSpec.TypeParams
			endPos = target.genDecl.End()
		} else if enclosingFn != nil && recvTypeName != "" {
			typeName = recvTypeName
			endPos = enclosingFn.End()
		} else {
			return marshalError(errNoStructFoundInFile)
		}
		return generateImplementInterface(req, fset, src, file, typeName, typeParams, endPos, readSource)

	case "move_symbol":
		return generateMoveSymbol(req, fset, tf, src, file, pos, readSource)

	default:
		return marshalError("unsupported generation kind: " + req.Kind)
	}
}

func declStartPos(doc *ast.CommentGroup, pos token.Pos) token.Pos {
	if doc != nil && doc.Pos().IsValid() && doc.Pos() < pos {
		return doc.Pos()
	}
	return pos
}

func locateTargetStruct(file *ast.File, pos token.Pos) (*structTarget, *ast.FuncDecl, string) {
	var allStructs []structTarget
	var enclosingFn *ast.FuncDecl
	var recvTypeName string

	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.GenDecl:
			if d.Tok != token.TYPE {
				continue
			}
			for _, spec := range d.Specs {
				ts, ok := spec.(*ast.TypeSpec)
				if !ok || ts.Name == nil {
					continue
				}
				st, ok := ts.Type.(*ast.StructType)
				if !ok {
					continue
				}
				allStructs = append(allStructs, structTarget{
					genDecl:    d,
					typeSpec:   ts,
					structType: st,
				})
			}
		case *ast.FuncDecl:
			if pos >= d.Pos() && pos <= d.End() {
				enclosingFn = d
				recvTypeName = extractReceiverTypeName(d.Recv)
			}
		}
	}

	for i := range allStructs {
		s := &allStructs[i]
		if pos >= s.typeSpec.Pos() && pos <= s.typeSpec.End() {
			return s, enclosingFn, recvTypeName
		}
		if pos >= s.genDecl.Pos() && pos <= s.genDecl.End() {
			return s, enclosingFn, recvTypeName
		}
	}

	if recvTypeName != "" {
		for i := range allStructs {
			if allStructs[i].typeSpec.Name.Name == recvTypeName {
				return &allStructs[i], enclosingFn, recvTypeName
			}
		}
		if enclosingFn != nil {
			return nil, enclosingFn, recvTypeName
		}
	}

	if len(allStructs) == 0 {
		return nil, enclosingFn, recvTypeName
	}
	if len(allStructs) == 1 {
		return &allStructs[0], enclosingFn, recvTypeName
	}

	bestIdx := 0
	for i := range allStructs {
		if allStructs[i].genDecl.Pos() <= pos {
			bestIdx = i
		}
	}
	return &allStructs[bestIdx], enclosingFn, recvTypeName
}

func extractReceiverTypeName(recv *ast.FieldList) string {
	if recv == nil || len(recv.List) == 0 {
		return ""
	}
	return baseTypeName(recv.List[0].Type)
}

func baseTypeName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return baseTypeName(t.X)
	case *ast.IndexExpr:
		return baseTypeName(t.X)
	case *ast.IndexListExpr:
		return baseTypeName(t.X)
	case *ast.ParenExpr:
		return baseTypeName(t.X)
	default:
		return ""
	}
}

func generateEmbeddedFieldName(expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.StarExpr:
		return generateEmbeddedFieldName(e.X)
	case *ast.IndexExpr:
		return generateEmbeddedFieldName(e.X)
	case *ast.IndexListExpr:
		return generateEmbeddedFieldName(e.X)
	case *ast.ParenExpr:
		return generateEmbeddedFieldName(e.X)
	case *ast.Ident:
		return e.Name
	case *ast.SelectorExpr:
		if e.Sel != nil {
			return e.Sel.Name
		}
	}
	return ""
}

func extractStructFields(fset *token.FileSet, src []byte, st *ast.StructType) []structFieldInfo {
	var fields []structFieldInfo
	if st == nil || st.Fields == nil {
		return fields
	}
	for _, field := range st.Fields.List {
		typStr := exprString(fset, src, field.Type)
		if typStr == "" {
			continue
		}
		if isGoastSyncLockType(typStr) {
			continue
		}
		if len(field.Names) == 0 {
			embName := generateEmbeddedFieldName(field.Type)
			if embName == "" || embName == "_" {
				continue
			}
			fields = append(fields, structFieldInfo{
				name: embName,
				typ:  typStr,
			})
			continue
		}
		for _, id := range field.Names {
			if id == nil || id.Name == "" || id.Name == "_" {
				continue
			}
			fields = append(fields, structFieldInfo{
				name: id.Name,
				typ:  typStr,
			})
		}
	}
	return fields
}

func safeParamName(fieldName string, used map[string]bool) string {
	if fieldName == "" {
		return "v"
	}
	allUpper := true
	for _, r := range fieldName {
		if unicode.IsLetter(r) && !unicode.IsUpper(r) {
			allUpper = false
			break
		}
	}
	var param string
	if allUpper {
		param = strings.ToLower(fieldName)
	} else {
		r, size := utf8.DecodeRuneInString(fieldName)
		param = string(unicode.ToLower(r)) + fieldName[size:]
	}
	if token.Lookup(param).IsKeyword() {
		param += "Val"
	}
	base := param
	for idx := 2; used[param]; idx++ {
		param = fmt.Sprintf("%s%d", base, idx)
	}
	used[param] = true
	return param
}

func receiverIdentForType(typeName string) string {
	recvName := "s"
	for _, r := range typeName {
		if unicode.IsLetter(r) {
			recvName = strings.ToLower(string(r))
			break
		}
	}
	if token.Lookup(recvName).IsKeyword() {
		recvName = "s"
	}
	return recvName
}

func constructorFuncName(typeName string) string {
	if typeName == "" {
		return "New"
	}
	r, size := utf8.DecodeRuneInString(typeName)
	upper := string(unicode.ToUpper(r)) + typeName[size:]
	if ast.IsExported(typeName) {
		return "New" + upper
	}
	return "new" + upper
}

func generateConstructor(path string, fset *token.FileSet, file *ast.File, src []byte, target *structTarget) string {
	typeName := target.typeSpec.Name.Name
	ctorName := constructorFuncName(typeName)
	tpDecl, tpUse, tpNames, _ := extractGoastTypeParams(fset, src, target.typeSpec.TypeParams)
	fields := extractStructFields(fset, src, target.structType)

	usedParams := map[string]bool{typeName: true, ctorName: true}
	addGoastReservedPredeclared(usedParams)
	for alias := range collectGoastFileImportAliases(file) {
		usedParams[alias] = true
	}
	for _, tp := range tpNames {
		if tp != "" {
			usedParams[tp] = true
		}
	}

	var params []string
	var inits []string
	for _, f := range fields {
		pName := safeParamName(f.name, usedParams)
		params = append(params, pName+" "+f.typ)
		inits = append(inits, fmt.Sprintf("\t\t%s: %s,", f.name, pName))
	}

	retType := typeName + tpUse
	var raw string
	if len(fields) == 0 {
		raw = fmt.Sprintf("func %s%s() *%s {\n\treturn &%s{}\n}", ctorName, tpDecl, retType, retType)
	} else {
		raw = fmt.Sprintf("func %s%s(%s) *%s {\n\treturn &%s{\n%s\n\t}\n}",
			ctorName,
			tpDecl,
			strings.Join(params, ", "),
			retType,
			retType,
			strings.Join(inits, "\n"),
		)
	}

	formatted, err := format.Source([]byte(raw))
	if err != nil {
		formatted = []byte(raw)
	}
	ctorCode := strings.TrimSpace(string(formatted))

	if packageDeclaresFunc(path, file, ctorName) {
		b, _ := json.Marshal(GenerateCodeResponse{Error: ctorName + " already exists. Rename or remove it, then generate the constructor again."})
		return string(b)
	}

	insertText := "\n\n" + ctorCode
	endPos := target.genDecl.End()
	resp := GenerateCodeResponse{
		EditsByPath: map[string][]SigTextEdit{
			path: {
				{
					Range:   lspRange(fset, src, endPos, endPos),
					NewText: insertText,
				},
			},
		},
	}
	b, _ := json.Marshal(resp)
	return string(b)
}
