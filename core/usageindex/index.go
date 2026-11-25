package usageindex

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/build/constraint"
	"go/parser"
	"go/token"
	"go/types"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
)

type Options struct {
	RunGo        func(ctx context.Context, dir string, args ...string) ([]byte, error)
	Overlay      func(path string) ([]byte, bool)
	OverlayFiles func() []string
}

var DefaultOverlayFiles func() []string

type Pos struct {
	Line, Col int
}

type Index struct {
	dir   string
	opts  Options
	sizes types.Sizes
	upd   sync.Mutex
	mu    sync.RWMutex
	state
	l *loader
}

type state struct {
	files     map[string]*fileEntry
	pkgs      []*pkgEntry
	deps      []*pkgEntry
	byPkgPath map[string]*pkgEntry
	byPath    map[string][]*fileEntry
	counts    map[string]int
	extRecv   map[string]extMethod
	byMethod  map[string][]summaryRef
	errorLoc  Loc
	ifaceIDs  map[string]string
}

type fileEntry struct {
	name    string
	pkgPath string
	pkgs    []int
	owner   int
	broken  bool
	uses    map[string]int
	ext     map[string]int
	decls   []decl
}

type decl struct {
	pos      Pos
	key      string
	method   string
	recv     string
	exported bool
	sum      *typeSummary
}

type pkgEntry struct {
	id         string
	path       string
	itv        bool
	importedBy []int
	files      []*fileEntry
	types      map[string]*typeSummary
	local      map[localKey][]Loc
	broken     bool
}

type summaryRef struct {
	pkg int
	sum *typeSummary
}

type extMethod struct {
	name string
	recv *typeSummary
}

type listPkg struct {
	ImportPath   string
	Name         string
	Dir          string
	ForTest      string
	GoFiles      []string
	CgoFiles     []string
	TestGoFiles  []string
	XTestGoFiles []string
	Imports      []string
	ImportMap    map[string]string
	Module       *struct {
		Main      bool
		GoVersion string
		Path      string
		Dir       string
	}
	Error *struct {
		Err string
	}
}

const maxWorkspaceVariants = 1500

var ErrTooLarge = errors.New("workspace too large")

const listFields = "-json=ImportPath,Name,Dir,ForTest,GoFiles,CgoFiles,TestGoFiles,XTestGoFiles,Imports,ImportMap,Module,Error"

func Build(ctx context.Context, workspaceDir string, opts Options) (*Index, error) {
	ix, _, err := build(ctx, workspaceDir, opts, nil)
	return ix, err
}

func build(ctx context.Context, workspaceDir string, opts Options, sizes types.Sizes) (*Index, string, error) {
	l, err := load(ctx, workspaceDir, opts, sizes, nil)
	if err != nil {
		return nil, "", err
	}
	ix := &Index{dir: workspaceDir, opts: opts, sizes: l.sizes}
	ix.install(l)
	return ix, l.staleReport(), nil
}

func (ix *Index) FileLenses(path string) map[Pos]Lens {
	ix.mu.RLock()
	defer ix.mu.RUnlock()
	fe := ix.files[filepath.Clean(path)]
	if fe == nil || fe.broken {
		return nil
	}
	out := make(map[Pos]Lens, len(fe.decls))
	for i := range fe.decls {
		d := &fe.decls[i]
		out[d.pos] = Lens{Count: ix.count(fe, d), Impls: ix.impls(fe, d)}
	}
	return out
}

func (ix *Index) Update(ctx context.Context, changedPaths []string) error {
	ix.upd.Lock()
	defer ix.upd.Unlock()
	if ok, err := ix.apply(ctx, changedPaths); err != nil || ok {
		return err
	}
	_, err := ix.rebuild(ctx)
	return err
}

func (ix *Index) updateInPlace(ctx context.Context, changedPaths []string) (bool, error) {
	ix.upd.Lock()
	defer ix.upd.Unlock()
	return ix.apply(ctx, changedPaths)
}

func (ix *Index) reload(ctx context.Context) (string, error) {
	ix.upd.Lock()
	defer ix.upd.Unlock()
	return ix.rebuild(ctx)
}

func (ix *Index) apply(ctx context.Context, changedPaths []string) (bool, error) {
	l := ix.l
	if l == nil {
		return false, nil
	}
	parsed := map[string]*parsedFile{}
	for _, p := range changedPaths {
		if !filepath.IsAbs(p) {
			l.forget(parsed)
			return false, fmt.Errorf("usageindex: changed path %q is not absolute", p)
		}
		p = filepath.Clean(p)
		if filepath.Ext(p) != ".go" || parsed[p] != nil {
			continue
		}
		if ix.files[p] == nil {
			l.forget(parsed)
			return false, nil
		}
		pf := l.parseFile(p, true)
		parsed[p] = pf
		if errors.Is(pf.err, fs.ErrNotExist) {
			l.forget(parsed)
			return false, nil
		}
	}
	if len(parsed) == 0 {
		return true, nil
	}
	return l.update(ctx, parsed, &ix.mu)
}

func (ix *Index) ReleaseTypes() {
	_ = ix.releaseTypes()
}

func (ix *Index) releaseTypes() bool {
	ix.upd.Lock()
	had := ix.l != nil
	ix.l = nil
	ix.upd.Unlock()
	return had
}

func (ix *Index) released() bool {
	ix.upd.Lock()
	defer ix.upd.Unlock()
	return ix.l == nil
}

func (ix *Index) rebuild(ctx context.Context) (string, error) {
	l, err := load(ctx, ix.dir, ix.opts, ix.sizes, &ix.state)
	if err != nil {
		return "", err
	}
	ix.install(l)
	return l.staleReport(), nil
}

func (ix *Index) install(l *loader) {
	ix.mu.Lock()
	ix.state = *l.st
	ix.mu.Unlock()
	l.st = &ix.state
	ix.l = l
}

func runGo(ctx context.Context, dir string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "go", args...)
	cmd.Dir = dir
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, CommandError(err, stderr.Bytes())
	}
	return out, nil
}

const maxStderr = 400

func CommandError(err error, stderr []byte) error {
	if err == nil {
		return nil
	}
	if msg := clip(string(stderr)); msg != "" {
		return fmt.Errorf("%w: %s", err, msg)
	}
	return fmt.Errorf("%w (nothing on stderr)", err)
}

func clip(msg string) string {
	msg = strings.TrimSpace(msg)
	if len(msg) > maxStderr {
		msg = strings.ToValidUTF8(msg[:maxStderr], "") + "..."
	}
	return msg
}

type node struct {
	lp      *listPkg
	ws      bool
	itv     bool
	pkg     int
	names   []string
	tpkg    *types.Package
	done    bool
	problem string
}

type parsedFile struct {
	file *ast.File
	src  []byte
	cols map[token.Pos]int
	err  error
}

type fileRec struct {
	fe     *fileEntry
	uses   map[string]int
	ext    map[string]int
	decls  []decl
	broken bool
}

type pkgRec struct {
	pe     *pkgEntry
	types  map[string]*typeSummary
	local  map[localKey][]Loc
	broken bool
}

type loader struct {
	ctx        context.Context
	overlay    func(string) ([]byte, bool)
	fset       *token.FileSet
	nodes      map[string]*node
	order      []string
	wsPaths    map[string]bool
	sizes      types.Sizes
	st         *state
	wsFiles    map[string]*parsedFile
	build      map[string]string
	cols       map[token.Pos]int
	strs       map[string]string
	builtin    string
	sumCache   map[types.Type]*typeSummary
	fileRecs   []fileRec
	pkgRecs    []pkgRec
	newExt     map[string]extMethod
	newImports map[*node][]string
	hook       func(n *node, files []*ast.File, info *types.Info)
}

func load(ctx context.Context, dir string, opts Options, sizes types.Sizes, prev *state) (*loader, error) {
	return loadWithHook(ctx, dir, opts, sizes, prev, nil)
}

func loadWithHook(ctx context.Context, dir string, opts Options, sizes types.Sizes, prev *state, hook func(l *loader, n *node, files []*ast.File, info *types.Info)) (*loader, error) {
	run := opts.RunGo
	if run == nil {
		run = runGo
	}
	if sizes == nil {
		env, err := run(ctx, dir, "env", "GOARCH")
		if err != nil {
			return nil, fmt.Errorf("usageindex: go env: %w", err)
		}
		arch := strings.TrimSpace(string(env))
		if sizes = types.SizesFor("gc", arch); sizes == nil {
			return nil, fmt.Errorf("usageindex: unsupported GOARCH %q", arch)
		}
	}
	listArgs := []string{"list", "-e", "-deps", "-test", listFields, "./...", "builtin"}
	if opts.Overlay != nil && (opts.RunGo == nil || opts.OverlayFiles != nil) {
		filesFn := opts.OverlayFiles
		if filesFn == nil {
			filesFn = DefaultOverlayFiles
		}
		if filesFn != nil {
			overlayPath, cleanup, err := stageListOverlay(dir, filesFn(), opts.Overlay)
			if err != nil {
				return nil, fmt.Errorf("usageindex: stage overlay: %w", err)
			}
			if cleanup != nil {
				defer cleanup()
			}
			if overlayPath != "" {
				listArgs = append([]string{"list", "-overlay=" + overlayPath}, listArgs[1:]...)
			}
		}
	}
	raw, err := run(ctx, dir, listArgs...)
	if err != nil {
		return nil, fmt.Errorf("usageindex: go list: %w", err)
	}
	l, err := newLoader(ctx, raw, sizes, opts.Overlay)
	if err != nil {
		return nil, err
	}
	if hook != nil {
		l.hook = func(n *node, files []*ast.File, info *types.Info) { hook(l, n, files, info) }
	}
	if n := len(l.st.pkgs); n > maxWorkspaceVariants {
		return nil, fmt.Errorf("%w: %d workspace package variants, limit %d", ErrTooLarge, n, maxWorkspaceVariants)
	}
	l.st.errorLoc = builtinErrorLoc(l.builtin)
	if prev != nil {
		l.inherit(prev)
	}
	for _, id := range l.reachable() {
		if _, err := l.check(id); err != nil {
			return nil, err
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	l.commit()
	return l, nil
}

func newLoader(ctx context.Context, raw []byte, sizes types.Sizes, overlay func(string) ([]byte, bool)) (*loader, error) {
	l := &loader{
		ctx:        ctx,
		overlay:    overlay,
		fset:       token.NewFileSet(),
		nodes:      map[string]*node{},
		wsPaths:    map[string]bool{},
		sizes:      sizes,
		wsFiles:    map[string]*parsedFile{},
		build:      map[string]string{},
		cols:       map[token.Pos]int{},
		strs:       map[string]string{},
		sumCache:   map[types.Type]*typeSummary{},
		newExt:     map[string]extMethod{},
		newImports: map[*node][]string{},
		st: &state{
			files:     map[string]*fileEntry{},
			byPkgPath: map[string]*pkgEntry{},
			byPath:    map[string][]*fileEntry{},
			counts:    map[string]int{},
			extRecv:   map[string]extMethod{},
			ifaceIDs:  map[string]string{},
		},
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	for {
		lp := new(listPkg)
		if err := dec.Decode(lp); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			return nil, fmt.Errorf("usageindex: decode go list output: %w", err)
		}
		if lp.Name == "main" && strings.HasSuffix(lp.ImportPath, ".test") {
			continue
		}
		if lp.ImportPath == "builtin" {
			if len(lp.GoFiles) == 1 {
				l.builtin = filepath.Join(lp.Dir, lp.GoFiles[0])
			}
			continue
		}
		path := pkgPath(lp.ImportPath)
		n := &node{
			lp:    lp,
			ws:    lp.Module != nil && lp.Module.Main,
			itv:   lp.ForTest != "" && path != lp.ForTest && path != lp.ForTest+"_test",
			pkg:   -1,
			names: fileList(lp),
		}
		l.nodes[lp.ImportPath] = n
		l.order = append(l.order, lp.ImportPath)
		if n.ws {
			l.wsPaths[path] = true
		}
	}
	st := l.st
	for _, id := range l.order {
		n := l.nodes[id]
		if !n.ws {
			continue
		}
		n.pkg = len(st.pkgs)
		pe := &pkgEntry{id: id, path: pkgPath(id), itv: n.itv, broken: true}
		st.pkgs = append(st.pkgs, pe)
		if id == pe.path {
			st.byPkgPath[pe.path] = pe
		}
		for _, name := range n.names {
			fe := st.files[name]
			if fe == nil {
				fe = &fileEntry{name: name, pkgPath: pe.path, owner: -1, broken: true}
				st.files[name] = fe
				st.byPath[pe.path] = append(st.byPath[pe.path], fe)
			}
			fe.pkgs = append(fe.pkgs, n.pkg)
			pe.files = append(pe.files, fe)
		}
	}
	for _, id := range l.order {
		n := l.nodes[id]
		if !n.ws {
			continue
		}
		for _, imp := range n.lp.Imports {
			if m := l.nodes[imp]; m != nil && m.ws {
				st.pkgs[m.pkg].importedBy = append(st.pkgs[m.pkg].importedBy, n.pkg)
			}
		}
	}
	for _, fe := range st.files {
		for _, p := range fe.pkgs {
			pe := st.pkgs[p]
			if pe.itv {
				continue
			}
			if fe.owner < 0 || len(pe.files) < len(st.pkgs[fe.owner].files) {
				fe.owner = p
			}
		}
	}
	return l, nil
}

func (l *loader) inherit(prev *state) {
	st := l.st
	st.ifaceIDs = maps.Clone(prev.ifaceIDs)
	good := map[string]*pkgEntry{}
	for _, pe := range prev.pkgs {
		if !pe.broken {
			good[pe.id] = pe
		}
	}
	for i, pe := range st.pkgs {
		old := good[pe.id]
		if old == nil {
			continue
		}
		pe.types, pe.local, pe.broken = old.types, old.local, false
		for _, fe := range pe.files {
			ofe := prev.files[fe.name]
			if fe.owner != i || ofe == nil || ofe.broken || prev.pkgs[ofe.owner] != old {
				continue
			}
			fe.uses, fe.ext, fe.decls, fe.broken = ofe.uses, ofe.ext, ofe.decls, false
			addCounts(st.counts, fe.uses, 1)
			for k := range fe.ext {
				st.extRecv[k] = prev.extRecv[k]
			}
		}
	}
}

func (l *loader) staleReport() string {
	const shown = 10
	var parts []string
	n := 0
	for _, id := range l.order {
		if p := l.nodes[id].problem; p != "" {
			if n++; n <= shown {
				parts = append(parts, id+": "+p)
			}
		}
	}
	if n == 0 {
		return ""
	}
	if n > shown {
		parts = append(parts, fmt.Sprintf("and %d more", n-shown))
	}
	plural := "s"
	if n == 1 {
		plural = ""
	}
	return fmt.Sprintf("usage index has no fresh data for %d package variant%s: %s", n, plural, strings.Join(parts, "; "))
}

func (l *loader) reachable() []string {
	seen := map[string]bool{}
	var queue []string
	for _, id := range l.order {
		if l.nodes[id].ws {
			seen[id] = true
			queue = append(queue, id)
		}
	}
	for len(queue) > 0 {
		n := l.nodes[queue[len(queue)-1]]
		queue = queue[:len(queue)-1]
		for _, imp := range n.lp.Imports {
			if l.nodes[imp] != nil && !seen[imp] {
				seen[imp] = true
				queue = append(queue, imp)
			}
		}
	}
	return slices.DeleteFunc(slices.Clone(l.order), func(id string) bool { return !seen[id] })
}

func pkgPath(id string) string {
	if i := strings.Index(id, " ["); i >= 0 {
		return id[:i]
	}
	return id
}

func fileList(lp *listPkg) []string {
	seen := map[string]bool{}
	var out []string
	add := func(names []string) {
		for _, f := range names {
			p := filepath.Join(lp.Dir, f)
			if !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	add(lp.GoFiles)
	add(lp.CgoFiles)
	if lp.ForTest != "" {
		if strings.HasSuffix(lp.Name, "_test") {
			add(lp.XTestGoFiles)
		} else if strings.HasPrefix(lp.ImportPath, lp.ForTest+" [") {
			add(lp.TestGoFiles)
		}
	}
	return out
}

type importerFunc func(path string) (*types.Package, error)

func (f importerFunc) Import(path string) (*types.Package, error) { return f(path) }

func (l *loader) check(id string) (*types.Package, error) {
	if id == "unsafe" {
		return types.Unsafe, nil
	}
	n := l.nodes[id]
	if n == nil {
		return nil, fmt.Errorf("package %s is not in the go list output", id)
	}
	if n.done {
		return n.tpkg, nil
	}
	if err := l.ctx.Err(); err != nil {
		return nil, err
	}
	n.done = true
	files, first := l.parse(n)
	if n.lp.Error != nil {
		first = errors.New("go list: " + n.lp.Error.Err)
	}
	record := n.ws && !n.itv
	conf := types.Config{
		FakeImportC:      true,
		IgnoreFuncBodies: !record,
		Sizes:            l.sizes,
		Error: func(err error) {
			if first == nil {
				first = err
			}
		},
		Importer: importerFunc(func(path string) (*types.Package, error) {
			if m, ok := n.lp.ImportMap[path]; ok {
				path = m
			}
			return l.check(path)
		}),
	}
	if n.lp.Module != nil && n.lp.Module.GoVersion != "" {
		conf.GoVersion = "go" + n.lp.Module.GoVersion
	}
	var info *types.Info
	if record {
		info = &types.Info{Defs: map[*ast.Ident]types.Object{}, Uses: map[*ast.Ident]types.Object{}}
		if l.hook != nil {
			info.Implicits = map[ast.Node]types.Object{}
		}
	}
	n.tpkg, _ = conf.Check(pkgPath(id), l.fset, files, info)
	if err := l.ctx.Err(); err != nil {
		return nil, err
	}
	if record {
		n.problem = ""
		if first != nil {
			n.problem = clip(strings.ReplaceAll(first.Error(), "\n", " "))
		}
		if l.hook != nil {
			l.hook(n, files, info)
		}
		l.record(n, info, first != nil)
	} else if !n.ws {
		if pe := (&pkgEntry{id: id, path: pkgPath(id), types: l.packageTypes(n.tpkg)}); len(pe.types) > 0 {
			l.st.deps = append(l.st.deps, pe)
			l.st.byPkgPath[pe.path] = pe
		}
	}
	return n.tpkg, nil
}

func (l *loader) parse(n *node) ([]*ast.File, error) {
	parsed := make([]*parsedFile, len(n.names))
	var wg sync.WaitGroup
	for i, name := range n.names {
		if pf := l.wsFiles[name]; n.ws && pf != nil {
			parsed[i] = pf
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			parsed[i] = l.parseFile(name, n.ws)
		}()
	}
	wg.Wait()
	var first error
	files := make([]*ast.File, 0, len(parsed))
	for i, pf := range parsed {
		maps.Copy(l.cols, pf.cols)
		pf.cols = nil
		if n.ws && l.wsFiles[n.names[i]] == nil {
			l.wsFiles[n.names[i]] = pf
			l.build[n.names[i]] = buildLines(pf)
		}
		if first == nil {
			first = pf.err
		}
		if pf.file != nil {
			files = append(files, pf.file)
		}
	}
	return files, first
}

func (l *loader) parseFile(name string, ws bool) *parsedFile {
	pf := &parsedFile{}
	if src, ok := l.overlayFor(name); ok {
		pf.src = src
	} else {
		pf.src, pf.err = os.ReadFile(name)
	}
	if pf.err == nil {
		pf.file, pf.err = parser.ParseFile(l.fset, name, pf.src, parser.SkipObjectResolution)
	}
	if !ws {
		if pf.file != nil {
			pf.cols = utf16Cols(l.fset, pf.file, pf.src)
		}
		pf.src = nil
		if pf.file != nil {
			for _, d := range pf.file.Decls {
				if fd, ok := d.(*ast.FuncDecl); ok {
					fd.Body = nil
				}
			}
		}
	}
	return pf
}

func (l *loader) overlayFor(name string) ([]byte, bool) {
	if l.overlay == nil {
		return nil, false
	}
	return l.overlay(name)
}

func stageListOverlay(dir string, paths []string, overlay func(string) ([]byte, bool)) (string, func(), error) {
	if len(paths) == 0 || overlay == nil {
		return "", nil, nil
	}
	cleanDir := filepath.Clean(dir)
	prefix := cleanDir + string(filepath.Separator)
	type stagedBuf struct {
		orig string
		buf  []byte
	}
	var pending []stagedBuf
	seen := make(map[string]bool, len(paths))
	for _, rawPath := range paths {
		p := filepath.Clean(rawPath)
		if seen[p] || filepath.Ext(p) != ".go" || !strings.HasPrefix(p, prefix) {
			continue
		}
		seen[p] = true
		buf, ok := overlay(p)
		if !ok {
			continue
		}
		disk, diskErr := os.ReadFile(p)
		if !goListNeedsOverlay(disk, diskErr, buf) {
			continue
		}
		pending = append(pending, stagedBuf{orig: p, buf: buf})
	}
	if len(pending) == 0 {
		return "", nil, nil
	}
	tmpDir, err := os.MkdirTemp("", "golens-uistage-*")
	if err != nil {
		return "", nil, err
	}
	cleanup := func() { _ = os.RemoveAll(tmpDir) }
	replace := make(map[string]string, len(pending))
	for i, item := range pending {
		stagedFile := filepath.Join(tmpDir, fmt.Sprintf("%d_%s", i, filepath.Base(item.orig)))
		if err := os.WriteFile(stagedFile, item.buf, 0o600); err != nil {
			cleanup()
			return "", nil, err
		}
		replace[item.orig] = stagedFile
	}
	overlayBytes, err := json.Marshal(struct {
		Replace map[string]string `json:"Replace"`
	}{Replace: replace})
	if err != nil {
		cleanup()
		return "", nil, err
	}
	overlayPath := filepath.Join(tmpDir, "overlay.json")
	if err := os.WriteFile(overlayPath, overlayBytes, 0o600); err != nil {
		cleanup()
		return "", nil, err
	}
	return overlayPath, cleanup, nil
}

func goListNeedsOverlay(disk []byte, diskErr error, buf []byte) bool {
	if diskErr != nil {
		return true
	}
	if bytes.Equal(disk, buf) {
		return false
	}
	diskKey, ok1 := parseGoListHeaderKey(disk)
	bufKey, ok2 := parseGoListHeaderKey(buf)
	if !ok1 || !ok2 {
		return true
	}
	return diskKey != bufKey
}

func parseGoListHeaderKey(src []byte) (string, bool) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "", src, parser.ImportsOnly|parser.ParseComments)
	if err != nil || f == nil {
		return "", false
	}
	var sb strings.Builder
	sb.WriteString(buildLines(&parsedFile{file: f, src: src}))
	sb.WriteString("pkg:")
	sb.WriteString(f.Name.Name)
	sb.WriteByte('\n')
	imps := make([]string, 0, len(f.Imports))
	for _, imp := range f.Imports {
		if imp != nil && imp.Path != nil {
			imps = append(imps, imp.Path.Value)
		}
	}
	slices.Sort(imps)
	for _, v := range imps {
		sb.WriteString("imp:")
		sb.WriteString(v)
		sb.WriteByte('\n')
	}
	return sb.String(), true
}

func buildLines(pf *parsedFile) string {
	if pf.file == nil || !pf.file.Package.IsValid() {
		return ""
	}
	var b strings.Builder
	for line := range strings.Lines(string(pf.src[:pf.file.Package-pf.file.FileStart])) {
		line = strings.TrimSpace(line)
		if constraint.IsGoBuild(line) || constraint.IsPlusBuild(line) {
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func (l *loader) forget(parsed map[string]*parsedFile) {
	for _, pf := range parsed {
		if pf.file != nil {
			l.fset.RemoveFile(l.fset.File(pf.file.FileStart))
		}
	}
}

func (l *loader) update(ctx context.Context, parsed map[string]*parsedFile, mu sync.Locker) (bool, error) {
	l.ctx = ctx
	st := l.st
	prevFiles := map[string]*parsedFile{}
	for name, pf := range parsed {
		prevFiles[name] = l.wsFiles[name]
		l.wsFiles[name] = pf
	}
	prevPkgs := map[*node]*types.Package{}
	rollback := func() {
		for name, pf := range prevFiles {
			l.wsFiles[name] = pf
		}
		for n, tpkg := range prevPkgs {
			n.tpkg, n.done = tpkg, true
		}
		l.forget(parsed)
		l.reset()
	}

	affected := map[int]bool{}
	var queue []int
	for name, pf := range parsed {
		fe := st.files[name]
		if pf.err == nil {
			if pf.file.Name.Name != l.nodes[st.pkgs[fe.owner].id].lp.Name || buildLines(pf) != l.build[name] {
				rollback()
				return false, nil
			}
		}
		queue = append(queue, fe.pkgs...)
	}
	for _, p := range queue {
		if !l.checkImports(l.nodes[st.pkgs[p].id]) {
			rollback()
			return false, nil
		}
	}
	for len(queue) > 0 {
		p := queue[len(queue)-1]
		queue = queue[:len(queue)-1]
		if !affected[p] {
			affected[p] = true
			queue = append(queue, st.pkgs[p].importedBy...)
		}
	}

	var ids []string
	for _, id := range l.order {
		if n := l.nodes[id]; n.ws && affected[n.pkg] {
			ids = append(ids, id)
			prevPkgs[n] = n.tpkg
			n.done = false
		}
	}
	for _, id := range ids {
		if _, err := l.check(id); err != nil {
			rollback()
			return false, err
		}
	}
	if err := ctx.Err(); err != nil {
		rollback()
		return false, err
	}
	mu.Lock()
	l.commit()
	mu.Unlock()
	l.forget(prevFiles)
	return true, nil
}

func (l *loader) checkImports(n *node) bool {
	if n.lp.Error != nil {
		return false
	}
	now := map[string]bool{}
	for _, name := range n.names {
		pf := l.wsFiles[name]
		if pf.err != nil {
			return true
		}
		for _, is := range pf.file.Imports {
			p, err := strconv.Unquote(is.Path.Value)
			if err != nil || p == "C" {
				continue
			}
			if m, ok := n.lp.ImportMap[p]; ok {
				p = m
			}
			now[p] = true
		}
	}
	for p := range now {
		if !slices.Contains(n.lp.Imports, p) {
			return false
		}
	}
	keep := slices.DeleteFunc(slices.Clone(n.lp.Imports), func(imp string) bool {
		m := l.nodes[imp]
		return m != nil && m.ws && !now[imp]
	})
	if len(keep) < len(n.lp.Imports) {
		l.newImports[n] = keep
	}
	return true
}

func (l *loader) record(n *node, info *types.Info, broken bool) {
	pe := l.st.pkgs[n.pkg]
	if broken && !pe.broken {
		return
	}
	for _, name := range n.names {
		fe := l.st.files[name]
		if fe.owner != n.pkg {
			continue
		}
		r := fileRec{fe: fe, broken: broken, uses: map[string]int{}, ext: map[string]int{}}
		if pf := l.wsFiles[name]; pf.file != nil {
			ast.Inspect(pf.file, func(nd ast.Node) bool {
				if id, ok := nd.(*ast.Ident); ok {
					if obj := info.Uses[id]; obj != nil {
						l.recordUse(&r, obj)
					}
				}
				return true
			})
			r.decls = l.decls(pf, info)
		}
		l.fileRecs = append(l.fileRecs, r)
	}
	l.pkgRecs = append(l.pkgRecs, pkgRec{pe: pe, types: l.packageTypes(n.tpkg), local: l.localImpls(n, info), broken: broken})
}

func (l *loader) packageTypes(pkg *types.Package) map[string]*typeSummary {
	sums := map[string]*typeSummary{}
	scope := pkg.Scope()
	for _, name := range scope.Names() {
		tn, ok := scope.Lookup(name).(*types.TypeName)
		if !ok || tn.IsAlias() {
			continue
		}
		if _, ok := tn.Type().(*types.Named); !ok {
			continue
		}
		if s := l.summarize(tn.Type()); s != nil {
			sums[keyOf(tn)] = s
		}
	}
	return sums
}

func (l *loader) recordUse(r *fileRec, obj types.Object) {
	if obj.Pkg() != nil && l.wsPaths[obj.Pkg().Path()] {
		if k := keyOf(obj); k != "" {
			r.uses[k]++
			return
		}
	}
	fn, ok := obj.(*types.Func)
	if !ok {
		return
	}
	recv := fn.Signature().Recv()
	if recv == nil || !types.IsInterface(recv.Type()) {
		return
	}
	k := l.extKey(fn, recv.Type())
	if k != "" {
		r.ext[k]++
	}
}

func (l *loader) extKey(fn *types.Func, recv types.Type) string {
	k := keyOf(fn)
	sum := l.summarize(recv)
	if sum == nil {
		return ""
	}
	name := methodID(fn)
	if k == "" {
		c := canon(sum)
		id, ok := l.st.ifaceIDs[c]
		if !ok {
			id = fmt.Sprintf("~%d", len(l.st.ifaceIDs))
			l.st.ifaceIDs[c] = id
		}
		k = id + " " + name
	}
	if _, ok := l.st.extRecv[k]; !ok {
		if _, ok := l.newExt[k]; !ok {
			l.newExt[k] = extMethod{name: name, recv: sum}
		}
	}
	return k
}

func (l *loader) decls(pf *parsedFile, info *types.Info) []decl {
	var out []decl
	for _, id := range lensIdents(pf.file) {
		obj := info.Defs[id]
		if obj == nil {
			continue
		}
		d := decl{pos: l.pos(pf.src, id), key: keyOf(obj), exported: obj.Exported()}
		if fn, ok := obj.(*types.Func); ok && fn.Signature().Recv() == nil {
			if d.key == "" && fn.Name() != "init" {
				continue
			}
		} else if tn, method := queryOf(obj); tn == nil {
			continue
		} else if method != nil {
			d.method, d.recv, d.sum = methodID(method), keyOf(tn), l.summarize(tn.Type())
		} else if d.key == "" {
			continue
		} else {
			d.sum = l.summarize(tn.Type())
		}
		out = append(out, d)
	}
	return out
}

func (l *loader) pos(src []byte, id *ast.Ident) Pos {
	loc := identLoc(l.fset.PositionFor(id.Pos(), false), src, id.Name)
	return Pos{Line: loc.Line, Col: loc.Col}
}

func (l *loader) commit() {
	st := l.st
	for _, r := range l.fileRecs {
		addCounts(st.counts, r.fe.uses, -1)
		r.fe.uses, r.fe.ext, r.fe.decls, r.fe.broken = r.uses, r.ext, r.decls, r.broken
		addCounts(st.counts, r.uses, 1)
	}
	for _, r := range l.pkgRecs {
		r.pe.types, r.pe.local, r.pe.broken = r.types, r.local, r.broken
	}
	for k, m := range l.newExt {
		st.extRecv[k] = m
	}
	for n, keep := range l.newImports {
		for _, imp := range n.lp.Imports {
			if m := l.nodes[imp]; m != nil && m.ws && !slices.Contains(keep, imp) {
				pe := st.pkgs[m.pkg]
				pe.importedBy = slices.DeleteFunc(pe.importedBy, func(q int) bool { return q == n.pkg })
			}
		}
		n.lp.Imports = keep
	}
	st.byMethod = map[string][]summaryRef{}
	for i, pe := range st.pkgs {
		for _, s := range pe.types {
			for _, m := range s.methods {
				st.byMethod[m.id] = append(st.byMethod[m.id], summaryRef{i, s})
			}
		}
	}
	l.reset()
}

func (l *loader) reset() {
	l.fileRecs, l.pkgRecs = nil, nil
	clear(l.newExt)
	clear(l.newImports)
	l.sumCache = map[types.Type]*typeSummary{}
}

func addCounts(counts, uses map[string]int, sign int) {
	for k, n := range uses {
		if c := counts[k] + sign*n; c != 0 {
			counts[k] = c
		} else {
			delete(counts, k)
		}
	}
}
