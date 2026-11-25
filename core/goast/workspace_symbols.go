package goast

import (
	"bytes"
	"container/heap"
	"encoding/json"
	"go/ast"
	"go/format"
	"go/token"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

type WorkspaceSymbolItem struct {
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Receiver  string `json:"receiver,omitempty"`
	Signature string `json:"signature"`
	Package   string `json:"package"`
	File      string `json:"file"`
	RelPath   string `json:"relPath"`
	Line      int    `json:"line"`
	Col       int    `json:"col"`
	Score     int    `json:"score"`
}

func SearchWorkspaceSymbolsJSON(workspacePath, query string, limit int) string {
	items := SearchWorkspaceSymbols(workspacePath, query, limit)
	if len(items) == 0 {
		return "[]"
	}
	raw, err := json.Marshal(items)
	if err != nil {
		return "[]"
	}
	return string(raw)
}

func SearchWorkspaceSymbols(workspacePath, query string, limit int) []WorkspaceSymbolItem {
	trimmedRoot := strings.TrimSpace(workspacePath)
	if trimmedRoot == "" {
		return []WorkspaceSymbolItem{}
	}
	if limit <= 0 {
		limit = 100
	}

	cleanRoot := filepath.Clean(trimmedRoot)
	if absRoot, err := filepath.Abs(cleanRoot); err == nil {
		cleanRoot = absRoot
	}

	symbols := workspaceSymbolIndexFor(cleanRoot).snapshot()
	results := topWorkspaceSymbols(symbols, strings.TrimSpace(query), limit)
	if results == nil {
		return []WorkspaceSymbolItem{}
	}
	return results
}

func topWorkspaceSymbols(symbols []WorkspaceSymbolItem, q string, limit int) []WorkspaceSymbolItem {
	h := &workspaceSymbolHeap{symbols: symbols}
	for i := range symbols {
		score := scoreWorkspaceSymbol(symbols[i], q)
		if q != "" && score <= 0 {
			continue
		}
		cand := rankedWorkspaceSymbol{index: i, score: score}
		if len(h.items) < limit {
			heap.Push(h, cand)
			continue
		}
		if workspaceSymbolBetter(symbols, cand, h.items[0]) {
			h.items[0] = cand
			heap.Fix(h, 0)
		}
	}
	if len(h.items) == 0 {
		return nil
	}
	ranked := h.items
	sort.Slice(ranked, func(i, j int) bool { return workspaceSymbolBetter(symbols, ranked[i], ranked[j]) })
	out := make([]WorkspaceSymbolItem, len(ranked))
	for i, r := range ranked {
		out[i] = symbols[r.index]
		out[i].Score = r.score
	}
	return out
}

type rankedWorkspaceSymbol struct {
	index int
	score int
}

type workspaceSymbolHeap struct {
	symbols []WorkspaceSymbolItem
	items   []rankedWorkspaceSymbol
}

func (h *workspaceSymbolHeap) Len() int { return len(h.items) }
func (h *workspaceSymbolHeap) Less(i, j int) bool {
	return workspaceSymbolBetter(h.symbols, h.items[j], h.items[i])
}
func (h *workspaceSymbolHeap) Swap(i, j int) { h.items[i], h.items[j] = h.items[j], h.items[i] }
func (h *workspaceSymbolHeap) Push(x any)    { h.items = append(h.items, x.(rankedWorkspaceSymbol)) }
func (h *workspaceSymbolHeap) Pop() any {
	last := h.items[len(h.items)-1]
	h.items = h.items[:len(h.items)-1]
	return last
}

func workspaceSymbolBetter(symbols []WorkspaceSymbolItem, a, b rankedWorkspaceSymbol) bool {
	if a.score != b.score {
		return a.score > b.score
	}
	x, y := &symbols[a.index], &symbols[b.index]
	if x.Name != y.Name {
		return x.Name < y.Name
	}
	if x.RelPath != y.RelPath {
		return x.RelPath < y.RelPath
	}
	if x.Line != y.Line {
		return x.Line < y.Line
	}
	if x.Col != y.Col {
		return x.Col < y.Col
	}
	return a.index < b.index
}
func shouldSkipWorkspaceSymbolDir(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	switch name {
	case "vendor", "node_modules", "build":
		return true
	default:
		return false
	}
}

func extractFileWorkspaceSymbols(fset *token.FileSet, f *ast.File, pkgName, cleanFile, relSlash string) []WorkspaceSymbolItem {
	var out []WorkspaceSymbolItem
	for _, decl := range f.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Name == nil || d.Name.Name == "_" {
				continue
			}
			kind := "func"
			recv := ""
			if d.Recv != nil && len(d.Recv.List) > 0 {
				kind = "method"
				recv = formatReceiverTypeName(fset, d.Recv.List[0].Type)
			}
			pos := fset.Position(d.Name.Pos())
			out = append(out, WorkspaceSymbolItem{
				Name:      d.Name.Name,
				Kind:      kind,
				Receiver:  recv,
				Signature: formatFuncSignatureOneLine(fset, d),
				Package:   pkgName,
				File:      cleanFile,
				RelPath:   relSlash,
				Line:      pos.Line,
				Col:       pos.Column,
			})
		case *ast.GenDecl:
			switch d.Tok {
			case token.TYPE:
				for _, spec := range d.Specs {
					ts, ok := spec.(*ast.TypeSpec)
					if !ok || ts.Name == nil || ts.Name.Name == "_" {
						continue
					}
					kind := "type"
					var sig string
					switch ts.Type.(type) {
					case *ast.StructType:
						kind = "struct"
						sig = "type " + ts.Name.Name + " struct"
					case *ast.InterfaceType:
						kind = "interface"
						sig = "type " + ts.Name.Name + " interface"
					default:
						typeText := formatNodeOneLine(fset, ts.Type)
						if ts.Assign.IsValid() {
							sig = "type " + ts.Name.Name + " = " + typeText
						} else if typeText != "" {
							sig = "type " + ts.Name.Name + " " + typeText
						} else {
							sig = "type " + ts.Name.Name
						}
					}
					pos := fset.Position(ts.Name.Pos())
					out = append(out, WorkspaceSymbolItem{
						Name:      ts.Name.Name,
						Kind:      kind,
						Signature: sig,
						Package:   pkgName,
						File:      cleanFile,
						RelPath:   relSlash,
						Line:      pos.Line,
						Col:       pos.Column,
					})
				}
			case token.CONST, token.VAR:
				kind := "var"
				if d.Tok == token.CONST {
					kind = "const"
				}
				for _, spec := range d.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok {
						continue
					}
					typeText := ""
					if vs.Type != nil {
						typeText = formatNodeOneLine(fset, vs.Type)
					}
					for _, id := range vs.Names {
						if id == nil || id.Name == "_" {
							continue
						}
						sig := kind + " " + id.Name
						if typeText != "" {
							sig += " " + typeText
						}
						pos := fset.Position(id.Pos())
						out = append(out, WorkspaceSymbolItem{
							Name:      id.Name,
							Kind:      kind,
							Signature: sig,
							Package:   pkgName,
							File:      cleanFile,
							RelPath:   relSlash,
							Line:      pos.Line,
							Col:       pos.Column,
						})
					}
				}
			default:
			}
		}
	}
	return out
}

func formatReceiverTypeName(fset *token.FileSet, expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.StarExpr:
		inner := formatReceiverBaseName(fset, e.X)
		if inner != "" {
			return "*" + inner
		}
	default:
		return formatReceiverBaseName(fset, expr)
	}
	return formatNodeOneLine(fset, expr)
}

func formatReceiverBaseName(fset *token.FileSet, expr ast.Expr) string {
	switch e := expr.(type) {
	case *ast.Ident:
		return e.Name
	case *ast.IndexExpr:
		return formatReceiverBaseName(fset, e.X)
	case *ast.IndexListExpr:
		return formatReceiverBaseName(fset, e.X)
	case *ast.ParenExpr:
		return formatReceiverBaseName(fset, e.X)
	default:
		return formatNodeOneLine(fset, expr)
	}
}

func formatFuncSignatureOneLine(fset *token.FileSet, fn *ast.FuncDecl) string {
	shallow := *fn
	shallow.Doc = nil
	shallow.Body = nil
	sig := formatNodeOneLine(fset, &shallow)
	if sig != "" {
		return sig
	}
	return "func " + fn.Name.Name + "()"
}

func formatNodeOneLine(fset *token.FileSet, node ast.Node) string {
	if node == nil {
		return ""
	}
	var buf bytes.Buffer
	if err := format.Node(&buf, fset, node); err != nil {
		return ""
	}
	return strings.Join(strings.Fields(buf.String()), " ")
}

func scoreWorkspaceSymbol(item WorkspaceSymbolItem, query string) int {
	if query == "" {
		if ast.IsExported(item.Name) {
			return 100
		}
		return 50
	}

	name := item.Name
	nameLower := strings.ToLower(name)
	qLower := strings.ToLower(query)

	if strings.EqualFold(name, query) {
		return 1000
	}
	if strings.HasPrefix(name, query) {
		return 800
	}
	if strings.HasPrefix(nameLower, qLower) {
		return 700
	}

	baseRecv := strings.TrimPrefix(item.Receiver, "*")
	recvDotName := ""
	baseRecvDotName := ""
	parenRecvDotName := ""
	if item.Receiver != "" {
		recvDotName = item.Receiver + "." + name
		baseRecvDotName = baseRecv + "." + name
		parenRecvDotName = "(" + item.Receiver + ")." + name
	}

	if matchesCamelCaseInitials(name, query) {
		return 500
	}
	if item.Receiver != "" {
		if strings.EqualFold(recvDotName, query) ||
			strings.EqualFold(baseRecvDotName, query) ||
			strings.EqualFold(parenRecvDotName, query) ||
			strings.HasPrefix(strings.ToLower(recvDotName), qLower) ||
			strings.HasPrefix(strings.ToLower(baseRecvDotName), qLower) ||
			strings.HasPrefix(strings.ToLower(parenRecvDotName), qLower) {
			return 500
		}
	}

	if strings.Contains(nameLower, qLower) {
		return 300
	}
	if item.Receiver != "" {
		if strings.Contains(strings.ToLower(recvDotName), qLower) ||
			strings.Contains(strings.ToLower(baseRecvDotName), qLower) ||
			strings.Contains(strings.ToLower(parenRecvDotName), qLower) {
			return 300
		}
	}
	if item.Package != "" {
		pkgDotName := strings.ToLower(item.Package + "." + name)
		if strings.Contains(pkgDotName, qLower) {
			return 300
		}
	}

	return 0
}

func matchesCamelCaseInitials(name, query string) bool {
	if len(query) < 2 || len(name) < 2 {
		return false
	}
	var initials []rune
	for i, r := range name {
		if i == 0 || unicode.IsUpper(r) {
			initials = append(initials, unicode.ToLower(r))
		}
	}
	if len(initials) < 2 {
		return false
	}
	initStr := string(initials)
	qLower := strings.ToLower(query)
	if strings.HasPrefix(initStr, qLower) {
		return true
	}

	qRunes := []rune(qLower)
	nameRunes := []rune(name)
	qi := 0
	for ni := 0; ni < len(nameRunes) && qi < len(qRunes); ni++ {
		r := nameRunes[ni]
		isHump := ni == 0 || unicode.IsUpper(r) || (ni > 0 && nameRunes[ni-1] == '_')
		if isHump && unicode.ToLower(r) == qRunes[qi] {
			qi++
		}
	}
	return qi == len(qRunes)
}
