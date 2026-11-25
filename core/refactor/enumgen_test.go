package refactor

import (
	"encoding/json"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnumGen_IntIotaEnum(t *testing.T) {
	src := `package orders

type OrderStatus int

const (
	OrderStatusPending OrderStatus = iota
	OrderStatusPaid
	OrderStatusShipped
)
`

	listReqBytes, _ := json.Marshal(ListEnumTypesRequest{
		Content:    src,
		CursorLine: 3,
	})
	listRespJSON := ListEnumTypes(string(listReqBytes))
	var listRes ListEnumTypesResult
	if err := json.Unmarshal([]byte(listRespJSON), &listRes); err != nil {
		t.Fatalf("failed to unmarshal ListEnumTypesResult: %v", err)
	}
	if listRes.Error != "" {
		t.Fatalf("unexpected error in ListEnumTypes: %s", listRes.Error)
	}
	if len(listRes.Enums) != 1 {
		t.Fatalf("expected 1 enum, got %d: %+v", len(listRes.Enums), listRes.Enums)
	}
	if listRes.SelectedEnum != "OrderStatus" {
		t.Fatalf("expected SelectedEnum OrderStatus, got %q", listRes.SelectedEnum)
	}
	if listRes.Enums[0].UnderlyingType != "int" {
		t.Fatalf("expected UnderlyingType int, got %q", listRes.Enums[0].UnderlyingType)
	}
	wantVals := []string{"OrderStatusPending", "OrderStatusPaid", "OrderStatusShipped"}
	if len(listRes.Enums[0].Values) != len(wantVals) {
		t.Fatalf("expected values %v, got %v", wantVals, listRes.Enums[0].Values)
	}
	for i, w := range wantVals {
		if listRes.Enums[0].Values[i] != w {
			t.Errorf("value[%d] = %q, want %q", i, listRes.Enums[0].Values[i], w)
		}
	}

	genReqBytes, _ := json.Marshal(GenerateEnumRequest{
		Content:               src,
		EnumName:              "OrderStatus",
		CursorLine:            3,
		TrimTypePrefix:        true,
		LowercaseStrings:      true,
		GenerateParse:         true,
		GenerateTextMarshaler: true,
		GenerateIsValid:       true,
	})
	genRespJSON := GenerateEnumMethods(string(genReqBytes))
	var genRes GenerateEnumResult
	if err := json.Unmarshal([]byte(genRespJSON), &genRes); err != nil {
		t.Fatalf("failed to unmarshal GenerateEnumResult: %v", err)
	}
	if genRes.Error != "" {
		t.Fatalf("unexpected error in GenerateEnumMethods: %s", genRes.Error)
	}
	if genRes.EnumName != "OrderStatus" {
		t.Fatalf("expected EnumName OrderStatus, got %q", genRes.EnumName)
	}
	if genRes.ValueCount != 3 {
		t.Fatalf("expected ValueCount 3, got %d", genRes.ValueCount)
	}

	mustContain := []string{
		"func (e OrderStatus) String() string",
		`return "pending"`,
		`return "paid"`,
		`return "shipped"`,
		`return fmt.Sprintf("OrderStatus(%v)", int(e))`,
		"func (e OrderStatus) IsValid() bool",
		"case OrderStatusPending, OrderStatusPaid, OrderStatusShipped:",
		"func ParseOrderStatus(s string) (OrderStatus, error)",
		`return 0, fmt.Errorf("invalid OrderStatus: %q", s)`,
		"func (e OrderStatus) MarshalText() ([]byte, error)",
		"func (e *OrderStatus) UnmarshalText(text []byte) error",
	}
	for _, needle := range mustContain {
		if !strings.Contains(genRes.GeneratedCode, needle) {
			t.Errorf("GeneratedCode missing %q:\n%s", needle, genRes.GeneratedCode)
		}
	}

	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "generated.go", "package orders\n\n"+genRes.GeneratedCode, parser.AllErrors); err != nil {
		t.Fatalf("GeneratedCode failed to parse with parser.ParseFile: %v\n%s", err, genRes.GeneratedCode)
	}
	if _, err := parser.ParseFile(fset, "orders.go", genRes.NewContent, parser.AllErrors); err != nil {
		t.Fatalf("NewContent failed to parse with parser.ParseFile: %v\n%s", err, genRes.NewContent)
	}
}

func TestEnumGen_StringEnum(t *testing.T) {
	src := `package auth

type Role string

const (
	RoleAdmin  Role = "admin"
	RoleEditor Role = "editor"
	RoleViewer Role = "viewer"
)
`

	listReqBytes, _ := json.Marshal(ListEnumTypesRequest{
		Content:    src,
		CursorLine: 3,
	})
	var listRes ListEnumTypesResult
	if err := json.Unmarshal([]byte(ListEnumTypes(string(listReqBytes))), &listRes); err != nil {
		t.Fatalf("failed to unmarshal ListEnumTypesResult: %v", err)
	}
	if len(listRes.Enums) != 1 || listRes.Enums[0].Name != "Role" || listRes.Enums[0].UnderlyingType != "string" {
		t.Fatalf("unexpected ListEnumTypesResult for string enum: %+v", listRes)
	}

	genReqBytes, _ := json.Marshal(GenerateEnumRequest{
		Content:               src,
		EnumName:              "Role",
		CursorLine:            3,
		TrimTypePrefix:        true,
		LowercaseStrings:      false,
		GenerateParse:         true,
		GenerateTextMarshaler: true,
		GenerateIsValid:       true,
	})
	var genRes GenerateEnumResult
	if err := json.Unmarshal([]byte(GenerateEnumMethods(string(genReqBytes))), &genRes); err != nil {
		t.Fatalf("failed to unmarshal GenerateEnumResult: %v", err)
	}
	if genRes.Error != "" {
		t.Fatalf("unexpected error: %s", genRes.Error)
	}
	if !strings.Contains(genRes.GeneratedCode, `return "Admin"`) {
		t.Errorf("expected capitalized trimmed string label \"Admin\", got:\n%s", genRes.GeneratedCode)
	}
	if !strings.Contains(genRes.GeneratedCode, `return "", fmt.Errorf("invalid Role: %q", s)`) {
		t.Errorf("expected string zero value in ParseRole, got:\n%s", genRes.GeneratedCode)
	}

	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "generated.go", "package auth\n\n"+genRes.GeneratedCode, parser.AllErrors); err != nil {
		t.Fatalf("GeneratedCode failed to parse with parser.ParseFile: %v\n%s", err, genRes.GeneratedCode)
	}
	if _, err := parser.ParseFile(fset, "role.go", genRes.NewContent, parser.AllErrors); err != nil {
		t.Fatalf("NewContent failed to parse with parser.ParseFile: %v\n%s", err, genRes.NewContent)
	}
}

func TestEnumGen_StructFallback(t *testing.T) {
	src := `package ledger

type Ledger struct {
	ID      string
	Balance int64
}
`

	listReqBytes, _ := json.Marshal(ListEnumTypesRequest{
		Content:    src,
		CursorLine: 3,
	})
	var listRes ListEnumTypesResult
	if err := json.Unmarshal([]byte(ListEnumTypes(string(listReqBytes))), &listRes); err != nil {
		t.Fatalf("failed to unmarshal ListEnumTypesResult: %v", err)
	}
	if listRes.Error != "" {
		t.Fatalf("unexpected error in ListEnumTypes on struct-only file: %s", listRes.Error)
	}
	if len(listRes.Enums) == 0 {
		t.Fatalf("expected synthesized fallback enum for struct-only file, got 0 enums")
	}
	if listRes.SelectedEnum != "LedgerStatus" {
		t.Fatalf("expected SelectedEnum LedgerStatus, got %q", listRes.SelectedEnum)
	}
	if len(listRes.Enums[0].Values) != 3 {
		t.Fatalf("expected 3 synthesized values, got %v", listRes.Enums[0].Values)
	}

	genReqBytes, _ := json.Marshal(GenerateEnumRequest{
		Content:               src,
		EnumName:              listRes.SelectedEnum,
		CursorLine:            3,
		TrimTypePrefix:        true,
		LowercaseStrings:      true,
		GenerateParse:         true,
		GenerateTextMarshaler: true,
		GenerateIsValid:       true,
	})
	var genRes GenerateEnumResult
	if err := json.Unmarshal([]byte(GenerateEnumMethods(string(genReqBytes))), &genRes); err != nil {
		t.Fatalf("failed to unmarshal GenerateEnumResult: %v", err)
	}
	if genRes.Error != "" {
		t.Fatalf("unexpected error in GenerateEnumMethods on struct-only file: %s", genRes.Error)
	}
	if genRes.ValueCount != 3 {
		t.Fatalf("expected ValueCount 3, got %d", genRes.ValueCount)
	}
	if !strings.Contains(genRes.GeneratedCode, "type LedgerStatus int") {
		t.Errorf("expected synthesized type declaration in GeneratedCode:\n%s", genRes.GeneratedCode)
	}
	if !strings.Contains(genRes.GeneratedCode, "LedgerStatusUnknown LedgerStatus = iota") {
		t.Errorf("expected synthesized const block in GeneratedCode:\n%s", genRes.GeneratedCode)
	}

	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "generated.go", "package ledger\n\n"+genRes.GeneratedCode, parser.AllErrors); err != nil {
		t.Fatalf("GeneratedCode failed to parse with parser.ParseFile: %v\n%s", err, genRes.GeneratedCode)
	}
	if _, err := parser.ParseFile(fset, "ledger.go", genRes.NewContent, parser.AllErrors); err != nil {
		t.Fatalf("NewContent failed to parse with parser.ParseFile: %v\n%s", err, genRes.NewContent)
	}
}

func TestInspectEnumMethods_IotaIntEnumWithPrefixTrim(t *testing.T) {
	src := `package workflow

type Status int

const (
	StatusPending Status = iota
	StatusActive
	StatusArchived
)

func ExistingHelper() string {
	return "ok"
}
`

	plan, err := InspectEnumMethods("", "status.go", src, 6, 1, "", true, true, true, true)
	if err != nil {
		t.Fatalf("InspectEnumMethods returned unexpected error: %v", err)
	}
	if plan.Error != "" {
		t.Fatalf("expected empty plan.Error, got %q", plan.Error)
	}
	if plan.PackageName != "workflow" {
		t.Fatalf("expected PackageName %q, got %q", "workflow", plan.PackageName)
	}
	if plan.TargetEnum != "Status" {
		t.Fatalf("expected TargetEnum %q, got %q", "Status", plan.TargetEnum)
	}
	if plan.UnderlyingType != "int" {
		t.Fatalf("expected UnderlyingType %q, got %q", "int", plan.UnderlyingType)
	}
	if len(plan.Constants) != 3 {
		t.Fatalf("expected 3 constants, got %d", len(plan.Constants))
	}

	wantConsts := []EnumConstItem{
		{Name: "StatusPending", Label: "Pending"},
		{Name: "StatusActive", Label: "Active"},
		{Name: "StatusArchived", Label: "Archived"},
	}
	for i, want := range wantConsts {
		if plan.Constants[i] != want {
			t.Errorf("constants[%d] = %+v, want %+v", i, plan.Constants[i], want)
		}
	}

	mustContain := []string{
		"func (e Status) String() string",
		"case StatusPending:",
		`return "Pending"`,
		`return fmt.Sprintf("Status(%v)", int(e))`,
		"func ParseStatus(s string) (Status, error)",
		`case "Pending", "StatusPending":`,
		`return Status(0), fmt.Errorf("invalid Status: %q", s)`,
		"func (e Status) IsValid() bool",
		"case StatusPending, StatusActive, StatusArchived:",
		"func AllStatusValues() []Status",
		"return []Status{StatusPending, StatusActive, StatusArchived}",
	}
	for _, needle := range mustContain {
		if !strings.Contains(plan.PreviewCode, needle) {
			t.Errorf("PreviewCode missing %q:\n%s", needle, plan.PreviewCode)
		}
	}

	fset := token.NewFileSet()
	parsedFile, parseErr := parser.ParseFile(fset, "status.go", plan.NewContent, parser.ParseComments)
	if parseErr != nil {
		t.Fatalf("generated NewContent failed to parse with go/parser: %v\nNewContent:\n%s", parseErr, plan.NewContent)
	}

	foundFuncs := map[string]bool{}
	foundImports := map[string]bool{}
	for _, imp := range parsedFile.Imports {
		if imp != nil && imp.Path != nil {
			foundImports[strings.Trim(imp.Path.Value, `"`)] = true
		}
	}
	for _, decl := range parsedFile.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name != nil {
			foundFuncs[fd.Name.Name] = true
		}
	}

	if !foundImports["fmt"] {
		t.Errorf("expected import \"fmt\" in NewContent, got imports=%v", foundImports)
	}
	for _, fn := range []string{"String", "ParseStatus", "IsValid", "AllStatusValues", "ExistingHelper"} {
		if !foundFuncs[fn] {
			t.Errorf("expected function %q in NewContent, got %v", fn, foundFuncs)
		}
	}
}

func TestInspectEnumMethods_StringEnumAndExplicitTypeSelection(t *testing.T) {
	src := `package auth

type Status int

const (
	StatusIdle Status = iota
	StatusBusy
)

type Role string

const (
	RoleAdmin  Role = "admin"
	RoleEditor Role = "editor"
	RoleViewer Role = "viewer"
)
`

	plan, err := InspectEnumMethods("", "role.go", src, 1, 1, "Role", false, true, true, false)
	if err != nil {
		t.Fatalf("InspectEnumMethods returned unexpected error: %v", err)
	}
	if plan.TargetEnum != "Role" {
		t.Fatalf("expected TargetEnum %q, got %q", "Role", plan.TargetEnum)
	}
	if plan.UnderlyingType != "string" {
		t.Fatalf("expected UnderlyingType %q, got %q", "string", plan.UnderlyingType)
	}
	if len(plan.AvailableEnums) != 2 {
		t.Fatalf("expected 2 available enums, got %v", plan.AvailableEnums)
	}
	if len(plan.Constants) != 3 {
		t.Fatalf("expected 3 constants, got %d", len(plan.Constants))
	}
	if plan.Constants[0].Label != "RoleAdmin" {
		t.Errorf("expected untrimmed label %q when trimPrefix=false, got %q", "RoleAdmin", plan.Constants[0].Label)
	}

	mustContain := []string{
		"func (e Role) String() string",
		"return string(e)",
		"func ParseRole(s string) (Role, error)",
		`case "RoleAdmin":`,
		`return Role(""), fmt.Errorf("invalid Role: %q", s)`,
		"func (e Role) IsValid() bool",
	}
	for _, needle := range mustContain {
		if !strings.Contains(plan.PreviewCode, needle) {
			t.Errorf("PreviewCode missing %q:\n%s", needle, plan.PreviewCode)
		}
	}
	if strings.Contains(plan.PreviewCode, "AllRoleValues") {
		t.Errorf("did not expect AllRoleValues when includeValues=false:\n%s", plan.PreviewCode)
	}

	fset := token.NewFileSet()
	if _, parseErr := parser.ParseFile(fset, "role.go", plan.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("generated NewContent failed to parse with go/parser: %v\nNewContent:\n%s", parseErr, plan.NewContent)
	}
}

func TestInspectEnumMethods_HandlesDuplicateValueAliases(t *testing.T) {
	src := `package main

type Status int

const (
	StatusOK      Status = 0
	StatusSuccess Status = 0
	StatusError   Status = 1
)
`
	plan, err := InspectEnumMethods("", "main.go", src, 3, 1, "Status", true, true, true, true)
	if err != nil {
		t.Fatalf("InspectEnumMethods returned unexpected error: %v", err)
	}
	if len(plan.Constants) != 3 {
		t.Fatalf("expected 3 constants, got %d", len(plan.Constants))
	}
	if plan.Constants[0].IsAlias || !plan.Constants[1].IsAlias || plan.Constants[2].IsAlias {
		t.Fatalf("expected StatusSuccess to be marked IsAlias=true, got %+v", plan.Constants)
	}
	if strings.Contains(plan.PreviewCode, "case StatusSuccess:") {
		t.Fatalf("did not expect duplicate switch case StatusSuccess in String():\n%s", plan.PreviewCode)
	}
	if strings.Contains(plan.PreviewCode, "case StatusOK, StatusSuccess, StatusError:") {
		t.Fatalf("did not expect duplicate switch case StatusSuccess in IsValid():\n%s", plan.PreviewCode)
	}
	if !strings.Contains(plan.PreviewCode, `case "Success", "StatusSuccess":`) {
		t.Fatalf("expected ParseStatus to still accept alias 'Success':\n%s", plan.PreviewCode)
	}
}

func typeCheckEnumSource(t *testing.T, pkgName, filename, src string) {
	t.Helper()
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filename, src, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse %s failed: %v\n%s", filename, err, src)
	}
	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check(pkgName, fset, []*ast.File{f}, nil); err != nil {
		t.Fatalf("typecheck %s failed: %v\n%s", filename, err, src)
	}
}

func TestEnumGen_EdgeCases_TypeCheckAndExecution(t *testing.T) {
	cases := []struct {
		name            string
		pkgName         string
		src             string
		typeName        string
		includeParse    bool
		includeIsValid  bool
		includeValues   bool
		mustContain     []string
		contentMustOmit []string
		previewMustOmit []string
		wantAvailEnums  []string
	}{
		{
			name:    "unexported_uint8_enum_preserves_helpers_and_comments",
			pkgName: "cfg",
			src: `//go:build darwin || linux

package cfg

// mode controls execution behavior.
type mode uint8

const (
	modeFast mode = iota
	modeSafe
)

func keepExistingHelper() string { return "ok" }
`,
			includeParse:   true,
			includeIsValid: true,
			includeValues:  true,
			mustContain:    []string{"//go:build darwin || linux", "keepExistingHelper", "func (e mode) String() string", "func Parsemode("},
		},
		{
			name:    "skips_alias_and_generic_selects_real_enum",
			pkgName: "kinds",
			src: `package kinds

type AliasKind = Kind

type GenericBox[T ~int] int

type Kind int

const (
	KindAlpha Kind = iota
	KindBeta
)
`,
			includeParse:    true,
			includeIsValid:  true,
			includeValues:   true,
			mustContain:     []string{"func (e Kind) String() string", "KindAlpha", "KindBeta"},
			previewMustOmit: []string{"AliasKind", "GenericBox"},
			wantAvailEnums:  []string{"Kind"},
		},
		{
			name:    "name_clashes_with_e_s_constants",
			pkgName: "tokens",
			src: `package tokens

type Tok int

const (
	e Tok = iota
	s
	text
	val
	err
)
`,
			includeParse:   true,
			includeIsValid: true,
			includeValues:  true,
			mustContain:    []string{"func (", "case e:", "case s:", "case e, s, text, val, err:", "ParseTok("},
		},
		{
			name:    "string_enum_without_parse_omits_unused_fmt",
			pkgName: "labels",
			src: `package labels

type Label string

const (
	LabelHot  Label = "hot"
	LabelCold Label = "cold"
)
`,
			includeParse:    false,
			includeIsValid:  true,
			includeValues:   true,
			mustContain:     []string{"func (e Label) String() string", "func (e Label) IsValid() bool", "AllLabelValues()"},
			contentMustOmit: []string{`"fmt"`, "ParseLabel("},
		},
		{
			name:    "idempotent_regeneration_replaces_old_methods",
			pkgName: "state",
			src: `package state

import "fmt"

type State int

const (
	StateInit State = iota
	StateDone
)

// old doc comment
func (e State) String() string { return "stale" }

func ParseState(s string) (State, error) { return 0, fmt.Errorf("stale %s", s) }

func (e State) IsValid() bool { return false }

func AllStateValues() []State { return nil }

func CustomUserFunc() int { return 42 }
`,
			includeParse:    true,
			includeIsValid:  true,
			includeValues:   true,
			mustContain:     []string{"CustomUserFunc", `return "Init"`},
			contentMustOmit: []string{`return "stale"`},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan, err := InspectEnumMethods("", "enum.go", tc.src, 1, 1, tc.typeName, true, tc.includeParse, tc.includeIsValid, tc.includeValues)
			if err != nil {
				t.Fatalf("InspectEnumMethods failed: %v", err)
			}
			if plan.Error != "" {
				t.Fatalf("plan.Error = %q", plan.Error)
			}
			for _, want := range tc.mustContain {
				if !strings.Contains(plan.NewContent, want) {
					t.Errorf("expected %q in NewContent:\n%s", want, plan.NewContent)
				}
			}
			for _, forbid := range tc.contentMustOmit {
				if strings.Contains(plan.NewContent, forbid) {
					t.Errorf("did not expect %q in NewContent:\n%s", forbid, plan.NewContent)
				}
			}
			for _, forbid := range tc.previewMustOmit {
				if strings.Contains(plan.PreviewCode, forbid) {
					t.Errorf("did not expect %q in PreviewCode:\n%s", forbid, plan.PreviewCode)
				}
			}
			if len(tc.wantAvailEnums) > 0 {
				if len(plan.AvailableEnums) != len(tc.wantAvailEnums) {
					t.Errorf("AvailableEnums = %v, want %v", plan.AvailableEnums, tc.wantAvailEnums)
				} else {
					for i, w := range tc.wantAvailEnums {
						if plan.AvailableEnums[i] != w {
							t.Errorf("AvailableEnums[%d] = %q, want %q", i, plan.AvailableEnums[i], w)
						}
					}
				}
			}
			typeCheckEnumSource(t, tc.pkgName, "enum.go", plan.NewContent)
		})
	}
}

func TestEnumGen_BuildTagsAndRealGoTestExecution(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte("module enumcheck\n\ngo 1.22\n"), 0644); err != nil {
		t.Fatal(err)
	}

	mainSrc := `package enumcheck

type Tok int

const (
	e Tok = iota
	s
	text
	val
	err
)
`
	ignoredSrc := `//go:build ignore

package enumcheck

const (
	ignoredExtra Tok = 99
)
`
	if err := os.WriteFile(filepath.Join(dir, "tok.go"), []byte(mainSrc), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ignored.go"), []byte(ignoredSrc), 0644); err != nil {
		t.Fatal(err)
	}

	genReqBytes, _ := json.Marshal(GenerateEnumRequest{
		Content:               mainSrc,
		EnumName:              "Tok",
		TrimTypePrefix:        true,
		GenerateParse:         true,
		GenerateTextMarshaler: true,
		GenerateIsValid:       true,
	})
	var genRes GenerateEnumResult
	if err := json.Unmarshal([]byte(GenerateEnumMethods(string(genReqBytes))), &genRes); err != nil {
		t.Fatalf("unmarshal GenerateEnumMethods: %v", err)
	}
	if genRes.Error != "" {
		t.Fatalf("GenerateEnumMethods error: %s", genRes.Error)
	}
	typeCheckEnumSource(t, "enumcheck", filepath.Join(dir, "tok.go"), genRes.NewContent)

	plan, planErr := InspectEnumMethods(dir, filepath.Join(dir, "tok.go"), mainSrc, 3, 1, "Tok", true, true, true, true)
	if planErr != nil {
		t.Fatalf("InspectEnumMethods failed: %v", planErr)
	}
	if strings.Contains(plan.NewContent, "ignoredExtra") {
		t.Fatalf("expected build-ignored constant excluded, got:\n%s", plan.NewContent)
	}
	if err := os.WriteFile(filepath.Join(dir, "tok.go"), []byte(genRes.NewContent), 0644); err != nil {
		t.Fatal(err)
	}

	testSrc := `package enumcheck

import "testing"

func TestGeneratedTokEnum(t *testing.T) {
	if got := e.String(); got != "e" {
		t.Fatalf("e.String() = %q", got)
	}
	if !err.IsValid() || Tok(999).IsValid() {
		t.Fatalf("unexpected IsValid")
	}
	parsed, parseErr := ParseTok("text")
	if parseErr != nil || parsed != text {
		t.Fatalf("ParseTok = (%v, %v)", parsed, parseErr)
	}
	b, mErr := val.MarshalText()
	if mErr != nil || string(b) != "val" {
		t.Fatalf("MarshalText = (%q, %v)", string(b), mErr)
	}
	var out Tok
	if uErr := out.UnmarshalText([]byte("s")); uErr != nil || out != s {
		t.Fatalf("UnmarshalText = (%v, %v)", out, uErr)
	}
}
`
	if err := os.WriteFile(filepath.Join(dir, "tok_test.go"), []byte(testSrc), 0644); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("go", "test", "-v", "./...")
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go test failed: %v\n%s\ngenerated:\n%s", err, string(out), genRes.NewContent)
	}
}
