package analysis

import (
	"encoding/json"
	"go/ast"
	"go/format"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mustInspectSerialSafety(t *testing.T, req SerialSafetyInspectRequest) SerialSafetyInspectResponse {
	t.Helper()
	reqBytes, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("failed to marshal inspect request: %v", err)
	}
	raw := InspectSerializationSafety(string(reqBytes))
	var resp SerialSafetyInspectResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("failed to unmarshal inspect response %q: %v", raw, err)
	}
	return resp
}

func mustFixSerialSafety(t *testing.T, req SerialSafetyFixRequest) SerialSafetyFixResponse {
	t.Helper()
	reqBytes, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("failed to marshal fix request: %v", err)
	}
	raw := ApplySerializationSafetyFix(string(reqBytes))
	var resp SerialSafetyFixResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		t.Fatalf("failed to unmarshal fix response %q: %v", raw, err)
	}
	return resp
}

func TestSerialSafetyInspectAllCategories(t *testing.T) {
	src := `package models

type AccountPayload struct {
	userID       string ` + "`json:\"user_id\"`" + `
	yamlSetting  string ` + "`yaml:\"yaml_setting\"`" + `
	xmlNode      string ` + "`xml:\"xml_node\"`" + `
	dbRowID      int64  ` + "`db:\"db_row_id\"`" + `
	internalNote string

	Password     string ` + "`json:\"password\"`" + `
	ClientSecret string
	AccessToken  string ` + "`yaml:\"access_token\"`" + `
	SafeSecret   string ` + "`json:\"-\"`" + `

	ID           string ` + "`json:\"id\"`" + `
	ExternalID   string ` + "`json:\"id,omitempty\"`" + `
}
`

	resp := mustInspectSerialSafety(t, SerialSafetyInspectRequest{
		FilePath: "models.go",
		Content:  src,
	})

	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}
	if resp.UnexportedTagCount != 4 {
		t.Fatalf("expected UnexportedTagCount=4, got %d", resp.UnexportedTagCount)
	}
	if resp.SensitiveExposedCount != 3 {
		t.Fatalf("expected SensitiveExposedCount=3, got %d", resp.SensitiveExposedCount)
	}
	if resp.DuplicateTagCount != 1 {
		t.Fatalf("expected DuplicateTagCount=1, got %d", resp.DuplicateTagCount)
	}
	if len(resp.Issues) != 8 {
		t.Fatalf("expected 8 total issues, got %d", len(resp.Issues))
	}

	for _, iss := range resp.Issues {
		if iss.Severity != "error" {
			t.Errorf("expected severity 'error' for %s, got %q", iss.ID, iss.Severity)
		}
		if !iss.CanAutoFix {
			t.Errorf("expected CanAutoFix=true for %s", iss.ID)
		}
		if iss.StructName != "AccountPayload" {
			t.Errorf("expected StructName='AccountPayload', got %q", iss.StructName)
		}
	}
}

func TestSerialSafetySensitiveKeywordsCoverage(t *testing.T) {
	src := `package auth

type Credentials struct {
	Password     string
	Passwd       string
	Secret       string
	Token        string
	APIKey       string
	PrivateKey   string
	AccessToken  string
	RefreshToken string
	ClientSecret string
	RedactedKey  string ` + "`json:\"-\"`" + `
}
`

	resp := mustInspectSerialSafety(t, SerialSafetyInspectRequest{
		FilePath: "auth.go",
		Content:  src,
	})
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}
	if resp.SensitiveExposedCount != 9 {
		t.Fatalf("expected 9 sensitive_field_exposed issues, got %d", resp.SensitiveExposedCount)
	}
}

func TestSerialSafetySingleIssueFixes(t *testing.T) {
	src := `package models

type UserRecord struct {
	userID      string ` + "`json:\"user_id\"`" + `
	APIKey      string ` + "`json:\"api_key\"`" + `
	PrimaryID   string ` + "`json:\"id\"`" + `
	SecondaryID string ` + "`json:\"id,omitempty\"`" + `
}
`

	inspectResp := mustInspectSerialSafety(t, SerialSafetyInspectRequest{
		FilePath: "user.go",
		Content:  src,
	})
	if len(inspectResp.Issues) != 3 {
		t.Fatalf("expected 3 issues, got %d", len(inspectResp.Issues))
	}

	var unexportedID, sensitiveID, duplicateID string
	for _, iss := range inspectResp.Issues {
		switch iss.Category {
		case "unexported_tagged_field":
			unexportedID = iss.ID
		case "sensitive_field_exposed":
			sensitiveID = iss.ID
		case "duplicate_json_tag":
			duplicateID = iss.ID
		}
	}

	// 1. Single fix for unexported_tagged_field
	fixUnexported := mustFixSerialSafety(t, SerialSafetyFixRequest{
		FilePath: "user.go",
		Content:  src,
		IssueID:  unexportedID,
		All:      false,
	})
	if fixUnexported.Error != "" {
		t.Fatalf("unexpected error fixing unexported field: %s", fixUnexported.Error)
	}
	if fixUnexported.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1, got %d", fixUnexported.FixedCount)
	}
	if !strings.Contains(fixUnexported.NewContent, "UserID") {
		t.Fatalf("expected userID to be capitalized to UserID:\n%s", fixUnexported.NewContent)
	}

	// 2. Single fix for sensitive_field_exposed
	fixSensitive := mustFixSerialSafety(t, SerialSafetyFixRequest{
		FilePath: "user.go",
		Content:  src,
		IssueID:  sensitiveID,
		All:      false,
	})
	if fixSensitive.Error != "" {
		t.Fatalf("unexpected error fixing sensitive field: %s", fixSensitive.Error)
	}
	if fixSensitive.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1, got %d", fixSensitive.FixedCount)
	}
	if !strings.Contains(fixSensitive.NewContent, "APIKey      string `json:\"-\"`") {
		t.Fatalf("expected APIKey tag to be updated to json:\"-\":\n%s", fixSensitive.NewContent)
	}

	// 3. Single fix for duplicate_json_tag
	fixDuplicate := mustFixSerialSafety(t, SerialSafetyFixRequest{
		FilePath: "user.go",
		Content:  src,
		IssueID:  duplicateID,
		All:      false,
	})
	if fixDuplicate.Error != "" {
		t.Fatalf("unexpected error fixing duplicate tag: %s", fixDuplicate.Error)
	}
	if fixDuplicate.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1, got %d", fixDuplicate.FixedCount)
	}
	if !strings.Contains(fixDuplicate.NewContent, "`json:\"secondary_id,omitempty\"`") {
		t.Fatalf("expected SecondaryID tag to be updated to secondary_id,omitempty:\n%s", fixDuplicate.NewContent)
	}
}

func TestSerialSafetyFixAll(t *testing.T) {
	src := `package models

type SessionConfig struct {
	sessionID    string ` + "`json:\"session_id\"`" + `
	RefreshToken string
	ClientSecret string ` + "`json:\"client_secret\" yaml:\"client_secret\"`" + `
	ID           string ` + "`json:\"id\"`" + `
	AccountID    string ` + "`json:\"id\"`" + `
}
`

	initial := mustInspectSerialSafety(t, SerialSafetyInspectRequest{
		FilePath: "session.go",
		Content:  src,
	})
	if initial.UnexportedTagCount != 1 || initial.SensitiveExposedCount != 2 || initial.DuplicateTagCount != 1 {
		t.Fatalf("unexpected initial counts: unexported=%d sensitive=%d duplicate=%d",
			initial.UnexportedTagCount, initial.SensitiveExposedCount, initial.DuplicateTagCount)
	}

	fixAll := mustFixSerialSafety(t, SerialSafetyFixRequest{
		FilePath: "session.go",
		Content:  src,
		All:      true,
	})
	if fixAll.Error != "" {
		t.Fatalf("unexpected FixAll error: %s", fixAll.Error)
	}
	if fixAll.FixedCount != 4 {
		t.Fatalf("expected FixedCount=4, got %d", fixAll.FixedCount)
	}

	if !strings.Contains(fixAll.NewContent, "SessionID") {
		t.Errorf("expected SessionID in fixed content:\n%s", fixAll.NewContent)
	}
	if !strings.Contains(fixAll.NewContent, "RefreshToken string `json:\"-\"`") {
		t.Errorf("expected RefreshToken redacted in fixed content:\n%s", fixAll.NewContent)
	}
	if !strings.Contains(fixAll.NewContent, "`json:\"-\" yaml:\"client_secret\"`") {
		t.Errorf("expected ClientSecret json redacted preserving yaml tag:\n%s", fixAll.NewContent)
	}
	if !strings.Contains(fixAll.NewContent, "`json:\"account_id\"`") {
		t.Errorf("expected AccountID duplicate tag renamed to account_id:\n%s", fixAll.NewContent)
	}

	formatted, err := format.Source([]byte(fixAll.NewContent))
	if err != nil {
		t.Fatalf("expected valid gofmt output, got err: %v", err)
	}
	if string(formatted) != fixAll.NewContent {
		t.Fatalf("expected NewContent to be gofmt-formatted")
	}

	recheck := mustInspectSerialSafety(t, SerialSafetyInspectRequest{
		FilePath: "session.go",
		Content:  fixAll.NewContent,
	})
	if len(recheck.Issues) != 0 {
		t.Fatalf("expected 0 issues after FixAll, got %d: %+v", len(recheck.Issues), recheck.Issues)
	}
}

func TestSerialSafetyUpdatesCompositeLitAndSelectorReferences(t *testing.T) {
	src := `package main

import (
	"encoding/json"
	"fmt"
)

type User struct {
	name string ` + "`json:\"name\"`" + `
	Age  int    ` + "`json:\"age\"`" + `
}

func main() {
	u := User{name: "Alice", Age: 30}
	fmt.Println(u.name)
	data, _ := json.Marshal(u)
	fmt.Println(string(data))
}
`

	fixed := mustFixSerialSafety(t, SerialSafetyFixRequest{
		FilePath: "main.go",
		Content:  src,
		All:      true,
	})
	if fixed.Error != "" || fixed.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1 without error, got %+v", fixed)
	}
	if !strings.Contains(fixed.NewContent, "Name string `json:\"name\"`") {
		t.Fatalf("expected struct field Name in fixed output:\n%s", fixed.NewContent)
	}
	if !strings.Contains(fixed.NewContent, `User{Name: "Alice", Age: 30}`) {
		t.Fatalf("expected composite literal key updated to Name in fixed output:\n%s", fixed.NewContent)
	}
	if !strings.Contains(fixed.NewContent, "fmt.Println(u.Name)") {
		t.Fatalf("expected selector u.name updated to u.Name in fixed output:\n%s", fixed.NewContent)
	}
}

func TestSerialSafetyMultiFileDoesNotRenameOtherStructFieldOrWriteDisk(t *testing.T) {
	dir := t.TempDir()
	userPath := filepath.Join(dir, "user.go")
	otherPath := filepath.Join(dir, "other.go")
	usagePath := filepath.Join(dir, "usage.go")

	userSrc := "package sample\n\ntype User struct {\n\tname string `json:\"name\"`\n}\n"
	otherSrc := "package sample\n\ntype Other struct {\n\tname string\n}\n"
	usageSrc := `package sample

func Combine(u User, o Other) string {
	u2 := User{name: u.name}
	o2 := Other{name: o.name}
	return u2.name + ":" + o2.name
}
`

	if err := os.WriteFile(userPath, []byte(userSrc), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(otherPath, []byte(otherSrc), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(usagePath, []byte(usageSrc), 0o644); err != nil {
		t.Fatal(err)
	}

	fixed := mustFixSerialSafety(t, SerialSafetyFixRequest{
		FilePath: userPath,
		Content:  userSrc,
		All:      true,
	})
	if fixed.Error != "" || fixed.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1 without error, got %+v", fixed)
	}

	diskUsageBytes, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(diskUsageBytes) != usageSrc {
		t.Fatalf("expected ApplySerializationSafetyFix not to mutate sibling usage.go on disk directly")
	}

	var updatedUsage string
	for _, edit := range fixed.FileEdits {
		if sameSyncFilePath(edit.FilePath, usagePath) {
			updatedUsage = edit.NewContent
			break
		}
	}
	if updatedUsage == "" {
		t.Fatalf("expected FileEdits to include %s, got %+v", usagePath, fixed.FileEdits)
	}
	if !strings.Contains(updatedUsage, "User{Name: u.Name}") || !strings.Contains(updatedUsage, "u2.Name") {
		t.Fatalf("expected User.name references to be updated to Name in usage.go:\n%s", updatedUsage)
	}
	if !strings.Contains(updatedUsage, "Other{name: o.name}") || !strings.Contains(updatedUsage, "o2.name") {
		t.Fatalf("expected Other.name references NOT to be renamed in usage.go:\n%s", updatedUsage)
	}

	fset := token.NewFileSet()
	fUser, err := parser.ParseFile(fset, userPath, fixed.NewContent, parser.AllErrors)
	if err != nil {
		t.Fatal(err)
	}
	fOther, err := parser.ParseFile(fset, otherPath, otherSrc, parser.AllErrors)
	if err != nil {
		t.Fatal(err)
	}
	fUsage, err := parser.ParseFile(fset, usagePath, updatedUsage, parser.AllErrors)
	if err != nil {
		t.Fatal(err)
	}
	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check("sample", fset, []*ast.File{fUser, fOther, fUsage}, nil); err != nil {
		t.Fatalf("expected package to type-check cleanly after Serialization Safety Fix, got: %v", err)
	}
}


