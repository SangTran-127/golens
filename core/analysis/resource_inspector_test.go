package analysis

import (
	"encoding/json"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestResourceInspector_UnclosedAndSafeResources(t *testing.T) {
	src := `package service

import (
	"database/sql"
	"net/http"
	"os"
)

func LoadLeakyResources(db *sql.DB, client *http.Client) error {
	f, err := os.Open("config.json")
	if err != nil {
		return err
	}
	_ = f

	resp, err := http.Get("https://example.com/data")
	if err != nil {
		return err
	}
	_ = resp

	rows, err := db.Query("SELECT id, email FROM users WHERE active = $1", true)
	if err != nil {
		return err
	}
	_ = rows

	req, _ := http.NewRequest("GET", "https://example.com", nil)
	doResp, err := client.Do(req)
	if err != nil {
		return err
	}
	_ = doResp

	return nil
}

func LoadSafeResources(db *sql.DB) (*os.File, error) {
	closedFile, err := os.Open("closed.txt")
	if err != nil {
		return nil, err
	}
	defer closedFile.Close()

	resp, err := http.Get("https://example.com/health")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	rows, err := db.Query("SELECT 1")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	returnedFile, err := os.Create("output.txt")
	if err != nil {
		return nil, err
	}
	return returnedFile, nil
}
`

	report, err := InspectResourceAndInjectionRisks("", "service.go", src, false)
	if err != nil {
		t.Fatalf("InspectResourceAndInjectionRisks returned error: %v", err)
	}

	if report.UnclosedCount != 4 {
		t.Fatalf("expected UnclosedCount=4, got %d: %+v", report.UnclosedCount, report.Findings)
	}
	if report.SQLRiskCount != 0 {
		t.Errorf("expected SQLRiskCount=0 for parameterized queries, got %d", report.SQLRiskCount)
	}
	if report.CmdRiskCount != 0 {
		t.Errorf("expected CmdRiskCount=0, got %d", report.CmdRiskCount)
	}
	if report.TotalFindings != 4 {
		t.Fatalf("expected TotalFindings=4, got %d", report.TotalFindings)
	}

	expectedTargets := map[string]string{
		"f":           "Insert defer f.Close()",
		"resp.Body":   "Insert defer resp.Body.Close()",
		"rows":        "Insert defer rows.Close()",
		"doResp.Body": "Insert defer doResp.Body.Close()",
	}

	for _, f := range report.Findings {
		if f.Kind != "RESOURCE_UNCLOSED" {
			t.Errorf("expected kind RESOURCE_UNCLOSED, got %q", f.Kind)
		}
		if f.FunctionName != "LoadLeakyResources" {
			t.Errorf("expected FunctionName=LoadLeakyResources, got %q", f.FunctionName)
		}
		if !f.CanQuickFix {
			t.Errorf("expected CanQuickFix=true for %+v", f)
		}
		wantFix, ok := expectedTargets[f.TargetName]
		if !ok {
			t.Errorf("unexpected TargetName %q in finding %+v", f.TargetName, f)
		} else if f.SuggestedFix != wantFix {
			t.Errorf("expected SuggestedFix=%q for %s, got %q", wantFix, f.TargetName, f.SuggestedFix)
		}
	}
}

func TestResourceInspector_SQLAndCommandInjectionRisks(t *testing.T) {
	src := `package runner

import (
	"context"
	"database/sql"
	"fmt"
	"os/exec"
)

func RunUnsafeQueriesAndCommands(ctx context.Context, db *sql.DB, userInput string, host string) error {
	rows, err := db.Query("SELECT * FROM accounts WHERE username = '" + userInput + "'")
	if err != nil {
		return err
	}
	defer rows.Close()

	_, err = db.ExecContext(ctx, fmt.Sprintf("DELETE FROM sessions WHERE token = '%s'", userInput))
	if err != nil {
		return err
	}

	cmd1 := exec.Command("sh", "-c", "ping -c 1 "+host)
	_ = cmd1.Run()

	cmd2 := exec.Command(fmt.Sprintf("/usr/local/bin/%s", host), "--version")
	_ = cmd2.Run()

	safeCmd := exec.Command("git", "status", "--porcelain", host)
	_ = safeCmd.Run()

	return nil
}
`

	report, err := InspectResourceAndInjectionRisks("", "runner.go", src, false)
	if err != nil {
		t.Fatalf("InspectResourceAndInjectionRisks returned error: %v", err)
	}

	if report.UnclosedCount != 0 {
		t.Errorf("expected UnclosedCount=0 (rows is closed), got %d", report.UnclosedCount)
	}
	if report.SQLRiskCount != 2 {
		t.Errorf("expected SQLRiskCount=2, got %d: %+v", report.SQLRiskCount, report.Findings)
	}
	if report.CmdRiskCount != 2 {
		t.Errorf("expected CmdRiskCount=2, got %d: %+v", report.CmdRiskCount, report.Findings)
	}
	if report.TotalFindings != 4 {
		t.Fatalf("expected TotalFindings=4, got %d: %+v", report.TotalFindings, report.Findings)
	}

	for _, f := range report.Findings {
		if f.Severity != "high" {
			t.Errorf("expected Severity=high for injection finding, got %q", f.Severity)
		}
		if f.FunctionName != "RunUnsafeQueriesAndCommands" {
			t.Errorf("expected FunctionName=RunUnsafeQueriesAndCommands, got %q", f.FunctionName)
		}
	}
}

func TestResourceInspector_FixUnclosedResourceWithAndWithoutErrCheck(t *testing.T) {
	src := `package loader

import (
	"net/http"
	"os"
)

func ReadWithErrCheck(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	_ = f
	return nil
}

func ReadWithoutErrCheck(path string) {
	rawFile, _ := os.Open(path)
	_ = rawFile
}

func FetchURL(url string) error {
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	_ = resp
	return nil
}
`

	initialReport, err := InspectResourceAndInjectionRisks("", "loader.go", src, false)
	if err != nil {
		t.Fatalf("initial inspect failed: %v", err)
	}
	if initialReport.UnclosedCount != 3 {
		t.Fatalf("expected 3 unclosed findings, got %d", initialReport.UnclosedCount)
	}

	// Fix 1: ReadWithErrCheck (has `if err != nil` block right after line 9)
	fixed1, err := FixResourceRiskIssue("loader.go", src, 9, "RESOURCE_UNCLOSED", "f")
	if err != nil {
		t.Fatalf("FixResourceRiskIssue with err check failed: %v", err)
	}
	wantWithErrBlock := "if err != nil {\n\t\treturn err\n\t}\n\tdefer f.Close()\n\t_ = f"
	if !strings.Contains(fixed1, wantWithErrBlock) {
		t.Errorf("expected defer f.Close() placed after if err != nil block, got:\n%s", fixed1)
	}

	// Fix 2: ReadWithoutErrCheck (no `if err != nil` block)
	reportAfter1, err := InspectResourceAndInjectionRisks("", "loader.go", fixed1, false)
	if err != nil {
		t.Fatalf("inspect after fix 1 failed: %v", err)
	}
	var rawFileLine int
	for _, f := range reportAfter1.Findings {
		if f.TargetName == "rawFile" {
			rawFileLine = f.Line
		}
	}
	if rawFileLine == 0 {
		t.Fatalf("expected to find rawFile finding in reportAfter1: %+v", reportAfter1.Findings)
	}

	fixed2, err := FixResourceRiskIssue("loader.go", fixed1, rawFileLine, "RESOURCE_UNCLOSED", "rawFile")
	if err != nil {
		t.Fatalf("FixResourceRiskIssue without err check failed: %v", err)
	}
	wantWithoutErrBlock := "rawFile, _ := os.Open(path)\n\tdefer rawFile.Close()\n\t_ = rawFile"
	if !strings.Contains(fixed2, wantWithoutErrBlock) {
		t.Errorf("expected defer rawFile.Close() placed directly after assignment, got:\n%s", fixed2)
	}

	// Fix 3: FetchURL (resp.Body)
	reportAfter2, err := InspectResourceAndInjectionRisks("", "loader.go", fixed2, false)
	if err != nil {
		t.Fatalf("inspect after fix 2 failed: %v", err)
	}
	if reportAfter2.UnclosedCount != 1 {
		t.Fatalf("expected 1 remaining unclosed finding, got %d", reportAfter2.UnclosedCount)
	}
	respFinding := reportAfter2.Findings[0]
	fixed3, err := FixResourceRiskIssue("loader.go", fixed2, respFinding.Line, respFinding.Kind, respFinding.TargetName)
	if err != nil {
		t.Fatalf("FixResourceRiskIssue for resp.Body failed: %v", err)
	}
	if !strings.Contains(fixed3, "defer resp.Body.Close()") {
		t.Errorf("expected defer resp.Body.Close() in fixed source, got:\n%s", fixed3)
	}

	if _, parseErr := parser.ParseFile(token.NewFileSet(), "loader.go", fixed3, parser.ParseComments); parseErr != nil {
		t.Fatalf("fixed source does not parse cleanly: %v\n%s", parseErr, fixed3)
	}

	finalReport, err := InspectResourceAndInjectionRisks("", "loader.go", fixed3, false)
	if err != nil {
		t.Fatalf("final inspect failed: %v", err)
	}
	if finalReport.TotalFindings != 0 {
		t.Errorf("expected 0 findings after fixing all issues, got %d: %+v", finalReport.TotalFindings, finalReport.Findings)
	}
}

func TestResourceInspector_WorkspaceScanning(t *testing.T) {
	tmpDir := t.TempDir()

	appFile := filepath.Join(tmpDir, "store.go")
	appSrc := `package store

import (
	"database/sql"
	"os"
)

func QueryUnsafe(db *sql.DB, filter string) error {
	f, err := os.Open("audit.log")
	if err != nil {
		return err
	}
	_ = f
	_, err = db.Exec("DELETE FROM audit WHERE kind = '" + filter + "'")
	return err
}
`
	if err := os.WriteFile(appFile, []byte(appSrc), 0644); err != nil {
		t.Fatal(err)
	}

	vendorDir := filepath.Join(tmpDir, "vendor", "pkg")
	if err := os.MkdirAll(vendorDir, 0755); err != nil {
		t.Fatal(err)
	}
	vendorFile := filepath.Join(vendorDir, "vendor.go")
	if err := os.WriteFile(vendorFile, []byte(`package pkg
import "os"
func Leak() { f, _ := os.Open("x"); _ = f }
`), 0644); err != nil {
		t.Fatal(err)
	}

	hiddenDir := filepath.Join(tmpDir, ".hidden")
	if err := os.MkdirAll(hiddenDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hiddenDir, "hidden.go"), []byte(`package hidden
import "os"
func Leak() { f, _ := os.Open("y"); _ = f }
`), 0644); err != nil {
		t.Fatal(err)
	}

	report, err := InspectResourceAndInjectionRisks(tmpDir, appFile, "", true)
	if err != nil {
		t.Fatalf("workspace InspectResourceAndInjectionRisks failed: %v", err)
	}
	if report.TotalFindings != 2 || report.UnclosedCount != 1 || report.SQLRiskCount != 1 {
		t.Fatalf("expected 2 findings (1 unclosed, 1 SQL risk) from workspace excluding vendor/.hidden, got %+v", report)
	}
}

func TestResourceInspector_NonReturningErrCheckDoesNotPanic(t *testing.T) {
	src := `package main

import (
	"fmt"
	"log"
	"net/http"
)

func main() {
	resp, err := http.Get("://bad")
	if err != nil {
		log.Println(err)
	}
	if resp == nil {
		return
	}
	fmt.Println(resp.Status)
}
`

	report, err := InspectResourceAndInjectionRisks("", "main.go", src, false)
	if err != nil {
		t.Fatalf("InspectResourceAndInjectionRisks failed: %v", err)
	}
	if len(report.Findings) != 1 {
		t.Fatalf("expected 1 finding, got %d: %+v", len(report.Findings), report.Findings)
	}

	f := report.Findings[0]
	fixed, err := FixResourceRiskIssue("main.go", src, f.Line, f.Kind, f.TargetName)
	if err != nil {
		t.Fatalf("FixResourceRiskIssue failed: %v", err)
	}

	nilCheckIdx := strings.Index(fixed, "if resp == nil")
	deferIdx := strings.Index(fixed, "defer resp.Body.Close()")
	if nilCheckIdx < 0 || deferIdx < 0 || deferIdx < nilCheckIdx {
		t.Fatalf("expected defer resp.Body.Close() to be placed after 'if resp == nil' guard, got:\n%s", fixed)
	}

	recheck, err := InspectResourceAndInjectionRisks("", "main.go", fixed, false)
	if err != nil {
		t.Fatalf("recheck failed: %v", err)
	}
	if recheck.TotalFindings != 0 {
		t.Fatalf("expected 0 findings after fix, got %d: %+v", recheck.TotalFindings, recheck.Findings)
	}

	tmpDir := t.TempDir()
	mainPath := filepath.Join(tmpDir, "main.go")
	if err := os.WriteFile(mainPath, []byte(fixed), 0644); err != nil {
		t.Fatal(err)
	}
	out, runErr := exec.Command("go", "run", mainPath).CombinedOutput()
	if runErr != nil {
		t.Fatalf("running fixed program panicked or failed: %v\noutput:\n%s\ncode:\n%s", runErr, string(out), fixed)
	}

	// Also verify when there is a non-returning `if err != nil` and NO `if resp == nil` guard
	srcNoNilGuard := `package main

import (
	"log"
	"net/http"
)

func main() {
	resp, err := http.Get("://bad")
	if err != nil {
		log.Println(err)
	}
	_ = resp
}
`
	rep2, err := InspectResourceAndInjectionRisks("", "main2.go", srcNoNilGuard, false)
	if err != nil || len(rep2.Findings) != 1 {
		t.Fatalf("expected 1 finding for srcNoNilGuard, got %+v (err=%v)", rep2.Findings, err)
	}
	fixed2, err := FixResourceRiskIssue("main2.go", srcNoNilGuard, rep2.Findings[0].Line, rep2.Findings[0].Kind, rep2.Findings[0].TargetName)
	if err != nil {
		t.Fatalf("FixResourceRiskIssue on srcNoNilGuard failed: %v", err)
	}
	if !strings.Contains(fixed2, "if resp != nil && resp.Body != nil") {
		t.Fatalf("expected nil-safe defer guard when err check does not return, got:\n%s", fixed2)
	}
	main2Path := filepath.Join(tmpDir, "main2.go")
	if err := os.WriteFile(main2Path, []byte(fixed2), 0644); err != nil {
		t.Fatal(err)
	}
	if out2, err2 := exec.Command("go", "run", main2Path).CombinedOutput(); err2 != nil {
		t.Fatalf("running fixed2 program panicked or failed: %v\noutput:\n%s\ncode:\n%s", err2, string(out2), fixed2)
	}
}

func TestResourceInspector_EarlyReturnLeakAndOpenRootAndSafePatterns(t *testing.T) {
	src := `package flow

import (
	"errors"
	"io"
	"os"
	"testing"
)

func LeakBeforeHappyClose(path string, fail bool) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	if fail {
		return errors.New("bad")
	}
	buf := make([]byte, 8)
	_, err = f.Read(buf)
	f.Close()
	return err
}

func LeakOpenRoot(dir string, skip bool) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	if skip {
		return errors.New("skip")
	}
	_ = root.Close()
	return nil
}

func LeakRootSubOpen(root *os.Root) error {
	f, err := root.Open("cfg.json")
	if err != nil {
		return err
	}
	_ = f
	return nil
}

func SafeBothBranchesClosed(path string, branch bool) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	if branch {
		f.Close()
		return errors.New("branch")
	}
	return f.Close()
}

func SafeErrEqualNilGuard(path string) {
	f, err := os.Open(path)
	if err == nil {
		defer f.Close()
		_, _ = io.ReadAll(f)
	}
}

func SafeDeferClosure(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	if path == "" {
		return errors.New("empty")
	}
	return nil
}

type fileHolder struct {
	file *os.File
}

func SafeReturnedStructFieldAndSlice(path string) (*fileHolder, []*os.File, error) {
	f1, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	var list []*os.File
	f2, err := os.Open(path)
	if err != nil {
		_ = f1.Close()
		return nil, nil, err
	}
	list = append(list, f2)
	return &fileHolder{file: f1}, list, nil
}

func SafeTestCleanup(t *testing.T, path string) {
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = f.Close() })
}

func SafeOuterVarAssignedInBranches(flag bool) error {
	var f *os.File
	var err error
	if flag {
		f, err = os.Open("a")
	} else {
		f, err = os.Open("b")
	}
	if err != nil {
		return err
	}
	defer f.Close()
	return nil
}

func LeakInsideLoop(paths []string) error {
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		_ = f
	}
	return nil
}
`

	rep, err := InspectResourceAndInjectionRisks("", "flow.go", src, false)
	if err != nil {
		t.Fatalf("InspectResourceAndInjectionRisks failed: %v", err)
	}
	wantFn := map[string]bool{
		"LeakBeforeHappyClose": true,
		"LeakOpenRoot":         true,
		"LeakRootSubOpen":      true,
		"LeakInsideLoop":       true,
	}
	gotFn := make(map[string]bool)
	for _, f := range rep.Findings {
		gotFn[f.FunctionName] = true
		if f.FunctionName == "LeakInsideLoop" {
			if f.CanQuickFix {
				t.Fatalf("expected CanQuickFix=false for loop finding: %+v", f)
			}
			if _, fixErr := FixResourceRiskIssue("flow.go", src, f.Line, f.Kind, f.TargetName); fixErr == nil {
				t.Fatalf("expected FixResourceRiskIssue to refuse loop acquisition")
			}
		} else if !f.CanQuickFix {
			t.Fatalf("expected CanQuickFix=true for %s: %+v", f.FunctionName, f)
		}
	}
	if len(gotFn) != len(wantFn) {
		t.Fatalf("findings mismatch: got=%+v wantFunctions=%v", rep.Findings, wantFn)
	}
	for fn := range wantFn {
		if !gotFn[fn] {
			t.Fatalf("missing finding for %s; got=%+v", fn, rep.Findings)
		}
	}
}

func TestResourceInspector_FixRemovesRedundantCloseButPreservesCheckedAndReassignedClose(t *testing.T) {
	src := `package clean

import (
	"errors"
	"os"
)

func FixAndClean(path string, fail bool) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	if fail {
		return errors.New("fail")
	}
	buf := make([]byte, 4)
	_, _ = f.Read(buf)
	_ = f.Close()
	return nil
}

func KeepCheckedClose(path string, fail bool) error {
	w, err := os.Create(path)
	if err != nil {
		return err
	}
	if fail {
		return errors.New("fail")
	}
	_, _ = w.Write([]byte("ok"))
	err = w.Close()
	return err
}

func KeepPostReassignClose(p1, p2 string, fail bool) error {
	h, err := os.Open(p1)
	if err != nil {
		return err
	}
	if fail {
		return errors.New("fail")
	}
	h, err = os.Open(p2)
	if err != nil {
		return err
	}
	h.Close()
	return nil
}
`
	lineOfNeedle := func(s, needle string) int {
		for idx, l := range strings.Split(s, "\n") {
			if strings.Contains(l, needle) {
				return idx + 1
			}
		}
		return 0
	}

	f1, err := FixResourceRiskIssue("clean.go", src, lineOfNeedle(src, `os.Open(path)`), "RESOURCE_UNCLOSED", "f")
	if err != nil {
		t.Fatalf("FixAndClean failed: %v", err)
	}
	if strings.Contains(f1, `_ = f.Close()`) {
		t.Fatalf("expected redundant _ = f.Close() removed:\n%s", f1)
	}
	if !strings.Contains(f1, "defer f.Close()") {
		t.Fatalf("expected defer f.Close():\n%s", f1)
	}

	f2, err := FixResourceRiskIssue("clean.go", src, lineOfNeedle(src, `os.Create(path)`), "RESOURCE_UNCLOSED", "w")
	if err != nil {
		t.Fatalf("KeepCheckedClose failed: %v", err)
	}
	if !strings.Contains(f2, "err = w.Close()") || !strings.Contains(f2, "defer w.Close()") {
		t.Fatalf("expected checked err = w.Close() preserved alongside defer w.Close():\n%s", f2)
	}

	f3, err := FixResourceRiskIssue("clean.go", src, lineOfNeedle(src, `os.Open(p1)`), "RESOURCE_UNCLOSED", "h")
	if err != nil {
		t.Fatalf("KeepPostReassignClose failed: %v", err)
	}
	if !strings.Contains(f3, "h.Close()") || !strings.Contains(f3, "defer h.Close()") {
		t.Fatalf("expected h.Close() after reassignment preserved alongside defer h.Close():\n%s", f3)
	}
}

func TestResourceInspector_PreservesReadAfterCloseNestedReassignAndBufferWriters(t *testing.T) {
	lineOf := func(s, needle string) int {
		for idx, l := range strings.Split(s, "\n") {
			if strings.Contains(l, needle) {
				return idx + 1
			}
		}
		t.Fatalf("missing %q", needle)
		return 0
	}

	writeReadSrc := `package files

import "os"

func writeAndRead(path string, abort bool) ([]byte, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	if abort {
		return nil, os.ErrInvalid
	}
	if _, err := f.WriteString("hello"); err != nil {
		return nil, err
	}
	f.Close()
	return os.ReadFile(path)
}
`
	fixedWriteRead, err := FixResourceRiskIssue("files.go", writeReadSrc, lineOf(writeReadSrc, "os.Create("), "RESOURCE_UNCLOSED", "f")
	if err != nil {
		t.Fatalf("writeAndRead fix: %v", err)
	}
	if !strings.Contains(fixedWriteRead, "defer f.Close()") || !strings.Contains(fixedWriteRead, "f.Close()\n\treturn os.ReadFile(path)") {
		t.Fatalf("expected sync f.Close() before os.ReadFile preserved alongside defer f.Close():\n%s", fixedWriteRead)
	}
	repAfter, err := InspectResourceAndInjectionRisks("", "files.go", fixedWriteRead, false)
	if err != nil || len(repAfter.Findings) != 0 {
		t.Fatalf("expected 0 findings after writeAndRead fix, got err=%v findings=%+v\n%s", err, repAfter.Findings, fixedWriteRead)
	}

	nestedReassignSrc := `package swap

import "os"

func swapInput(p1, p2 string, swap bool) error {
	f, err := os.Open(p1)
	if err != nil {
		return err
	}
	if p1 == "" {
		return os.ErrInvalid
	}
	if swap {
		_ = f.Close()
		f, err = os.Open(p2)
		if err != nil {
			return err
		}
	}
	_ = f.Close()
	return nil
}
`
	fixedSwap, err := FixResourceRiskIssue("swap.go", nestedReassignSrc, lineOf(nestedReassignSrc, "os.Open(p1)"), "RESOURCE_UNCLOSED", "f")
	if err != nil {
		t.Fatalf("swapInput fix: %v", err)
	}
	if !strings.Contains(fixedSwap, "defer f.Close()") {
		t.Fatalf("expected defer f.Close() in swapInput:\n%s", fixedSwap)
	}
	if strings.Count(fixedSwap, "_ = f.Close()") != 2 {
		t.Fatalf("expected both _ = f.Close() preserved when f is reassigned in nested if:\n%s", fixedSwap)
	}
	repSwap, err := InspectResourceAndInjectionRisks("", "swap.go", fixedSwap, false)
	if err != nil || len(repSwap.Findings) != 0 {
		t.Fatalf("expected 0 findings after nested swapInput fix, got err=%v findings=%+v\n%s", err, repSwap.Findings, fixedSwap)
	}

	addrSrc := `package addr

import "os"

func takeAddr(fPtr **os.File) {}

func addrRebind(p string, fail bool) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	if fail {
		return os.ErrInvalid
	}
	takeAddr(&f)
	_ = f.Close()
	return nil
}
`
	fixedAddr, err := FixResourceRiskIssue("addr.go", addrSrc, lineOf(addrSrc, "os.Open(p)"), "RESOURCE_UNCLOSED", "f")
	if err != nil {
		t.Fatalf("addrRebind fix: %v", err)
	}
	if !strings.Contains(fixedAddr, "_ = f.Close()") {
		t.Fatalf("expected trailing _ = f.Close() preserved when &f is taken:\n%s", fixedAddr)
	}

	multipartSafeSrc := `package upload

import (
	"bytes"
	"io"
	"mime/multipart"
	"net/http"
)

func postPart(url string, r io.Reader) (*http.Request, error) {
	body := &bytes.Buffer{}
	writer := multipart.NewWriter(body)
	part, err := writer.CreateFormFile("file", "a.txt")
	if err != nil {
		return nil, err
	}
	if _, err := io.Copy(part, r); err != nil {
		return nil, err
	}
	writer.Close()
	req, err := http.NewRequest("POST", url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", writer.FormDataContentType())
	return req, nil
}
`
	repMultipart, err := InspectResourceAndInjectionRisks("", "upload.go", multipartSafeSrc, false)
	if err != nil {
		t.Fatalf("InspectResourceAndInjectionRisks multipart: %v", err)
	}
	if len(repMultipart.Findings) != 0 {
		t.Fatalf("expected 0 false-positive findings for multipart.NewWriter closed before http.NewRequest(body), got %+v", repMultipart.Findings)
	}
	if _, fixErr := FixResourceRiskIssue("upload.go", multipartSafeSrc, lineOf(multipartSafeSrc, "multipart.NewWriter"), "RESOURCE_UNCLOSED", "writer"); fixErr == nil {
		fixedBuf, _ := FixResourceRiskIssue("upload.go", multipartSafeSrc, lineOf(multipartSafeSrc, "multipart.NewWriter"), "RESOURCE_UNCLOSED", "writer")
		if fixedBuf != multipartSafeSrc && !strings.Contains(fixedBuf, "writer.Close()") {
			t.Fatalf("multipart writer.Close() was removed:\n%s", fixedBuf)
		}
	}

	gzipUnclosedBufSrc := `package zipbuf

import (
	"bytes"
	"compress/gzip"
)

func compressForgotClose(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
`
	repGzip, err := InspectResourceAndInjectionRisks("", "zipbuf.go", gzipUnclosedBufSrc, false)
	if err != nil || len(repGzip.Findings) != 1 {
		t.Fatalf("expected 1 finding for unclosed gzip.NewWriter(&buf), got err=%v findings=%+v", err, repGzip.Findings)
	}
	if repGzip.Findings[0].CanQuickFix {
		t.Fatalf("expected CanQuickFix=false when gzip buffer is read in return: %+v", repGzip.Findings[0])
	}
	if _, fixErr := FixResourceRiskIssue("zipbuf.go", gzipUnclosedBufSrc, lineOf(gzipUnclosedBufSrc, "gzip.NewWriter"), "RESOURCE_UNCLOSED", "zw"); fixErr == nil {
		t.Fatalf("expected FixResourceRiskIssue to refuse defer fix before buffer read")
	}

	gzipClosedBufSrc := `package zipbufok

import (
	"bytes"
	"compress/gzip"
)

func compressClosedBeforeBytes(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(data); err != nil {
		return nil, err
	}
	zw.Close()
	return buf.Bytes(), nil
}
`
	repGzipOK, err := InspectResourceAndInjectionRisks("", "zipbufok.go", gzipClosedBufSrc, false)
	if err != nil || len(repGzipOK.Findings) != 0 {
		t.Fatalf("expected 0 findings when gzip.NewWriter is closed synchronously before buf.Bytes(), got err=%v findings=%+v", err, repGzipOK.Findings)
	}
}

func TestResourceInspector_NonTerminatingElseAndElseIfGuardsNilSafe(t *testing.T) {
	lineOf := func(s, needle string) int {
		for idx, l := range strings.Split(s, "\n") {
			if strings.Contains(l, needle) {
				return idx + 1
			}
		}
		t.Fatalf("missing %q", needle)
		return 0
	}

	nonTermElseSrc := `package logsafe

import (
	"log"
	"os"
)

func readWithLogElse(path string, fail bool) error {
	f, err := os.Open(path)
	if err != nil {
		log.Println(err)
	} else {
		if fail {
			return os.ErrInvalid
		}
		_ = f.Name()
	}
	if fail {
		return os.ErrPermission
	}
	return nil
}
`
	fixedElse, err := FixResourceRiskIssue("logsafe.go", nonTermElseSrc, lineOf(nonTermElseSrc, "os.Open("), "RESOURCE_UNCLOSED", "f")
	if err != nil {
		t.Fatalf("readWithLogElse fix: %v", err)
	}
	if strings.Contains(strings.Split(fixedElse, "if err != nil")[0], "defer f.Close()") {
		t.Fatalf("bare defer must NEVER be inserted before nil check:\n%s", fixedElse)
	}
	if !strings.Contains(fixedElse, "} else {\n\t\tdefer f.Close()") {
		t.Fatalf("expected defer f.Close() inside else block:\n%s", fixedElse)
	}
	typeCheckFixture(t, "logsafe.go", fixedElse)
	repElse, err := InspectResourceAndInjectionRisks("", "logsafe.go", fixedElse, false)
	if err != nil || len(repElse.Findings) != 0 {
		t.Fatalf("expected 0 residual findings after else fix, got err=%v findings=%+v\n%s", err, repElse.Findings, fixedElse)
	}

	elseIfSrc := `package elseifsafe

import (
	"log"
	"os"
)

func readWithElseIf(path string, alt bool, fail bool) error {
	f, err := os.Open(path)
	if err != nil {
		log.Println(err)
	} else if alt {
		_ = f.Name()
	}
	if fail {
		return os.ErrInvalid
	}
	return nil
}
`
	fixedElseIf, err := FixResourceRiskIssue("elseifsafe.go", elseIfSrc, lineOf(elseIfSrc, "os.Open("), "RESOURCE_UNCLOSED", "f")
	if err != nil {
		t.Fatalf("readWithElseIf fix: %v", err)
	}
	if strings.Contains(strings.Split(fixedElseIf, "if err != nil")[0], "defer f.Close()") {
		t.Fatalf("bare defer must NEVER be inserted before nil check:\n%s", fixedElseIf)
	}
	if !strings.Contains(fixedElseIf, "if f != nil {\n\t\tdefer f.Close()\n\t}") {
		t.Fatalf("expected nil-guarded defer after if/else-if chain:\n%s", fixedElseIf)
	}
	typeCheckFixture(t, "elseifsafe.go", fixedElseIf)
	repElseIf, err := InspectResourceAndInjectionRisks("", "elseifsafe.go", fixedElseIf, false)
	if err != nil || len(repElseIf.Findings) != 0 {
		t.Fatalf("expected 0 residual findings after else-if fix, got err=%v findings=%+v\n%s", err, repElseIf.Findings, fixedElseIf)
	}
}

func collectCorpusPackageDirs(root string) ([]string, error) {
	pkgSet := make(map[string]bool)
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			base := d.Name()
			if base == "vendor" || base == "testdata" || strings.HasPrefix(base, ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(d.Name(), ".go") {
			pkgSet[filepath.Dir(p)] = true
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	dirs := make([]string, 0, len(pkgSet))
	for d := range pkgSet {
		dirs = append(dirs, d)
	}
	sort.Strings(dirs)
	return dirs, nil
}

func TestDualCorpusResourceAndSQLAnalyzerRegressionAndSpeed(t *testing.T) {
	runCorpus := func(t *testing.T, root string, assertZeroResourceAndSQLFP bool) {
		t.Helper()
		dirs, err := collectCorpusPackageDirs(root)
		if err != nil {
			t.Fatalf("walk %s: %v", root, err)
		}
		if len(dirs) == 0 {
			t.Fatalf("no Go packages found in %s", root)
		}
		var durations []time.Duration
		var resourceSQLFindings []string
		for _, dir := range dirs {
			start := time.Now()
			raw := RunPackageAnalyzersJSON(root, dir, "")
			durations = append(durations, time.Since(start))

			var res PackageAnalyzeResult
			if err := json.Unmarshal([]byte(raw), &res); err != nil {
				t.Fatalf("unmarshal %s: %v", dir, err)
			}
			for filePath, diags := range res.Files {
				for _, d := range diags {
					if d.Code == CategoryResourceSafety && (strings.Contains(d.Message, "never closed") || strings.Contains(d.Message, "early return") || strings.Contains(d.Message, "SQL transaction")) {
						resourceSQLFindings = append(resourceSQLFindings, filePath+":"+d.Message)
						data, readErr := os.ReadFile(filePath)
						if readErr == nil {
							_, _ = ContextualASTQuickFixes(root, filePath, string(data), d.Line+1)
						}
					}
				}
			}
		}
		sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
		median := durations[len(durations)/2]
		if median > 200*time.Millisecond {
			t.Fatalf("%s median package latency %v exceeds 200ms across %d packages", root, median, len(dirs))
		}
		t.Logf("%s: %d packages, median=%v, findings=%d", root, len(dirs), median, len(resourceSQLFindings))
		for _, item := range resourceSQLFindings {
			t.Logf("  finding: %s", item)
		}
		if assertZeroResourceAndSQLFP && len(resourceSQLFindings) > 0 {
			t.Fatalf("expected 0 resource/SQL leak findings in %s, got %d:\n%s", root, len(resourceSQLFindings), strings.Join(resourceSQLFindings, "\n"))
		}
	}

	coreRoot, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	t.Run("velo_core", func(t *testing.T) {
		runCorpus(t, coreRoot, true)
	})

	lmsBackend := os.Getenv("GOLENS_LMS_BACKEND")
	t.Run("lms_saas_backend", func(t *testing.T) {
		if st, err := os.Stat(lmsBackend); lmsBackend == "" || err != nil || !st.IsDir() {
			t.Skip("set GOLENS_LMS_BACKEND to an lms-saas backend checkout")
		}
		runCorpus(t, lmsBackend, false)
	})
}
