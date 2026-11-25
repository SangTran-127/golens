package goast

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func generateMoveSymbol(
	req GenerateCodeRequest,
	fset *token.FileSet,
	tf *token.File,
	src []byte,
	file *ast.File,
	pos token.Pos,
	readSource func(string) ([]byte, error),
) string {
	targetFile := strings.TrimSpace(req.TargetName)
	if targetFile == "" {
		return marshalError("missing target file name")
	}
	if !strings.HasSuffix(targetFile, ".go") {
		targetFile += ".go"
	}

	var destPath string
	if filepath.IsAbs(targetFile) {
		destPath = filepath.Clean(targetFile)
	} else {
		destPath = filepath.Join(filepath.Dir(req.Path), targetFile)
	}
	if destPath == filepath.Clean(req.Path) {
		return marshalError("destination file is the same as source file")
	}

	var matchedDecl ast.Decl
	var declStart, declEnd token.Pos
	cursorLine := fset.Position(pos).Line

	for _, decl := range file.Decls {
		switch d := decl.(type) {
		case *ast.FuncDecl:
			sPos := declStartPos(d.Doc, d.Pos())
			ePos := d.End()
			if (pos >= sPos && pos <= ePos) ||
				(cursorLine >= fset.Position(sPos).Line && cursorLine <= fset.Position(ePos).Line) {
				matchedDecl = d
				declStart = sPos
				declEnd = ePos
			}
		case *ast.GenDecl:
			if d.Tok == token.IMPORT {
				continue
			}
			sPos := declStartPos(d.Doc, d.Pos())
			ePos := d.End()
			if (pos >= sPos && pos <= ePos) ||
				(cursorLine >= fset.Position(sPos).Line && cursorLine <= fset.Position(ePos).Line) {
				matchedDecl = d
				declStart = sPos
				declEnd = ePos
			}
		}
		if matchedDecl != nil {
			break
		}
	}

	if matchedDecl == nil {
		return marshalError("no top-level symbol found at cursor")
	}

	startOff := fset.Position(declStart).Offset
	endOff := fset.Position(declEnd).Offset
	if startOff < 0 || endOff < startOff || endOff > len(src) {
		return marshalError("invalid symbol span")
	}

	declText := strings.TrimSpace(string(src[startOff:endOff]))

	removeStart := startOff
	for removeStart > 0 && (src[removeStart-1] == ' ' || src[removeStart-1] == '\t') {
		removeStart--
	}
	removeEnd := endOff
	newlinesConsumed := 0
	for removeEnd < len(src) && newlinesConsumed < 2 {
		if src[removeEnd] == '\r' {
			removeEnd++
			continue
		}
		if src[removeEnd] == '\n' {
			removeEnd++
			newlinesConsumed++
			continue
		}
		break
	}
	if newlinesConsumed == 0 && removeStart > 0 && src[removeStart-1] == '\n' {
		removeStart--
		if removeStart > 0 && src[removeStart-1] == '\r' {
			removeStart--
		}
	}

	removeEdit := SigTextEdit{
		Range:   lspRange(fset, src, tf.Pos(removeStart), tf.Pos(removeEnd)),
		NewText: "",
	}

	pkgName := "main"
	if file.Name != nil && file.Name.Name != "" {
		pkgName = file.Name.Name
	}

	editsByPath := map[string][]SigTextEdit{req.Path: {removeEdit}}
	if destSrc, err := readSource(destPath); err == nil {
		destFset := token.NewFileSet()
		destTf := destFset.AddFile(destPath, -1, len(destSrc))
		destTf.SetLinesForContent(destSrc)
		destEndPos := destTf.Pos(len(destSrc))

		var insertText string
		if len(strings.TrimSpace(string(destSrc))) == 0 {
			insertText = fmt.Sprintf("package %s\n\n%s\n", pkgName, declText)
		} else if strings.HasSuffix(string(destSrc), "\n\n") {
			insertText = declText + "\n"
		} else if strings.HasSuffix(string(destSrc), "\n") {
			insertText = "\n" + declText + "\n"
		} else {
			insertText = "\n\n" + declText + "\n"
		}
		editsByPath[destPath] = []SigTextEdit{{
			Range:   lspRange(destFset, destSrc, destEndPos, destEndPos),
			NewText: insertText,
		}}
	} else {
		rawNewFile := fmt.Sprintf("package %s\n\n%s\n", pkgName, declText)
		formatted, fmtErr := format.Source([]byte(rawNewFile))
		if fmtErr != nil {
			formatted = []byte(rawNewFile)
		}
		if err := os.WriteFile(destPath, formatted, 0o644); err != nil {
			return marshalError(fmt.Sprintf("could not create %s: %v", filepath.Base(destPath), err))
		}
	}

	resp := GenerateCodeResponse{
		EditsByPath: editsByPath,
		TargetPath:  destPath,
	}
	b, _ := json.Marshal(resp)
	return string(b)
}

func resolveGoastModuleRoot(filePath, wsDir string) (string, string) {
	candidates := []string{}
	if filePath != "" {
		candidates = append(candidates, filepath.Dir(filePath))
	}
	if wsDir != "" {
		candidates = append(candidates, wsDir)
	}
	for _, start := range candidates {
		dir := filepath.Clean(start)
		for dir != "" && dir != "/" && dir != "." {
			modFile := filepath.Join(dir, "go.mod")
			if data, err := os.ReadFile(modFile); err == nil {
				for _, line := range strings.Split(string(data), "\n") {
					trim := strings.TrimSpace(line)
					if strings.HasPrefix(trim, "module ") {
						modName := strings.TrimSpace(strings.TrimPrefix(trim, "module "))
						modName = strings.Trim(modName, `"`)
						if modName != "" {
							return dir, modName
						}
					}
				}
			}
			next := filepath.Dir(dir)
			if next == dir {
				break
			}
			dir = next
		}
	}
	return "", ""
}

func computeGoastImportPath(dir, modRoot, modPath string) string {
	if modRoot == "" || modPath == "" || dir == "" {
		return ""
	}
	absDir, err1 := filepath.Abs(dir)
	absRoot, err2 := filepath.Abs(modRoot)
	if err1 != nil || err2 != nil {
		return ""
	}
	rel, err := filepath.Rel(absRoot, absDir)
	if err != nil || strings.HasPrefix(rel, "..") {
		return ""
	}
	if rel == "." {
		return modPath
	}
	return modPath + "/" + filepath.ToSlash(rel)
}

func defaultGoastImportIdent(impPath string) string {
	trimmed := strings.Trim(strings.TrimSpace(impPath), `"`)
	if trimmed == "" {
		return ""
	}
	if idx := strings.LastIndexByte(trimmed, '/'); idx >= 0 {
		trimmed = trimmed[idx+1:]
	}
	if strings.HasPrefix(trimmed, "v") && len(trimmed) > 1 {
		allDigits := true
		for _, r := range trimmed[1:] {
			if r < '0' || r > '9' {
				allDigits = false
				break
			}
		}
		if allDigits {
			parts := strings.Split(strings.Trim(impPath, `"`), "/")
			if len(parts) >= 2 {
				return parts[len(parts)-2]
			}
		}
	}
	return trimmed
}

func collectGoastFileImportAliases(file *ast.File) map[string]string {
	aliases := map[string]string{}
	if file == nil {
		return aliases
	}
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		impPath := strings.Trim(imp.Path.Value, `"`)
		if impPath == "" {
			continue
		}
		alias := ""
		if imp.Name != nil && imp.Name.Name != "" {
			if imp.Name.Name == "_" || imp.Name.Name == "." {
				continue
			}
			alias = imp.Name.Name
		} else {
			alias = defaultGoastImportIdent(impPath)
		}
		if alias != "" {
			aliases[alias] = impPath
		}
	}
	return aliases
}

func collectGoastUsedImportSpecs(files []*ast.File, code string, stdlib map[string]string) []goastImportSpec {
	combined := map[string]string{}
	for _, f := range files {
		for alias, p := range collectGoastFileImportAliases(f) {
			if _, exists := combined[alias]; !exists {
				combined[alias] = p
			}
		}
	}
	referenced := map[string]bool{}
	parsed, err := parser.ParseFile(token.NewFileSet(), "snippet.go", "package p\n"+code, parser.SkipObjectResolution)
	if err == nil && parsed != nil {
		ast.Inspect(parsed, func(n ast.Node) bool {
			if sel, ok := n.(*ast.SelectorExpr); ok {
				if id, ok := sel.X.(*ast.Ident); ok && id.Name != "" {
					referenced[id.Name] = true
				}
			}
			return true
		})
	} else {
		for alias := range combined {
			if strings.Contains(code, alias+".") {
				referenced[alias] = true
			}
		}
		for alias := range stdlib {
			if strings.Contains(code, alias+".") {
				referenced[alias] = true
			}
		}
	}

	var specs []goastImportSpec
	seen := map[string]bool{}
	for ident := range referenced {
		if p, ok := combined[ident]; ok {
			key := ident + "|" + p
			if !seen[key] {
				seen[key] = true
				specs = append(specs, goastImportSpec{Alias: ident, Path: p})
			}
			continue
		}
		if p, ok := stdlib[ident]; ok {
			key := "|" + p
			if !seen[key] {
				seen[key] = true
				specs = append(specs, goastImportSpec{Path: p})
			}
		}
	}
	sort.Slice(specs, func(i, j int) bool {
		if specs[i].Path != specs[j].Path {
			return specs[i].Path < specs[j].Path
		}
		return specs[i].Alias < specs[j].Alias
	})
	return specs
}

func buildGoastImportEdits(fset *token.FileSet, file *ast.File, src []byte, required []goastImportSpec) []SigTextEdit {
	if file == nil || len(required) == 0 {
		return nil
	}
	type binding struct {
		name string
		path string
	}
	var existing []binding
	existingDefault := map[string]bool{}
	for _, imp := range file.Imports {
		if imp == nil || imp.Path == nil {
			continue
		}
		p := strings.Trim(imp.Path.Value, `"`)
		name := ""
		if imp.Name != nil {
			name = imp.Name.Name
		}
		if name != "_" && name != "." {
			existing = append(existing, binding{name: name, path: p})
			if name == "" || name == defaultGoastImportIdent(p) {
				existingDefault[p] = true
			}
		}
	}

	seen := map[string]bool{}
	var missing []goastImportSpec
	for _, req := range required {
		p := strings.Trim(strings.TrimSpace(req.Path), `"`)
		if p == "" {
			continue
		}
		alias := strings.TrimSpace(req.Alias)
		key := alias + "|" + p
		if seen[key] {
			continue
		}
		satisfied := false
		if alias == "" {
			satisfied = existingDefault[p]
		} else {
			for _, b := range existing {
				if b.path == p && (b.name == alias || (b.name == "" && alias == defaultGoastImportIdent(p))) {
					satisfied = true
					break
				}
			}
		}
		if !satisfied {
			seen[key] = true
			missing = append(missing, goastImportSpec{Alias: alias, Path: p})
		}
	}
	if len(missing) == 0 {
		return nil
	}

	formatSpec := func(m goastImportSpec) string {
		if m.Alias != "" && m.Alias != defaultGoastImportIdent(m.Path) {
			return fmt.Sprintf("%s %q", m.Alias, m.Path)
		}
		return fmt.Sprintf("%q", m.Path)
	}

	var firstImportDecl *ast.GenDecl
	for _, decl := range file.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if ok && gd.Tok == token.IMPORT {
			firstImportDecl = gd
			break
		}
	}

	if firstImportDecl != nil {
		if firstImportDecl.Lparen.IsValid() && firstImportDecl.Rparen.IsValid() {
			rparenOff := fset.Position(firstImportDecl.Rparen).Offset
			var addBuf strings.Builder
			if rparenOff > 0 && rparenOff <= len(src) && src[rparenOff-1] != '\n' {
				addBuf.WriteByte('\n')
			}
			for _, m := range missing {
				addBuf.WriteString("\t" + formatSpec(m) + "\n")
			}
			return []SigTextEdit{{
				Range:   lspRange(fset, src, firstImportDecl.Rparen, firstImportDecl.Rparen),
				NewText: addBuf.String(),
			}}
		}

		var specs []string
		for _, spec := range firstImportDecl.Specs {
			is, ok := spec.(*ast.ImportSpec)
			if !ok || is.Path == nil {
				continue
			}
			if is.Name != nil && is.Name.Name != "" {
				specs = append(specs, fmt.Sprintf("\t%s %s", is.Name.Name, is.Path.Value))
			} else {
				specs = append(specs, fmt.Sprintf("\t%s", is.Path.Value))
			}
		}
		for _, m := range missing {
			specs = append(specs, "\t"+formatSpec(m))
		}
		return []SigTextEdit{{
			Range:   lspRange(fset, src, firstImportDecl.Pos(), firstImportDecl.End()),
			NewText: "import (\n" + strings.Join(specs, "\n") + "\n)",
		}}
	}

	if file.Name != nil {
		var importBlock strings.Builder
		if len(missing) == 1 {
			importBlock.WriteString("\n\nimport " + formatSpec(missing[0]))
		} else {
			importBlock.WriteString("\n\nimport (\n")
			for _, m := range missing {
				importBlock.WriteString("\t" + formatSpec(m) + "\n")
			}
			importBlock.WriteString(")")
		}
		insertPos := file.Name.End()
		if tf := fset.File(insertPos); tf != nil {
			off := tf.Offset(insertPos)
			for off < len(src) && src[off] != '\n' {
				off++
			}
			if off <= tf.Size() {
				insertPos = tf.Pos(off)
			}
		}
		return []SigTextEdit{{
			Range:   lspRange(fset, src, insertPos, insertPos),
			NewText: importBlock.String(),
		}}
	}
	return nil
}

func packageDeclaresFunc(path string, file *ast.File, name string) bool {
	declares := func(f *ast.File) bool {
		for _, decl := range f.Decls {
			if fd, ok := decl.(*ast.FuncDecl); ok && fd.Recv == nil && fd.Name != nil && fd.Name.Name == name {
				return true
			}
		}
		return false
	}
	if file != nil && declares(file) {
		return true
	}
	if path == "" || file == nil {
		return false
	}
	dir := filepath.Dir(path)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") || filepath.Join(dir, n) == path {
			continue
		}
		f, err := parser.ParseFile(token.NewFileSet(), filepath.Join(dir, n), nil, parser.SkipObjectResolution)
		if err == nil && f.Name.Name == file.Name.Name && declares(f) {
			return true
		}
	}
	return false
}
