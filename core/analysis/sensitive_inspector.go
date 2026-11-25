package analysis

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type SensitiveFindingItem struct {
	ID            string `json:"id"`
	Kind          string `json:"kind"`
	Severity      string `json:"severity"`
	Title         string `json:"title"`
	Detail        string `json:"detail"`
	StructName    string `json:"structName"`
	FieldName     string `json:"fieldName"`
	File          string `json:"file"`
	RelFile       string `json:"relFile"`
	Line          int    `json:"line"`
	QuickFixTitle string `json:"quickFixTitle"`
}

type SensitiveDataReport struct {
	TotalFindings        int                    `json:"totalFindings"`
	TagLeakCount         int                    `json:"tagLeakCount"`
	StringerMissingCount int                    `json:"stringerMissingCount"`
	LogLeakCount         int                    `json:"logLeakCount"`
	Findings             []SensitiveFindingItem `json:"findings"`
	Summary              string                 `json:"summary"`
	Error                string                 `json:"error,omitempty"`
}

var sensitiveKeywords = []string{
	"password",
	"passwd",
	"secret",
	"token",
	"apikey",
	"api_key",
	"privatekey",
	"private_key",
	"accesskey",
	"access_key",
	"credential",
	"ssn",
	"creditcard",
	"clientsecret",
}

func isSensitiveIdentifier(name string) bool {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" || trimmed == "_" {
		return false
	}
	lower := strings.ToLower(trimmed)
	compact := strings.ReplaceAll(lower, "_", "")
	for _, kw := range sensitiveKeywords {
		if strings.Contains(lower, kw) || strings.Contains(compact, kw) {
			return true
		}
	}
	return false
}

func InspectSensitiveData(workspaceDir, filePath, content string, includeWorkspace bool) (SensitiveDataReport, error) {
	report := SensitiveDataReport{
		Findings: []SensitiveFindingItem{},
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
		targets = collectWorkspaceGoTargets(absWorkspace, absActiveFile, content, false)
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
			report.Summary = "No sensitive data exposure issues detected."
			return report, nil
		}
		targets = append(targets, loadedGoSourceTarget(targetPath, src))
	}

	type parsedTarget struct {
		path     string
		relFile  string
		dir      string
		fset     *token.FileSet
		file     *ast.File
		stringer []string
	}

	parsedFiles, firstParseErr := analyseGoSourceTargets(targets, parser.ParseComments, func(src parsedGoSource) parsedTarget {
		relFile := filepath.Base(src.path)
		if absWorkspace != "" {
			if rel, relErr := filepath.Rel(absWorkspace, src.path); relErr == nil && rel != "" && !strings.HasPrefix(rel, "..") {
				relFile = filepath.ToSlash(rel)
			}
		}
		return parsedTarget{
			path:     src.path,
			relFile:  relFile,
			dir:      filepath.Dir(src.path),
			fset:     src.fset,
			file:     src.file,
			stringer: collectStringerReceivers(src.file),
		}
	})

	stringerByDir := make(map[string]map[string]bool)
	for _, parsed := range parsedFiles {
		if stringerByDir[parsed.dir] == nil {
			stringerByDir[parsed.dir] = make(map[string]bool)
		}
		for _, structName := range parsed.stringer {
			stringerByDir[parsed.dir][structName] = true
		}
	}

	if len(parsedFiles) == 0 && firstParseErr != nil && !includeWorkspace {
		report.Error = firstParseErr.Error()
		report.Summary = "Failed to parse Go source file."
		return report, firstParseErr
	}

	var findings []SensitiveFindingItem

	for _, pf := range parsedFiles {
		fileFindings := inspectASTFileSensitiveData(pf.fset, pf.file, pf.path, pf.relFile, stringerByDir[pf.dir])
		findings = append(findings, fileFindings...)
	}

	sort.SliceStable(findings, func(i, j int) bool {
		if findings[i].RelFile != findings[j].RelFile {
			return findings[i].RelFile < findings[j].RelFile
		}
		if findings[i].Line != findings[j].Line {
			return findings[i].Line < findings[j].Line
		}
		return findings[i].Kind < findings[j].Kind
	})

	for _, f := range findings {
		switch f.Kind {
		case "sensitive_tag":
			report.TagLeakCount++
		case "sensitive_stringer":
			report.StringerMissingCount++
		case "sensitive_log":
			report.LogLeakCount++
		}
	}

	report.TotalFindings = len(findings)
	if findings != nil {
		report.Findings = findings
	}
	if report.TotalFindings == 0 {
		report.Summary = "No sensitive data exposure issues detected."
	} else {
		report.Summary = fmt.Sprintf(
			"%d sensitive data issue%s detected · %d tag leak%s, %d missing String(), %d log leak%s",
			report.TotalFindings,
			pluralSuffix(report.TotalFindings),
			report.TagLeakCount,
			pluralSuffix(report.TagLeakCount),
			report.StringerMissingCount,
			report.LogLeakCount,
			pluralSuffix(report.LogLeakCount),
		)
	}

	return report, nil
}

func collectStringerReceivers(file *ast.File) []string {
	var out []string
	if file == nil {
		return out
	}
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name == nil || fn.Name.Name != "String" {
			continue
		}
		if fn.Recv == nil || len(fn.Recv.List) == 0 {
			continue
		}
		if fn.Type.Params != nil && len(fn.Type.Params.List) > 0 {
			continue
		}
		if fn.Type.Results == nil || len(fn.Type.Results.List) != 1 {
			continue
		}
		resIdent, ok := fn.Type.Results.List[0].Type.(*ast.Ident)
		if !ok || resIdent.Name != "string" {
			continue
		}
		if !isSafeRedactedStringerFunc(fn) {
			continue
		}
		recvName := sensitiveReceiverBaseTypeName(fn.Recv.List[0].Type)
		if recvName != "" {
			out = append(out, recvName)
		}
	}
	return out
}

func isSafeRedactedStringerFunc(fn *ast.FuncDecl) bool {
	if fn == nil || fn.Body == nil {
		return false
	}
	var recvIdentName string
	if fn.Recv != nil && len(fn.Recv.List) > 0 && len(fn.Recv.List[0].Names) > 0 && fn.Recv.List[0].Names[0] != nil {
		recvIdentName = fn.Recv.List[0].Names[0].Name
	}
	leaksSensitiveField := false
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		if leaksSensitiveField || n == nil {
			return false
		}
		if sel, ok := n.(*ast.SelectorExpr); ok && sel.Sel != nil {
			if isSensitiveIdentifier(sel.Sel.Name) {
				if recvIdentName == "" {
					leaksSensitiveField = true
					return false
				}
				if xIdent, ok := sel.X.(*ast.Ident); ok && xIdent.Name == recvIdentName {
					leaksSensitiveField = true
					return false
				}
			}
		}
		return true
	})
	return !leaksSensitiveField
}

func sensitiveReceiverBaseTypeName(expr ast.Expr) string {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name
	case *ast.StarExpr:
		return sensitiveReceiverBaseTypeName(t.X)
	case *ast.IndexExpr:
		return sensitiveReceiverBaseTypeName(t.X)
	case *ast.IndexListExpr:
		return sensitiveReceiverBaseTypeName(t.X)
	default:
		return ""
	}
}

func inspectASTFileSensitiveData(
	fset *token.FileSet,
	file *ast.File,
	filePath string,
	relFile string,
	stringerStructs map[string]bool,
) []SensitiveFindingItem {
	var findings []SensitiveFindingItem

	for _, decl := range file.Decls {
		genDecl, ok := decl.(*ast.GenDecl)
		if !ok || genDecl.Tok != token.TYPE {
			continue
		}
		for _, spec := range genDecl.Specs {
			typeSpec, ok := spec.(*ast.TypeSpec)
			if !ok || typeSpec.Name == nil {
				continue
			}
			structType, ok := typeSpec.Type.(*ast.StructType)
			if !ok || structType.Fields == nil {
				continue
			}
			structName := typeSpec.Name.Name
			firstSensitiveField := ""

			for _, field := range structType.Fields.List {
				tagVal := ""
				if field.Tag != nil {
					tagVal = field.Tag.Value
				}
				hasRedactedJSONTag := hasJSONDashTag(tagVal)

				for _, ident := range field.Names {
					if ident == nil || !isSensitiveIdentifier(ident.Name) {
						continue
					}
					fieldName := ident.Name
					if firstSensitiveField == "" {
						firstSensitiveField = fieldName
					}
					fieldLine := fset.Position(ident.Pos()).Line
					if ast.IsExported(fieldName) && !hasRedactedJSONTag {
						findings = append(findings, SensitiveFindingItem{
							ID:            fmt.Sprintf("sensitive_tag:%s:%d:%s.%s", relFile, fieldLine, structName, fieldName),
							Kind:          "sensitive_tag",
							Severity:      "high",
							Title:         fmt.Sprintf("Sensitive field %s.%s is serialized without redaction", structName, fieldName),
							Detail:        fmt.Sprintf("Exported field '%s.%s' can be serialized into JSON payloads unless redacted with `json:\"-\"`.", structName, fieldName),
							StructName:    structName,
							FieldName:     fieldName,
							File:          filePath,
							RelFile:       relFile,
							Line:          fieldLine,
							QuickFixTitle: "Add json:\"-\" Tag",
						})
					}
				}
			}

			if firstSensitiveField != "" && !stringerStructs[structName] {
				structLine := fset.Position(typeSpec.Pos()).Line
				findings = append(findings, SensitiveFindingItem{
					ID:            fmt.Sprintf("sensitive_stringer:%s:%d:%s", relFile, structLine, structName),
					Kind:          "sensitive_stringer",
					Severity:      "warning",
					Title:         fmt.Sprintf("%s prints sensitive field %s because it has no redacting String method", structName, firstSensitiveField),
					Detail:        fmt.Sprintf("Formatting '%s' with %%v or fmt.Println may expose '%s' unless a custom String() method redacts it.", structName, firstSensitiveField),
					StructName:    structName,
					FieldName:     firstSensitiveField,
					File:          filePath,
					RelFile:       relFile,
					Line:          structLine,
					QuickFixTitle: "Generate redacted String() method",
				})
			}
		}
	}

	ast.Inspect(file, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		pkgName, funcName := loggingCallTarget(call)
		if pkgName == "" || funcName == "" {
			return true
		}

		args := call.Args
		if pkgName == "fmt" && strings.HasPrefix(funcName, "Fprint") && len(args) > 0 {
			args = args[1:]
		}

		for _, arg := range args {
			exprStr, matched := sensitiveLogArgumentExprWithStringers(fset, arg, stringerStructs)
			if !matched {
				continue
			}
			argLine := fset.Position(arg.Pos()).Line
			if argLine <= 0 {
				argLine = fset.Position(call.Pos()).Line
			}
			findings = append(findings, SensitiveFindingItem{
				ID:            fmt.Sprintf("sensitive_log:%s:%d:%s", relFile, argLine, exprStr),
				Kind:          "sensitive_log",
				Severity:      "high",
				Title:         fmt.Sprintf("Sensitive value %s is written to a log or output", exprStr),
				Detail:        fmt.Sprintf("Call to %s.%s logs sensitive expression '%s' in cleartext.", pkgName, funcName, exprStr),
				StructName:    "",
				FieldName:     exprStr,
				File:          filePath,
				RelFile:       relFile,
				Line:          argLine,
				QuickFixTitle: "Redact logged argument as \"[REDACTED]\"",
			})
		}
		return true
	})

	return findings
}

func hasJSONDashTag(rawTagLit string) bool {
	if rawTagLit == "" {
		return false
	}
	return strings.Contains(rawTagLit, `json:"-"`)
}

func loggingCallTarget(call *ast.CallExpr) (string, string) {
	if call == nil {
		return "", ""
	}
	sel, ok := call.Fun.(*ast.SelectorExpr)
	if !ok || sel.Sel == nil {
		return "", ""
	}
	pkgIdent, ok := sel.X.(*ast.Ident)
	if !ok {
		return "", ""
	}
	pkg := pkgIdent.Name
	fn := sel.Sel.Name

	switch pkg {
	case "fmt":
		if strings.HasPrefix(fn, "Print") || strings.HasPrefix(fn, "Sprint") || strings.HasPrefix(fn, "Fprint") {
			return pkg, fn
		}
	case "log":
		if strings.HasPrefix(fn, "Print") || strings.HasPrefix(fn, "Fatal") {
			return pkg, fn
		}
	case "slog":
		if strings.HasPrefix(fn, "Info") || strings.HasPrefix(fn, "Debug") || strings.HasPrefix(fn, "Warn") || strings.HasPrefix(fn, "Error") {
			return pkg, fn
		}
	}
	return "", ""
}

func sensitiveLogArgumentExpr(fset *token.FileSet, arg ast.Expr) (string, bool) {
	return sensitiveLogArgumentExprWithStringers(fset, arg, nil)
}

func sensitiveLogArgumentExprWithStringers(fset *token.FileSet, arg ast.Expr, safeStringers map[string]bool) (string, bool) {
	if arg == nil {
		return "", false
	}
	switch expr := arg.(type) {
	case *ast.Ident:
		if isSensitiveIdentifier(expr.Name) {
			return expr.Name, true
		}
	case *ast.SelectorExpr:
		if expr.Sel != nil && isSensitiveIdentifier(expr.Sel.Name) {
			return exprToString(fset, expr), true
		}
	case *ast.UnaryExpr:
		if expr.Op == token.AND {
			if _, ok := sensitiveLogArgumentExprWithStringers(fset, expr.X, safeStringers); ok {
				return exprToString(fset, expr), true
			}
		}
	case *ast.CompositeLit:
		typeName := sensitiveReceiverBaseTypeName(expr.Type)
		if typeName != "" && safeStringers != nil && safeStringers[typeName] {
			return "", false
		}
		for _, elt := range expr.Elts {
			kv, ok := elt.(*ast.KeyValueExpr)
			if !ok {
				continue
			}
			switch k := kv.Key.(type) {
			case *ast.Ident:
				if isSensitiveIdentifier(k.Name) {
					return exprToString(fset, expr), true
				}
			case *ast.BasicLit:
				trimmedKey := strings.Trim(k.Value, "\"'`")
				if isSensitiveIdentifier(trimmedKey) {
					return exprToString(fset, expr), true
				}
			}
		}
	}
	return "", false
}

var jsonTagPattern = regexp.MustCompile(`json:"[^"]*"`)

func FixSensitiveDataIssue(filePath, content string, line int, kind, targetName string) (string, error) {
	if content == "" && filePath != "" {
		data, err := os.ReadFile(filePath)
		if err != nil {
			return "", err
		}
		content = string(data)
	}
	if strings.TrimSpace(content) == "" {
		return content, fmt.Errorf("empty Go source content")
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, filePath, content, parser.ParseComments)
	if err != nil && astFile == nil {
		return content, err
	}

	lines := strings.Split(content, "\n")

	switch kind {
	case "sensitive_tag":
		return applySensitiveTagFix(fset, astFile, lines, content, line, targetName)
	case "sensitive_stringer":
		return applySensitiveStringerFix(fset, astFile, lines, content, line, targetName)
	case "sensitive_log":
		return applySensitiveLogFix(fset, astFile, lines, content, line, targetName)
	default:
		return content, fmt.Errorf("unsupported sensitive data fix kind %q", kind)
	}
}

func applySensitiveTagFix(
	fset *token.FileSet,
	file *ast.File,
	_ []string,
	content string,
	line int,
	targetName string,
) (string, error) {
	targetField := strings.TrimSpace(targetName)
	if dot := strings.LastIndex(targetField, "."); dot >= 0 {
		targetField = targetField[dot+1:]
	}
	if file == nil {
		return content, fmt.Errorf("source does not parse")
	}

	var target *ast.Field
	ast.Inspect(file, func(n ast.Node) bool {
		if target != nil {
			return false
		}
		st, ok := n.(*ast.StructType)
		if !ok || st.Fields == nil {
			return true
		}
		for _, field := range st.Fields.List {
			for _, ident := range field.Names {
				if fset.Position(ident.Pos()).Line != line {
					continue
				}
				if targetField == "" || ident.Name == targetField {
					target = field
					return false
				}
			}
		}
		return true
	})
	if target == nil {
		return content, fmt.Errorf("no struct field %q on line %d", targetField, line)
	}

	if target.Tag == nil {
		insertAt := fset.Position(target.Type.End()).Offset
		if insertAt < 0 || insertAt > len(content) {
			return content, fmt.Errorf("invalid field span on line %d", line)
		}
		return content[:insertAt] + " `json:\"-\"`" + content[insertAt:], nil
	}

	tagInner, err := strconv.Unquote(target.Tag.Value)
	if err != nil {
		return content, err
	}
	var newTagInner string
	switch {
	case jsonTagPattern.MatchString(tagInner):
		newTagInner = jsonTagPattern.ReplaceAllString(tagInner, `json:"-"`)
	case strings.TrimSpace(tagInner) == "":
		newTagInner = `json:"-"`
	default:
		newTagInner = `json:"-" ` + strings.TrimSpace(tagInner)
	}
	newTag := strconv.Quote(newTagInner)
	if !strings.Contains(newTagInner, "`") {
		newTag = "`" + newTagInner + "`"
	}
	start := fset.Position(target.Tag.Pos()).Offset
	end := fset.Position(target.Tag.End()).Offset
	if start < 0 || end < start || end > len(content) {
		return content, fmt.Errorf("invalid tag span on line %d", line)
	}
	return content[:start] + newTag + content[end:], nil
}

func findLineCommentOutsideTicks(s string) int {
	inTick := false
	inQuote := false
	escaped := false
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if escaped {
			escaped = false
			continue
		}
		if inQuote {
			if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				inQuote = false
			}
			continue
		}
		if ch == '`' {
			inTick = !inTick
			continue
		}
		if !inTick {
			if ch == '"' {
				inQuote = true
				continue
			}
			if ch == '/' && i+1 < len(s) && s[i+1] == '/' {
				return i
			}
		}
	}
	return -1
}

func applySensitiveStringerFix(
	fset *token.FileSet,
	file *ast.File,
	lines []string,
	content string,
	line int,
	targetName string,
) (string, error) {
	if file == nil {
		return content, fmt.Errorf("failed to parse Go file for String() generation")
	}

	desiredStruct := strings.TrimSpace(targetName)
	if dot := strings.Index(desiredStruct, "."); dot > 0 {
		desiredStruct = desiredStruct[:dot]
	}

	var matchedSpec *ast.TypeSpec
	var matchedGenDecl *ast.GenDecl

	for _, decl := range file.Decls {
		genDecl, ok := decl.(*ast.GenDecl)
		if !ok || genDecl.Tok != token.TYPE {
			continue
		}
		for _, spec := range genDecl.Specs {
			ts, ok := spec.(*ast.TypeSpec)
			if !ok || ts.Name == nil {
				continue
			}
			if _, isStruct := ts.Type.(*ast.StructType); !isStruct {
				continue
			}
			startLine := fset.Position(ts.Pos()).Line
			endLine := fset.Position(ts.End()).Line
			if desiredStruct != "" && ts.Name.Name == desiredStruct {
				matchedSpec = ts
				matchedGenDecl = genDecl
				break
			}
			if line >= startLine && line <= endLine {
				matchedSpec = ts
				matchedGenDecl = genDecl
				break
			}
		}
		if matchedSpec != nil {
			break
		}
	}

	if matchedSpec == nil {
		return content, fmt.Errorf("could not locate struct declaration at line %d", line)
	}

	structName := matchedSpec.Name.Name
	existingReceivers := collectStringerReceivers(file)
	for _, r := range existingReceivers {
		if r == structName {
			return content, nil
		}
	}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name == nil || fn.Name.Name != "String" || fn.Recv == nil || len(fn.Recv.List) == 0 {
			continue
		}
		if sensitiveReceiverBaseTypeName(fn.Recv.List[0].Type) == structName {
			startOff := fset.Position(fn.Pos()).Offset
			endOff := fset.Position(fn.End()).Offset
			if startOff >= 0 && endOff > startOff && endOff <= len(content) {
				replacement := fmt.Sprintf("func (s %s) String() string {\n\treturn \"%s{[REDACTED]}\"\n}", structName, structName)
				return content[:startOff] + replacement + content[endOff:], nil
			}
		}
	}

	endLine := fset.Position(matchedSpec.End()).Line
	if matchedGenDecl != nil && len(matchedGenDecl.Specs) > 1 {
		endLine = fset.Position(matchedGenDecl.End()).Line
	}
	if endLine < 1 || endLine > len(lines) {
		endLine = len(lines)
	}

	methodBlock := fmt.Sprintf("\nfunc (s %s) String() string {\n\treturn \"%s{[REDACTED]}\"\n}", structName, structName)

	newLines := make([]string, 0, len(lines)+4)
	newLines = append(newLines, lines[:endLine]...)
	newLines = append(newLines, methodBlock)
	newLines = append(newLines, lines[endLine:]...)
	return strings.Join(newLines, "\n"), nil
}

func applySensitiveLogFix(
	fset *token.FileSet,
	file *ast.File,
	lines []string,
	content string,
	line int,
	targetName string,
) (string, error) {
	if line < 1 || line > len(lines) {
		return content, fmt.Errorf("line %d out of range", line)
	}

	trimmedTarget := strings.TrimSpace(targetName)

	if file != nil {
		type replacementSpan struct {
			start int
			end   int
			expr  string
		}
		var spans []replacementSpan

		ast.Inspect(file, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			pkgName, funcName := loggingCallTarget(call)
			if pkgName == "" || funcName == "" {
				return true
			}
			callStartLine := fset.Position(call.Pos()).Line
			callEndLine := fset.Position(call.End()).Line
			if line < callStartLine || line > callEndLine {
				return true
			}

			args := call.Args
			if pkgName == "fmt" && strings.HasPrefix(funcName, "Fprint") && len(args) > 0 {
				args = args[1:]
			}

			for _, arg := range args {
				exprStr, matched := sensitiveLogArgumentExpr(fset, arg)
				if !matched {
					continue
				}
				argLine := fset.Position(arg.Pos()).Line
				if argLine != line && callStartLine != line {
					continue
				}
				if trimmedTarget != "" && exprStr != trimmedTarget && !strings.HasSuffix(exprStr, "."+trimmedTarget) {
					continue
				}
				startOffset := fset.Position(arg.Pos()).Offset
				endOffset := fset.Position(arg.End()).Offset
				if startOffset >= 0 && endOffset > startOffset && endOffset <= len(content) {
					spans = append(spans, replacementSpan{
						start: startOffset,
						end:   endOffset,
						expr:  exprStr,
					})
				}
			}
			return true
		})

		if len(spans) > 0 {
			sort.Slice(spans, func(i, j int) bool {
				return spans[i].start > spans[j].start
			})
			var buf bytes.Buffer
			updated := content
			for _, sp := range spans {
				buf.Reset()
				buf.WriteString(updated[:sp.start])
				buf.WriteString(`"[REDACTED]"`)
				buf.WriteString(updated[sp.end:])
				updated = buf.String()
			}
			return updated, nil
		}
	}

	if trimmedTarget != "" && strings.Contains(lines[line-1], trimmedTarget) {
		lines[line-1] = strings.Replace(lines[line-1], trimmedTarget, `"[REDACTED]"`, 1)
		return strings.Join(lines, "\n"), nil
	}

	return content, fmt.Errorf("no sensitive logging argument found on line %d", line)
}
