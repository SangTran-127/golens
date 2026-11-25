package goast

import (
	"encoding/json"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestModifyStructTagsAddTransformAndOmitEmpty(t *testing.T) {
	src := `package models

type User struct {
	UserID     int
	HTTPServer string
	CreatedAt  string
}
`
	req := StructTagRequest{
		Path:      "models.go",
		Src:       src,
		Offset:    30,
		Action:    "add",
		Tags:      []string{"json", "yaml", "db"},
		Transform: "snake",
		OmitEmpty: true,
	}
	reqBytes, _ := json.Marshal(req)
	rawResp := ModifyStructTags(string(reqBytes))

	var resp GenerateCodeResponse
	if err := json.Unmarshal([]byte(rawResp), &resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}

	edits := resp.EditsByPath["models.go"]
	if len(edits) != 1 {
		t.Fatalf("expected 1 edit, got %d", len(edits))
	}
	got := edits[0].NewText

	wantSnippets := []string{
		"`json:\"user_id,omitempty\" yaml:\"user_id,omitempty\" db:\"user_id\"`",
		"`json:\"http_server,omitempty\" yaml:\"http_server,omitempty\" db:\"http_server\"`",
		"`json:\"created_at,omitempty\" yaml:\"created_at,omitempty\" db:\"created_at\"`",
	}
	for _, snippet := range wantSnippets {
		if !strings.Contains(got, snippet) {
			t.Errorf("expected output to contain %s, got:\n%s", snippet, got)
		}
	}
}

func TestModifyStructTagsCamelPascalKebab(t *testing.T) {
	src := `package models

type Config struct {
	UserID     int
	HTTPServer string
	userID     string
}
`
	cases := []struct {
		transform string
		expected  []string
	}{
		{
			transform: "camel",
			expected: []string{
				"`json:\"userId\"`",
				"`json:\"httpServer\"`",
			},
		},
		{
			transform: "pascal",
			expected: []string{
				"`json:\"UserID\"`",
				"`json:\"HTTPServer\"`",
			},
		},
		{
			transform: "kebab",
			expected: []string{
				"`json:\"user-id\"`",
				"`json:\"http-server\"`",
			},
		},
	}

	for _, tc := range cases {
		req := StructTagRequest{
			Path:      "config.go",
			Src:       src,
			Offset:    25,
			Action:    "add",
			Tags:      []string{"json"},
			Transform: tc.transform,
			OmitEmpty: false,
		}
		reqBytes, _ := json.Marshal(req)
		var resp GenerateCodeResponse
		if err := json.Unmarshal([]byte(ModifyStructTags(string(reqBytes))), &resp); err != nil {
			t.Fatalf("transform %s decode error: %v", tc.transform, err)
		}
		if resp.Error != "" {
			t.Fatalf("transform %s unexpected error: %s", tc.transform, resp.Error)
		}
		got := resp.EditsByPath["config.go"][0].NewText
		for _, exp := range tc.expected {
			if !strings.Contains(got, exp) {
				t.Errorf("transform %s: expected %s in:\n%s", tc.transform, exp, got)
			}
		}
	}
}

func TestModifyStructTagsPreserveAndRemove(t *testing.T) {
	src := "package models\n\ntype Item struct {\n\tItemID int `validate:\"required\" json:\"old_id\"`\n\tName string `xml:\"name\"`\n}\n"

	addReq := StructTagRequest{
		Path:      "item.go",
		Src:       src,
		Offset:    20,
		Action:    "add",
		Tags:      []string{"json", "db"},
		Transform: "snake",
		OmitEmpty: false,
	}
	addBytes, _ := json.Marshal(addReq)
	var addResp GenerateCodeResponse
	if err := json.Unmarshal([]byte(ModifyStructTags(string(addBytes))), &addResp); err != nil {
		t.Fatalf("failed to unmarshal addResp: %v", err)
	}
	updatedSrc := addResp.EditsByPath["item.go"][0].NewText
	if !strings.Contains(updatedSrc, "`validate:\"required\" json:\"item_id\" db:\"item_id\"`") {
		t.Fatalf("expected existing validate tag preserved and json/db updated, got:\n%s", updatedSrc)
	}
	if !strings.Contains(updatedSrc, "`xml:\"name\" json:\"name\" db:\"name\"`") {
		t.Fatalf("expected xml tag preserved and json/db added, got:\n%s", updatedSrc)
	}

	remSpecificReq := StructTagRequest{
		Path:   "item.go",
		Src:    updatedSrc,
		Offset: 20,
		Action: "remove",
		Tags:   []string{"json", "xml"},
	}
	remSpecificBytes, _ := json.Marshal(remSpecificReq)
	var remSpecificResp GenerateCodeResponse
	if err := json.Unmarshal([]byte(ModifyStructTags(string(remSpecificBytes))), &remSpecificResp); err != nil {
		t.Fatalf("failed to unmarshal remSpecificResp: %v", err)
	}
	afterSpecific := remSpecificResp.EditsByPath["item.go"][0].NewText
	if !strings.Contains(afterSpecific, "`validate:\"required\" db:\"item_id\"`") {
		t.Fatalf("expected validate and db kept on ItemID, got:\n%s", afterSpecific)
	}
	if !strings.Contains(afterSpecific, "Name   string `db:\"name\"`") && !strings.Contains(afterSpecific, "Name string `db:\"name\"`") {
		t.Fatalf("expected only db tag kept on Name, got:\n%s", afterSpecific)
	}

	remAllReq := StructTagRequest{
		Path:   "item.go",
		Src:    afterSpecific,
		Offset: 20,
		Action: "remove",
		Tags:   nil,
	}
	remAllBytes, _ := json.Marshal(remAllReq)
	var remAllResp GenerateCodeResponse
	if err := json.Unmarshal([]byte(ModifyStructTags(string(remAllBytes))), &remAllResp); err != nil {
		t.Fatalf("failed to unmarshal remAllResp: %v", err)
	}
	afterAll := remAllResp.EditsByPath["item.go"][0].NewText
	if strings.Contains(afterAll, "`") {
		t.Fatalf("expected all struct tags removed, got:\n%s", afterAll)
	}
}

func TestModifyStructTagsNoStructAndFileRead(t *testing.T) {
	noStructReq := StructTagRequest{
		Path:   "empty.go",
		Src:    "package main\n\nfunc main() {}\n",
		Offset: 0,
		Action: "add",
	}
	b, _ := json.Marshal(noStructReq)
	var resp GenerateCodeResponse
	_ = json.Unmarshal([]byte(ModifyStructTags(string(b))), &resp)
	if resp.Error != "No struct found in current file" {
		t.Fatalf("expected 'No struct found in current file', got %q", resp.Error)
	}

	tmpDir := t.TempDir()
	filePath := filepath.Join(tmpDir, "disk.go")
	diskSrc := "package main\n\ntype DiskRecord struct {\n\tRecordID int\n}\n"
	if err := os.WriteFile(filePath, []byte(diskSrc), 0644); err != nil {
		t.Fatalf("write temp file: %v", err)
	}
	diskReq := StructTagRequest{
		Path:   filePath,
		Offset: 0,
		Action: "add",
	}
	db, _ := json.Marshal(diskReq)
	var diskResp GenerateCodeResponse
	_ = json.Unmarshal([]byte(ModifyStructTags(string(db))), &diskResp)
	if diskResp.Error != "" {
		t.Fatalf("unexpected error reading from disk: %s", diskResp.Error)
	}
	if !strings.Contains(diskResp.EditsByPath[filePath][0].NewText, "`json:\"record_id\"`") {
		t.Fatalf("expected json tag on RecordID, got:\n%s", diskResp.EditsByPath[filePath][0].NewText)
	}
}

func TestJSONToGoStructObjectsArraysAndInitialisms(t *testing.T) {
	rawJSON := `{
  "user_name": "golens",
  "id": 42,
  "score": 98.5,
  "active": true,
  "api_url": "https://example.com/api",
  "tags": ["go", "ide"],
  "counts": [1, 2, 3],
  "metadata": null,
  "profile": {
    "http_port": 8080,
    "uuid": "abc-123"
  },
  "items": [
    {
      "id": 1,
      "item_name": "hammer"
    }
  ]
}`
	req := JSONToStructRequest{
		JSONText: rawJSON,
		TypeName: "Payload",
	}
	reqBytes, _ := json.Marshal(req)
	var resp JSONToStructResponse
	if err := json.Unmarshal([]byte(JSONToGoStruct(string(reqBytes))), &resp); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if resp.Error != "" {
		t.Fatalf("unexpected error: %s", resp.Error)
	}

	code := resp.GoCode
	expectedPieces := []string{
		"type Payload struct {",
		"ID",
		"`json:\"id\"`",
		"Active",
		"bool",
		"`json:\"active\"`",
		"APIURL",
		"string",
		"`json:\"api_url\"`",
		"Counts",
		"[]int",
		"`json:\"counts\"`",
		"Items",
		"[]struct {",
		"ItemName string `json:\"item_name\"`",
		"Metadata",
		"any",
		"`json:\"metadata\"`",
		"Profile",
		"HTTPPort int    `json:\"http_port\"`",
		"UUID     string `json:\"uuid\"`",
		"Score",
		"float64",
		"`json:\"score\"`",
		"Tags",
		"[]string",
		"`json:\"tags\"`",
		"UserName",
		"`json:\"user_name\"`",
	}
	for _, piece := range expectedPieces {
		if !strings.Contains(code, piece) {
			t.Errorf("expected generated struct to contain %q, got:\n%s", piece, code)
		}
	}

	idIdx := strings.Index(code, "ID ")
	activeIdx := strings.Index(code, "Active ")
	if idIdx < 0 || activeIdx < 0 || idIdx > activeIdx {
		t.Errorf("expected ID field to be sorted first before Active, got:\n%s", code)
	}
}

func TestJSONToGoStructTopLevelArrayAndErrors(t *testing.T) {
	arrReq := JSONToStructRequest{
		JSONText: `[{"id": 10, "user_id": 99}]`,
		TypeName: "",
	}
	b, _ := json.Marshal(arrReq)
	var arrResp JSONToStructResponse
	_ = json.Unmarshal([]byte(JSONToGoStruct(string(b))), &arrResp)
	if arrResp.Error != "" {
		t.Fatalf("unexpected error for array of objects: %s", arrResp.Error)
	}
	if !strings.Contains(arrResp.GoCode, "type AutoGenerated struct") || !strings.Contains(arrResp.GoCode, "UserID int `json:\"user_id\"`") {
		t.Fatalf("unexpected GoCode for array of objects:\n%s", arrResp.GoCode)
	}

	invalidReq := JSONToStructRequest{
		JSONText: `["not_an_object"]`,
		TypeName: "Bad",
	}
	ib, _ := json.Marshal(invalidReq)
	var invalidResp JSONToStructResponse
	_ = json.Unmarshal([]byte(JSONToGoStruct(string(ib))), &invalidResp)
	if invalidResp.Error == "" {
		t.Fatalf("expected error for array of strings, got none")
	}
}

func typeCheckSingleGoastFile(t *testing.T, pkgName, filename, src string) {
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

func TestModifyStructTags_EdgeCasesPreservesCommentsAndTypeCheck(t *testing.T) {
	cases := []struct {
		name        string
		src         string
		cursorNeed  string
		action      string
		tags        []string
		transform   string
		omitEmpty   bool
		mustContain []string
		mustOmit    []string
	}{
		{
			name: "preserves_build_tag_doc_and_inline_comments",
			src: `//go:build darwin || linux

package models

// Profile holds user attributes.
type Profile struct {
	// UserID identifies the record.
	UserID   int    // primary key
	FullName string ` + "`yaml:\"full_name\"`" + ` // display name
}
`,
			cursorNeed:  "type Profile struct",
			action:      "add",
			tags:        []string{"json"},
			transform:   "snake",
			omitEmpty:   true,
			mustContain: []string{"//go:build darwin || linux", "// Profile holds user attributes.", "// UserID identifies the record.", "// primary key", "// display name", `json:"user_id,omitempty"`, `yaml:"full_name"`},
		},
		{
			name: "generic_and_unexported_struct_with_interpreted_tags",
			src: `package store

type item[T any] struct {
	KeyName string "db:\"key_name\" note:\"a\\\"b\""
	Value   T
}
`,
			cursorNeed:  "type item",
			action:      "add",
			tags:        []string{"json"},
			transform:   "snake",
			omitEmpty:   false,
			mustContain: []string{`json:"key_name"`, `json:"value"`, `db:"key_name"`},
		},
		{
			name: "remove_tag_keeps_comments_and_other_tags",
			src: `package models

type Config struct {
	HostName string ` + "`json:\"host_name\" yaml:\"host\"`" + ` // bind address
}
`,
			cursorNeed:  "type Config",
			action:      "remove",
			tags:        []string{"yaml"},
			mustContain: []string{`json:"host_name"`, "// bind address"},
			mustOmit:    []string{`yaml:`},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			off := strings.Index(tc.src, tc.cursorNeed)
			if off < 0 {
				t.Fatalf("missing %q", tc.cursorNeed)
			}
			reqBytes, _ := json.Marshal(StructTagRequest{
				Path:      "models.go",
				Src:       tc.src,
				Offset:    off,
				Action:    tc.action,
				Tags:      tc.tags,
				Transform: tc.transform,
				OmitEmpty: tc.omitEmpty,
			})
			var resp GenerateCodeResponse
			if err := json.Unmarshal([]byte(ModifyStructTags(string(reqBytes))), &resp); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if resp.Error != "" {
				t.Fatalf("resp.Error = %q", resp.Error)
			}
			updated := applyEditsToText(tc.src, resp.EditsByPath["models.go"])
			for _, want := range tc.mustContain {
				if !strings.Contains(updated, want) {
					t.Errorf("expected %q in:\n%s", want, updated)
				}
			}
			for _, forbid := range tc.mustOmit {
				if strings.Contains(updated, forbid) {
					t.Errorf("did not expect %q in:\n%s", forbid, updated)
				}
			}
			pkgName := "models"
			if strings.Contains(updated, "package store") {
				pkgName = "store"
			}
			typeCheckSingleGoastFile(t, pkgName, "models.go", updated)
		})
	}
}

func TestJSONToGoStruct_EdgeCasesAndTypeCheck(t *testing.T) {
	cases := []struct {
		name        string
		jsonText    string
		typeName    string
		mustContain []string
	}{
		{
			name:        "mixed_object_array_uint64_and_conflicts",
			jsonText:    `[{"id": 18446744073709551615, "score": 10, "meta": {"a": 1}, "dyn": "str"}, {"id": 2, "score": 2.5, "meta": {"b": true}, "dyn": 99}]`,
			typeName:    "Record",
			mustContain: []string{"type Record struct", "uint64", "Score float64", "Dyn  any", "A int", "B bool"},
		},
		{
			name:        "nested_object_arrays_with_empty_and_partial_samples",
			jsonText:    `[{"tags":[{"id":1}],"items":[{"x":1}]},{"tags":[],"items":[{"y":"s"}]}]`,
			typeName:    "Post",
			mustContain: []string{"Tags []struct", "ID int", "Items []struct", "X int", "Y string"},
		},
		{
			name:        "special_keys_quotes_backticks_digits_keywords",
			jsonText:    `{"a\"b": 1, "x` + "`" + `y": "ok", "123num": true, "type": "go"}`,
			typeName:    "SpecialPayload",
			mustContain: []string{"type SpecialPayload struct", `json:"a\"b"`, "XY", `\"x` + "`" + `y\"`, "string"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b, _ := json.Marshal(JSONToStructRequest{
				JSONText: tc.jsonText,
				TypeName: tc.typeName,
			})
			var resp JSONToStructResponse
			if err := json.Unmarshal([]byte(JSONToGoStruct(string(b))), &resp); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if resp.Error != "" {
				t.Fatalf("resp.Error = %q", resp.Error)
			}
			for _, want := range tc.mustContain {
				if !strings.Contains(resp.GoCode, want) {
					t.Errorf("expected %q in:\n%s", want, resp.GoCode)
				}
			}
			typeCheckSingleGoastFile(t, "generated", "gen.go", "package generated\n\n"+resp.GoCode)
		})
	}
}
