package goast

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type ParamSpec struct {
	OrigIndex    int    `json:"origIndex"`
	Name         string `json:"name"`
	Type         string `json:"type"`
	DefaultValue string `json:"defaultValue"`
}

type FuncSignatureSpec struct {
	Path     string      `json:"path"`
	Name     string      `json:"name"`
	OrigName string      `json:"origName"`
	Receiver string      `json:"receiver"`
	NameLine int         `json:"nameLine"`
	NameCol  int         `json:"nameCol"`
	Params   []ParamSpec `json:"params"`
	Results  []ParamSpec `json:"results"`
}

type SigRefLocation struct {
	Path string `json:"path"`
	Line int    `json:"line"`
	Col  int    `json:"col"`
}

type ChangeSignatureRequest struct {
	Spec       FuncSignatureSpec `json:"spec"`
	References []SigRefLocation  `json:"references"`
	Buffers    map[string]string `json:"buffers"`
}

type LSPWirePos struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type LSPWireRange struct {
	Start LSPWirePos `json:"start"`
	End   LSPWirePos `json:"end"`
}

type SigTextEdit struct {
	Range   LSPWireRange `json:"range"`
	NewText string       `json:"newText"`
}

type ChangeSignatureResponse struct {
	EditsByPath map[string][]SigTextEdit `json:"editsByPath"`
	Error       string                   `json:"error,omitempty"`
}

func InspectFuncSignature(path string, src []byte, offset int) string {
	fset := token.NewFileSet()
	f, _ := parser.ParseFile(fset, path, src, parser.ParseComments)
	if f == nil {
		return ""
	}
	tf := fset.File(f.Pos())
	if tf == nil {
		return ""
	}
	if offset < 0 {
		offset = 0
	}
	if offset > tf.Size() {
		offset = tf.Size()
	}
	pos := tf.Pos(offset)
	caretLine := fset.Position(pos).Line

	for _, d := range f.Decls {
		fn, ok := d.(*ast.FuncDecl)
		if !ok || fn.Name == nil {
			continue
		}
		headerEnd := fn.End()
		if fn.Body != nil {
			headerEnd = fn.Body.Pos()
		}
		if (pos >= fn.Pos() && pos <= headerEnd) || fset.Position(fn.Name.Pos()).Line == caretLine {
			return buildFuncSignatureSpec(path, src, fset, fn)
		}
	}

	if callSpec := inspectCallSiteSignature(path, src, fset, f, pos, caretLine); callSpec != "" {
		return callSpec
	}

	var target *ast.FuncDecl
	for _, d := range f.Decls {
		fn, ok := d.(*ast.FuncDecl)
		if !ok || fn.Name == nil {
			continue
		}
		if pos >= fn.Pos() && pos <= fn.End() {
			target = fn
			break
		}
	}
	if target == nil {
		return ""
	}
	return buildFuncSignatureSpec(path, src, fset, target)
}

func buildFuncSignatureSpec(path string, src []byte, fset *token.FileSet, target *ast.FuncDecl) string {
	recvStr := ""
	if target.Recv != nil && len(target.Recv.List) > 0 {
		rf := target.Recv.List[0]
		rType := exprString(fset, src, rf.Type)
		if len(rf.Names) > 0 && rf.Names[0] != nil && rf.Names[0].Name != "" {
			recvStr = rf.Names[0].Name + " " + rType
		} else {
			recvStr = rType
		}
	}

	namePos := fset.Position(target.Name.Pos())
	lineStart := namePos.Offset - (namePos.Column - 1)
	if lineStart < 0 {
		lineStart = 0
	}
	nameCol := 1
	if namePos.Offset >= lineStart && namePos.Offset <= len(src) {
		nameCol = utf16Len(src[lineStart:namePos.Offset]) + 1
	}

	spec := FuncSignatureSpec{
		Path:     path,
		Name:     target.Name.Name,
		OrigName: target.Name.Name,
		Receiver: recvStr,
		NameLine: namePos.Line,
		NameCol:  nameCol,
		Params:   flattenFieldList(fset, src, target.Type.Params),
		Results:  flattenFieldList(fset, src, target.Type.Results),
	}

	b, err := json.Marshal(spec)
	if err != nil {
		return ""
	}
	return string(b)
}

func inspectCallSiteSignature(path string, src []byte, fset *token.FileSet, f *ast.File, pos token.Pos, caretLine int) string {
	var onFunCalls []*ast.CallExpr
	var containingCalls []*ast.CallExpr
	var sameLineCalls []*ast.CallExpr

	ast.Inspect(f, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok || call.Fun == nil {
			return true
		}
		if pos >= call.Fun.Pos() && pos <= call.Fun.End() {
			onFunCalls = append(onFunCalls, call)
		} else if pos >= call.Pos() && pos <= call.End() {
			containingCalls = append(containingCalls, call)
		} else if fset.Position(call.Pos()).Line == caretLine {
			sameLineCalls = append(sameLineCalls, call)
		}
		return true
	})

	var candidates []*ast.CallExpr
	for i := len(onFunCalls) - 1; i >= 0; i-- {
		candidates = append(candidates, onFunCalls[i])
	}
	for i := len(containingCalls) - 1; i >= 0; i-- {
		candidates = append(candidates, containingCalls[i])
	}
	candidates = append(candidates, sameLineCalls...)

	for _, call := range candidates {
		calleeIdent := extractCalleeIdent(call.Fun)
		if calleeIdent == nil || calleeIdent.Name == "" {
			continue
		}
		if declPath, declSrc, declFset, declFn := resolveCalledFuncDecl(path, src, fset, f, call, calleeIdent.Name); declFn != nil {
			return buildFuncSignatureSpec(declPath, declSrc, declFset, declFn)
		}
	}

	var standaloneSel *ast.SelectorExpr
	ast.Inspect(f, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok || sel.Sel == nil {
			return true
		}
		if pos >= sel.Pos() && pos <= sel.End() {
			standaloneSel = sel
		}
		return true
	})
	if standaloneSel != nil && standaloneSel.Sel.Name != "" {
		synthCall := &ast.CallExpr{
			Fun:    standaloneSel,
			Lparen: standaloneSel.End(),
			Rparen: standaloneSel.End(),
		}
		if declPath, declSrc, declFset, declFn := resolveCalledFuncDecl(path, src, fset, f, synthCall, standaloneSel.Sel.Name); declFn != nil {
			return buildFuncSignatureSpec(declPath, declSrc, declFset, declFn)
		}
	}
	return ""
}

type parsedSigFile struct {
	path string
	src  []byte
	fset *token.FileSet
	ast  *ast.File
}

func unwrapCallFunExpr(fun ast.Expr) ast.Expr {
	cur := fun
	for {
		switch x := cur.(type) {
		case *ast.IndexExpr:
			cur = x.X
		case *ast.IndexListExpr:
			cur = x.X
		case *ast.ParenExpr:
			cur = x.X
		default:
			return cur
		}
	}
}

func baseTypeNameForContainer(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.ArrayType:
		return baseTypeNameForContainer(t.Elt)
	case *ast.MapType:
		return baseTypeNameForContainer(t.Value)
	case *ast.Ellipsis:
		return baseTypeNameForContainer(t.Elt)
	default:
		return baseTypeName(expr)
	}
}

func loadSiblingSigFiles(primaryPath string, primarySrc []byte, primaryFset *token.FileSet, primaryAST *ast.File, buffers map[string]string) []parsedSigFile {
	out := []parsedSigFile{
		{path: primaryPath, src: primarySrc, fset: primaryFset, ast: primaryAST},
	}
	dir := filepath.Dir(primaryPath)
	if dir == "" {
		return out
	}
	seen := map[string]bool{primaryPath: true}
	var candPaths []string
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if strings.HasSuffix(name, ".go") && !strings.HasPrefix(name, ".") && !strings.HasPrefix(name, "_") {
				full := filepath.Join(dir, name)
				if !seen[full] {
					seen[full] = true
					candPaths = append(candPaths, full)
				}
			}
		}
	}
	for bufPath := range buffers {
		if filepath.Dir(bufPath) == dir && strings.HasSuffix(bufPath, ".go") && !seen[bufPath] {
			seen[bufPath] = true
			candPaths = append(candPaths, bufPath)
		}
	}
	sort.Strings(candPaths)
	for _, candPath := range candPaths {
		var candSrc []byte
		if buffers != nil {
			if buf, ok := buffers[candPath]; ok {
				candSrc = []byte(buf)
			}
		}
		if candSrc == nil {
			data, err := os.ReadFile(candPath)
			if err != nil {
				continue
			}
			candSrc = data
		}
		candFset := token.NewFileSet()
		candAST, _ := parser.ParseFile(candFset, candPath, candSrc, parser.ParseComments)
		if candAST == nil {
			continue
		}
		out = append(out, parsedSigFile{
			path: candPath,
			src:  candSrc,
			fset: candFset,
			ast:  candAST,
		})
	}
	return out
}

func inferSigSelectorReceiverType(fileAST *ast.File, fileSrc []byte, fileFset *token.FileSet, pkgFiles []parsedSigFile, sel *ast.SelectorExpr, atPos token.Pos) string {
	if sel == nil || sel.X == nil {
		return ""
	}
	return inferSigExprBaseType(sel.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, 0)
}

func inferSigExprBaseType(expr ast.Expr, atPos token.Pos, fileAST *ast.File, fileSrc []byte, fileFset *token.FileSet, pkgFiles []parsedSigFile, depth int) string {
	if expr == nil || depth > 8 {
		return ""
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return inferSigExprBaseType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, depth+1)
	case *ast.StarExpr:
		return inferSigExprBaseType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, depth+1)
	case *ast.UnaryExpr:
		if e.Op == token.AND || e.Op == token.ARROW {
			return inferSigExprBaseType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, depth+1)
		}
	case *ast.CompositeLit:
		return baseTypeNameForContainer(e.Type)
	case *ast.TypeAssertExpr:
		return baseTypeNameForContainer(e.Type)
	case *ast.IndexExpr:
		return inferSigExprBaseType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, depth+1)
	case *ast.SliceExpr:
		return inferSigExprBaseType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, depth+1)
	case *ast.CallExpr:
		uFun := unwrapCallFunExpr(e.Fun)
		switch fun := uFun.(type) {
		case *ast.Ident:
			if fun.Name == "new" || fun.Name == "make" {
				if len(e.Args) >= 1 {
					return baseTypeNameForContainer(e.Args[0])
				}
			}
			for _, pf := range pkgFiles {
				for _, d := range pf.ast.Decls {
					fn, ok := d.(*ast.FuncDecl)
					if !ok || fn.Recv != nil || fn.Name == nil || fn.Name.Name != fun.Name {
						continue
					}
					if fn.Type.Results != nil && len(fn.Type.Results.List) > 0 {
						if bt := baseTypeNameForContainer(fn.Type.Results.List[0].Type); bt != "" {
							return bt
						}
					}
				}
			}
			if strings.HasPrefix(fun.Name, "New") && len(fun.Name) > 3 {
				candType := fun.Name[3:]
				for _, pf := range pkgFiles {
					if findTypeSpecInFile(pf.ast, candType) != nil {
						return candType
					}
				}
				return candType
			}
		case *ast.SelectorExpr:
			if fun.Sel != nil {
				recvT := inferSigExprBaseType(fun.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, depth+1)
				for _, pf := range pkgFiles {
					for _, d := range pf.ast.Decls {
						fn, ok := d.(*ast.FuncDecl)
						if !ok || fn.Recv == nil || fn.Name == nil || fn.Name.Name != fun.Sel.Name {
							continue
						}
						if recvT == "" || extractReceiverTypeName(fn.Recv) == recvT {
							if fn.Type.Results != nil && len(fn.Type.Results.List) > 0 {
								if bt := baseTypeNameForContainer(fn.Type.Results.List[0].Type); bt != "" {
									return bt
								}
							}
						}
					}
				}
			}
		}
	case *ast.SelectorExpr:
		if e.Sel != nil {
			ownerType := inferSigExprBaseType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles, depth+1)
			if ownerType != "" {
				for _, pf := range pkgFiles {
					ts := findTypeSpecInFile(pf.ast, ownerType)
					if ts == nil {
						continue
					}
					st, ok := ts.Type.(*ast.StructType)
					if !ok || st.Fields == nil {
						continue
					}
					for _, field := range st.Fields.List {
						if len(field.Names) == 0 {
							if baseTypeNameForContainer(field.Type) == e.Sel.Name {
								return e.Sel.Name
							}
						}
						for _, fn := range field.Names {
							if fn != nil && fn.Name == e.Sel.Name {
								return baseTypeNameForContainer(field.Type)
							}
						}
					}
				}
			}
		}
	case *ast.Ident:
		if fileAST == nil || e.Name == "" || e.Name == "_" {
			return ""
		}
		for _, d := range fileAST.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || fn.Pos() > atPos || fn.End() < atPos {
				continue
			}
			if fn.Recv != nil {
				for _, rf := range fn.Recv.List {
					for _, rn := range rf.Names {
						if rn != nil && rn.Name == e.Name {
							return baseTypeNameForContainer(rf.Type)
						}
					}
				}
			}
			if fn.Type.Params != nil {
				for _, pf := range fn.Type.Params.List {
					for _, pn := range pf.Names {
						if pn != nil && pn.Name == e.Name {
							return baseTypeNameForContainer(pf.Type)
						}
					}
				}
			}
			if fn.Type.Results != nil {
				for _, rf := range fn.Type.Results.List {
					for _, rn := range rf.Names {
						if rn != nil && rn.Name == e.Name {
							return baseTypeNameForContainer(rf.Type)
						}
					}
				}
			}
			if fn.Body != nil {
				var inferred string
				ast.Inspect(fn.Body, func(n ast.Node) bool {
					if n == nil || n.Pos() > atPos {
						return false
					}
					switch s := n.(type) {
					case *ast.DeclStmt:
						if gd, ok := s.Decl.(*ast.GenDecl); ok && gd.Tok == token.VAR {
							for _, spec := range gd.Specs {
								vs, ok := spec.(*ast.ValueSpec)
								if !ok {
									continue
								}
								for i, id := range vs.Names {
									if id == nil || id.Name != e.Name {
										continue
									}
									if vs.Type != nil {
										if bt := baseTypeNameForContainer(vs.Type); bt != "" {
											inferred = bt
										}
									} else if i < len(vs.Values) {
										if bt := inferSigExprBaseType(vs.Values[i], s.Pos(), fileAST, fileSrc, fileFset, pkgFiles, depth+1); bt != "" {
											inferred = bt
										}
									}
								}
							}
						}
					case *ast.AssignStmt:
						if s.Tok == token.DEFINE || s.Tok == token.ASSIGN {
							for i, lhs := range s.Lhs {
								id, ok := lhs.(*ast.Ident)
								if !ok || id == nil || id.Name != e.Name {
									continue
								}
								if i < len(s.Rhs) {
									if bt := inferSigExprBaseType(s.Rhs[i], s.Pos(), fileAST, fileSrc, fileFset, pkgFiles, depth+1); bt != "" {
										inferred = bt
									}
								} else if len(s.Rhs) == 1 && i == 0 {
									if bt := inferSigExprBaseType(s.Rhs[0], s.Pos(), fileAST, fileSrc, fileFset, pkgFiles, depth+1); bt != "" {
										inferred = bt
									}
								}
							}
						}
					case *ast.RangeStmt:
						if id, ok := s.Value.(*ast.Ident); ok && id != nil && id.Name == e.Name {
							if bt := inferSigExprBaseType(s.X, s.Pos(), fileAST, fileSrc, fileFset, pkgFiles, depth+1); bt != "" {
								inferred = bt
							}
						}
					}
					return true
				})
				if inferred != "" {
					return inferred
				}
			}
		}
		for _, pf := range pkgFiles {
			for _, d := range pf.ast.Decls {
				gd, ok := d.(*ast.GenDecl)
				if !ok || gd.Tok != token.VAR {
					continue
				}
				for _, spec := range gd.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok {
						continue
					}
					for i, id := range vs.Names {
						if id == nil || id.Name != e.Name {
							continue
						}
						if vs.Type != nil {
							if bt := baseTypeNameForContainer(vs.Type); bt != "" {
								return bt
							}
						} else if i < len(vs.Values) {
							if bt := inferSigExprBaseType(vs.Values[i], vs.Pos(), pf.ast, pf.src, pf.fset, pkgFiles, depth+1); bt != "" {
								return bt
							}
						}
					}
				}
			}
		}
	}
	return ""
}

func inferCallArgType(arg ast.Expr, atPos token.Pos, fileAST *ast.File, fileSrc []byte, fileFset *token.FileSet, pkgFiles []parsedSigFile) string {
	if arg == nil {
		return ""
	}
	switch e := arg.(type) {
	case *ast.ParenExpr:
		return inferCallArgType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles)
	case *ast.BasicLit:
		switch e.Kind {
		case token.STRING:
			return "string"
		case token.INT:
			return "int"
		case token.FLOAT:
			return "float64"
		case token.CHAR:
			return "rune"
		case token.IMAG:
			return "complex128"
		default:
		}
	case *ast.Ident:
		if e.Name == "true" || e.Name == "false" {
			return "bool"
		}
		if e.Name == "nil" {
			return ""
		}
	case *ast.UnaryExpr:
		if e.Op == token.NOT {
			return "bool"
		}
		if e.Op == token.SUB || e.Op == token.ADD {
			return inferCallArgType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles)
		}
	case *ast.BinaryExpr:
		switch e.Op {
		case token.EQL, token.NEQ, token.LSS, token.LEQ, token.GTR, token.GEQ, token.LAND, token.LOR:
			return "bool"
		default:
			if lt := inferCallArgType(e.X, atPos, fileAST, fileSrc, fileFset, pkgFiles); lt != "" {
				return lt
			}
			return inferCallArgType(e.Y, atPos, fileAST, fileSrc, fileFset, pkgFiles)
		}
	}
	return inferSigExprBaseType(arg, atPos, fileAST, fileSrc, fileFset, pkgFiles, 0)
}

func isFuncDeclVariadic(fn *ast.FuncDecl) bool {
	if fn == nil || fn.Type == nil || fn.Type.Params == nil || len(fn.Type.Params.List) == 0 {
		return false
	}
	last := fn.Type.Params.List[len(fn.Type.Params.List)-1]
	_, ok := last.Type.(*ast.Ellipsis)
	return ok
}

type sigCandidateScoreCtx struct {
	call             *ast.CallExpr
	primaryPath      string
	callerAST        *ast.File
	callerSrc        []byte
	callerFset       *token.FileSet
	pkgFiles         []parsedSigFile
	isSel            bool
	inferredRecvType string
}

func scoreSigCandidate(pf parsedSigFile, fn *ast.FuncDecl, sctx sigCandidateScoreCtx) int {
	call := sctx.call
	primaryPath := sctx.primaryPath
	callerAST := sctx.callerAST
	callerSrc := sctx.callerSrc
	callerFset := sctx.callerFset
	pkgFiles := sctx.pkgFiles
	isSel := sctx.isSel
	inferredRecvType := sctx.inferredRecvType
	score := 0
	if pf.path == primaryPath {
		score += 1
	}
	if isSel {
		if fn.Recv != nil {
			score += 5
			candRecv := extractReceiverTypeName(fn.Recv)
			if inferredRecvType != "" {
				if candRecv == inferredRecvType {
					score += 100
				} else {
					score -= 100
				}
			}
		}
	} else if fn.Recv == nil {
		score += 10
	}

	if call == nil {
		return score
	}

	params := flattenFieldList(pf.fset, pf.src, fn.Type.Params)
	variadic := isFuncDeclVariadic(fn)
	if !variadic {
		if len(call.Args) == len(params) {
			score += 20
		} else {
			score -= 30
		}
	} else {
		if len(call.Args) >= len(params)-1 {
			score += 10
		} else {
			score -= 30
		}
	}

	for i, arg := range call.Args {
		if i >= len(params) {
			break
		}
		pType := strings.TrimSpace(strings.TrimPrefix(params[i].Type, "..."))
		pBase := strings.TrimPrefix(pType, "*")
		argType := inferCallArgType(arg, call.Pos(), callerAST, callerSrc, callerFset, pkgFiles)
		if argType == "" || pType == "" {
			continue
		}
		argBase := strings.TrimPrefix(argType, "*")
		if argType == pType || argBase == pBase {
			score += 25
		} else if pType == "any" || pType == "interface{}" {
			score += 2
		} else {
			score -= 25
		}
	}
	return score
}

