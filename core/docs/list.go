package docs

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type Target struct {
	GOOS       string `json:"goos,omitempty"`
	GOARCH     string `json:"goarch,omitempty"`
	Tags       string `json:"tags,omitempty"`
	IncludeStd bool   `json:"includeStd,omitempty"`
}

type Options struct {
	Target                        Target
	Env                           []string
	IncludeStd, IncludeUnexported bool
	Overlay                       map[string]string
	Timeout                       time.Duration
}

type Replacement struct {
	Path    string `json:"path"`
	Version string `json:"version,omitempty"`
	Dir     string `json:"dir,omitempty"`
}

type Module struct {
	Path      string       `json:"path"`
	Version   string       `json:"version,omitempty"`
	Dir       string       `json:"dir,omitempty"`
	Main      bool         `json:"main,omitempty"`
	GoVersion string       `json:"goVersion,omitempty"`
	Replace   *Replacement `json:"replace,omitempty"`
	Source    string       `json:"source"`
	Missing   bool         `json:"missing,omitempty"`
	Error     string       `json:"error,omitempty"`
	ErrorKind string       `json:"errorKind,omitempty"`
}

type Package struct {
	ImportPath     string   `json:"importPath"`
	Name           string   `json:"name,omitempty"`
	Synopsis       string   `json:"synopsis,omitempty"`
	Dir            string   `json:"dir,omitempty"`
	ModulePath     string   `json:"modulePath,omitempty"`
	Origin         string   `json:"origin"`
	Source         string   `json:"source,omitempty"`
	Version        string   `json:"version,omitempty"`
	Error          string   `json:"error,omitempty"`
	ErrorKind      string   `json:"errorKind,omitempty"`
	Missing        bool     `json:"missing,omitempty"`
	MissingModule  string   `json:"missingModule,omitempty"`
	MissingVersion string   `json:"missingVersion,omitempty"`
	GoFiles        []string `json:"goFiles,omitempty"`
	IgnoredGoFiles []string `json:"ignoredGoFiles,omitempty"`
	TestGoFiles    []string `json:"testGoFiles,omitempty"`
	XTestGoFiles   []string `json:"xTestGoFiles,omitempty"`
}

type Index struct {
	Root       string    `json:"root"`
	GoVersion  string    `json:"goVersion"`
	GoWork     string    `json:"goWork,omitempty"`
	GoMod      string    `json:"goMod,omitempty"`
	Vendor     bool      `json:"vendor,omitempty"`
	Target     Target    `json:"target"`
	Modules    []Module  `json:"modules"`
	Packages   []Package `json:"packages"`
	Errors     []string  `json:"errors,omitempty"`
	Generation int64     `json:"generation,omitempty"`
	Cancelled  bool      `json:"cancelled,omitempty"`
	Error      string    `json:"error,omitempty"`
	ErrorKind  string    `json:"errorKind,omitempty"`
}

const (
	OriginProject    = "project"
	OriginDependency = "dependency"
	OriginStdlib     = "stdlib"

	SourceWorkspace    = "workspace"
	SourceModuleCache  = "module-cache"
	SourceLocalReplace = "local-replace"
	SourceVendor       = "vendor"
	SourceStdlib       = "stdlib"

	ErrorKindMissingModule   = "missingModule"
	ErrorKindBuildConstraint = "buildConstraint"
	ErrorKindParseError      = "parseError"
	ErrorKindLoadError       = "loadError"

	listFields = "ImportPath,Name,Doc,Dir,Standard,Module,GoFiles,CgoFiles,IgnoredGoFiles,TestGoFiles,XTestGoFiles,Error,DepsErrors,Incomplete"
)

type listModule struct {
	Path, Version, Dir, GoVersion string
	Main, Indirect                bool
	Replace                       *listModule
	Error                         *struct{ Err string }
}

type listPackage struct {
	ImportPath, Name, Doc, Dir                                   string
	Standard, Incomplete                                         bool
	Module                                                       *listModule
	GoFiles, CgoFiles, IgnoredGoFiles, TestGoFiles, XTestGoFiles []string
	Error                                                        *struct{ Err string }
	DepsErrors                                                   []struct{ Err string }
}

type goEnv struct{ GOWORK, GOMOD, GOVERSION, GOFLAGS, GOOS, GOARCH string }

func ListPackages(ctx context.Context, root string, opts Options) (*Index, error) {
	ctx, cancel := withTimeout(ctx, opts.Timeout)
	defer cancel()
	overlay, cleanup, err := writeOverlay(opts.Overlay)
	if err != nil {
		return nil, err
	}
	defer cleanup()
	env, err := readGoEnv(ctx, root, opts)
	if err != nil {
		return nil, err
	}
	includeStd := opts.IncludeStd || opts.Target.IncludeStd
	idx := &Index{Root: root, GoVersion: env.GOVERSION, Target: Target{GOOS: env.GOOS, GOARCH: env.GOARCH, Tags: opts.Target.Tags, IncludeStd: includeStd}}
	if env.GOWORK != "" && env.GOWORK != "off" {
		idx.GoWork = env.GOWORK
	}
	if env.GOMOD != "" && env.GOMOD != os.DevNull {
		idx.GoMod = env.GOMOD
	}
	if detectVendorDir(root, idx.GoWork) != "" && !strings.Contains(lookupEnv(Environ(opts), "GOFLAGS"), "-mod=") {
		idx.Vendor = true
	}
	useModVendor := idx.Vendor && idx.GoWork != ""
	patterns, err := mainPatterns(ctx, root, opts)
	if err != nil {
		return nil, err
	}
	pkgs, stderr, err := runList(ctx, root, opts, append(append(listArgs(opts, overlay, useModVendor), "-deps"), patterns...))
	if err != nil && len(pkgs) == 0 {
		return nil, err
	}
	if stderr != "" {
		idx.Errors = append(idx.Errors, stderr)
	}
	if includeStd {
		if std, _, serr := runList(ctx, root, opts, append(listArgs(opts, overlay, useModVendor), "std")); serr == nil {
			pkgs = append(pkgs, std...)
		}
	}
	var allMods []listModule
	if !idx.Vendor {
		if all, merr := listAllModules(ctx, root, opts); merr == nil {
			allMods = all
			seenMod := map[string]bool{}
			for _, lp := range pkgs {
				if lp.Module != nil {
					seenMod[lp.Module.Path] = true
				}
			}
			var extraPatterns []string
			for _, lm := range allMods {
				m := convertModule(&lm, "")
				if !lm.Main && m.Dir != "" && (m.Source == SourceLocalReplace || !lm.Indirect) && !seenMod[m.Path] {
					extraPatterns = append(extraPatterns, m.Path+"/...")
				}
			}
			if len(extraPatterns) > 0 {
				if extra, _, eerr := runList(ctx, root, opts, append(listArgs(opts, overlay, false), extraPatterns...)); eerr == nil {
					pkgs = append(pkgs, extra...)
				}
			}
		} else {
			idx.Errors = append(idx.Errors, merr.Error())
		}
	}
	mods := collectIndexModulesAndPackages(idx, pkgs)
	for _, lm := range allMods {
		if m := convertModule(&lm, ""); mods[m.Path] == nil || mods[m.Path].Source != SourceVendor {
			mods[m.Path] = m
		}
	}
	linkPackagesToModules(idx, mods)
	for _, m := range mods {
		idx.Modules = append(idx.Modules, *m)
	}
	sortIndex(idx)
	return idx, nil
}

func collectIndexModulesAndPackages(idx *Index, pkgs []listPackage) map[string]*Module {
	mods, seen := map[string]*Module{}, map[string]bool{}
	for _, lp := range pkgs {
		if seen[lp.ImportPath] {
			continue
		}
		seen[lp.ImportPath] = true
		p := convertPackage(lp)
		if lp.Module != nil {
			m := mods[lp.Module.Path]
			if m == nil {
				m = convertModule(lp.Module, lp.Dir)
				mods[m.Path] = m
			}
			if p.Missing {
				m.Missing, m.ErrorKind, m.Error = true, ErrorKindMissingModule, firstNonEmpty(m.Error, p.Error)
			}
			if m.Source == SourceVendor {
				idx.Vendor = true
			}
		}
		idx.Packages = append(idx.Packages, p)
	}
	return mods
}

func linkPackagesToModules(idx *Index, mods map[string]*Module) {
	for i := range idx.Packages {
		p := &idx.Packages[i]
		if p.Origin == OriginStdlib {
			p.Source = SourceStdlib
			continue
		}
		if p.ModulePath == "" && p.Origin == OriginDependency {
			p.ModulePath = owningModule(p.ImportPath, mods)
		}
		if m := mods[p.ModulePath]; m != nil {
			p.Source, p.Version = m.Source, m.Version
			if m.Missing && p.Origin == OriginDependency {
				p.Missing, p.ErrorKind = true, ErrorKindMissingModule
				p.MissingModule, p.MissingVersion = firstNonEmpty(p.MissingModule, m.Path), firstNonEmpty(p.MissingVersion, m.Version)
			}
		} else if p.Missing && p.MissingModule == "" {
			p.MissingModule, p.MissingVersion = extractMissingModSpec(p.Error)
		}
	}
}

func listAllModules(ctx context.Context, root string, opts Options) ([]listModule, error) {
	out, stderr, err := runGo(ctx, root, opts, []string{"list", "-m", "-e", "-json", "all"})
	if err != nil && len(out) == 0 {
		return nil, fmt.Errorf("go list -m all: %s", firstNonEmpty(stderr, err.Error()))
	}
	dec := json.NewDecoder(bytes.NewReader(out))
	var mods []listModule
	for {
		var m listModule
		if dec.Decode(&m) != nil {
			break
		}
		mods = append(mods, m)
	}
	return mods, nil
}

func owningModule(importPath string, mods map[string]*Module) string {
	best := ""
	for path := range mods {
		if (importPath == path || strings.HasPrefix(importPath, path+"/")) && len(path) > len(best) {
			best = path
		}
	}
	return best
}

func convertPackage(lp listPackage) Package {
	p := Package{
		ImportPath: lp.ImportPath, Name: lp.Name, Synopsis: lp.Doc, Dir: lp.Dir,
		GoFiles:        append(append([]string{}, lp.GoFiles...), lp.CgoFiles...),
		IgnoredGoFiles: lp.IgnoredGoFiles, TestGoFiles: lp.TestGoFiles, XTestGoFiles: lp.XTestGoFiles,
	}
	switch {
	case lp.Standard:
		p.Origin, p.Source = OriginStdlib, SourceStdlib
	case lp.Module != nil && lp.Module.Main:
		p.Origin, p.Source = OriginProject, SourceWorkspace
	default:
		p.Origin = OriginDependency
	}
	if lp.Module != nil {
		p.ModulePath, p.Version = lp.Module.Path, lp.Module.Version
	}
	if lp.Error != nil {
		p.Error = strings.TrimSpace(lp.Error.Err)
		p.ErrorKind = classifyLoadError(p.Error, len(p.GoFiles), len(p.IgnoredGoFiles))
		p.Missing = p.ErrorKind == ErrorKindMissingModule || (lp.Dir == "" && lp.Module != nil && !lp.Module.Main && p.ErrorKind != ErrorKindBuildConstraint)
		if p.Missing {
			p.ErrorKind = ErrorKindMissingModule
			if lp.Module != nil {
				p.MissingModule, p.MissingVersion = lp.Module.Path, lp.Module.Version
			}
			if p.MissingModule == "" {
				p.MissingModule, p.MissingVersion = extractMissingModSpec(p.Error)
			}
		}
	} else if len(p.GoFiles) == 0 && len(p.IgnoredGoFiles) > 0 {
		p.ErrorKind = ErrorKindBuildConstraint
	}
	return p
}

func classifyLoadError(msg string, goCount, ignoredCount int) string {
	switch {
	case isMissingSource(msg):
		return ErrorKindMissingModule
	case strings.Contains(msg, "build constraints exclude all Go files"), strings.Contains(msg, "no buildable Go source files"), goCount == 0 && ignoredCount > 0:
		return ErrorKindBuildConstraint
	case strings.Contains(msg, "expected '"), strings.Contains(msg, "syntax error"):
		return ErrorKindParseError
	case msg != "":
		return ErrorKindLoadError
	default:
		return ""
	}
}

func extractMissingModSpec(msg string) (string, string) {
	if idx := strings.Index(msg, ": module lookup disabled"); idx > 0 {
		if fields := strings.Fields(strings.TrimSpace(msg[:idx])); len(fields) > 0 {
			if mod, ver, ok := strings.Cut(fields[len(fields)-1], "@"); ok {
				return mod, ver
			}
			return fields[len(fields)-1], ""
		}
	}
	for _, marker := range []string{"no required module provides package ", "cannot find module providing package "} {
		if idx := strings.Index(msg, marker); idx >= 0 {
			if fields := strings.Fields(strings.TrimSpace(msg[idx+len(marker):])); len(fields) > 0 {
				return strings.Trim(fields[0], ":\"'"), ""
			}
		}
	}
	return "", ""
}

func isMissingSource(msg string) bool {
	for _, s := range []string{"GOPROXY=off", "module lookup disabled", "missing go.sum entry", "no required module provides", "not in std", "cannot find module providing", "-mod=mod"} {
		if strings.Contains(msg, s) {
			return true
		}
	}
	return false
}

func convertModule(lm *listModule, pkgDir string) *Module {
	m := &Module{Path: lm.Path, Version: lm.Version, Dir: lm.Dir, Main: lm.Main, GoVersion: lm.GoVersion}
	if lm.Error != nil {
		m.Error, m.ErrorKind = lm.Error.Err, classifyLoadError(lm.Error.Err, 0, 0)
	}
	switch {
	case lm.Main:
		m.Source = SourceWorkspace
	case lm.Replace != nil && lm.Replace.Version == "":
		m.Source = SourceLocalReplace
		m.Replace = &Replacement{Path: lm.Replace.Path, Dir: lm.Replace.Dir}
	case lm.Dir == "" && strings.Contains(filepath.ToSlash(pkgDir), "/vendor/"):
		m.Source = SourceVendor
	default:
		m.Source = SourceModuleCache
		if lm.Replace != nil {
			m.Replace = &Replacement{Path: lm.Replace.Path, Version: lm.Replace.Version, Dir: lm.Replace.Dir}
			m.Dir = lm.Replace.Dir
		}
		if m.Dir == "" {
			m.Missing, m.ErrorKind = true, firstNonEmpty(m.ErrorKind, ErrorKindMissingModule)
		}
	}
	return m
}

func mainPatterns(ctx context.Context, root string, opts Options) ([]string, error) {
	out, stderr, err := runGo(ctx, root, opts, []string{"list", "-m", "-e", "-f", "{{.Path}}"})
	if err != nil {
		return nil, fmt.Errorf("go list -m: %s", firstNonEmpty(stderr, err.Error()))
	}
	var pats []string
	for _, line := range strings.Split(string(out), "\n") {
		if line = strings.TrimSpace(line); line != "" && line != "command-line-arguments" {
			pats = append(pats, line+"/...")
		}
	}
	if len(pats) == 0 {
		return []string{"./..."}, nil
	}
	return pats, nil
}

func listArgs(opts Options, overlay string, useModVendor bool) []string {
	args := []string{"list", "-e"}
	if useModVendor {
		args = append(args, "-mod=vendor")
	}
	args = append(args, "-json="+listFields)
	if tags := strings.TrimSpace(opts.Target.Tags); tags != "" {
		args = append(args, "-tags="+tags)
	}
	if overlay != "" {
		args = append(args, "-overlay="+overlay)
	}
	return args
}

func runList(ctx context.Context, root string, opts Options, args []string) ([]listPackage, string, error) {
	out, stderr, err := runGo(ctx, root, opts, args)
	dec := json.NewDecoder(bytes.NewReader(out))
	var pkgs []listPackage
	for {
		var lp listPackage
		if derr := dec.Decode(&lp); derr != nil {
			if !errors.Is(derr, io.EOF) && err == nil {
				err = derr
			}
			break
		}
		pkgs = append(pkgs, lp)
	}
	if err != nil {
		err = fmt.Errorf("go list: %s", firstNonEmpty(stderr, err.Error()))
	}
	return pkgs, stderr, err
}

func readGoEnv(ctx context.Context, root string, opts Options) (goEnv, error) {
	var env goEnv
	out, stderr, err := runGo(ctx, root, opts, []string{"env", "-json", "GOWORK", "GOMOD", "GOVERSION", "GOFLAGS", "GOOS", "GOARCH"})
	if err != nil {
		return env, fmt.Errorf("go env: %s", firstNonEmpty(stderr, err.Error()))
	}
	return env, json.Unmarshal(out, &env)
}
