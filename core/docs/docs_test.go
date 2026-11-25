package docs

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixture(t *testing.T, name string) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func requireGo(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go tool not available")
	}
}

func findPackage(t *testing.T, idx *Index, path string) Package {
	t.Helper()
	for _, p := range idx.Packages {
		if p.ImportPath == path {
			return p
		}
	}
	t.Fatalf("package %s not in index", path)
	return Package{}
}

func findModule(t *testing.T, idx *Index, path string) Module {
	t.Helper()
	for _, m := range idx.Modules {
		if m.Path == path {
			return m
		}
	}
	t.Fatalf("module %s not in index", path)
	return Module{}
}

func findSymbol(ss []Symbol, name string) *Symbol {
	for i := range ss {
		if ss[i].Name == name {
			return &ss[i]
		}
	}
	return nil
}

func excludedNames(pd *PackageDoc, reason string) map[string]string {
	out := map[string]string{}
	for _, e := range pd.Excluded {
		if e.Reason == reason {
			out[e.Name] = e.Build
		}
	}
	return out
}

func loadDoc(t *testing.T, root, path string, opts Options) *PackageDoc {
	t.Helper()
	pd, err := LoadPackageDoc(context.Background(), root, path, opts)
	if err != nil {
		t.Fatalf("LoadPackageDoc(%s): %v", path, err)
	}
	return pd
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func copyDir(t *testing.T, src, dst string) {
	t.Helper()
	must(t, os.MkdirAll(dst, 0o755))
	entries, err := os.ReadDir(src)
	must(t, err)
	for _, e := range entries {
		data, err := os.ReadFile(filepath.Join(src, e.Name()))
		must(t, err)
		must(t, os.WriteFile(filepath.Join(dst, e.Name()), data, 0o644))
	}
}

func goCmd(t *testing.T, dir string, env []string, args ...string) {
	t.Helper()
	cmd := exec.Command("go", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), env...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go %v: %v\n%s", args, err, out)
	}
}

func writeProxyModule(t *testing.T, proxy, srcDir, version string) {
	t.Helper()
	base := filepath.Join(proxy, "example.com", "pdep", "@v")
	must(t, os.MkdirAll(base, 0o755))
	mod, err := os.ReadFile(filepath.Join(srcDir, "go.mod"))
	must(t, err)
	must(t, os.WriteFile(filepath.Join(base, version+".mod"), mod, 0o644))
	must(t, os.WriteFile(filepath.Join(base, version+".info"), []byte(`{"Version":"`+version+`"}`), 0o644))
	f, err := os.Create(filepath.Join(base, version+".zip"))
	must(t, err)
	zw := zip.NewWriter(f)
	entries, _ := os.ReadDir(srcDir)
	for _, e := range entries {
		data, err := os.ReadFile(filepath.Join(srcDir, e.Name()))
		must(t, err)
		w, err := zw.Create("example.com/pdep@" + version + "/" + e.Name())
		must(t, err)
		_, err = w.Write(data)
		must(t, err)
	}
	must(t, zw.Close())
	must(t, f.Close())
	list, _ := os.ReadFile(filepath.Join(base, "list"))
	must(t, os.WriteFile(filepath.Join(base, "list"), append(list, []byte(version+"\n")...), 0o644))
}

func TestSingleModuleAndBuildTargets(t *testing.T) {
	requireGo(t)
	root := fixture(t, "single")
	idx, err := ListPackages(context.Background(), root, Options{Target: Target{GOOS: "darwin", GOARCH: "arm64"}})
	must(t, err)
	p := findPackage(t, idx, "example.com/single/shapes")
	if p.Origin != OriginProject || p.ModulePath != "example.com/single" || !strings.HasPrefix(p.Synopsis, "Package shapes provides") {
		t.Fatalf("unexpected package %+v", p)
	}
	if m := findModule(t, idx, "example.com/single"); !m.Main || m.Source != SourceWorkspace {
		t.Fatalf("module %+v", m)
	}
	darwin := loadDoc(t, root, "example.com/single/shapes", Options{Target: Target{GOOS: "darwin", GOARCH: "arm64"}})
	if findSymbol(darwin.Funcs, "DarwinOnly") == nil || findSymbol(darwin.Funcs, "LinuxOnly") != nil {
		t.Fatalf("darwin funcs wrong: %+v", darwin.Funcs)
	}
	if ex := excludedNames(darwin, "build-constraint"); ex["LinuxOnly"] != "linux" || ex["ProOnly"] != "pro" {
		t.Fatalf("excluded %+v", darwin.Excluded)
	}
	if _, ok := excludedNames(darwin, "test-only")["HelperForTests"]; !ok {
		t.Fatalf("test-only symbol missing: %+v", darwin.Excluded)
	}
	linux := loadDoc(t, root, "example.com/single/shapes", Options{Target: Target{GOOS: "linux", GOARCH: "amd64", Tags: "pro"}})
	if findSymbol(linux.Funcs, "LinuxOnly") == nil || findSymbol(linux.Funcs, "ProOnly") == nil || findSymbol(linux.Funcs, "DarwinOnly") != nil {
		t.Fatalf("linux funcs wrong: %+v", linux.Funcs)
	}
	if excludedNames(linux, "build-constraint")["DarwinOnly"] != "darwin" {
		t.Fatalf("linux excluded %+v", linux.Excluded)
	}
}

func TestGenericsAliasesExamplesLinksAndFieldComments(t *testing.T) {
	requireGo(t)
	pd := loadDoc(t, fixture(t, "single"), "example.com/single/shapes", Options{})
	sq := findSymbol(pd.Types, "Square")
	if sq == nil || !strings.Contains(sq.Signature, "// S is the side length.") || !strings.Contains(sq.Signature, "// length in units") {
		t.Fatalf("Square signature missed struct field comments: %+v", sq)
	}
	if m := findSymbol(pd.Funcs, "Map"); m == nil || !m.Generic || !strings.Contains(m.Signature, "func Map[S ~[]E, E, R any]") {
		t.Fatalf("Map %+v", m)
	}
	box := findSymbol(pd.Types, "Box")
	if box == nil || !box.Generic || findSymbol(box.Funcs, "NewBox") == nil || findSymbol(box.Methods, "Get") == nil {
		t.Fatalf("Box %+v", box)
	}
	for _, name := range []string{"Polygon", "IntBox"} {
		if a := findSymbol(pd.Types, name); a == nil || !a.Alias || a.Kind != "alias" {
			t.Fatalf("alias %s %+v", name, a)
		}
	}
	if len(pd.Examples) != 1 || pd.Examples[0].Output != "64\n" {
		t.Fatalf("package examples %+v", pd.Examples)
	}
	for _, want := range []string{"golens-doc:example.com/single/shapes#Area", "golens-doc:example.com/single/shapes#Box.Get", "golens-doc:strings#Cut"} {
		if !strings.Contains(pd.Doc, want) {
			t.Fatalf("doc %q missing %q", pd.Doc, want)
		}
	}
	if findSymbol(pd.Funcs, "helper") != nil {
		t.Fatal("unexported symbol leaked when IncludeUnexported is false")
	}
	unexp := loadDoc(t, fixture(t, "single"), "example.com/single/shapes", Options{IncludeUnexported: true})
	if h := findSymbol(unexp.Funcs, "helper"); h == nil || h.Exported {
		t.Fatalf("expected unexported helper with IncludeUnexported: %+v", h)
	}
}

func TestWorkspacesLocalReplaceVendorAndMissingDocs(t *testing.T) {
	requireGo(t)
	nodoc := loadDoc(t, fixture(t, "single"), "example.com/single/nodoc", Options{})
	if !nodoc.Missing || findSymbol(nodoc.Funcs, "Exported") == nil || !findSymbol(nodoc.Funcs, "Exported").Missing {
		t.Fatalf("nodoc %+v", nodoc)
	}
	workIdx, err := ListPackages(context.Background(), fixture(t, "work"), Options{})
	must(t, err)
	if !strings.HasSuffix(workIdx.GoWork, "go.work") || findPackage(t, workIdx, "example.com/b/util").Origin != OriginProject {
		t.Fatalf("workIdx %+v", workIdx)
	}
	repRoot := fixture(t, "replace/app")
	repIdx, err := ListPackages(context.Background(), repRoot, Options{})
	must(t, err)
	if m := findModule(t, repIdx, "example.com/dep"); m.Source != SourceLocalReplace || m.Version != "v1.4.0" {
		t.Fatalf("replace module %+v", m)
	}
	venIdx, err := ListPackages(context.Background(), fixture(t, "vendored"), Options{Env: []string{"GOMODCACHE=" + t.TempDir()}})
	must(t, err)
	if m := findModule(t, venIdx, "example.com/vdep"); m.Source != SourceVendor || m.Version != "v1.2.0" || !venIdx.Vendor {
		t.Fatalf("vendor module %+v", m)
	}
	wvRoot := fixture(t, "workvendor")
	wvIdx, err := ListPackages(context.Background(), wvRoot, Options{Env: []string{"GOMODCACHE=" + t.TempDir()}})
	must(t, err)
	if !wvIdx.Vendor || wvIdx.GoWork == "" {
		t.Fatalf("workvendor flags wrong: %+v", wvIdx)
	}
	if p := findPackage(t, wvIdx, "example.com/wvdep"); p.Source != SourceVendor || p.Missing {
		t.Fatalf("workvendor pkg %+v", p)
	}
	wvDoc := loadDoc(t, wvRoot, "example.com/wvdep", Options{Env: []string{"GOMODCACHE=" + t.TempDir()}})
	if findSymbol(wvDoc.Funcs, "Hello") == nil {
		t.Fatalf("workvendor Hello missing %+v", wvDoc)
	}
}

func TestOverlayStdlibEffectiveVersionAndMissingCache(t *testing.T) {
	requireGo(t)
	root := fixture(t, "work")
	file := filepath.Join(root, "b", "util", "util.go")
	buf := "package util\n\n// Greet from buffer.\nfunc Greet(name string) string { return name }\n\nfunc Farewell() {}\n"
	pd := loadDoc(t, root, "example.com/b/util", Options{Overlay: map[string]string{file: buf}})
	if g := findSymbol(pd.Funcs, "Greet"); g == nil || !strings.Contains(g.Doc, "from buffer") || findSymbol(pd.Funcs, "Farewell") == nil || len(pd.FromBuffer) != 1 {
		t.Fatalf("overlay failed %+v", pd)
	}
	stdDoc := loadDoc(t, fixture(t, "single"), "strings", Options{})
	if stdDoc.Origin != OriginStdlib || findSymbol(stdDoc.Funcs, "Cut") == nil {
		t.Fatalf("stdlib Cut missing %+v", stdDoc)
	}
	tmp := t.TempDir()
	proxy := filepath.Join(tmp, "proxy")
	writeProxyModule(t, proxy, fixture(t, "proxysrc/pdep-v1.0.0"), "v1.0.0")
	writeProxyModule(t, proxy, fixture(t, "proxysrc/pdep-v1.1.0"), "v1.1.0")
	app := filepath.Join(tmp, "app")
	copyDir(t, fixture(t, "proxyapp"), app)
	cache := filepath.Join(tmp, "cache")
	setup := []string{"GOPROXY=file://" + filepath.ToSlash(proxy), "GOSUMDB=off", "GOMODCACHE=" + cache, "GOFLAGS=-modcacherw", "GOWORK=off"}
	goCmd(t, app, setup, "mod", "tidy")
	present := Options{Env: []string{"GOMODCACHE=" + cache, "GOWORK=off", "GOFLAGS=-modcacherw"}}
	if pd := loadDoc(t, app, "example.com/pdep", present); findSymbol(pd.Funcs, "OnlyInV11") != nil {
		t.Fatal("v1.1.0 symbol leaked into v1.0.0")
	}
	goCmd(t, app, setup, "get", "example.com/pdep@v1.1.0")
	if pd := loadDoc(t, app, "example.com/pdep", present); findSymbol(pd.Funcs, "OnlyInV11") == nil {
		t.Fatal("v1.1.0 symbol missing after upgrade")
	}
	svc := NewService()
	missingPage := svc.LoadPackagePage("r1", app, "example.com/pdep", Options{Env: []string{"GOMODCACHE=" + filepath.Join(tmp, "empty"), "GOWORK=off", "GOFLAGS=-modcacherw"}})
	if !missingPage.MissingSource || missingPage.ErrorKind != ErrorKindMissingModule || missingPage.MissingModule != "example.com/pdep" || missingPage.MissingVersion != "v1.1.0" {
		t.Fatalf("expected structured missingModule page, got %+v", missingPage)
	}
}

func TestErrorClassificationCacheEvictionAndCancel(t *testing.T) {
	requireGo(t)
	tmp := t.TempDir()
	must(t, os.WriteFile(filepath.Join(tmp, "go.mod"), []byte("module example.com/errs\n\ngo 1.26\n"), 0o644))
	must(t, os.MkdirAll(filepath.Join(tmp, "onlylinux"), 0o755))
	must(t, os.WriteFile(filepath.Join(tmp, "onlylinux", "l.go"), []byte("//go:build linux\n\npackage onlylinux\n\nfunc OnlyLinux() {}\n"), 0o644))
	must(t, os.MkdirAll(filepath.Join(tmp, "bad"), 0o755))
	must(t, os.WriteFile(filepath.Join(tmp, "bad", "b.go"), []byte("package bad\n\nfunc Broken( {\n"), 0o644))

	svc := NewService()
	target := Target{GOOS: "darwin", GOARCH: "arm64"}
	constraintPage := svc.LoadPackagePage("bc", tmp, "example.com/errs/onlylinux", Options{Target: target})
	if constraintPage.ErrorKind != ErrorKindBuildConstraint || len(constraintPage.Excluded) != 1 || constraintPage.Excluded[0].Name != "OnlyLinux" {
		t.Fatalf("expected buildConstraint classification, got %+v", constraintPage)
	}
	badPage := svc.LoadPackagePage("pe", tmp, "example.com/errs/bad", Options{Target: target})
	if badPage.ErrorKind != ErrorKindParseError || len(badPage.ParseErrors) == 0 {
		t.Fatalf("expected parseError classification, got %+v", badPage)
	}

	for i := range 5 {
		d := filepath.Join(tmp, fmt.Sprintf("ws%d", i))
		must(t, os.MkdirAll(d, 0o755))
		must(t, os.WriteFile(filepath.Join(d, "go.mod"), []byte(fmt.Sprintf("module example.com/ws%d\n\ngo 1.26\n", i)), 0o644))
		must(t, os.WriteFile(filepath.Join(d, "w.go"), []byte("package w\n\nfunc F() {}\n"), 0o644))
		idx := svc.ListPackages("ev", d, Options{Target: target})
		if idx.Error != "" || idx.Generation == 0 {
			t.Fatalf("ws%d failed: %+v", i, idx)
		}
	}
	svc.mu.Lock()
	cachedCount := len(svc.entries)
	svc.mu.Unlock()
	if cachedCount != maxCachedWorkspaces {
		t.Fatalf("cachedCount = %d, want %d", cachedCount, maxCachedWorkspaces)
	}

	d4 := filepath.Join(tmp, "ws4")
	hit := svc.ListPackages("hit", d4, Options{Target: target})
	svc.Invalidate(d4)
	reloaded := svc.ListPackages("rel", d4, Options{Target: target})
	if reloaded.Generation <= hit.Generation {
		t.Fatalf("generation did not advance after Invalidate: %d <= %d", reloaded.Generation, hit.Generation)
	}

	t.Run("cancel", func(t *testing.T) {
		svc.Invalidate(d4)
		marker := filepath.Join(tmp, "started")
		wrapper := filepath.Join(tmp, "go")
		must(t, os.WriteFile(wrapper, []byte("#!/bin/sh\ntouch "+marker+"\nsleep 5\n"), 0o755))
		t.Setenv("PATH", tmp+":"+os.Getenv("PATH"))
		done := make(chan *Index, 1)
		go func() {
			done <- svc.ListPackages("cancel-req", d4, Options{Target: target})
		}()
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := os.Stat(marker); err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		svc.Cancel("cancel-req")
		select {
		case res := <-done:
			if !res.Cancelled {
				t.Fatalf("expected cancelled result, got %+v", res)
			}
		case <-time.After(3 * time.Second):
			t.Fatal("DocsCancel did not kill running process group promptly")
		}
	})
}

func TestSearchRankingScopesAndLimit(t *testing.T) {
	requireGo(t)
	root := fixture(t, "single")
	svc := NewService()
	opts := Options{Target: Target{GOOS: "darwin", GOARCH: "arm64", IncludeStd: true}}
	resp := svc.Search("s1", root, opts, "project", "shapes.Area", 50)
	if resp.Error != "" || len(resp.Results) == 0 {
		t.Fatalf("search failed: %+v", resp)
	}
	if resp.Results[0].Symbol != "Area" || resp.Results[0].ImportPath != "example.com/single/shapes" {
		t.Fatalf("expected exact pkg.Symbol rank 0 first, got %+v", resp.Results[0])
	}
	unexp := svc.Search("s2", root, Options{Target: targetDarwin(), IncludeUnexported: true}, "project", "helper", 20)
	if len(unexp.Results) == 0 || unexp.Results[0].Symbol != "helper" {
		t.Fatalf("expected unexported helper in search when IncludeUnexported=true: %+v", unexp.Results)
	}
	ex := svc.Search("s3", root, opts, "project", "ProOnly", 20)
	if len(ex.Results) == 0 || !ex.Results[0].Excluded || ex.Results[0].Build != "pro" {
		t.Fatalf("expected excluded build-constraint hit for ProOnly: %+v", ex.Results)
	}
	stdOnly := svc.Search("s4", root, opts, "stdlib", "strings", 50)
	if len(stdOnly.Results) == 0 || stdOnly.Results[0].ImportPath != "strings" || stdOnly.Results[0].Origin != OriginStdlib {
		t.Fatalf("expected exact stdlib strings package first: %+v", stdOnly.Results)
	}
	capped := svc.Search("s5", root, opts, "all", "e", 999)
	if len(capped.Results) != maxSearchResults {
		t.Fatalf("expected search capped at %d, got %d", maxSearchResults, len(capped.Results))
	}
}

func TestListPackagesPopulatesUnimportedLocalReplaceModule(t *testing.T) {
	requireGo(t)
	base := t.TempDir()
	dep := filepath.Join(base, "localdep")
	app := filepath.Join(base, "app")
	if err := os.MkdirAll(filepath.Join(dep, "helper"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(app, "calc"), 0o755); err != nil {
		t.Fatal(err)
	}
	_ = os.WriteFile(filepath.Join(dep, "go.mod"), []byte("module example.com/localdep\n\ngo 1.22\n"), 0o644)
	_ = os.WriteFile(filepath.Join(dep, "helper", "helper.go"), []byte("package helper\nfunc Hi() string { return \"hi\" }\n"), 0o644)
	_ = os.WriteFile(filepath.Join(app, "go.mod"), []byte("module example.com/app\n\ngo 1.22\n\nrequire example.com/localdep v0.0.0\n\nreplace example.com/localdep => ../localdep\n"), 0o644)
	_ = os.WriteFile(filepath.Join(app, "calc", "calc.go"), []byte("package calc\nfunc Ok() int { return 1 }\n"), 0o644)

	idx := NewService().ListPackages("u1", app, Options{Target: targetDarwin()})
	if idx.Error != "" {
		t.Fatalf("unexpected error: %s", idx.Error)
	}
	found := false
	for _, p := range idx.Packages {
		if p.ImportPath == "example.com/localdep/helper" && p.Source == SourceLocalReplace {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected unimported local replace package helper, got %+v", idx.Packages)
	}
}

func targetDarwin() Target {
	return Target{GOOS: "darwin", GOARCH: "arm64"}
}

func TestSymlinkedWorkspaceOverlayAndListPackages(t *testing.T) {
	requireGo(t)
	base := t.TempDir()
	realRoot := filepath.Join(base, "real")
	linkRoot := filepath.Join(base, "link")
	if err := os.MkdirAll(filepath.Join(realRoot, "pkg"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realRoot, linkRoot); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	_ = os.WriteFile(filepath.Join(realRoot, "go.mod"), []byte("module example.com/sym\n\ngo 1.22\n"), 0o644)
	_ = os.WriteFile(filepath.Join(realRoot, "pkg", "pkg.go"), []byte("package pkg\n\n// Alpha runs.\nfunc Alpha() int { return 1 }\n"), 0o644)

	svc := NewService()
	idx := svc.ListPackages("i1", linkRoot, Options{Target: targetDarwin()})
	if idx.Error != "" {
		t.Fatalf("unexpected ListPackages error: %s", idx.Error)
	}
	_ = findPackage(t, idx, "example.com/sym/pkg")

	overlaySrc := "package pkg\n\n// Alpha runs with buffer update.\nfunc Alpha() int { return 2 }\n"
	pd := svc.LoadPackagePage("p1", linkRoot, "example.com/sym/pkg", Options{
		Target:  targetDarwin(),
		Overlay: map[string]string{filepath.Join(linkRoot, "pkg", "pkg.go"): overlaySrc},
	})
	if pd.Error != "" {
		t.Fatalf("unexpected LoadPackagePage error: %s", pd.Error)
	}
	if len(pd.FromBuffer) == 0 {
		t.Fatalf("expected FromBuffer populated for symlinked overlay, got empty")
	}
	if len(pd.Funcs) == 0 || !strings.Contains(pd.Funcs[0].Doc, "buffer update") {
		t.Fatalf("expected overlay doc text in %+v", pd.Funcs)
	}
}
