package usageindex

import (
	"context"
	"errors"
	"fmt"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"golens/core/goast"
)

func buildModule(t *testing.T, files map[string]string) (string, *Index) {
	t.Helper()
	dir := t.TempDir()
	files["go.mod"] = "module example.com/m\n\ngo 1.26\n"
	for name, src := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	ix, err := Build(context.Background(), dir, Options{})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	return dir, ix
}

// countsByName returns the counts of a file's lens declarations by name, or
// nil when the index has no counts for the file.
func countsByName(t *testing.T, ix *Index, dir, rel string) map[string]int {
	t.Helper()
	path := filepath.Join(dir, rel)
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lenses := ix.FileLenses(path)
	if lenses == nil {
		return nil
	}
	out := map[string]int{}
	for _, d := range goast.Declarations(src) {
		if _, dup := out[d.Name]; dup {
			t.Fatalf("%s declares %s twice; use distinct names in test sources", rel, d.Name)
		}
		c, ok := lenses[Pos{Line: d.Line, Col: d.Col}]
		if !ok {
			t.Fatalf("%s: no count for %s %s at %d:%d", rel, d.Kind, d.Name, d.Line, d.Col)
		}
		out[d.Name] = c.Count
	}
	return out
}

func expectCounts(t *testing.T, ix *Index, dir, rel string, want map[string]int) {
	t.Helper()
	if got := countsByName(t, ix, dir, rel); !reflect.DeepEqual(got, want) {
		t.Errorf("%s counts = %v, want %v", rel, got, want)
	}
}

func TestFuncTypeGenericAndMethodCounts(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"a/a.go": `package a

type Box[T any] struct{ v T }

func (b *Box[T]) Get() T { return b.v }

func New[T any](v T) *Box[T] { return &Box[T]{v: v} }

type Plain struct{}

func (Plain) Name() string { return "p" }

func helper() int { return 1 }

func Use() int {
	b := New(1)
	_ = b.Get()
	var p Plain
	_ = p.Name()
	return helper() + helper()
}

func init() {}
`,
		"b/b.go": `package b

import "example.com/m/a"

var _ a.Box[string]

func Run() string {
	_ = a.Use()
	return a.New("x").Get()
}
`,
	})
	expectCounts(t, ix, dir, "a/a.go", map[string]int{
		"Box": 4, "Get": 2, "New": 2, "Plain": 2, "Name": 1, "helper": 2, "Use": 1, "init": 0,
	})
	expectCounts(t, ix, dir, "b/b.go", map[string]int{"Run": 0})
}

func TestTestFilesCountedOnce(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"a/a.go": `package a

type Plain struct{}

func helper() int { return 1 }

func Use() int { return helper() }
`,
		"a/a_test.go": `package a

import "testing"

func TestInternal(t *testing.T) {
	_ = helper()
	var _ Plain
}
`,
		"a/ext_test.go": `package a_test

import (
	"testing"

	"example.com/m/a"
)

func TestExternal(t *testing.T) {
	_ = a.Use()
	var _ a.Plain
}
`,
	})
	expectCounts(t, ix, dir, "a/a.go", map[string]int{"Plain": 2, "helper": 2, "Use": 1})
	expectCounts(t, ix, dir, "a/a_test.go", map[string]int{"TestInternal": 0})
	expectCounts(t, ix, dir, "a/ext_test.go", map[string]int{"TestExternal": 0})
}

func TestConcreteMethodCountsWorkspaceInterfaceCalls(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"c/c.go": `package c

type Namer interface{ Name() string }

func Call(n Namer) string { return n.Name() }
`,
		"d/d.go": `package d

type T struct{}

func (T) Name() string { return "t" }

func (*T) Other() {}
`,
		"e/e.go": `package e

import (
	"example.com/m/c"
	"example.com/m/d"
)

func Run() string { return c.Call(d.T{}) }
`,
	})
	expectCounts(t, ix, dir, "d/d.go", map[string]int{"T": 3, "Name": 1, "Other": 0})
	expectCounts(t, ix, dir, "c/c.go", map[string]int{"Namer": 1, "Call": 1})
}

func TestErrorMethodCountsErrorCallsInDeclaringPackageOnly(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"e/e.go": `package e

type E struct{}

func (E) Error() string { return "e" }

func Msg(err error) string { return err.Error() }
`,
		"f/f.go": `package f

import "example.com/m/e"

func Msg(err error) string { return err.Error() + e.E{}.Error() }
`,
	})
	expectCounts(t, ix, dir, "e/e.go", map[string]int{"E": 2, "Error": 2, "Msg": 0})
}

func TestAliasInMethodSignatureStillCorresponds(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"g/g.go": `package g

type ID = string

type Getter interface{ Get(id string) error }

type S struct{}

func (S) Get(id ID) error { return nil }

func Use(x Getter) error { return x.Get("a") }
`,
	})
	expectCounts(t, ix, dir, "g/g.go", map[string]int{"ID": 1, "Getter": 1, "S": 1, "Get": 1, "Use": 0})
}

func TestEmbeddedExternalInterfaceMethod(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"res/res.go": `package res

import "io"

type Resource interface {
	io.Closer
	Name() string
}
`,
		"impl/impl.go": `package impl

type File struct{}

func (*File) Close() error { return nil }

func (*File) Name() string { return "f" }
`,
		"user/user.go": `package user

import (
	"io"

	"example.com/m/res"
)

func Shut(c io.Closer) error { return c.Close() }

func Label(r res.Resource) string { return r.Name() }
`,
		"other/other.go": `package other

import "io"

func Shut(c io.Closer) error { return c.Close() }
`,
		"app/app.go": `package app

import "example.com/m/impl"

func Run() error { return (&impl.File{}).Close() }
`,
	})
	expectCounts(t, ix, dir, "impl/impl.go", map[string]int{"File": 3, "Close": 2, "Name": 1})
}

func TestPackageWithTypeErrorHasNoCounts(t *testing.T) {
	dir, ix := buildModule(t, map[string]string{
		"bad/bad.go": `package bad

func Broken() int { return "x" }
`,
		"ok/ok.go": `package ok

import "example.com/m/bad"

func Fine() int { return bad.Broken() }

func Caller() int { return Fine() }
`,
	})
	if got := countsByName(t, ix, dir, "bad/bad.go"); got != nil {
		t.Errorf("bad/bad.go counts = %v, want none", got)
	}
	expectCounts(t, ix, dir, "ok/ok.go", map[string]int{"Fine": 1, "Caller": 0})
	if got := ix.FileLenses(filepath.Join(dir, "missing.go")); got != nil {
		t.Errorf("unknown file counts = %v, want none", got)
	}
}

func TestBuildReportsGoListFailure(t *testing.T) {
	failure := errors.New("vm unavailable")
	_, err := Build(context.Background(), t.TempDir(), Options{
		RunGo: func(context.Context, string, ...string) ([]byte, error) { return nil, failure },
	})
	if !errors.Is(err, failure) {
		t.Fatalf("Build error = %v, want %v", err, failure)
	}
}

func TestBuildStopsWhenCancelled(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module example.com/m\n\ngo 1.26\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "m.go"), []byte("package m\n\nimport \"fmt\"\n\nvar _ = fmt.Sprint\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_, err := Build(ctx, dir, Options{
		RunGo: func(ctx context.Context, dir string, args ...string) ([]byte, error) {
			out, err := runGo(ctx, dir, args...)
			cancel()
			return out, err
		},
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Build error = %v, want context.Canceled", err)
	}
}

// implsByName returns the implementation results of a file's lens
// declarations by name, sorted, each location as the identifier it points at
// with its file relative to dir. Of the standard library only the io and
// builtin packages are kept, relative to GOROOT/src.
func implsByName(t *testing.T, ix *Index, dir, rel string) map[string][]string {
	t.Helper()
	srcRoot := gorootSrc(t, dir)
	path := filepath.Join(dir, rel)
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lenses := ix.FileLenses(path)
	out := map[string][]string{}
	for _, d := range goast.Declarations(src) {
		lens, ok := lenses[Pos{Line: d.Line, Col: d.Col}]
		if !ok {
			t.Fatalf("%s: no lens for %s", rel, d.Name)
		}
		for _, loc := range lens.Impls {
			b, err := os.ReadFile(loc.File)
			if err != nil {
				t.Fatal(err)
			}
			line := strings.Split(string(b), "\n")[loc.Line-1]
			name, inWS := strings.CutPrefix(loc.File, dir+"/")
			if !inWS {
				name = strings.TrimPrefix(loc.File, srcRoot+"/")
				if !strings.HasPrefix(name, "io/io.go") && !strings.HasPrefix(name, "builtin/") {
					continue
				}
			}
			out[d.Name] = append(out[d.Name], fmt.Sprintf("%s:%d:%s", name, loc.Line, line[loc.Col-1:loc.EndCol-1]))
		}
		sort.Strings(out[d.Name])
	}
	return out
}

func TestImplementations(t *testing.T) {
	files := map[string]string{
		"a/a.go": `package a

type Namer interface{ Name() string }

type Plain struct{}

func (Plain) Name() string { return "p" }

type E struct{}

func (*E) Error() string { return "e" }

func useLocal() {
	type localNamer struct{ Plain }
	_ = localNamer{}
}
`,
		"a/a_test.go": `package a

type testNamer struct{}

func (testNamer) Name() string { return "t" }
`,
		"a/x_test.go": `package a_test

type XNamer struct{}

func (XNamer) Name() string { return "x" }
`,
		"b/b.go": `package b

type T struct{}
`,
		"c/c.go": `package c

import "io"

type RC interface {
	io.Reader
	Close() error
}

type F struct{}

func (*F) Read(p []byte) (int, error) { return 0, nil }

func (*F) Close() error { return nil }

var _ io.Reader = (*F)(nil)
`,
		"g/g.go": `package g

type Box[T any] struct{ v T }

func (b *Box[T]) Get() T { return b.v }
`,
		"h/h.go": `package h

type IntGetter interface{ Get() int }
`,
	}
	dir, ix := buildModule(t, files)
	expect := func(rel string, want map[string][]string) {
		t.Helper()
		for _, w := range want {
			sort.Strings(w)
		}
		if got := implsByName(t, ix, dir, rel); !reflect.DeepEqual(got, want) {
			t.Errorf("%s implementations:\n got %v\nwant %v", rel, got, want)
		}
	}
	expect("a/a.go", map[string][]string{
		"Namer": {"a/a.go:14:localNamer", "a/a.go:5:Plain", "a/a_test.go:3:testNamer", "a/x_test.go:3:XNamer"},
		"Plain": {"a/a.go:3:Namer"},
		"Name":  {"a/a.go:3:Name"},
		"E":     {"builtin/builtin.go:" + errorLine(t, dir) + ":error"},
		"Error": {"builtin/builtin.go:" + errorLine(t, dir) + ":error"},
	})
	expect("c/c.go", map[string][]string{
		"RC":    {"c/c.go:10:F", "io/io.go:" + ioLine(t, dir, "type ReadCloser interface") + ":ReadCloser", "io/io.go:" + ioLine(t, dir, "type ReadSeekCloser interface") + ":ReadSeekCloser", "io/io.go:" + ioLine(t, dir, "type ReadWriteCloser interface") + ":ReadWriteCloser", "io/io.go:" + ioLine(t, dir, "type nopCloser struct") + ":nopCloser", "io/io.go:" + ioLine(t, dir, "type nopCloserWriterTo struct") + ":nopCloserWriterTo"},
		"F":     {"c/c.go:5:RC", "io/io.go:" + ioLine(t, dir, "type Closer interface") + ":Closer", "io/io.go:" + ioLine(t, dir, "type ReadCloser interface") + ":ReadCloser", "io/io.go:" + ioLine(t, dir, "type Reader interface") + ":Reader"},
		"Read":  {"io/io.go:" + ioLine(t, dir, "\tRead(p []byte) (n int, err error)") + ":Read"},
		"Close": {"c/c.go:7:Close", "io/io.go:" + ioLine(t, dir, "\tClose() error") + ":Close"},
	})
	expect("g/g.go", map[string][]string{"Box": {"h/h.go:3:IntGetter"}, "Get": {"h/h.go:3:Get"}})
	expect("h/h.go", map[string][]string{"IntGetter": {"g/g.go:3:Box"}})
	expect("b/b.go", map[string][]string{})

	l := ix.l
	writeFiles(t, dir, map[string]string{"b/b.go": files["b/b.go"] + "\nfunc (T) Name() string { return \"b\" }\n"})
	mustUpdate(t, ix, dir, "b/b.go")
	if ix.l != l {
		t.Fatal("a body edit rebuilt the index")
	}
	expect("a/a.go", map[string][]string{
		"Namer": {"a/a.go:14:localNamer", "a/a.go:5:Plain", "a/a_test.go:3:testNamer", "a/x_test.go:3:XNamer", "b/b.go:3:T"},
		"Plain": {"a/a.go:3:Namer"},
		"Name":  {"a/a.go:3:Name"},
		"E":     {"builtin/builtin.go:" + errorLine(t, dir) + ":error"},
		"Error": {"builtin/builtin.go:" + errorLine(t, dir) + ":error"},
	})
	expectMatchesFreshBuild(t, ix, dir, Options{})
	ix.ReleaseTypes()
	if got := implsByName(t, ix, dir, "b/b.go"); !reflect.DeepEqual(got, map[string][]string{"T": {"a/a.go:3:Namer"}, "Name": {"a/a.go:3:Name"}}) {
		t.Errorf("b/b.go implementations after ReleaseTypes = %v", got)
	}
}

func goSourceLine(t *testing.T, path, prefix string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for i, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, prefix) {
			return fmt.Sprint(i + 1)
		}
	}
	t.Fatalf("%s has no line starting with %q", path, prefix)
	return ""
}

func gorootSrc(t *testing.T, dir string) string {
	t.Helper()
	goroot, err := runGo(context.Background(), dir, "env", "GOROOT")
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(strings.TrimSpace(string(goroot)), "src")
}

func ioLine(t *testing.T, dir, prefix string) string {
	return goSourceLine(t, filepath.Join(gorootSrc(t, dir), "io", "io.go"), prefix)
}

func errorLine(t *testing.T, dir string) string {
	return goSourceLine(t, filepath.Join(gorootSrc(t, dir), "builtin", "builtin.go"), "type error interface")
}

func TestBuildHandlesGeneratedLineDirectiveWithoutColumn(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{
		"go.mod": "module example.com/linegen\n\ngo 1.26\n",
		"gen/greet.pb.go": "// Code generated by protoc-gen-go. DO NOT EDIT.\n" +
			"// source: greet.proto\n\n" +
			"package gen\n\n" +
			"//line ../api/greet.proto:4\n" +
			"type Greeter interface {\n" +
			"\tGreet() string\n" +
			"}\n\n" +
			"type HelloGreeter struct{}\n\n" +
			"func (HelloGreeter) Greet() string { return \"hi\" }\n",
	}
	writeFiles(t, dir, files)

	ix, err := Build(context.Background(), dir, Options{})
	if err != nil {
		t.Fatalf("Build failed on //line without column: %v", err)
	}
	pbPath := filepath.Join(dir, "gen/greet.pb.go")
	lenses := ix.FileLenses(pbPath)
	if len(lenses) == 0 {
		t.Fatalf("expected non-empty lenses for %s", pbPath)
	}
	src, err := os.ReadFile(pbPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range goast.Declarations(src) {
		if d.Name == "Greeter" || d.Name == "HelloGreeter" || d.Name == "Greet" {
			if _, ok := lenses[Pos{Line: d.Line, Col: d.Col}]; !ok {
				t.Fatalf("missing lens at %s (%d:%d)", d.Name, d.Line, d.Col)
			}
		}
	}
	got := identLoc(token.Position{Filename: pbPath, Offset: 10, Line: 4, Column: 0}, []byte("package x\nfunc F(){}\n"), "F")
	if got.Col < 1 {
		t.Fatalf("expected Col >= 1 on zero-column Position, got %+v", got)
	}
}
