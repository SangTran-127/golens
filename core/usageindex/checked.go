package usageindex

import (
	"context"
	"go/ast"
	"go/token"
	"go/types"
)

type CheckedPackage struct {
	ID         string
	Path       string
	Name       string
	Dir        string
	ForTest    string
	ModulePath string
	ModuleDir  string
	Problem    string
	Files      []*ast.File
	Info       *types.Info
	Types      *types.Package
}

type CheckedWorkspace struct {
	Fset     *token.FileSet
	Packages []*CheckedPackage
	sources  map[string][]byte
	imports  map[string][]string
}

func (w *CheckedWorkspace) Source(path string) []byte { return w.sources[path] }

func (w *CheckedWorkspace) Reaches(from, to string) bool {
	seen := map[string]bool{}
	var visit func(p string) bool
	visit = func(p string) bool {
		if seen[p] {
			return false
		}
		seen[p] = true
		for _, dep := range w.imports[p] {
			if dep == to || visit(dep) {
				return true
			}
		}
		return false
	}
	return visit(from)
}

func CheckWorkspace(ctx context.Context, dir string, opts Options) (*CheckedWorkspace, error) {
	w := &CheckedWorkspace{sources: map[string][]byte{}, imports: map[string][]string{}}
	l, err := loadWithHook(ctx, dir, opts, nil, nil, func(l *loader, n *node, files []*ast.File, info *types.Info) {
		p := &CheckedPackage{
			ID:      n.lp.ImportPath,
			Path:    pkgPath(n.lp.ImportPath),
			Name:    n.lp.Name,
			Dir:     n.lp.Dir,
			ForTest: n.lp.ForTest,
			Problem: n.problem,
			Files:   files,
			Info:    info,
			Types:   n.tpkg,
		}
		if n.lp.Module != nil {
			p.ModulePath = n.lp.Module.Path
			p.ModuleDir = n.lp.Module.Dir
		}
		w.Packages = append(w.Packages, p)
	})
	if err != nil {
		return nil, err
	}
	w.Fset = l.fset
	for name, pf := range l.wsFiles {
		if pf != nil && pf.src != nil {
			w.sources[name] = pf.src
		}
	}
	for id, n := range l.nodes {
		if n.lp.ForTest != "" {
			continue
		}
		from := pkgPath(id)
		for _, imp := range n.lp.Imports {
			if m, ok := n.lp.ImportMap[imp]; ok {
				imp = m
			}
			w.imports[from] = append(w.imports[from], pkgPath(imp))
		}
	}
	return w, nil
}
