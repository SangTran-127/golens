package goast

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"sort"
	"strings"
)

type ByteSpan struct {
	StartByte int `json:"startByte"`
	EndByte   int `json:"endByte"`
}

func SyntaxSelectionRanges(src string, byteOffset int) string {
	spans := computeSyntaxSelectionRanges(src, byteOffset)
	b, err := json.Marshal(spans)
	if err != nil {
		return "[]"
	}
	return string(b)
}

func computeSyntaxSelectionRanges(src string, byteOffset int) []ByteSpan {
	if len(src) == 0 {
		return []ByteSpan{}
	}
	if byteOffset < 0 {
		byteOffset = 0
	}
	if byteOffset > len(src) {
		byteOffset = len(src)
	}

	fset := token.NewFileSet()
	file, _ := parser.ParseFile(fset, "selection.go", src, parser.ParseComments)
	if file == nil {
		return []ByteSpan{}
	}
	tf := fset.File(file.Pos())
	if tf == nil {
		return []ByteSpan{}
	}

	var rawSpans []ByteSpan
	addSpan := func(start, end int) {
		if start < 0 {
			start = 0
		}
		if end > len(src) {
			end = len(src)
		}
		if start >= end {
			return
		}
		if start <= byteOffset && byteOffset <= end {
			rawSpans = append(rawSpans, ByteSpan{StartByte: start, EndByte: end})
		}
	}

	for _, cg := range file.Comments {
		if cg == nil {
			continue
		}
		cgStart := posOffset(tf, len(src), cg.Pos())
		cgEnd := posOffset(tf, len(src), cg.End())
		if byteOffset < cgStart || byteOffset > cgEnd {
			continue
		}
		for _, c := range cg.List {
			if c == nil {
				continue
			}
			cStart := posOffset(tf, len(src), c.Pos())
			cEnd := posOffset(tf, len(src), c.End())
			if byteOffset < cStart || byteOffset > cEnd {
				continue
			}
			if strings.HasPrefix(c.Text, "//") {
				innerStart := cStart + 2
				for innerStart < cEnd && (src[innerStart] == ' ' || src[innerStart] == '\t') {
					innerStart++
				}
				addSpan(innerStart, cEnd)
				addSpan(cStart+2, cEnd)
			} else if strings.HasPrefix(c.Text, "/*") && strings.HasSuffix(c.Text, "*/") && cEnd-cStart >= 4 {
				addSpan(cStart+2, cEnd-2)
			}
			addSpan(cStart, cEnd)
		}
		addSpan(cgStart, cgEnd)
	}

	ast.Inspect(file, func(n ast.Node) bool {
		if n == nil {
			return false
		}
		nStart := posOffset(tf, len(src), n.Pos())
		nEnd := posOffset(tf, len(src), n.End())
		if nStart < 0 || nEnd < 0 {
			return true
		}

		switch node := n.(type) {
		case *ast.BasicLit:
			if nStart <= byteOffset && byteOffset <= nEnd {
				if (node.Kind == token.STRING || node.Kind == token.CHAR) && nEnd-nStart >= 2 {
					addSpan(nStart+1, nEnd-1)
				}
				addSpan(nStart, nEnd)
			}

		case *ast.Ident,
			*ast.SelectorExpr,
			*ast.IndexExpr,
			*ast.IndexListExpr,
			*ast.SliceExpr,
			*ast.TypeAssertExpr,
			*ast.StarExpr,
			*ast.UnaryExpr,
			*ast.BinaryExpr,
			*ast.KeyValueExpr,
			*ast.ParenExpr,
			*ast.CompositeLit,
			*ast.FuncLit,
			*ast.ValueSpec,
			*ast.TypeSpec,
			*ast.Field,
			*ast.AssignStmt,
			*ast.ReturnStmt,
			*ast.ExprStmt,
			*ast.DeclStmt,
			*ast.DeferStmt,
			*ast.GoStmt,
			*ast.SendStmt,
			*ast.IncDecStmt,
			*ast.BranchStmt,
			*ast.IfStmt,
			*ast.ForStmt,
			*ast.RangeStmt,
			*ast.SwitchStmt,
			*ast.TypeSwitchStmt,
			*ast.SelectStmt,
			*ast.CommClause,
			*ast.CaseClause:
			addSpan(nStart, nEnd)

		case *ast.CallExpr:
			if len(node.Args) > 1 {
				aStart := posOffset(tf, len(src), node.Args[0].Pos())
				aEnd := posOffset(tf, len(src), node.Args[len(node.Args)-1].End())
				addSpan(aStart, aEnd)
			}
			addSpan(nStart, nEnd)

		case *ast.BlockStmt:
			if len(node.List) > 0 {
				firstStart := posOffset(tf, len(src), node.List[0].Pos())
				lastEnd := posOffset(tf, len(src), node.List[len(node.List)-1].End())
				addSpan(firstStart, lastEnd)
			}
			lbrace := posOffset(tf, len(src), node.Lbrace)
			rbrace := posOffset(tf, len(src), node.Rbrace)
			if lbrace >= 0 && rbrace > lbrace+1 {
				addSpan(lbrace+1, rbrace)
			}
			addSpan(nStart, nEnd)

		case *ast.FuncDecl:
			addSpan(nStart, nEnd)
			if node.Doc != nil {
				docStart := posOffset(tf, len(src), node.Doc.Pos())
				addSpan(docStart, nEnd)
			}

		case *ast.GenDecl:
			addSpan(nStart, nEnd)
			if node.Doc != nil {
				docStart := posOffset(tf, len(src), node.Doc.Pos())
				addSpan(docStart, nEnd)
			}

		case *ast.File:
			addSpan(nStart, nEnd)
			addSpan(0, len(src))
		}

		return true
	})

	addSpan(0, len(src))

	sort.SliceStable(rawSpans, func(i, j int) bool {
		lenI := rawSpans[i].EndByte - rawSpans[i].StartByte
		lenJ := rawSpans[j].EndByte - rawSpans[j].StartByte
		if lenI != lenJ {
			return lenI < lenJ
		}
		if rawSpans[i].StartByte != rawSpans[j].StartByte {
			return rawSpans[i].StartByte > rawSpans[j].StartByte
		}
		return rawSpans[i].EndByte < rawSpans[j].EndByte
	})

	var result []ByteSpan
	for _, sp := range rawSpans {
		if len(result) == 0 {
			result = append(result, sp)
			continue
		}
		prev := result[len(result)-1]
		if sp.StartByte <= prev.StartByte && sp.EndByte >= prev.EndByte &&
			(sp.EndByte-sp.StartByte) > (prev.EndByte-prev.StartByte) {
			result = append(result, sp)
		}
	}

	return result
}

func posOffset(tf *token.File, srcLen int, p token.Pos) int {
	if !p.IsValid() || tf == nil {
		return -1
	}
	off := int(p) - tf.Base()
	if off < 0 {
		return 0
	}
	if off > srcLen {
		return srcLen
	}
	return off
}
