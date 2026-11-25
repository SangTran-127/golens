package analysis

import (
	"go/importer"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestSerialFieldRenameEdits_SamePackageImporterMatchesToolchainImporter(t *testing.T) {
	dir := t.TempDir()
	userPath := filepath.Join(dir, "user.go")
	usagePath := filepath.Join(dir, "usage.go")
	userSrc := "package sample\n\nimport \"time\"\n\ntype User struct {\n\tname    string `json:\"name\"`\n\tcreated time.Time\n}\n"
	usageSrc := `package sample

import (
	"encoding/json"
	"net/http"
	"strings"

	"example.com/missing/dep"
)

type Wrapper struct {
	User
	Other dep.Thing
}

func Handle(w http.ResponseWriter, r *http.Request, users []User, wrap Wrapper) {
	u := User{name: strings.TrimSpace(r.URL.Query().Get("n"))}
	for _, each := range users {
		_ = each.name
	}
	ptr := &users[0]
	_ = ptr.name + wrap.name + wrap.User.name
	_ = json.NewEncoder(w).Encode(u.name)
	_ = dep.Use(u.name)
}
`
	for path, src := range map[string]string{userPath: userSrc, usagePath: usageSrc} {
		if err := os.WriteFile(path, []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	renamed := map[string]map[string]string{"User": {"name": "Name"}}

	start := time.Now()
	fastEdits, fastPlans, fastErr := collectPackageSerialFieldRenameEditsWithImporter(samePackageOnlyImporter{}, userPath, userSrc, renamed, nil)
	fastElapsed := time.Since(start)
	refEdits, refPlans, refErr := collectPackageSerialFieldRenameEditsWithImporter(importer.Default(), userPath, userSrc, renamed, nil)
	if fastErr != nil || refErr != nil {
		t.Fatalf("unexpected errors: %v / %v", fastErr, refErr)
	}

	normalise := func(edits []serialSpanEdit) []serialSpanEdit {
		out := append([]serialSpanEdit(nil), edits...)
		sort.Slice(out, func(i, j int) bool { return out[i].start < out[j].start })
		return out
	}
	if !reflect.DeepEqual(normalise(fastEdits), normalise(refEdits)) {
		t.Fatalf("primary edits differ:\n fast %+v\n  ref %+v", fastEdits, refEdits)
	}
	if !reflect.DeepEqual(fastPlans, refPlans) {
		t.Fatalf("sibling plans differ:\n fast %+v\n  ref %+v", fastPlans, refPlans)
	}
	if len(fastPlans) != 1 {
		t.Fatalf("expected one sibling edit plan, got %+v", fastPlans)
	}
	updated := fastPlans[0].NewContent
	for _, want := range []string{"User{Name: strings", "each.Name", "ptr.Name + wrap.Name + wrap.User.Name", "Encode(u.Name)", "dep.Use(u.Name)"} {
		if !strings.Contains(updated, want) {
			t.Fatalf("expected %q in renamed sibling:\n%s", want, updated)
		}
	}
	t.Logf("same-package importer resolved renames in %v", fastElapsed)
}

func TestSamePackageOnlyImporter_NeverFails(t *testing.T) {
	for _, path := range []string{"fmt", "net/http", "example.com/x/y", "gopkg.in/yaml.v3"} {
		pkg, err := (samePackageOnlyImporter{}).Import(path)
		if err != nil || pkg == nil || !pkg.Complete() || pkg.Path() != path {
			t.Fatalf("import %q: pkg=%v err=%v", path, pkg, err)
		}
	}
}
