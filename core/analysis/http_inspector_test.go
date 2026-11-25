package analysis

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectHTTPSafety_AllCategories(t *testing.T) {
	src := `package netcheck

import (
	"crypto/tls"
	"net/http"
)

func FetchAndServe(endpoint string, req *http.Request) error {
	cli := &http.Client{}
	resp, err := http.Get(endpoint)
	if err != nil {
		return err
	}
	_ = resp

	resp2, err := cli.Do(req)
	if err != nil {
		return err
	}
	_ = resp2

	tr := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: true,
		},
	}
	_ = tr

	srv := &http.Server{Addr: ":8080"}
	_ = srv

	return http.ListenAndServe(":9090", nil)
}
`

	report, err := InspectHTTPSafety("service.go", src)
	if err != nil {
		t.Fatalf("InspectHTTPSafety returned unexpected error: %v", err)
	}
	if report.PackageName != "netcheck" {
		t.Fatalf("expected packageName 'netcheck', got %q", report.PackageName)
	}
	if report.DefaultClientCount != 2 {
		t.Fatalf("expected DefaultClientCount=2 (&http.Client{} + http.Get), got %d", report.DefaultClientCount)
	}
	if report.UnclosedBodyCount != 2 {
		t.Fatalf("expected UnclosedBodyCount=2 (resp + resp2), got %d", report.UnclosedBodyCount)
	}
	if report.ServerTimeoutCount != 2 {
		t.Fatalf("expected ServerTimeoutCount=2 (&http.Server + http.ListenAndServe), got %d", report.ServerTimeoutCount)
	}
	if report.InsecureTLSCount != 1 {
		t.Fatalf("expected InsecureTLSCount=1, got %d", report.InsecureTLSCount)
	}
	if report.TotalIssues != 7 {
		t.Fatalf("expected TotalIssues=7, got %d", report.TotalIssues)
	}
	if report.AutoFixableCount != 6 {
		t.Fatalf("expected AutoFixableCount=6, got %d", report.AutoFixableCount)
	}

	foundTLSMessage := false
	for _, iss := range report.Issues {
		if iss.Kind == "TLS_INSECURE_SKIP_VERIFY" {
			foundTLSMessage = true
			if iss.CanAutoFix {
				t.Fatalf("expected TLS_INSECURE_SKIP_VERIFY CanAutoFix=false")
			}
			if !strings.Contains(iss.Message, "InsecureSkipVerify: true") {
				t.Fatalf("unexpected TLS message: %q", iss.Message)
			}
		}
	}
	if !foundTLSMessage {
		t.Fatalf("expected to find TLS_INSECURE_SKIP_VERIFY issue")
	}
}

func TestInspectHTTPSafety_ApplyFixes(t *testing.T) {
	src := `package clientpkg

import (
	"crypto/tls"
	"net/http"
)

func RunWork(endpoint string) error {
	c := &http.Client{}
	_ = c

	resp, err := http.Get(endpoint)
	if err != nil {
		return err
	}
	_ = resp

	srv := &http.Server{Addr: ":8080"}
	_ = srv

	tlsCfg := &tls.Config{InsecureSkipVerify: true}
	_ = tlsCfg

	return nil
}
`

	fixedSrc, appliedCount, err := ApplyHTTPSafetyFixes("worker.go", src)
	if err != nil {
		t.Fatalf("ApplyHTTPSafetyFixes failed: %v", err)
	}
	if appliedCount != 4 {
		t.Fatalf("expected 4 applied fixes, got %d\nFixed source:\n%s", appliedCount, fixedSrc)
	}
	if !strings.Contains(fixedSrc, `"time"`) {
		t.Fatalf("expected 'time' import to be added:\n%s", fixedSrc)
	}
	if !strings.Contains(fixedSrc, `Timeout: 10 * time.Second`) {
		t.Fatalf("expected Timeout: 10 * time.Second in fixed code:\n%s", fixedSrc)
	}
	if !strings.Contains(fixedSrc, `(&http.Client{Timeout: 10 * time.Second}).Get(endpoint)`) {
		t.Fatalf("expected timed http.Client.Get in fixed code:\n%s", fixedSrc)
	}
	if !strings.Contains(fixedSrc, `ReadHeaderTimeout: 5 * time.Second`) {
		t.Fatalf("expected ReadHeaderTimeout: 5 * time.Second in fixed code:\n%s", fixedSrc)
	}
	if !strings.Contains(fixedSrc, `defer resp.Body.Close()`) {
		t.Fatalf("expected defer resp.Body.Close() in fixed code:\n%s", fixedSrc)
	}

	recheck, err := InspectHTTPSafety("worker.go", fixedSrc)
	if err != nil {
		t.Fatalf("re-running InspectHTTPSafety failed: %v", err)
	}
	if recheck.AutoFixableCount != 0 {
		t.Fatalf("expected 0 auto-fixable issues after ApplyHTTPSafetyFixes, got %d: %+v\nFixed:\n%s", recheck.AutoFixableCount, recheck.Issues, fixedSrc)
	}
	if recheck.DefaultClientCount != 0 || recheck.ServerTimeoutCount != 0 || recheck.UnclosedBodyCount != 0 {
		t.Fatalf("expected 0 client/server/body issues after fix, got %+v", recheck)
	}
	if recheck.InsecureTLSCount != 1 {
		t.Fatalf("expected 1 non-autofixable TLS issue to remain, got %d", recheck.InsecureTLSCount)
	}
}

func TestInspectHTTPSafety_SafeCodeAndDiskRead(t *testing.T) {
	safeSrc := `package safepkg

import (
	"crypto/tls"
	"net/http"
	"time"
)

func SafeCall(url string) error {
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	srv := &http.Server{
		Addr:              ":8443",
		ReadHeaderTimeout: 5 * time.Second,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS13,
		},
	}
	_ = srv
	return nil
}
`
	tmpDir := t.TempDir()
	filePath := filepath.Join(tmpDir, "safe.go")
	if err := os.WriteFile(filePath, []byte(safeSrc), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	report, err := InspectHTTPSafety(filePath, "")
	if err != nil {
		t.Fatalf("InspectHTTPSafety disk read failed: %v", err)
	}
	if report.TotalIssues != 0 {
		t.Fatalf("expected 0 issues on safe code, got %d: %+v", report.TotalIssues, report.Issues)
	}
}

func TestInspectHTTPSafety_UnclosedBodyWithoutErrCheckAndPostHead(t *testing.T) {
	src := `package main

import "net/http"

func QuickPing(url string) {
	resp, _ := http.Head(url)
	_ = resp
}
`
	report, err := InspectHTTPSafety("ping.go", src)
	if err != nil {
		t.Fatalf("InspectHTTPSafety failed: %v", err)
	}
	if report.DefaultClientCount != 1 || report.UnclosedBodyCount != 1 {
		t.Fatalf("expected 1 default client and 1 unclosed body issue, got %+v", report)
	}

	fixed, count, err := ApplyHTTPSafetyFixes("ping.go", src)
	if err != nil {
		t.Fatalf("ApplyHTTPSafetyFixes failed: %v", err)
	}
	if count != 2 {
		t.Fatalf("expected 2 fixes applied, got %d", count)
	}

	after, err := InspectHTTPSafety("ping.go", fixed)
	if err != nil {
		t.Fatalf("recheck failed: %v", err)
	}
	if after.TotalIssues != 0 {
		t.Fatalf("expected 0 issues after fix, got %d: %+v\nFixed:\n%s", after.TotalIssues, after.Issues, fixed)
	}
}

func TestInspectHTTPSafety_ListenAndServeAndMultilineLiterals(t *testing.T) {
	src := `package serverpkg

import (
	"net/http"
)

func StartAll(url string) error {
	cli := &http.Client{
		Transport: http.DefaultTransport,
	}
	_ = cli

	srv := &http.Server{
		Addr: ":8080",
	}
	_ = srv

	resp, err := http.Post(url, "application/json", nil)
	if err != nil {
		return err
	}
	_ = resp

	return http.ListenAndServe(":9000", nil)
}

func ReturnResponseCallerCloses(client *http.Client, req *http.Request) (*http.Response, error) {
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	return resp, nil
}
`

	report, err := InspectHTTPSafety("server.go", src)
	if err != nil {
		t.Fatalf("InspectHTTPSafety failed: %v", err)
	}
	if report.DefaultClientCount != 2 {
		t.Fatalf("expected DefaultClientCount=2, got %d", report.DefaultClientCount)
	}
	if report.ServerTimeoutCount != 2 {
		t.Fatalf("expected ServerTimeoutCount=2, got %d", report.ServerTimeoutCount)
	}
	if report.UnclosedBodyCount != 1 {
		t.Fatalf("expected UnclosedBodyCount=1 (returned response should not be flagged), got %d", report.UnclosedBodyCount)
	}

	fixed, applied, err := ApplyHTTPSafetyFixes("server.go", src)
	if err != nil {
		t.Fatalf("ApplyHTTPSafetyFixes failed: %v", err)
	}
	if applied != 5 {
		t.Fatalf("expected 5 fixes applied, got %d\nFixed:\n%s", applied, fixed)
	}

	after, err := InspectHTTPSafety("server.go", fixed)
	if err != nil {
		t.Fatalf("recheck failed: %v", err)
	}
	if after.TotalIssues != 0 || after.AutoFixableCount != 0 {
		t.Fatalf("expected 0 issues after fix, got %+v\nFixed:\n%s", after, fixed)
	}
}

