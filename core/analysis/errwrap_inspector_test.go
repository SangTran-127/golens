package analysis

import (
	"errors"
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestErrorWrapping_InspectAllThreeCategories(t *testing.T) {
	src := `package storage

import (
	"fmt"
	"io"
)

var ErrNotFound = fmt.Errorf("not found")

type MyError struct {
	Code int
}

func (e *MyError) Error() string { return "my error" }

func LoadRecord(name string, err error) error {
	if err == nil {
		return nil
	}
	if err == ErrNotFound {
		return fmt.Errorf("load %s failed: %v", name, err)
	}
	if err != io.EOF {
		return fmt.Errorf("unexpected stream failure: %s", err)
	}
	if target, ok := err.(*MyError); ok && target.Code == 500 {
		return fmt.Errorf("already wrapped: %w", err)
	}
	return nil
}
`

	report, err := InspectErrorWrapping("", "storage.go", src, false)
	if err != nil {
		t.Fatalf("InspectErrorWrapping returned error: %v", err)
	}

	if report.VerbCount != 2 {
		t.Errorf("expected VerbCount=2, got %d", report.VerbCount)
	}
	if report.EqualityCount != 2 {
		t.Errorf("expected EqualityCount=2, got %d", report.EqualityCount)
	}
	if report.TypeAssertCount != 1 {
		t.Errorf("expected TypeAssertCount=1, got %d", report.TypeAssertCount)
	}
	if report.TotalFindings != 5 {
		t.Fatalf("expected TotalFindings=5, got %d: %+v", report.TotalFindings, report.Findings)
	}

	var sawEq, sawNeq, sawVerbV, sawVerbS, sawTypeAssert bool
	for _, f := range report.Findings {
		if f.FunctionName != "LoadRecord" {
			t.Errorf("expected FunctionName=LoadRecord, got %q", f.FunctionName)
		}
		switch f.Kind {
		case "ERRWRAP_EQUALITY":
			if f.TargetName == "ErrNotFound" {
				sawEq = true
				if f.Title != "Error compared with == instead of errors.Is" {
					t.Errorf("unexpected equality title: %q", f.Title)
				}
				if !f.CanQuickFix {
					t.Errorf("expected CanQuickFix=true for ERRWRAP_EQUALITY")
				}
			}
			if f.TargetName == "io.EOF" {
				sawNeq = true
				if f.Title != "Error compared with != instead of errors.Is" {
					t.Errorf("unexpected inequality title: %q", f.Title)
				}
			}
		case "ERRWRAP_VERB":
			if strings.Contains(f.Snippet, "%v") {
				sawVerbV = true
			}
			if strings.Contains(f.Snippet, "%s") && strings.Contains(f.Snippet, "unexpected stream failure") {
				sawVerbS = true
			}
			if f.Title != "fmt.Errorf formats the error with %v instead of %w" {
				t.Errorf("unexpected verb title: %q", f.Title)
			}
			if !f.CanQuickFix {
				t.Errorf("expected CanQuickFix=true for ERRWRAP_VERB")
			}
		case "ERRWRAP_TYPE_ASSERT":
			if f.TargetName == "*MyError" {
				sawTypeAssert = true
				if f.Title != "Type assertion on an error instead of errors.As" {
					t.Errorf("unexpected type assert title: %q", f.Title)
				}
			}
		}
	}

	if !sawEq || !sawNeq || !sawVerbV || !sawVerbS || !sawTypeAssert {
		t.Errorf("missing expected findings: sawEq=%v sawNeq=%v sawVerbV=%v sawVerbS=%v sawTypeAssert=%v",
			sawEq, sawNeq, sawVerbV, sawVerbS, sawTypeAssert)
	}
}

func TestErrorWrapping_FixVerbAndEqualityAndAutoImport(t *testing.T) {
	src := `package storage

import (
	"fmt"
	"io"
)

var ErrNotFound = fmt.Errorf("not found")

func Process(name string, err error) error {
	if err == ErrNotFound {
		return fmt.Errorf("lookup %s: %v", name, err)
	}
	if err != io.EOF {
		return fmt.Errorf("read failed: %s", err)
	}
	return nil
}
`

	fixed1, err := FixErrorWrappingIssue("storage.go", src, 11, "ERRWRAP_EQUALITY", "ErrNotFound")
	if err != nil {
		t.Fatalf("FixErrorWrappingIssue equality failed: %v", err)
	}
	if !strings.Contains(fixed1, `if errors.Is(err, ErrNotFound)`) {
		t.Errorf("expected errors.Is(err, ErrNotFound), got:\n%s", fixed1)
	}
	if !strings.Contains(fixed1, `"errors"`) {
		t.Errorf("expected \"errors\" auto-imported, got:\n%s", fixed1)
	}

	reportAfter1, err := InspectErrorWrapping("", "storage.go", fixed1, false)
	if err != nil {
		t.Fatalf("re-inspect failed: %v", err)
	}

	cur := fixed1
	for _, f := range reportAfter1.Findings {
		if !f.CanQuickFix {
			continue
		}
		cur, err = FixErrorWrappingIssue("storage.go", cur, f.Line, f.Kind, f.TargetName)
		if err != nil {
			t.Fatalf("FixErrorWrappingIssue(%s at line %d) failed: %v", f.Kind, f.Line, err)
		}
	}

	if !strings.Contains(cur, `return fmt.Errorf("lookup %s: %w", name, err)`) {
		t.Errorf("expected %%v converted to %%w while preserving %%s, got:\n%s", cur)
	}
	if !strings.Contains(cur, `if !errors.Is(err, io.EOF)`) {
		t.Errorf("expected err != io.EOF converted to !errors.Is(err, io.EOF), got:\n%s", cur)
	}
	if !strings.Contains(cur, `return fmt.Errorf("read failed: %w", err)`) {
		t.Errorf("expected %%s converted to %%w, got:\n%s", cur)
	}

	if _, parseErr := parser.ParseFile(token.NewFileSet(), "storage.go", cur, parser.ParseComments); parseErr != nil {
		t.Fatalf("fixed code does not parse cleanly: %v\n%s", parseErr, cur)
	}

	finalReport, err := InspectErrorWrapping("", "storage.go", cur, false)
	if err != nil {
		t.Fatalf("final inspect failed: %v", err)
	}
	if finalReport.TotalFindings != 0 {
		t.Errorf("expected 0 findings after fixing all issues, got %d: %+v", finalReport.TotalFindings, finalReport.Findings)
	}

	idempotent, err := FixErrorWrappingIssue("storage.go", cur, 12, "ERRWRAP_VERB", "err")
	if err != nil {
		t.Fatalf("idempotent call returned error: %v", err)
	}
	if idempotent != cur {
		t.Errorf("expected FixErrorWrappingIssue to be idempotent")
	}
}

func TestErrorWrapping_WorkspaceInspection(t *testing.T) {
	tmpDir := t.TempDir()

	mainFile := filepath.Join(tmpDir, "repo.go")
	mainSrc := `package repo

import "fmt"

func Wrap(err error) error {
	return fmt.Errorf("repo: %v", err)
}
`
	if err := os.WriteFile(mainFile, []byte(mainSrc), 0644); err != nil {
		t.Fatal(err)
	}

	vendorDir := filepath.Join(tmpDir, "vendor", "ext")
	if err := os.MkdirAll(vendorDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vendorDir, "ext.go"), []byte(`package ext
import "fmt"
func Bad(err error) error { return fmt.Errorf("ext: %v", err) }
`), 0644); err != nil {
		t.Fatal(err)
	}

	report, err := InspectErrorWrapping(tmpDir, mainFile, "", true)
	if err != nil {
		t.Fatalf("workspace InspectErrorWrapping failed: %v", err)
	}
	if report.TotalFindings != 1 || report.VerbCount != 1 {
		t.Fatalf("expected 1 finding from workspace (excluding vendor), got %+v", report)
	}
}

func TestErrorWrapping_FixPositionalVerbPreservesArgumentMapping(t *testing.T) {
	src := `package main
import "fmt"
func wrap(err error, detail string) error {
	return fmt.Errorf("detail %[2]v error %[1]v", err, detail)
}
`
	fixed, err := FixErrorWrappingIssue("sample.go", src, 4, "ERRWRAP_VERB", "err")
	if err != nil {
		t.Fatalf("FixErrorWrappingIssue failed: %v", err)
	}
	if !strings.Contains(fixed, `fmt.Errorf("detail %[2]v error %[1]w", err, detail)`) {
		t.Fatalf("expected positional verb %%[1]w in fixed code, got:\n%s", fixed)
	}

	report, err := InspectErrorWrapping("", "sample.go", fixed, false)
	if err != nil {
		t.Fatalf("re-inspect failed: %v", err)
	}
	if report.TotalFindings != 0 {
		t.Fatalf("expected 0 findings after fix, got %+v", report.Findings)
	}

	rootErr := errors.New("failure")
	got := fmt.Errorf("detail %[2]v error %[1]w", rootErr, "disk")
	if got.Error() != "detail disk error failure" {
		t.Fatalf("got formatted error %q, want %q", got.Error(), "detail disk error failure")
	}
	if !errors.Is(got, rootErr) {
		t.Fatalf("expected errors.Is(got, rootErr) == true")
	}
}
