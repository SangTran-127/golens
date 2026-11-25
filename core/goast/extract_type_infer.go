package goast

import (
	"go/ast"
	"go/token"
	"strings"
)

type funcTypeInferCtx struct {
	fset           *token.FileSet
	file           *ast.File
	src            []byte
	body           *ast.BlockStmt
	selStartPos    token.Pos
	selEndPos      token.Pos
	env            map[string]string
	declaredBefore map[string]bool
}

func inferTypesInFunc(ictx funcTypeInferCtx) {
	fset := ictx.fset
	file := ictx.file
	src := ictx.src
	body := ictx.body
	selStartPos := ictx.selStartPos
	selEndPos := ictx.selEndPos
	env := ictx.env
	declaredBefore := ictx.declaredBefore
	ast.Inspect(body, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		if n.Pos() > selEndPos {
			return false
		}
		isBefore := n.Pos() < selStartPos

		switch s := n.(type) {
		case *ast.DeclStmt:
			gd, ok := s.Decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.VAR {
				return true
			}
			for _, spec := range gd.Specs {
				vs, ok := spec.(*ast.ValueSpec)
				if !ok {
					continue
				}
				explicitType := ""
				if vs.Type != nil {
					explicitType = exprString(fset, src, vs.Type)
				}
				var rhsTypes []string
				if len(vs.Values) == 1 && len(vs.Names) > 1 {
					rhsTypes = inferExprTypes(fset, file, src, vs.Values[0], env)
				}
				for i, id := range vs.Names {
					if id == nil || id.Name == "" || id.Name == "_" {
						continue
					}
					if isBefore {
						declaredBefore[id.Name] = true
					}
					typ := explicitType
					if typ == "" {
						if len(rhsTypes) == len(vs.Names) {
							typ = rhsTypes[i]
						} else if i < len(vs.Values) {
							ts := inferExprTypes(fset, file, src, vs.Values[i], env)
							if len(ts) > 0 {
								typ = ts[0]
							}
						}
					}
					if typ == "" || typ == "any" {
						typ = fallbackTypeByName(id.Name, typ)
					}
					if typ != "" && (env[id.Name] == "" || env[id.Name] == "any") {
						env[id.Name] = typ
					}
				}
			}

		case *ast.AssignStmt:
			if s.Tok != token.DEFINE && s.Tok != token.ASSIGN {
				return true
			}
			var multiTypes []string
			if len(s.Rhs) == 1 && len(s.Lhs) > 1 {
				multiTypes = inferExprTypes(fset, file, src, s.Rhs[0], env)
			}
			for i, lhs := range s.Lhs {
				id, ok := lhs.(*ast.Ident)
				if !ok || id == nil || id.Name == "" || id.Name == "_" {
					continue
				}
				if isBefore && s.Tok == token.DEFINE {
					declaredBefore[id.Name] = true
				}
				var typ string
				if len(multiTypes) == len(s.Lhs) {
					typ = multiTypes[i]
				} else if i < len(s.Rhs) {
					ts := inferExprTypes(fset, file, src, s.Rhs[i], env)
					if len(ts) > 0 {
						typ = ts[0]
					}
				} else if len(s.Lhs) == 2 && i == 1 && len(s.Rhs) == 1 {
					switch s.Rhs[0].(type) {
					case *ast.IndexExpr, *ast.TypeAssertExpr, *ast.UnaryExpr:
						typ = "bool"
					}
				}
				if typ == "" || typ == "any" {
					typ = fallbackTypeByName(id.Name, typ)
				}
				if typ != "" && (env[id.Name] == "" || env[id.Name] == "any") {
					env[id.Name] = typ
				}
			}

		case *ast.RangeStmt:
			if isBefore && s.Tok == token.DEFINE {
				if id, ok := s.Key.(*ast.Ident); ok && id != nil && id.Name != "_" {
					declaredBefore[id.Name] = true
				}
				if id, ok := s.Value.(*ast.Ident); ok && id != nil && id.Name != "_" {
					declaredBefore[id.Name] = true
				}
			}
			kType, vType := inferRangeTypes(fset, file, src, s.X, env)
			if id, ok := s.Key.(*ast.Ident); ok && id != nil && id.Name != "_" {
				if env[id.Name] == "" || env[id.Name] == "any" {
					env[id.Name] = kType
				}
			}
			if id, ok := s.Value.(*ast.Ident); ok && id != nil && id.Name != "_" {
				if env[id.Name] == "" || env[id.Name] == "any" {
					env[id.Name] = vType
				}
			}
		}
		return true
	})
}

func inferRangeTypes(fset *token.FileSet, file *ast.File, src []byte, expr ast.Expr, env map[string]string) (string, string) {
	ts := inferExprTypes(fset, file, src, expr, env)
	t := ""
	if len(ts) > 0 {
		t = ts[0]
	}
	if strings.HasPrefix(t, "[]") {
		return "int", strings.TrimPrefix(t, "[]")
	}
	if strings.HasPrefix(t, "map[") {
		k, v := splitMapType(t)
		if k != "" && v != "" {
			return k, v
		}
	}
	if t == "string" {
		return "int", "rune"
	}
	return "int", "any"
}

func splitMapType(mapType string) (string, string) {
	if !strings.HasPrefix(mapType, "map[") {
		return "", ""
	}
	rest := strings.TrimPrefix(mapType, "map[")
	depth := 1
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case '[':
			depth++
		case ']':
			depth--
			if depth == 0 {
				return strings.TrimSpace(rest[:i]), strings.TrimSpace(rest[i+1:])
			}
		}
	}
	return "", ""
}

func inferExprTypes(fset *token.FileSet, file *ast.File, src []byte, expr ast.Expr, env map[string]string) []string {
	if expr == nil {
		return []string{"any"}
	}
	switch e := expr.(type) {
	case *ast.ParenExpr:
		return inferExprTypes(fset, file, src, e.X, env)

	case *ast.BasicLit:
		switch e.Kind {
		case token.STRING:
			return []string{"string"}
		case token.CHAR:
			return []string{"rune"}
		case token.INT:
			return []string{"int"}
		case token.FLOAT:
			return []string{"float64"}
		case token.IMAG:
			return []string{"complex128"}
		default:
		}

	case *ast.Ident:
		switch e.Name {
		case "true", "false":
			return []string{"bool"}
		default:
			if t, ok := env[e.Name]; ok && t != "" {
				return []string{t}
			}
			return []string{fallbackTypeByName(e.Name, "any")}
		}

	case *ast.CompositeLit:
		if e.Type != nil {
			return []string{exprString(fset, src, e.Type)}
		}

	case *ast.UnaryExpr:
		switch e.Op {
		case token.AND:
			if cl, ok := e.X.(*ast.CompositeLit); ok && cl.Type != nil {
				return []string{"*" + exprString(fset, src, cl.Type)}
			}
			sub := inferExprTypes(fset, file, src, e.X, env)
			if len(sub) > 0 && sub[0] != "" && sub[0] != "any" {
				return []string{"*" + sub[0]}
			}
		case token.NOT:
			return []string{"bool"}
		case token.ARROW:
			sub := inferExprTypes(fset, file, src, e.X, env)
			if len(sub) > 0 {
				t := strings.TrimSpace(strings.TrimPrefix(strings.TrimPrefix(sub[0], "<-chan"), "chan"))
				if t != "" {
					return []string{t}
				}
			}
		default:
			return inferExprTypes(fset, file, src, e.X, env)
		}

	case *ast.StarExpr:
		sub := inferExprTypes(fset, file, src, e.X, env)
		if len(sub) > 0 && strings.HasPrefix(sub[0], "*") {
			return []string{strings.TrimPrefix(sub[0], "*")}
		}

	case *ast.BinaryExpr:
		switch e.Op {
		case token.EQL, token.NEQ, token.LSS, token.LEQ, token.GTR, token.GEQ, token.LAND, token.LOR:
			return []string{"bool"}
		default:
			lt := inferExprTypes(fset, file, src, e.X, env)
			if len(lt) > 0 && lt[0] != "" && lt[0] != "any" {
				return lt
			}
			rt := inferExprTypes(fset, file, src, e.Y, env)
			if len(rt) > 0 && rt[0] != "" {
				return rt
			}
		}

	case *ast.IndexExpr:
		sub := inferExprTypes(fset, file, src, e.X, env)
		if len(sub) > 0 {
			xt := sub[0]
			if strings.HasPrefix(xt, "[]") {
				return []string{strings.TrimPrefix(xt, "[]")}
			}
			if strings.HasPrefix(xt, "map[") {
				_, v := splitMapType(xt)
				if v != "" {
					return []string{v}
				}
			}
			if xt == "string" {
				return []string{"byte"}
			}
		}

	case *ast.SliceExpr:
		return inferExprTypes(fset, file, src, e.X, env)

	case *ast.TypeAssertExpr:
		if e.Type != nil {
			return []string{exprString(fset, src, e.Type)}
		}

	case *ast.FuncLit:
		if e.Type != nil {
			return []string{exprString(fset, src, e.Type)}
		}

	case *ast.SelectorExpr:
		if e.Sel != nil {
			baseTypes := inferExprTypes(fset, file, src, e.X, env)
			if len(baseTypes) > 0 {
				structName := strings.TrimPrefix(baseTypes[0], "*")
				if ts := findTypeSpecInFile(file, structName); ts != nil {
					if st, ok := ts.Type.(*ast.StructType); ok && st.Fields != nil {
						for _, f := range st.Fields.List {
							for _, fn := range f.Names {
								if fn != nil && fn.Name == e.Sel.Name {
									return []string{exprString(fset, src, f.Type)}
								}
							}
						}
					}
				}
			}
		}

	case *ast.CallExpr:
		return inferCallExprTypes(fset, file, src, e, env)
	}

	return []string{"any"}
}

func inferCallExprTypes(fset *token.FileSet, file *ast.File, src []byte, call *ast.CallExpr, env map[string]string) []string {
	switch fun := call.Fun.(type) {
	case *ast.ArrayType, *ast.MapType, *ast.ChanType, *ast.StarExpr:
		return []string{exprString(fset, src, fun)}

	case *ast.Ident:
		switch fun.Name {
		case "len", "cap":
			return []string{"int"}
		case "make":
			if len(call.Args) >= 1 {
				return []string{exprString(fset, src, call.Args[0])}
			}
		case "new":
			if len(call.Args) >= 1 {
				return []string{"*" + exprString(fset, src, call.Args[0])}
			}
		case "append":
			if len(call.Args) >= 1 {
				return inferExprTypes(fset, file, src, call.Args[0], env)
			}
		case "string", "bool", "byte", "rune", "error",
			"int", "int8", "int16", "int32", "int64",
			"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
			"float32", "float64", "complex64", "complex128":
			return []string{fun.Name}
		}

		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if ok && fn.Recv == nil && fn.Name != nil && fn.Name.Name == fun.Name {
				return extractResultTypes(fset, src, fn.Type.Results)
			}
		}

	case *ast.SelectorExpr:
		if fun.Sel == nil {
			break
		}
		selName := fun.Sel.Name
		if pkgIdent, ok := fun.X.(*ast.Ident); ok {
			switch pkgIdent.Name + "." + selName {
			case "fmt.Sprintf", "fmt.Sprint", "fmt.Sprintln",
				"strings.TrimSpace", "strings.Trim", "strings.TrimPrefix", "strings.TrimSuffix",
				"strings.ToLower", "strings.ToUpper", "strings.Join", "strings.Replace", "strings.ReplaceAll", "strings.Repeat",
				"filepath.Join", "filepath.Dir", "filepath.Base", "filepath.Ext", "filepath.Clean",
				"strconv.Itoa", "strconv.FormatInt", "strconv.FormatBool", "strconv.Quote",
				"os.Getenv", "os.TempDir":
				return []string{"string"}
			case "strings.Split", "strings.Fields":
				return []string{"[]string"}
			case "strings.Contains", "strings.HasPrefix", "strings.HasSuffix", "strings.EqualFold":
				return []string{"bool"}
			case "strings.Index", "strings.LastIndex", "strings.Count":
				return []string{"int"}
			case "fmt.Errorf", "errors.New", "os.WriteFile", "os.Remove", "os.RemoveAll", "os.MkdirAll", "json.Unmarshal":
				return []string{"error"}
			case "strconv.Atoi":
				return []string{"int", "error"}
			case "strconv.Unquote":
				return []string{"string", "error"}
			case "strconv.ParseBool":
				return []string{"bool", "error"}
			case "strconv.ParseInt":
				return []string{"int64", "error"}
			case "strconv.ParseFloat":
				return []string{"float64", "error"}
			case "os.ReadFile", "json.Marshal", "json.MarshalIndent":
				return []string{"[]byte", "error"}
			case "context.Background", "context.TODO":
				return []string{"context.Context"}
			}
		}

		recvTypes := inferExprTypes(fset, file, src, fun.X, env)
		recvBase := ""
		if len(recvTypes) > 0 {
			recvBase = strings.TrimPrefix(recvTypes[0], "*")
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Recv == nil || fn.Name == nil || fn.Name.Name != selName {
				continue
			}
			if recvBase != "" && extractReceiverTypeName(fn.Recv) == recvBase {
				return extractResultTypes(fset, src, fn.Type.Results)
			}
		}
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if ok && fn.Recv != nil && fn.Name != nil && fn.Name.Name == selName {
				return extractResultTypes(fset, src, fn.Type.Results)
			}
		}
	}

	return []string{"any"}
}

func extractResultTypes(fset *token.FileSet, src []byte, results *ast.FieldList) []string {
	if results == nil || len(results.List) == 0 {
		return nil
	}
	var out []string
	for _, field := range results.List {
		t := exprString(fset, src, field.Type)
		if len(field.Names) == 0 {
			out = append(out, t)
		} else {
			for range field.Names {
				out = append(out, t)
			}
		}
	}
	return out
}

func fallbackTypeByName(name string, current string) string {
	switch name {
	case "err":
		return "error"
	case "ok":
		return "bool"
	case "ctx":
		return "context.Context"
	}
	if strings.HasSuffix(name, "Err") {
		return "error"
	}
	if current != "" {
		return current
	}
	return "any"
}

func lookupInferredType(name string, env map[string]string) string {
	if t, ok := env[name]; ok && t != "" {
		return t
	}
	return fallbackTypeByName(name, "any")
}

func collectTopLevelDeclNames(file *ast.File) map[string]bool {
	names := map[string]bool{}
	for _, imp := range file.Imports {
		if imp == nil {
			continue
		}
		if imp.Name != nil && imp.Name.Name != "" && imp.Name.Name != "." && imp.Name.Name != "_" {
			names[imp.Name.Name] = true
		} else if imp.Path != nil {
			p := strings.Trim(imp.Path.Value, "\"`")
			if idx := strings.LastIndex(p, "/"); idx >= 0 {
				p = p[idx+1:]
			}
			if p != "" {
				names[p] = true
			}
		}
	}
	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Recv == nil && d.Name != nil {
				names[d.Name.Name] = true
			}
		case *ast.GenDecl:
			for _, spec := range d.Specs {
				switch s := spec.(type) {
				case *ast.TypeSpec:
					if s.Name != nil {
						names[s.Name.Name] = true
					}
				case *ast.ValueSpec:
					for _, id := range s.Names {
						if id != nil {
							names[id.Name] = true
						}
					}
				}
			}
		}
	}
	return names
}

func isPredeclaredIdent(name string) bool {
	switch name {
	case "true", "false", "nil", "iota",
		"any", "bool", "byte", "comparable",
		"complex64", "complex128", "error", "float32", "float64",
		"int", "int8", "int16", "int32", "int64",
		"rune", "string",
		"uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
		"append", "cap", "clear", "close", "complex", "copy", "delete", "imag",
		"len", "make", "max", "min", "new", "panic", "print", "println", "real", "recover",
		"fmt", "os", "strings", "strconv", "errors", "filepath", "json", "time", "context", "io", "sort", "math", "sync":
		return true
	}
	return false
}
