package docs

import (
	"bytes"
	"context"
	"fmt"
	"go/ast"
	"go/doc"
	"go/doc/comment"
	"go/format"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Position struct {
	File   string `json:"file"`
	Line   int    `json:"line"`
	Column int    `json:"column"`
}

type Example struct {
	Name      string   `json:"name"`
	Suffix    string   `json:"suffix,omitempty"`
	Doc       string   `json:"doc,omitempty"`
	Code      string   `json:"code"`
	Output    string   `json:"output,omitempty"`
	Unordered bool     `json:"unordered,omitempty"`
	Position  Position `json:"position"`
}

type Symbol struct {
	Name      string    `json:"name"`
	Kind      string    `json:"kind"`
	Recv      string    `json:"recv,omitempty"`
	Signature string    `json:"signature"`
	Doc       string    `json:"doc,omitempty"`
	Missing   bool      `json:"missingDoc,omitempty"`
	Generic   bool      `json:"generic,omitempty"`
	Alias     bool      `json:"alias,omitempty"`
	Exported  bool      `json:"exported"`
	Position  Position  `json:"position"`
	Examples  []Example `json:"examples,omitempty"`
	Funcs     []Symbol  `json:"funcs,omitempty"`
	Methods   []Symbol  `json:"methods,omitempty"`
}

type ExcludedSymbol struct {
	Name     string   `json:"name"`
	Kind     string   `json:"kind"`
	Reason   string   `json:"reason"`
	File     string   `json:"file"`
	Build    string   `json:"build,omitempty"`
	Position Position `json:"position"`
}

type PackageDoc struct {
	Root              string           `json:"root,omitempty"`
	Generation        int64            `json:"generation,omitempty"`
	ImportPath        string           `json:"importPath"`
	Name              string           `json:"name"`
	Dir               string           `json:"dir"`
	Origin            string           `json:"origin,omitempty"`
	Source            string           `json:"source,omitempty"`
	ModulePath        string           `json:"modulePath,omitempty"`
	Version           string           `json:"version,omitempty"`
	ReplacePath       string           `json:"replacePath,omitempty"`
	ReplaceDir        string           `json:"replaceDir,omitempty"`
	Synopsis          string           `json:"synopsis,omitempty"`
	Doc               string           `json:"doc,omitempty"`
	Missing           bool             `json:"missingDoc,omitempty"`
	MissingSource     bool             `json:"missingSource,omitempty"`
	MissingModule     string           `json:"missingModule,omitempty"`
	MissingVersion    string           `json:"missingVersion,omitempty"`
	Error             string           `json:"error,omitempty"`
	ErrorKind         string           `json:"errorKind,omitempty"`
	Cancelled         bool             `json:"cancelled,omitempty"`
	IncludeUnexported bool             `json:"includeUnexported,omitempty"`
	Target            Target           `json:"target"`
	FromBuffer        []string         `json:"fromBuffer,omitempty"`
	Consts            []Symbol         `json:"consts,omitempty"`
	Vars              []Symbol         `json:"vars,omitempty"`
	Funcs             []Symbol         `json:"funcs,omitempty"`
	Types             []Symbol         `json:"types,omitempty"`
	Examples          []Example        `json:"examples,omitempty"`
	Excluded          []ExcludedSymbol `json:"excluded,omitempty"`
	ParseErrors       []string         `json:"parseErrors,omitempty"`
}

type PackageError struct {
	Kind, Message, Module, Version string
}

func (e *PackageError) Error() string { return e.Message }

const LinkScheme = "golens-doc"

func LoadPackageDoc(ctx context.Context, root, importPath string, opts Options) (*PackageDoc, error) {
	ctx, cancel := withTimeout(ctx, opts.Timeout)
	defer cancel()
	overlay, cleanup, err := writeOverlay(opts.Overlay)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	env, envErr := readGoEnv(ctx, root, opts)
	useModVendor := envErr == nil && env.GOWORK != "" && env.GOWORK != "off" &&
		hasVendorModules(filepath.Dir(env.GOWORK)) &&
		!strings.Contains(lookupEnv(Environ(opts), "GOFLAGS"), "-mod=")
	pkgs, _, err := runList(ctx, root, opts, append(listArgs(opts, overlay, useModVendor), importPath))
	if len(pkgs) == 0 {
		if err == nil {
			err = fmt.Errorf("package %s not found", importPath)
		}
		return nil, err
	}
	p := convertPackage(pkgs[0])
	target := opts.Target
	if (target.GOOS == "" || target.GOARCH == "") && envErr == nil {
		target.GOOS, target.GOARCH = env.GOOS, env.GOARCH
	}
	if p.Error != "" && len(p.GoFiles) == 0 {
		out := &PackageDoc{
			Root: root, ImportPath: p.ImportPath, Name: p.Name, Dir: p.Dir, Origin: p.Origin,
			Source: p.Source, ModulePath: p.ModulePath, Version: p.Version, Target: target,
			Error: p.Error, ErrorKind: p.ErrorKind, MissingSource: p.Missing,
			MissingModule: p.MissingModule, MissingVersion: p.MissingVersion,
			IncludeUnexported: opts.IncludeUnexported,
		}
		if len(p.IgnoredGoFiles) > 0 && p.Dir != "" {
			out.Excluded = append(out.Excluded, excluded(p.Dir, p.Name, p.IgnoredGoFiles, "build-constraint", target, map[string]bool{}, opts.Overlay)...)
			out.Excluded = append(out.Excluded, excluded(p.Dir, p.Name, p.TestGoFiles, "test-only", target, map[string]bool{}, opts.Overlay)...)
			out.ErrorKind = ErrorKindBuildConstraint
			return out, &PackageError{Kind: ErrorKindBuildConstraint, Message: p.Error}
		}
		return out, &PackageError{Kind: p.ErrorKind, Message: p.Error, Module: p.MissingModule, Version: p.MissingVersion}
	}
	return BuildPackageDocWithOptions(p, target, opts)
}

func BuildPackageDoc(p Package, target Target, overlay map[string]string) (*PackageDoc, error) {
	return BuildPackageDocWithOptions(p, target, Options{Target: target, Overlay: overlay})
}

func BuildPackageDocWithOptions(p Package, target Target, opts Options) (*PackageDoc, error) {
	fset := token.NewFileSet()
	allowUnexported := opts.IncludeUnexported && (p.Origin == OriginProject || p.Source == SourceLocalReplace)
	out := &PackageDoc{
		ImportPath: p.ImportPath, Name: p.Name, Dir: p.Dir, Origin: p.Origin, Source: p.Source,
		ModulePath: p.ModulePath, Version: p.Version, Target: target, IncludeUnexported: allowUnexported,
	}
	var files []*ast.File
	for _, name := range append(append(append([]string{}, p.GoFiles...), p.TestGoFiles...), p.XTestGoFiles...) {
		path := filepath.Join(p.Dir, name)
		var src any
		if content, ok := lookupOverlay(opts.Overlay, path); ok {
			src = content
			out.FromBuffer = append(out.FromBuffer, path)
		}
		f, err := parser.ParseFile(fset, path, src, parser.ParseComments)
		if err != nil {
			out.ParseErrors = append(out.ParseErrors, err.Error())
		}
		if f != nil && (err == nil || !strings.HasSuffix(name, "_test.go")) {
			files = append(files, f)
		}
	}
	if len(files) == 0 {
		if len(out.ParseErrors) > 0 {
			out.ErrorKind, out.Error = ErrorKindParseError, out.ParseErrors[0]
		}
		return out, fmt.Errorf("no Go files for %s", p.ImportPath)
	}
	var mode doc.Mode
	if allowUnexported {
		mode = doc.AllDecls
	}
	dp, err := doc.NewFromFiles(fset, files, p.ImportPath, mode)
	if err != nil {
		return out, err
	}
	r := renderer{fset: fset, pkg: dp}
	out.Name, out.Doc, out.Synopsis = dp.Name, r.markdown(dp.Doc), dp.Synopsis(dp.Doc)
	out.Missing = strings.TrimSpace(dp.Doc) == ""
	out.Examples = r.examples(dp.Examples)
	out.Consts, out.Vars, out.Funcs = r.values(dp.Consts, "const"), r.values(dp.Vars, "var"), r.funcs(dp.Funcs, "func")
	for _, t := range dp.Types {
		out.Types = append(out.Types, r.typ(t))
	}
	if len(out.ParseErrors) > 0 {
		out.ErrorKind = ErrorKindParseError
	}
	included := map[string]bool{}
	for _, s := range allSymbols(out) {
		included[s] = true
	}
	out.Excluded = append(out.Excluded, excluded(p.Dir, p.Name, p.IgnoredGoFiles, "build-constraint", target, included, opts.Overlay)...)
	out.Excluded = append(out.Excluded, excluded(p.Dir, p.Name, p.TestGoFiles, "test-only", target, included, opts.Overlay)...)
	return out, nil
}

func allSymbols(pd *PackageDoc) []string {
	var names []string
	add := func(ss []Symbol) {
		for _, s := range ss {
			names = append(names, s.Name)
		}
	}
	add(pd.Consts)
	add(pd.Vars)
	add(pd.Funcs)
	for _, t := range pd.Types {
		names = append(names, t.Name)
		add(t.Funcs)
		for _, m := range t.Methods {
			names = append(names, t.Name+"."+m.Name)
		}
	}
	for _, c := range pd.Consts {
		names = append(names, strings.Split(c.Name, ", ")...)
	}
	for _, v := range pd.Vars {
		names = append(names, strings.Split(v.Name, ", ")...)
	}
	return names
}

func excluded(dir, pkgName string, names []string, reason string, target Target, included map[string]bool, overlay map[string]string) []ExcludedSymbol {
	var out []ExcludedSymbol
	for _, name := range names {
		path := filepath.Join(dir, name)
		var src any
		if content, ok := lookupOverlay(overlay, path); ok {
			src = content
		}
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, path, src, parser.ParseComments)
		if err != nil || f.Name == nil || (pkgName != "" && f.Name.Name != pkgName) || (pkgName == "" && strings.HasSuffix(f.Name.Name, "_test")) {
			continue
		}
		build := buildExpr(f)
		if reason == "build-constraint" && build == "" {
			build = filenameConstraint(name)
		}
		for _, decl := range f.Decls {
			for _, s := range declNames(decl) {
				if !allExported(s.name) || included[s.name] || (reason == "test-only" && s.kind == "func" && isTestFunc(s.name)) {
					continue
				}
				out = append(out, ExcludedSymbol{Name: s.name, Kind: s.kind, Reason: reason, File: path, Build: build, Position: pos(fset, s.pos)})
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

type renderer struct {
	fset *token.FileSet
	pkg  *doc.Package
}

func (r renderer) markdown(text string) string {
	if strings.TrimSpace(text) == "" {
		return ""
	}
	p := r.pkg.Printer()
	p.DocLinkURL = func(link *comment.DocLink) string {
		path := firstNonEmpty(link.ImportPath, r.pkg.ImportPath)
		name := link.Name
		if link.Recv != "" {
			name = link.Recv + "." + name
		}
		if name != "" {
			return LinkScheme + ":" + path + "#" + name
		}
		return LinkScheme + ":" + path
	}
	return strings.TrimSpace(string(p.Markdown(r.pkg.Parser().Parse(text))))
}

func (r renderer) node(n any) string {
	var b bytes.Buffer
	cfg := printer.Config{Mode: printer.UseSpaces | printer.TabIndent, Tabwidth: 8}
	if err := cfg.Fprint(&b, r.fset, n); err != nil {
		return ""
	}
	return b.String()
}

func (r renderer) symbol(name, kind, text string, decl ast.Node) Symbol {
	return Symbol{
		Name: name, Kind: kind, Doc: r.markdown(text), Missing: strings.TrimSpace(text) == "",
		Signature: r.node(decl), Exported: symbolExported(name), Position: pos(r.fset, decl.Pos()),
	}
}

func symbolExported(name string) bool {
	for _, item := range strings.Split(name, ", ") {
		if allExported(strings.TrimSpace(item)) {
			return true
		}
	}
	return false
}

func (r renderer) values(vals []*doc.Value, kind string) []Symbol {
	var out []Symbol
	for _, v := range vals {
		d := *v.Decl
		d.Doc = nil
		out = append(out, r.symbol(strings.Join(v.Names, ", "), kind, v.Doc, &d))
	}
	return out
}

func (r renderer) funcs(fs []*doc.Func, kind string) []Symbol {
	var out []Symbol
	for _, f := range fs {
		d := *f.Decl
		d.Doc, d.Body = nil, nil
		k := kind
		if f.Recv != "" {
			k = "method"
		}
		s := r.symbol(f.Name, k, f.Doc, &d)
		s.Recv, s.Generic, s.Examples = f.Recv, d.Type.TypeParams != nil && len(d.Type.TypeParams.List) > 0, r.examples(f.Examples)
		out = append(out, s)
	}
	return out
}

func (r renderer) typ(t *doc.Type) Symbol {
	d := *t.Decl
	d.Doc = nil
	var matched *ast.TypeSpec
	for _, spec := range t.Decl.Specs {
		if ts, ok := spec.(*ast.TypeSpec); ok && ts.Name.Name == t.Name {
			matched = ts
			break
		}
	}
	var declNode ast.Node = &d
	if matched != nil && len(t.Decl.Specs) > 1 {
		tsCopy := *matched
		tsCopy.Doc = nil
		declNode = &ast.GenDecl{TokPos: t.Decl.TokPos, Tok: token.TYPE, Specs: []ast.Spec{&tsCopy}}
	}
	s := r.symbol(t.Name, "type", t.Doc, declNode)
	if matched != nil {
		s.Alias, s.Generic = matched.Assign.IsValid(), matched.TypeParams != nil && len(matched.TypeParams.List) > 0
		if s.Alias {
			s.Kind = "alias"
		}
		s.Position = pos(r.fset, matched.Pos())
	}
	s.Examples, s.Funcs, s.Methods = r.examples(t.Examples), r.funcs(t.Funcs, "func"), r.funcs(t.Methods, "method")
	s.Funcs = append(s.Funcs, append(r.values(t.Consts, "const"), r.values(t.Vars, "var")...)...)
	return s
}

func (r renderer) examples(exs []*doc.Example) []Example {
	var out []Example
	for _, ex := range exs {
		var b bytes.Buffer
		_ = format.Node(&b, r.fset, &printer.CommentedNode{Node: ex.Code, Comments: ex.Comments})
		out = append(out, Example{Name: ex.Name, Suffix: ex.Suffix, Doc: ex.Doc, Code: b.String(), Output: ex.Output, Unordered: ex.Unordered, Position: pos(r.fset, ex.Code.Pos())})
	}
	return out
}

func pos(fset *token.FileSet, p token.Pos) Position {
	ps := fset.Position(p)
	return Position{File: ps.Filename, Line: ps.Line, Column: ps.Column}
}

func originRank(o string) int {
	switch o {
	case OriginProject:
		return 0
	case OriginDependency:
		return 1
	}
	return 2
}

func sortIndex(idx *Index) {
	sort.Slice(idx.Modules, func(i, j int) bool {
		if idx.Modules[i].Main != idx.Modules[j].Main {
			return idx.Modules[i].Main
		}
		return idx.Modules[i].Path < idx.Modules[j].Path
	})
	sort.Slice(idx.Packages, func(i, j int) bool {
		if oi, oj := originRank(idx.Packages[i].Origin), originRank(idx.Packages[j].Origin); oi != oj {
			return oi < oj
		}
		return idx.Packages[i].ImportPath < idx.Packages[j].ImportPath
	})
}

func ReadSourceStamp(dir string, names []string) string {
	var b strings.Builder
	for _, n := range names {
		if fi, err := os.Stat(filepath.Join(dir, n)); err == nil {
			fmt.Fprintf(&b, "%s:%d:%d;", n, fi.Size(), fi.ModTime().UnixNano())
		}
	}
	return b.String()
}

func detectVendorDir(root, goWork string) string {
	for _, base := range []string{root, filepath.Dir(goWork)} {
		if base != "" && base != "." {
			if _, err := os.Stat(filepath.Join(base, "vendor", "modules.txt")); err == nil {
				return filepath.Join(base, "vendor")
			}
		}
	}
	return ""
}
