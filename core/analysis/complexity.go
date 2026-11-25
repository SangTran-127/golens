package analysis

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type FunctionComplexityItem struct {
	Name        string   `json:"name"`
	PackageName string   `json:"packageName"`
	File        string   `json:"file"`
	RelFile     string   `json:"relFile"`
	Line        int      `json:"line"`
	EndLine     int      `json:"endLine"`
	LineCount   int      `json:"lineCount"`
	ParamCount  int      `json:"paramCount"`
	ReturnCount int      `json:"returnCount"`
	Cyclomatic  int      `json:"cyclomatic"`
	Cognitive   int      `json:"cognitive"`
	MaxNesting  int      `json:"maxNesting"`
	Rating      string   `json:"rating"`
	Drivers     []string `json:"drivers"`
	Suggestion  string   `json:"suggestion"`
}

type ComplexityReport struct {
	TotalFunctions    int                      `json:"totalFunctions"`
	HighCount         int                      `json:"highCount"`
	ModerateCount     int                      `json:"moderateCount"`
	GoodCount         int                      `json:"goodCount"`
	MaxCognitive      int                      `json:"maxCognitive"`
	AverageCyclomatic float64                  `json:"averageCyclomatic"`
	Functions         []FunctionComplexityItem `json:"functions"`
	Summary           string                   `json:"summary"`
	Error             string                   `json:"error,omitempty"`
}

func InspectFunctionComplexity(workspaceDir, filePath, content string, includeWorkspace bool) (ComplexityReport, error) {
	report := ComplexityReport{
		Functions: []FunctionComplexityItem{},
	}

	workspaceDir = strings.TrimSpace(workspaceDir)
	filePath = strings.TrimSpace(filePath)

	var absWorkspace string
	if workspaceDir != "" {
		if abs, err := filepath.Abs(workspaceDir); err == nil {
			absWorkspace = abs
		} else {
			absWorkspace = workspaceDir
		}
	}

	var absActiveFile string
	if filePath != "" {
		if abs, err := filepath.Abs(filePath); err == nil {
			absActiveFile = abs
		} else {
			absActiveFile = filePath
		}
	}

	var targets []goSourceTarget

	if includeWorkspace && absWorkspace != "" {
		targets = collectWorkspaceGoTargets(absWorkspace, absActiveFile, content, true)
	} else {
		var src []byte
		targetPath := absActiveFile
		if content != "" {
			src = []byte(content)
			if targetPath == "" {
				targetPath = "input.go"
			}
		} else if targetPath != "" {
			data, err := os.ReadFile(targetPath)
			if err != nil {
				report.Error = err.Error()
				report.Summary = "Unable to read Go source file."
				return report, err
			}
			src = data
		} else {
			report.Summary = "No Go functions found in current scope."
			return report, nil
		}
		targets = append(targets, loadedGoSourceTarget(targetPath, src))
	}

	perFile, firstParseErr := analyseGoSourceTargets(targets, parser.SkipObjectResolution, func(src parsedGoSource) []FunctionComplexityItem {
		pkgName := ""
		if src.file.Name != nil {
			pkgName = src.file.Name.Name
		}

		relFile := filepath.Base(src.path)
		if absWorkspace != "" {
			if rel, relErr := filepath.Rel(absWorkspace, src.path); relErr == nil && rel != "" && !strings.HasPrefix(rel, "..") {
				relFile = filepath.ToSlash(rel)
			}
		}

		var fileItems []FunctionComplexityItem
		for _, decl := range src.file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			fileItems = append(fileItems, analyzeFuncDecl(src.fset, fn, pkgName, src.path, relFile))
		}
		return fileItems
	})
	items := flattenGoSourceResults(perFile)

	if len(items) == 0 && firstParseErr != nil && !includeWorkspace {
		report.Error = firstParseErr.Error()
		report.Summary = "Failed to parse Go source file."
		return report, firstParseErr
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].Cognitive != items[j].Cognitive {
			return items[i].Cognitive > items[j].Cognitive
		}
		if items[i].Cyclomatic != items[j].Cyclomatic {
			return items[i].Cyclomatic > items[j].Cyclomatic
		}
		if items[i].LineCount != items[j].LineCount {
			return items[i].LineCount > items[j].LineCount
		}
		if items[i].RelFile != items[j].RelFile {
			return items[i].RelFile < items[j].RelFile
		}
		return items[i].Line < items[j].Line
	})

	totalCyclo := 0
	for _, item := range items {
		totalCyclo += item.Cyclomatic
		if item.Cognitive > report.MaxCognitive {
			report.MaxCognitive = item.Cognitive
		}
		switch item.Rating {
		case "high":
			report.HighCount++
		case "moderate":
			report.ModerateCount++
		default:
			report.GoodCount++
		}
	}

	report.TotalFunctions = len(items)
	if len(items) > 0 {
		avg := float64(totalCyclo) / float64(len(items))
		report.AverageCyclomatic = math.Round(avg*10) / 10
		report.Functions = items
		report.Summary = fmt.Sprintf(
			"%d function%s analyzed · %d high, %d moderate, %d good · avg cyclomatic %.1f · max cognitive %d",
			report.TotalFunctions,
			pluralSuffix(report.TotalFunctions),
			report.HighCount,
			report.ModerateCount,
			report.GoodCount,
			report.AverageCyclomatic,
			report.MaxCognitive,
		)
	} else {
		report.Summary = "No Go functions found in current scope."
	}

	return report, nil
}

func analyzeFuncDecl(fset *token.FileSet, fn *ast.FuncDecl, pkgName, filePath, relFile string) FunctionComplexityItem {
	startPos := fset.Position(fn.Pos())
	endPos := fset.Position(fn.End())
	line := startPos.Line
	endLine := endPos.Line
	if endLine < line {
		endLine = line
	}
	lineCount := endLine - line + 1

	paramCount := countFieldList(fn.Type.Params)
	returnCount := countFieldList(fn.Type.Results)
	funcName := formatFuncName(fset, fn)

	metrics := computeComplexityMetrics(fn.Body)

	rating := "good"
	if metrics.cognitive > 20 || metrics.cyclomatic > 20 {
		rating = "high"
	} else if metrics.cognitive >= 11 || metrics.cyclomatic >= 11 {
		rating = "moderate"
	}

	drivers := buildDrivers(metrics, lineCount)
	suggestion := buildSuggestion(rating, metrics, lineCount)

	return FunctionComplexityItem{
		Name:        funcName,
		PackageName: pkgName,
		File:        filePath,
		RelFile:     relFile,
		Line:        line,
		EndLine:     endLine,
		LineCount:   lineCount,
		ParamCount:  paramCount,
		ReturnCount: returnCount,
		Cyclomatic:  metrics.cyclomatic,
		Cognitive:   metrics.cognitive,
		MaxNesting:  metrics.maxNesting,
		Rating:      rating,
		Drivers:     drivers,
		Suggestion:  suggestion,
	}
}

type complexityMetrics struct {
	cyclomatic    int
	cognitive     int
	maxNesting    int
	ifBranches    int
	loopCount     int
	nestedLoops   int
	switchCount   int
	caseBranches  int
	logicalOps    int
	labeledJumps  int
}

func computeComplexityMetrics(body *ast.BlockStmt) complexityMetrics {
	m := complexityMetrics{
		cyclomatic: 1,
	}
	if body == nil {
		return m
	}

	elseIfSet := make(map[*ast.IfStmt]bool)

	var walkExpr func(expr ast.Expr, nesting int, parentOp token.Token)
	var walkNode func(node ast.Node, nesting int, loopDepth int)

	walkExpr = func(expr ast.Expr, nesting int, parentOp token.Token) {
		if expr == nil {
			return
		}
		switch e := expr.(type) {
		case *ast.ParenExpr:
			walkExpr(e.X, nesting, parentOp)
		case *ast.BinaryExpr:
			if e.Op == token.LAND || e.Op == token.LOR {
				m.cyclomatic++
				m.logicalOps++
				if parentOp != e.Op {
					m.cognitive++
				}
				walkExpr(e.X, nesting, e.Op)
				walkExpr(e.Y, nesting, e.Op)
				return
			}
			walkExpr(e.X, nesting, token.ILLEGAL)
			walkExpr(e.Y, nesting, token.ILLEGAL)
		case *ast.UnaryExpr:
			walkExpr(e.X, nesting, token.ILLEGAL)
		case *ast.CallExpr:
			walkExpr(e.Fun, nesting, token.ILLEGAL)
			for _, arg := range e.Args {
				walkExpr(arg, nesting, token.ILLEGAL)
			}
		case *ast.FuncLit:
			if e.Body != nil {
				nextNest := nesting + 1
				if nextNest > m.maxNesting {
					m.maxNesting = nextNest
				}
				for _, stmt := range e.Body.List {
					walkNode(stmt, nextNest, 0)
				}
			}
		case *ast.CompositeLit:
			for _, elt := range e.Elts {
				walkExpr(elt, nesting, token.ILLEGAL)
			}
		case *ast.KeyValueExpr:
			walkExpr(e.Key, nesting, token.ILLEGAL)
			walkExpr(e.Value, nesting, token.ILLEGAL)
		case *ast.IndexExpr:
			walkExpr(e.X, nesting, token.ILLEGAL)
			walkExpr(e.Index, nesting, token.ILLEGAL)
		case *ast.SliceExpr:
			walkExpr(e.X, nesting, token.ILLEGAL)
			walkExpr(e.Low, nesting, token.ILLEGAL)
			walkExpr(e.High, nesting, token.ILLEGAL)
			walkExpr(e.Max, nesting, token.ILLEGAL)
		case *ast.SelectorExpr:
			walkExpr(e.X, nesting, token.ILLEGAL)
		case *ast.StarExpr:
			walkExpr(e.X, nesting, token.ILLEGAL)
		case *ast.TypeAssertExpr:
			walkExpr(e.X, nesting, token.ILLEGAL)
		}
	}

	walkNode = func(node ast.Node, nesting int, loopDepth int) {
		if node == nil {
			return
		}
		switch n := node.(type) {
		case *ast.BlockStmt:
			for _, stmt := range n.List {
				walkNode(stmt, nesting, loopDepth)
			}
		case *ast.IfStmt:
			m.cyclomatic++
			m.ifBranches++
			isElseIf := elseIfSet[n]
			if isElseIf {
				m.cognitive += 1
			} else {
				m.cognitive += 1 + nesting
			}
			if n.Init != nil {
				walkNode(n.Init, nesting, loopDepth)
			}
			walkExpr(n.Cond, nesting, token.ILLEGAL)

			innerNest := nesting + 1
			if innerNest > m.maxNesting {
				m.maxNesting = innerNest
			}
			if n.Body != nil {
				walkNode(n.Body, innerNest, loopDepth)
			}
			if n.Else != nil {
				if nextIf, ok := n.Else.(*ast.IfStmt); ok {
					elseIfSet[nextIf] = true
					walkNode(nextIf, nesting, loopDepth)
				} else {
					walkNode(n.Else, innerNest, loopDepth)
				}
			}
		case *ast.ForStmt:
			m.cyclomatic++
			m.loopCount++
			if loopDepth > 0 {
				m.nestedLoops++
			}
			m.cognitive += 1 + nesting
			if n.Init != nil {
				walkNode(n.Init, nesting, loopDepth)
			}
			walkExpr(n.Cond, nesting, token.ILLEGAL)
			if n.Post != nil {
				walkNode(n.Post, nesting, loopDepth)
			}
			innerNest := nesting + 1
			if innerNest > m.maxNesting {
				m.maxNesting = innerNest
			}
			if n.Body != nil {
				walkNode(n.Body, innerNest, loopDepth+1)
			}
		case *ast.RangeStmt:
			m.cyclomatic++
			m.loopCount++
			if loopDepth > 0 {
				m.nestedLoops++
			}
			m.cognitive += 1 + nesting
			walkExpr(n.Key, nesting, token.ILLEGAL)
			walkExpr(n.Value, nesting, token.ILLEGAL)
			walkExpr(n.X, nesting, token.ILLEGAL)
			innerNest := nesting + 1
			if innerNest > m.maxNesting {
				m.maxNesting = innerNest
			}
			if n.Body != nil {
				walkNode(n.Body, innerNest, loopDepth+1)
			}
		case *ast.SwitchStmt:
			m.switchCount++
			m.cognitive += 1 + nesting
			if n.Init != nil {
				walkNode(n.Init, nesting, loopDepth)
			}
			walkExpr(n.Tag, nesting, token.ILLEGAL)
			innerNest := nesting + 1
			if innerNest > m.maxNesting {
				m.maxNesting = innerNest
			}
			if n.Body != nil {
				for _, stmt := range n.Body.List {
					if cc, ok := stmt.(*ast.CaseClause); ok {
						if cc.List != nil {
							m.cyclomatic++
							m.caseBranches++
						}
						for _, expr := range cc.List {
							walkExpr(expr, innerNest, token.ILLEGAL)
						}
						for _, bodyStmt := range cc.Body {
							walkNode(bodyStmt, innerNest, loopDepth)
						}
					}
				}
			}
		case *ast.TypeSwitchStmt:
			m.switchCount++
			m.cognitive += 1 + nesting
			if n.Init != nil {
				walkNode(n.Init, nesting, loopDepth)
			}
			if n.Assign != nil {
				walkNode(n.Assign, nesting, loopDepth)
			}
			innerNest := nesting + 1
			if innerNest > m.maxNesting {
				m.maxNesting = innerNest
			}
			if n.Body != nil {
				for _, stmt := range n.Body.List {
					if cc, ok := stmt.(*ast.CaseClause); ok {
						if cc.List != nil {
							m.cyclomatic++
							m.caseBranches++
						}
						for _, bodyStmt := range cc.Body {
							walkNode(bodyStmt, innerNest, loopDepth)
						}
					}
				}
			}
		case *ast.SelectStmt:
			m.switchCount++
			m.cognitive += 1 + nesting
			innerNest := nesting + 1
			if innerNest > m.maxNesting {
				m.maxNesting = innerNest
			}
			if n.Body != nil {
				for _, stmt := range n.Body.List {
					if cc, ok := stmt.(*ast.CommClause); ok {
						if cc.Comm != nil {
							m.cyclomatic++
							m.caseBranches++
							walkNode(cc.Comm, innerNest, loopDepth)
						}
						for _, bodyStmt := range cc.Body {
							walkNode(bodyStmt, innerNest, loopDepth)
						}
					}
				}
			}
		case *ast.BranchStmt:
			if n.Tok == token.GOTO || ((n.Tok == token.BREAK || n.Tok == token.CONTINUE) && n.Label != nil) {
				m.cognitive++
				m.labeledJumps++
			}
		case *ast.AssignStmt:
			for _, lhs := range n.Lhs {
				walkExpr(lhs, nesting, token.ILLEGAL)
			}
			for _, rhs := range n.Rhs {
				walkExpr(rhs, nesting, token.ILLEGAL)
			}
		case *ast.ReturnStmt:
			for _, res := range n.Results {
				walkExpr(res, nesting, token.ILLEGAL)
			}
		case *ast.ExprStmt:
			walkExpr(n.X, nesting, token.ILLEGAL)
		case *ast.DeferStmt:
			walkExpr(n.Call, nesting, token.ILLEGAL)
		case *ast.GoStmt:
			walkExpr(n.Call, nesting, token.ILLEGAL)
		case *ast.SendStmt:
			walkExpr(n.Chan, nesting, token.ILLEGAL)
			walkExpr(n.Value, nesting, token.ILLEGAL)
		case *ast.IncDecStmt:
			walkExpr(n.X, nesting, token.ILLEGAL)
		case *ast.LabeledStmt:
			walkNode(n.Stmt, nesting, loopDepth)
		case *ast.DeclStmt:
			if gd, ok := n.Decl.(*ast.GenDecl); ok {
				for _, spec := range gd.Specs {
					if vs, ok := spec.(*ast.ValueSpec); ok {
						for _, val := range vs.Values {
							walkExpr(val, nesting, token.ILLEGAL)
						}
					}
				}
			}
		}
	}

	walkNode(body, 0, 0)
	return m
}

func buildDrivers(m complexityMetrics, lineCount int) []string {
	var drivers []string
	if m.nestedLoops > 0 {
		drivers = append(drivers, fmt.Sprintf("%d nested loop%s", m.loopCount, pluralSuffix(m.loopCount)))
	} else if m.loopCount > 0 {
		drivers = append(drivers, fmt.Sprintf("%d loop%s", m.loopCount, pluralSuffix(m.loopCount)))
	}
	if m.ifBranches > 0 {
		if m.ifBranches == 1 {
			drivers = append(drivers, "1 if/else branch")
		} else {
			drivers = append(drivers, fmt.Sprintf("%d if/else branches", m.ifBranches))
		}
	}
	if m.switchCount > 0 {
		drivers = append(drivers, fmt.Sprintf("%d switch/select (%d cases)", m.switchCount, m.caseBranches))
	}
	if m.logicalOps > 0 {
		drivers = append(drivers, fmt.Sprintf("%d boolean op%s", m.logicalOps, pluralSuffix(m.logicalOps)))
	}
	if m.maxNesting >= 3 {
		drivers = append(drivers, fmt.Sprintf("nesting depth %d", m.maxNesting))
	}
	if lineCount == 1 {
		drivers = append(drivers, "1 line")
	} else {
		drivers = append(drivers, fmt.Sprintf("%d lines", lineCount))
	}
	return drivers
}

func buildSuggestion(rating string, m complexityMetrics, _ int) string {
	switch rating {
	case "high":
		if m.nestedLoops > 0 || m.maxNesting >= 3 {
			return "Consider extracting inner loop or deeply nested branch with Extract Function (⌥⌘M) and applying early-return guard clauses"
		}
		return "Consider decomposing branching logic into focused helpers with Extract Function (⌥⌘M)"
	case "moderate":
		return "Consider extracting inner loop or branch with Extract Function (⌥⌘M)"
	default:
		return "Clean, maintainable control flow"
	}
}

func formatFuncName(fset *token.FileSet, fn *ast.FuncDecl) string {
	if fn == nil || fn.Name == nil {
		return ""
	}
	if fn.Recv == nil || len(fn.Recv.List) == 0 {
		return fn.Name.Name
	}
	recvType := fn.Recv.List[0].Type
	if star, ok := recvType.(*ast.StarExpr); ok {
		return fmt.Sprintf("(*%s).%s", exprToString(fset, star.X), fn.Name.Name)
	}
	return fmt.Sprintf("%s.%s", exprToString(fset, recvType), fn.Name.Name)
}

func exprToString(fset *token.FileSet, expr ast.Expr) string {
	if expr == nil {
		return ""
	}
	var buf bytes.Buffer
	if err := printer.Fprint(&buf, fset, expr); err != nil {
		return ""
	}
	return buf.String()
}

func countFieldList(fl *ast.FieldList) int {
	if fl == nil {
		return 0
	}
	count := 0
	for _, field := range fl.List {
		if len(field.Names) > 0 {
			count += len(field.Names)
		} else {
			count++
		}
	}
	return count
}

func pluralSuffix(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
