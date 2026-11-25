package movedecl

import (
	"context"
	"fmt"
	"go/ast"
	"go/format"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"golens/core/goast"
	"golens/core/usageindex"
)

type Request struct {
	Path         string
	Offset       int
	Dest         string
	WorkspaceDir string
	Buffers      map[string]string
}

type edit struct {
	start, end int
	text       string
}

type span struct {
	file       string
	start, end int
	prefix     string
}

type mover struct {
	ws        *usageindex.CheckedWorkspace
	fset      *token.FileSet
	src       *usageindex.CheckedPackage
	srcDir    string
	destDir   string
	destPath  string
	destName  string
	destPkg   *usageindex.CheckedPackage
	names     map[string]bool
	primary   string
	spans     []span
	edits     map[string][]edit
	blockers  []string
	addImport map[string]map[string]string
}

func Move(ctx context.Context, req Request) goast.GenerateCodeResponse {
	resp, err := move(ctx, req)
	if err != nil {
		return goast.GenerateCodeResponse{Error: err.Error()}
	}
	return resp
}

func move(ctx context.Context, req Request) (goast.GenerateCodeResponse, error) {
	var none goast.GenerateCodeResponse
	srcFile := filepath.Clean(req.Path)
	destFile := filepath.Clean(req.Dest)
	if !strings.HasSuffix(destFile, ".go") {
		return none, fmt.Errorf("the destination must be a .go file")
	}
	if strings.HasSuffix(destFile, "_test.go") != strings.HasSuffix(srcFile, "_test.go") {
		return none, fmt.Errorf("move between test files and non-test files is not supported")
	}
	root := loadRoot(req.WorkspaceDir, srcFile)
	opts := usageindex.Options{}
	if len(req.Buffers) > 0 {
		opts.Overlay = func(path string) ([]byte, bool) {
			text, ok := req.Buffers[path]
			return []byte(text), ok
		}
		opts.OverlayFiles = func() []string {
			paths := make([]string, 0, len(req.Buffers))
			for p := range req.Buffers {
				paths = append(paths, p)
			}
			return paths
		}
	}
	ws, err := usageindex.CheckWorkspace(ctx, root, opts)
	if err != nil {
		return none, fmt.Errorf("could not load the project: %v", err)
	}
	m := &mover{
		ws: ws, fset: ws.Fset, srcDir: filepath.Dir(srcFile), destDir: filepath.Dir(destFile),
		names: map[string]bool{}, edits: map[string][]edit{}, addImport: map[string]map[string]string{},
	}
	for _, p := range ws.Packages {
		if !m.contains(p, srcFile) {
			continue
		}
		if m.src == nil || (m.src.ForTest != "" && p.ForTest == "") {
			m.src = p
		}
	}
	if m.src == nil {
		return none, fmt.Errorf("%s is not part of a package in this project", filepath.Base(srcFile))
	}
	if m.src.Problem != "" {
		return none, fmt.Errorf("package %s has errors (%s); fix them before moving a declaration", m.src.Name, m.src.Problem)
	}
	if err := m.resolveDestination(destFile); err != nil {
		return none, err
	}
	if err := m.selectDeclaration(srcFile, req.Offset); err != nil {
		return none, err
	}
	moved := m.rewriteMoved()
	m.rewriteReferences(moved)
	if len(m.blockers) > 0 {
		return none, fmt.Errorf("%s", strings.Join(dedupe(m.blockers), " "))
	}
	if err := m.writeDestination(destFile, moved); err != nil {
		return none, err
	}
	m.removeSource()
	out := goast.GenerateCodeResponse{EditsByPath: map[string][]goast.SigTextEdit{}, TargetPath: destFile}
	for path, list := range m.edits {
		src := m.ws.Source(path)
		if path == destFile && src == nil {
			if data, err := os.ReadFile(path); err == nil {
				src = data
			}
		}
		out.EditsByPath[path] = toWire(src, mergeEdits(list))
	}
	return out, nil
}

func loadRoot(workspaceDir, file string) string {
	if workspaceDir != "" {
		for _, name := range []string{"go.work", "go.mod"} {
			if _, err := os.Stat(filepath.Join(workspaceDir, name)); err == nil {
				return workspaceDir
			}
		}
	}
	for dir := filepath.Dir(file); ; dir = filepath.Dir(dir) {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		if dir == filepath.Dir(dir) {
			break
		}
	}
	if workspaceDir != "" {
		return workspaceDir
	}
	return filepath.Dir(file)
}

func (m *mover) contains(p *usageindex.CheckedPackage, file string) bool {
	for _, f := range p.Files {
		if m.filename(f) == file {
			return true
		}
	}
	return false
}

func (m *mover) filename(f *ast.File) string {
	return filepath.Clean(m.fset.Position(f.Package).Filename)
}

func (m *mover) offset(pos token.Pos) int { return m.fset.Position(pos).Offset }

func (m *mover) resolveDestination(destFile string) error {
	if m.destDir == m.srcDir {
		return fmt.Errorf("the destination is in the same package")
	}
	for _, p := range m.ws.Packages {
		if filepath.Clean(p.Dir) == m.destDir && p.ForTest == "" {
			m.destPkg = p
			m.destPath, m.destName = p.Path, p.Name
		}
	}
	if m.destPkg == nil {
		if m.src.ModuleDir == "" || m.src.ModulePath == "" {
			return fmt.Errorf("the destination package could not be resolved")
		}
		rel, err := filepath.Rel(m.src.ModuleDir, m.destDir)
		if err != nil || strings.HasPrefix(rel, "..") {
			return fmt.Errorf("the destination must be inside module %s", m.src.ModulePath)
		}
		if entries, err := os.ReadDir(m.destDir); err == nil {
			for _, e := range entries {
				if strings.HasSuffix(e.Name(), ".go") {
					return fmt.Errorf("the package in %s is not built for the current target, so it cannot receive the declaration", rel)
				}
			}
		}
		m.destPath = m.src.ModulePath + "/" + filepath.ToSlash(rel)
		m.destName = packageName(filepath.Base(m.destDir))
	}
	if m.destName == "main" {
		return fmt.Errorf("the destination is package main, which other packages cannot import")
	}
	if m.destPath == m.src.Path {
		return fmt.Errorf("the destination is in the same package")
	}
	return nil
}

func packageName(base string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(base) {
		if unicode.IsLetter(r) || r == '_' || (b.Len() > 0 && unicode.IsDigit(r)) {
			b.WriteRune(r)
		}
	}
	if b.Len() == 0 {
		return "pkg"
	}
	return b.String()
}

func (m *mover) selectDeclaration(srcFile string, offset int) error {
	var file *ast.File
	for _, f := range m.src.Files {
		if m.filename(f) == srcFile {
			file = f
		}
	}
	src := m.ws.Source(srcFile)
	if file == nil || src == nil {
		return fmt.Errorf("could not read %s", filepath.Base(srcFile))
	}
	for _, decl := range file.Decls {
		start, end := m.declStart(src, decl.Pos()), m.offset(decl.End())
		if offset < start || offset > end {
			continue
		}
		switch d := decl.(type) {
		case *ast.FuncDecl:
			if d.Recv != nil {
				return fmt.Errorf("place the cursor on the type; its methods move with it")
			}
			m.primary = d.Name.Name
			m.names[d.Name.Name] = true
			m.spans = append(m.spans, span{file: srcFile, start: start, end: end})
			return nil
		case *ast.GenDecl:
			return m.selectSpec(srcFile, src, d, offset)
		}
	}
	return fmt.Errorf("place the cursor on a top-level function, type, variable or constant")
}

func (m *mover) selectSpec(srcFile string, src []byte, d *ast.GenDecl, offset int) error {
	if d.Tok == token.IMPORT {
		return fmt.Errorf("place the cursor on a top-level function, type, variable or constant")
	}
	spec := d.Specs[0]
	if len(d.Specs) > 1 {
		spec = nil
		for _, s := range d.Specs {
			if offset >= m.declStart(src, s.Pos()) && offset <= m.offset(s.End()) {
				spec = s
			}
		}
		if spec == nil {
			return fmt.Errorf("place the cursor on one declaration inside the group")
		}
		if d.Tok == token.CONST {
			return fmt.Errorf("constants declared in a group may depend on each other; move the constant out of the group first")
		}
	}
	switch s := spec.(type) {
	case *ast.TypeSpec:
		m.primary = s.Name.Name
		m.names[s.Name.Name] = true
	case *ast.ValueSpec:
		for _, name := range s.Names {
			if name.Name == "_" {
				return fmt.Errorf("a blank declaration cannot be moved")
			}
			m.names[name.Name] = true
			if m.primary == "" {
				m.primary = name.Name
			}
		}
	}
	if len(d.Specs) > 1 {
		start, end := m.declStart(src, spec.Pos()), m.offset(spec.End())
		m.spans = append(m.spans, span{file: srcFile, start: start, end: end, prefix: d.Tok.String() + " "})
	} else {
		m.spans = append(m.spans, span{file: srcFile, start: m.declStart(src, d.Pos()), end: m.offset(d.End())})
	}
	if _, ok := spec.(*ast.TypeSpec); !ok {
		return nil
	}
	for _, p := range m.ws.Packages {
		if filepath.Clean(p.Dir) != m.srcDir {
			continue
		}
		for _, f := range p.Files {
			name := m.filename(f)
			for _, decl := range f.Decls {
				fd, ok := decl.(*ast.FuncDecl)
				if !ok || fd.Recv == nil || len(fd.Recv.List) == 0 || receiverName(fd.Recv.List[0].Type) != m.primary {
					continue
				}
				if strings.HasSuffix(name, "_test.go") != strings.HasSuffix(srcFile, "_test.go") {
					return fmt.Errorf("method %s.%s is declared in %s; move it next to the type first", m.primary, fd.Name.Name, filepath.Base(name))
				}
				fsrc := m.ws.Source(name)
				sp := span{file: name, start: m.declStart(fsrc, fd.Pos()), end: m.offset(fd.End())}
				if !m.hasSpan(sp) {
					m.spans = append(m.spans, sp)
				}
			}
		}
	}
	return nil
}

func receiverName(expr ast.Expr) string {
	for {
		switch e := expr.(type) {
		case *ast.StarExpr:
			expr = e.X
		case *ast.ParenExpr:
			expr = e.X
		case *ast.IndexExpr:
			expr = e.X
		case *ast.IndexListExpr:
			expr = e.X
		case *ast.Ident:
			return e.Name
		default:
			return ""
		}
	}
}

func (m *mover) hasSpan(sp span) bool {
	for _, s := range m.spans {
		if s.file == sp.file && s.start == sp.start {
			return true
		}
	}
	return false
}

func (m *mover) declStart(src []byte, pos token.Pos) int {
	start := m.offset(pos)
	lineStart := start
	for lineStart > 0 && src[lineStart-1] != '\n' {
		lineStart--
	}
	if strings.TrimSpace(string(src[lineStart:start])) != "" {
		return start
	}
	for lineStart > 0 {
		prevEnd := lineStart - 1
		prevStart := prevEnd
		for prevStart > 0 && src[prevStart-1] != '\n' {
			prevStart--
		}
		if !strings.HasPrefix(strings.TrimSpace(string(src[prevStart:prevEnd])), "//") {
			break
		}
		lineStart = prevStart
	}
	return lineStart
}

func (m *mover) inSpans(file string, off int) bool {
	for _, s := range m.spans {
		if s.file == file && off >= s.start && off < s.end {
			return true
		}
	}
	return false
}

func (m *mover) isMoved(obj types.Object) bool {
	return obj != nil && obj.Pkg() != nil && obj.Pkg().Path() == m.src.Path && obj.Parent() == obj.Pkg().Scope() && m.names[obj.Name()]
}

func (m *mover) declaredInSpans(obj types.Object) bool {
	if !obj.Pos().IsValid() {
		return false
	}
	p := m.fset.Position(obj.Pos())
	return m.inSpans(filepath.Clean(p.Filename), p.Offset)
}

type movedCode struct {
	texts    []string
	imports  map[string]string
	needsSrc bool
	srcLocal string
}

func (m *mover) rewriteMoved() movedCode {
	out := movedCode{imports: map[string]string{}, srcLocal: m.src.Name}
	inner := map[string][]edit{}
	selectors := map[*ast.Ident]*ast.SelectorExpr{}
	for _, f := range m.src.Files {
		name := m.filename(f)
		ast.Inspect(f, func(n ast.Node) bool {
			if sel, ok := n.(*ast.SelectorExpr); ok {
				if x, ok := sel.X.(*ast.Ident); ok {
					selectors[x] = sel
				}
			}
			id, ok := n.(*ast.Ident)
			if !ok || !m.inSpans(name, m.offset(id.Pos())) {
				return true
			}
			obj := m.src.Info.Uses[id]
			if obj == nil {
				return true
			}
			if pn, ok := obj.(*types.PkgName); ok {
				path := pn.Imported().Path()
				if path == m.destPath {
					if sel := selectors[id]; sel != nil {
						inner[name] = append(inner[name], edit{m.offset(id.Pos()), m.offset(sel.Sel.Pos()), ""})
					}
					return true
				}
				out.imports[path] = importName(pn)
				return true
			}
			if obj.Pkg() == nil || obj.Pkg().Path() != m.src.Path || m.declaredInSpans(obj) {
				return true
			}
			if obj.Parent() == obj.Pkg().Scope() {
				if m.names[obj.Name()] {
					return true
				}
				if !obj.Exported() {
					m.blockers = append(m.blockers, fmt.Sprintf("%s uses %s, which is not exported from package %s.", m.primary, obj.Name(), m.src.Name))
					return true
				}
				out.needsSrc = true
				inner[name] = append(inner[name], edit{m.offset(id.Pos()), m.offset(id.Pos()), "\x00"})
				return true
			}
			if !obj.Exported() {
				m.blockers = append(m.blockers, fmt.Sprintf("%s uses %s, which is not exported from package %s.", m.primary, obj.Name(), m.src.Name))
			}
			return true
		})
	}
	if out.needsSrc {
		if m.src.Name == "main" {
			m.blockers = append(m.blockers, fmt.Sprintf("%s uses declarations of package main, which the destination cannot import.", m.primary))
		}
		for path, local := range out.imports {
			if local == out.srcLocal && path != m.src.Path {
				out.srcLocal = m.src.Name + "pkg"
			}
		}
		out.imports[m.src.Path] = ""
		if out.srcLocal != m.src.Name {
			out.imports[m.src.Path] = out.srcLocal
		}
	}
	for _, sp := range m.spans {
		src := m.ws.Source(sp.file)
		var local []edit
		for _, e := range inner[sp.file] {
			if e.start >= sp.start && e.end <= sp.end {
				if e.text == "\x00" {
					e.text = out.srcLocal + "."
				}
				local = append(local, e)
			}
		}
		out.texts = append(out.texts, sp.prefix+applyEdits(src[sp.start:sp.end], sp.start, local))
	}
	return out
}

func importName(pn *types.PkgName) string {
	if pn.Name() != pn.Imported().Name() {
		return pn.Name()
	}
	return ""
}

func applyEdits(src []byte, base int, edits []edit) string {
	edits = mergeEdits(edits)
	var b strings.Builder
	at := 0
	for _, e := range edits {
		b.Write(src[at : e.start-base])
		b.WriteString(e.text)
		at = e.end - base
	}
	b.Write(src[at:])
	return b.String()
}

func mergeEdits(edits []edit) []edit {
	sort.SliceStable(edits, func(i, j int) bool {
		if edits[i].start != edits[j].start {
			return edits[i].start < edits[j].start
		}
		return edits[i].end < edits[j].end
	})
	var out []edit
	for _, e := range edits {
		if n := len(out); n > 0 && out[n-1].start == e.start && out[n-1].end == e.end && out[n-1].text == e.text {
			continue
		}
		if n := len(out); n > 0 && e.start < out[n-1].end {
			continue
		}
		out = append(out, e)
	}
	return out
}

func (m *mover) rewriteReferences(moved movedCode) {
	importers := map[string]bool{}
	for _, name := range sortedNames(m.names) {
		if m.destPkg != nil && m.destPkg.Types != nil && m.destPkg.Types.Scope().Lookup(name) != nil {
			m.blockers = append(m.blockers, fmt.Sprintf("Package %s already declares %s.", m.destName, name))
		}
	}
	for _, p := range m.ws.Packages {
		for _, f := range p.Files {
			m.rewriteFile(p, f, importers)
		}
	}
	destDeps := []string{}
	for path := range moved.imports {
		destDeps = append(destDeps, path)
	}
	if m.destPkg != nil {
		destDeps = append(destDeps, m.destPath)
	}
	for importer := range importers {
		for _, dep := range destDeps {
			if dep == importer || m.ws.Reaches(dep, importer) {
				m.blockers = append(m.blockers, fmt.Sprintf("Package %s would import %s and %s would import it back, which Go does not allow.", pathBase(importer), m.destName, m.destName))
				break
			}
		}
	}
}

func pathBase(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[i+1:]
	}
	return path
}

func sortedNames(set map[string]bool) []string {
	names := make([]string, 0, len(set))
	for n := range set {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

func (m *mover) rewriteFile(p *usageindex.CheckedPackage, f *ast.File, importers map[string]bool) {
	name := m.filename(f)
	dir := filepath.Dir(name)
	selectors := map[*ast.Ident]*ast.SelectorExpr{}
	ast.Inspect(f, func(n ast.Node) bool {
		if sel, ok := n.(*ast.SelectorExpr); ok {
			selectors[sel.Sel] = sel
		}
		return true
	})
	local := ""
	total := map[*types.PkgName]int{}
	rewritten := map[*types.PkgName]int{}
	var pending []edit
	needsImport := false
	ast.Inspect(f, func(n ast.Node) bool {
		id, ok := n.(*ast.Ident)
		if !ok {
			return true
		}
		obj := p.Info.Uses[id]
		if obj == nil {
			return true
		}
		off := m.offset(id.Pos())
		inMoved := m.inSpans(name, off)
		if pn, ok := obj.(*types.PkgName); ok {
			if !inMoved {
				total[pn]++
			}
			return true
		}
		if inMoved {
			return true
		}
		if dir == m.srcDir && p.Path == m.src.Path && obj.Pkg() != nil && obj.Pkg().Path() == m.src.Path && m.declaredInSpans(obj) && !m.isMoved(obj) && !obj.Exported() {
			m.blockers = append(m.blockers, fmt.Sprintf("Package %s still uses %s of %s, which is not exported.", m.src.Name, obj.Name(), m.primary))
			return true
		}
		if !m.isMoved(obj) {
			return true
		}
		sel := selectors[id]
		var qualifier *types.PkgName
		if sel != nil {
			if x, ok := sel.X.(*ast.Ident); ok {
				qualifier, _ = p.Info.Uses[x].(*types.PkgName)
			}
		}
		if dir == m.destDir {
			if qualifier != nil {
				pending = append(pending, edit{m.offset(sel.X.Pos()), m.offset(sel.Sel.Pos()), ""})
				rewritten[qualifier]++
			}
			return true
		}
		if !ast.IsExported(id.Name) {
			m.blockers = append(m.blockers, fmt.Sprintf("%s is not exported but %s uses it; give it an exported name first.", id.Name, filepath.Base(name)))
			return true
		}
		if local == "" {
			local = m.localName(p, f)
		}
		needsImport = true
		importers[p.Path] = true
		if qualifier != nil {
			pending = append(pending, edit{m.offset(sel.X.Pos()), m.offset(sel.X.End()), local})
			rewritten[qualifier]++
		} else if p.Path == m.src.Path || p.Path == m.src.Path+"_test" {
			if p.Path != m.src.Path {
				m.blockers = append(m.blockers, fmt.Sprintf("%s refers to %s through a dot import, which this refactoring does not rewrite.", filepath.Base(name), id.Name))
				return true
			}
			pending = append(pending, edit{off, off, local + "."})
		} else {
			m.blockers = append(m.blockers, fmt.Sprintf("%s refers to %s through a dot import, which this refactoring does not rewrite.", filepath.Base(name), id.Name))
		}
		return true
	})
	if len(pending) == 0 {
		return
	}
	m.edits[name] = append(m.edits[name], pending...)
	src := m.ws.Source(name)
	for pn, n := range rewritten {
		if total[pn] == n {
			if e, ok := m.removeImportEdit(f, src, pn); ok {
				m.edits[name] = append(m.edits[name], e)
			}
		}
	}
	if needsImport && !m.imports(f, m.destPath) {
		alias := ""
		if local != m.destName {
			alias = local
		}
		if m.addImport[name] == nil {
			m.addImport[name] = map[string]string{}
		}
		m.addImport[name][m.destPath] = alias
		if e, ok := importEdit(m, f, src, m.addImport[name]); ok {
			m.edits[name] = append(m.edits[name], e)
		}
	}
}

func (m *mover) imports(f *ast.File, path string) bool {
	for _, spec := range f.Imports {
		if p, err := strconv.Unquote(spec.Path.Value); err == nil && p == path {
			return spec.Name == nil || (spec.Name.Name != "_" && spec.Name.Name != ".")
		}
	}
	return false
}

func (m *mover) localName(p *usageindex.CheckedPackage, f *ast.File) string {
	taken := false
	for _, spec := range f.Imports {
		path, _ := strconv.Unquote(spec.Path.Value)
		if path == m.destPath {
			if spec.Name != nil && spec.Name.Name != "_" && spec.Name.Name != "." {
				return spec.Name.Name
			}
			if spec.Name == nil {
				return m.destName
			}
			continue
		}
		name := pathBase(path)
		if spec.Name != nil {
			name = spec.Name.Name
		} else if obj, ok := p.Info.Implicits[spec].(*types.PkgName); ok {
			name = obj.Name()
		}
		if name == m.destName {
			taken = true
		}
	}
	if p.Types != nil && p.Types.Scope().Lookup(m.destName) != nil {
		taken = true
	}
	if taken {
		return m.destName + "pkg"
	}
	return m.destName
}

func (m *mover) removeImportEdit(f *ast.File, src []byte, pn *types.PkgName) (edit, bool) {
	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.IMPORT {
			continue
		}
		for _, spec := range gd.Specs {
			is := spec.(*ast.ImportSpec)
			path, _ := strconv.Unquote(is.Path.Value)
			if path != pn.Imported().Path() {
				continue
			}
			if is.Name != nil && is.Name.Name != pn.Name() {
				continue
			}
			start, end := m.offset(is.Pos()), m.offset(is.End())
			if len(gd.Specs) == 1 {
				start, end = m.offset(gd.Pos()), m.offset(gd.End())
			}
			return edit{lineStart(src, start), lineEnd(src, end), ""}, true
		}
	}
	return edit{}, false
}

func lineStart(src []byte, off int) int {
	for off > 0 && src[off-1] != '\n' {
		off--
	}
	return off
}

func lineEnd(src []byte, off int) int {
	for off < len(src) && src[off] != '\n' {
		off++
	}
	if off < len(src) {
		off++
	}
	return off
}

func importLine(path, alias string) string {
	if alias != "" {
		return alias + " " + strconv.Quote(path)
	}
	return strconv.Quote(path)
}

func importEdit(m *mover, f *ast.File, src []byte, imports map[string]string) (edit, bool) {
	paths := make([]string, 0, len(imports))
	for p := range imports {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		return edit{}, false
	}
	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.IMPORT {
			continue
		}
		var b strings.Builder
		if gd.Rparen.IsValid() {
			at := lineStart(src, m.offset(gd.Rparen))
			if at <= m.offset(gd.Lparen) {
				at = m.offset(gd.Rparen)
				b.WriteString("\n")
			}
			for _, p := range paths {
				b.WriteString("\t" + importLine(p, imports[p]) + "\n")
			}
			return edit{at, at, b.String()}, true
		}
		at := lineEnd(src, m.offset(gd.End()))
		if at > 0 && src[at-1] != '\n' {
			b.WriteString("\n")
		}
		for _, p := range paths {
			b.WriteString("import " + importLine(p, imports[p]) + "\n")
		}
		return edit{at, at, b.String()}, true
	}
	at := lineEnd(src, m.offset(f.Name.End()))
	var b strings.Builder
	if at > 0 && src[at-1] != '\n' {
		b.WriteString("\n")
	}
	b.WriteString("\nimport (\n")
	for _, p := range paths {
		b.WriteString("\t" + importLine(p, imports[p]) + "\n")
	}
	b.WriteString(")\n")
	return edit{at, at, b.String()}, true
}

func (m *mover) writeDestination(destFile string, moved movedCode) error {
	body := strings.Join(moved.texts, "\n\n") + "\n"
	var existing *ast.File
	if m.destPkg != nil {
		for _, f := range m.destPkg.Files {
			if m.filename(f) == destFile {
				existing = f
			}
		}
	}
	if existing == nil {
		if _, err := os.Stat(destFile); err == nil {
			return fmt.Errorf("%s exists but is not built for the current target", filepath.Base(destFile))
		}
		var b strings.Builder
		b.WriteString("package " + m.destName + "\n\n")
		if len(moved.imports) > 0 {
			b.WriteString("import (\n")
			for _, p := range sortedKeys(moved.imports) {
				b.WriteString("\t" + importLine(p, moved.imports[p]) + "\n")
			}
			b.WriteString(")\n\n")
		}
		b.WriteString(body)
		content := []byte(b.String())
		if formatted, err := format.Source(content); err == nil {
			content = formatted
		}
		if err := os.MkdirAll(filepath.Dir(destFile), 0o755); err != nil {
			return fmt.Errorf("could not create %s: %v", filepath.Dir(destFile), err)
		}
		if err := os.WriteFile(destFile, content, 0o644); err != nil {
			return fmt.Errorf("could not create %s: %v", filepath.Base(destFile), err)
		}
		m.edits[destFile] = []edit{{0, 0, string(content)}}
		return nil
	}
	src := m.ws.Source(destFile)
	missing := map[string]string{}
	for path, alias := range moved.imports {
		name := alias
		found := false
		for _, spec := range existing.Imports {
			p, _ := strconv.Unquote(spec.Path.Value)
			if p != path {
				continue
			}
			have := ""
			if spec.Name != nil {
				have = spec.Name.Name
			}
			if have == name {
				found = true
			}
		}
		if !found {
			missing[path] = alias
		}
	}
	if e, ok := importEdit(m, existing, src, missing); ok {
		m.edits[destFile] = append(m.edits[destFile], e)
	}
	sep := "\n"
	if len(src) > 0 && src[len(src)-1] != '\n' {
		sep = "\n\n"
	}
	m.edits[destFile] = append(m.edits[destFile], edit{len(src), len(src), sep + body})
	return nil
}

func sortedKeys(set map[string]string) []string {
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func (m *mover) removeSource() {
	files := map[string]bool{}
	for _, sp := range m.spans {
		src := m.ws.Source(sp.file)
		start, end := sp.start, sp.end
		if sp.prefix == "" {
			for end < len(src) && (src[end] == ' ' || src[end] == '\t') {
				end++
			}
			newlines := 0
			for end < len(src) && src[end] == '\n' && newlines < 2 {
				end++
				newlines++
			}
		} else {
			start, end = lineStart(src, start), lineEnd(src, end)
		}
		m.edits[sp.file] = append(m.edits[sp.file], edit{start, end, ""})
		files[sp.file] = true
	}
	for _, f := range m.src.Files {
		name := m.filename(f)
		if !files[name] {
			continue
		}
		outside := map[*types.PkgName]int{}
		inside := map[*types.PkgName]int{}
		ast.Inspect(f, func(n ast.Node) bool {
			id, ok := n.(*ast.Ident)
			if !ok {
				return true
			}
			if pn, ok := m.src.Info.Uses[id].(*types.PkgName); ok {
				if m.inSpans(name, m.offset(id.Pos())) {
					inside[pn]++
				} else {
					outside[pn]++
				}
			}
			return true
		})
		src := m.ws.Source(name)
		for pn, n := range inside {
			if n > 0 && outside[pn] == 0 {
				if e, ok := m.removeImportEdit(f, src, pn); ok {
					m.edits[name] = append(m.edits[name], e)
				}
			}
		}
	}
}

func dedupe(list []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range list {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	if len(out) > 3 {
		out = append(out[:3], fmt.Sprintf("(%d more reasons)", len(out)-3))
	}
	return out
}

func toWire(src []byte, edits []edit) []goast.SigTextEdit {
	out := make([]goast.SigTextEdit, 0, len(edits))
	for _, e := range edits {
		out = append(out, goast.SigTextEdit{
			Range:   goast.LSPWireRange{Start: wirePos(src, e.start), End: wirePos(src, e.end)},
			NewText: e.text,
		})
	}
	return out
}

func wirePos(src []byte, off int) goast.LSPWirePos {
	if off > len(src) {
		off = len(src)
	}
	line, col := 0, 0
	for i := 0; i < off; {
		r, size := utf8.DecodeRune(src[i:])
		if r == '\n' {
			line++
			col = 0
		} else if r >= 0x10000 {
			col += 2
		} else {
			col++
		}
		i += size
	}
	return goast.LSPWirePos{Line: line, Character: col}
}
