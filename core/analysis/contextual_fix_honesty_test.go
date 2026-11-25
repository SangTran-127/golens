package analysis

import (
	"go/ast"
	"go/importer"
	"go/parser"
	"go/scanner"
	"go/token"
	"go/types"
	"slices"
	"strings"
	"sync"
	"testing"
)

var (
	honestyImporterOnce sync.Once
	honestyImporter     types.Importer
)

func typeCheckFixture(t *testing.T, path, src string) {
	t.Helper()
	honestyImporterOnce.Do(func() {
		honestyImporter = importer.ForCompiler(token.NewFileSet(), "source", nil)
	})
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, src, parser.AllErrors)
	if err != nil {
		t.Fatalf("parse %s: %v\n%s", path, err, src)
	}
	var errs []string
	conf := types.Config{
		Importer: honestyImporter,
		Error:    func(err error) { errs = append(errs, err.Error()) },
	}
	_, _ = conf.Check(file.Name.Name, fset, []*ast.File{file}, nil)
	if len(errs) > 0 {
		t.Fatalf("type-check %s:\n%s\n%s", path, strings.Join(errs, "\n"), src)
	}
}

func codeTokens(t *testing.T, src string) []string {
	t.Helper()
	fset := token.NewFileSet()
	var sc scanner.Scanner
	sc.Init(fset.AddFile("fixture.go", -1, len(src)), []byte(src), nil, 0)
	var out []string
	for {
		_, tok, lit := sc.Scan()
		if tok == token.EOF {
			return out
		}
		out = append(out, tok.String()+" "+lit)
	}
}

func countFindings(t *testing.T, inspector, kind, path, src string) (total, fixable int) {
	t.Helper()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, path, src, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	add := func(match, canFix bool) {
		if match {
			total++
			if canFix {
				fixable++
			}
		}
	}
	switch inspector {
	case "concurrency":
		for _, f := range inspectConcurrencyAST(fset, file, path, src).Findings {
			add(f.Kind == kind, f.CanAutoFix)
		}
	case "http":
		report := &HTTPSafetyReport{}
		fillHTTPSafetyReport(report, fset, file, src)
		for _, iss := range report.Issues {
			add(iss.Kind == kind, iss.CanAutoFix)
		}
	case "httpresp":
		for _, iss := range inspectHTTPRespSafetyAST(fset, file, path, src).Issues {
			add(iss.Category == kind, iss.CanAutoFix)
		}
	case "testing":
		var res TestingSafetyInspectResult
		fillTestingSafetyResult(&res, fset, file, src)
		for _, iss := range res.Issues {
			add(iss.Category == kind, iss.CanAutoFix)
		}
	case "netdial":
		var res NetDialSafetyResult
		fillNetDialSafetyResult(&res, fset, file, src)
		for _, iss := range res.Issues {
			add(iss.Category == kind, iss.CanAutoFix)
		}
	case "errwrap":
		for _, f := range inspectASTFileErrorWrapping(fset, file, path, src) {
			add(f.Kind == kind, f.CanQuickFix)
		}
	case "security":
		for _, f := range inspectASTFileSensitiveData(fset, file, path, path, nil) {
			add(f.Kind == kind, f.QuickFixTitle != "")
		}
	case "modernization":
		for _, f := range inspectASTFileModernization(fset, file, path, src) {
			add(f.Kind == kind, f.CanQuickFix)
		}
	case "resource":
		for _, rf := range inspectASTFileResourceAndInjection(fset, file, path, src) {
			add(rf.Kind == kind, rf.CanQuickFix)
		}
	case "sqltx":
		for _, txIssue := range inspectASTFileSQLTransactions(fset, file, src) {
			add(kind == "SQL_TX_UNCLOSED", txIssue.CanQuickFix)
		}
	case "time":
		for _, tf := range inspectASTFileTimeSafety(fset, file, path, src) {
			add(tf.Category == kind, tf.CanAutoFix)
		}
	case "sync":
		syncStructs := make(map[string]string)
		collectSyncLockStructs(fset, file, syncStructs)
		for _, sf := range inspectASTFileSyncSafety(fset, file, path, src, syncStructs) {
			add(sf.Category == kind, sf.CanAutoFix)
		}
	default:
		t.Fatalf("unknown inspector %q", inspector)
	}
	return total, fixable
}

func lineOf(t *testing.T, src, needle string) int {
	t.Helper()
	for i, l := range strings.Split(src, "\n") {
		if strings.Contains(l, needle) {
			return i + 1
		}
	}
	t.Fatalf("fixture has no line containing %q", needle)
	return 0
}

type honestFixCase struct {
	name      string
	path      string
	inspector string
	kind      string
	at        string
	title     string
	src       string
}

func TestContextualQuickFixesRemoveTheirFindingAndCompile(t *testing.T) {
	cases := []honestFixCase{
		{
			name:      "missing cancel defer",
			inspector: "concurrency",
			kind:      "missing_cancel_defer",
			at:        "context.WithTimeout",
			title:     "Add defer cancel()",
			src: `package worker

import (
	"context"
	"time"
)

func waitReady(parent context.Context, ready <-chan struct{}) error {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	select {
	case <-ready:
		cancel()
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
`,
		},
		{
			name:      "missing cancel defer across lines",
			inspector: "concurrency",
			kind:      "missing_cancel_defer",
			at:        "context.WithTimeout",
			title:     "Add defer stop()",
			src: `package worker

import (
	"context"
	"time"
)

func waitReady(parent context.Context, ready <-chan struct{}) error {
	ctx, stop := context.WithTimeout(
		parent,
		5*time.Second,
	)
	select {
	case <-ready:
		stop()
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
`,
		},
		{
			name:      "discarded cancel",
			inspector: "concurrency",
			kind:      "missing_cancel_defer",
			at:        "context.WithCancel",
			title:     "Add defer cancel()",
			src: `package worker

import "context"

func consume(parent context.Context, jobs <-chan int) int {
	ctx, _ := context.WithCancel(parent)
	total := 0
	for {
		select {
		case j := <-jobs:
			total += j
		case <-ctx.Done():
			return total
		}
	}
}
`,
		},
		{
			name:      "discarded cancel with a cancel already in scope",
			inspector: "concurrency",
			kind:      "missing_cancel_defer",
			at:        "context.WithTimeout",
			title:     "Add defer cancel2()",
			src: `package worker

import (
	"context"
	"time"
)

func consume(parent context.Context, jobs <-chan int) int {
	outer, cancel := context.WithCancel(parent)
	defer cancel()
	ctx, _ := context.WithTimeout(outer, time.Second)
	total := 0
	for {
		select {
		case j := <-jobs:
			total += j
		case <-ctx.Done():
			return total
		}
	}
}
`,
		},
		{
			name:      "context.Background with a ctx parameter",
			inspector: "concurrency",
			kind:      "context_background_in_func",
			at:        "context.Background()",
			title:     "Use ctx Instead of context.Background()",
			src: `package store

import (
	"context"
	"net/http"
)

func newRequest(ctx context.Context, url string) (*http.Request, error) {
	return http.NewRequestWithContext(context.Background(), http.MethodGet, url, nil)
}
`,
		},
		{
			name:      "context.TODO with a ctx parameter",
			inspector: "concurrency",
			kind:      "context_background_in_func",
			at:        "context.TODO()",
			title:     "Use reqCtx Instead of context.TODO()",
			src: `package store

import (
	"context"
	"net/http"
)

func newRequest(reqCtx context.Context, url string) (*http.Request, error) {
	return http.NewRequestWithContext(context.TODO(), http.MethodGet, url, nil)
}
`,
		},
		{
			name:      "http.Get on the default client",
			inspector: "http",
			kind:      "HTTP_DEFAULT_CLIENT",
			at:        "http.Get(",
			title:     "Use an http.Client With a 10-Second Timeout",
			src: `package fetch

import (
	"io"
	"net/http"
)

func body(url string) ([]byte, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}
`,
		},
		{
			name:      "http.Client literal without a timeout",
			inspector: "http",
			kind:      "HTTP_DEFAULT_CLIENT",
			at:        "http.Client{",
			title:     "Add a 10-Second Timeout to http.Client",
			src: `package fetch

import "net/http"

func newClient(tr http.RoundTripper) *http.Client {
	return &http.Client{
		Transport: tr,
	}
}
`,
		},
		{
			name:      "http.ListenAndServe without timeouts",
			inspector: "http",
			kind:      "HTTP_SERVER_NO_TIMEOUT",
			at:        "http.ListenAndServe(",
			title:     "Use an http.Server With a 5-Second ReadHeaderTimeout",
			src: `package server

import (
	"log"
	"net/http"
)

func serve(addr string, mux *http.ServeMux) {
	log.Fatal(http.ListenAndServe(addr, mux))
}
`,
		},
		{
			name:      "http.Server literal without timeouts",
			inspector: "http",
			kind:      "HTTP_SERVER_NO_TIMEOUT",
			at:        "http.Server{",
			title:     "Add a 5-Second ReadHeaderTimeout to http.Server",
			src: `package server

import (
	"net/http"
	"time"
)

func newServer(addr string, h http.Handler) *http.Server {
	return &http.Server{Addr: addr, Handler: h, WriteTimeout: 30 * time.Second}
}
`,
		},
		{
			name:      "unclosed response body",
			inspector: "http",
			kind:      "HTTP_BODY_UNCLOSED",
			at:        "client.Get(",
			title:     "Add defer resp.Body.Close()",
			src: `package fetch

import "net/http"

func status(client *http.Client, url string) (int, error) {
	resp, err := client.Get(url)
	if err != nil {
		return 0, err
	}
	return resp.StatusCode, nil
}
`,
		},
		{
			name:      "unclosed body from http.Get only adds the close",
			inspector: "http",
			kind:      "HTTP_BODY_UNCLOSED",
			at:        "http.Get(",
			title:     "Add defer resp.Body.Close()",
			src: `package fetch

import "net/http"

func status(url string) (int, error) {
	resp, err := http.Get(url)
	if err != nil {
		return 0, err
	}
	return resp.StatusCode, nil
}
`,
		},
		{
			name:      "http.ListenAndServeTLS without timeouts",
			inspector: "http",
			kind:      "HTTP_SERVER_NO_TIMEOUT",
			at:        "http.ListenAndServeTLS(",
			title:     "Use an http.Server With a 5-Second ReadHeaderTimeout",
			src: `package server

import "net/http"

func serveTLS(addr string, h http.Handler) error {
	return http.ListenAndServeTLS(addr, "cert.pem", "key.pem", h)
}
`,
		},
		{
			name:      "WriteHeader after the body",
			inspector: "httpresp",
			kind:      "writeheader_after_write",
			at:        "w.WriteHeader(",
			title:     "Move WriteHeader Before the Body Write",
			src: `package api

import "net/http"

func created(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("created"))
	w.WriteHeader(http.StatusCreated)
}
`,
		},
		{
			name:      "Header().Set after the body",
			inspector: "httpresp",
			kind:      "writeheader_after_write",
			at:        "w.Header().Set(",
			title:     "Move Header().Set Before the Body Write",
			src: `package api

import (
	"fmt"
	"net/http"
)

func hello(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintf(w, "hello %s", r.URL.Path)
	w.Header().Set("Cache-Control", "no-store")
}
`,
		},
		{
			name:      "JSON without a Content-Type",
			inspector: "httpresp",
			kind:      "missing_content_type_before_write",
			at:        "json.NewEncoder(w)",
			title:     "Set the JSON Content-Type Header",
			src: `package api

import (
	"encoding/json"
	"net/http"
)

func user(w http.ResponseWriter, r *http.Request) {
	u := map[string]string{"name": "gopher"}
	json.NewEncoder(w).Encode(u)
}
`,
		},
		{
			name:      "JSON without a Content-Type after WriteHeader",
			inspector: "httpresp",
			kind:      "missing_content_type_before_write",
			at:        "json.NewEncoder(w)",
			title:     "Set the JSON Content-Type Header",
			src: `package api

import (
	"encoding/json"
	"net/http"
)

func user(w http.ResponseWriter, r *http.Request) {
	u := map[string]string{"name": "gopher"}
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(u)
}
`,
		},
		{
			name:      "t.Fatal in a goroutine",
			path:      "fetch_test.go",
			inspector: "testing",
			kind:      "t_fatal_in_goroutine",
			at:        "t.Fatal(err)",
			title:     "Replace t.Fatal With t.Error and Return",
			src: `package fetch

import (
	"errors"
	"testing"
)

func work() error { return errors.New("boom") }

func TestWork(t *testing.T) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		if err := work(); err != nil {
			t.Fatal(err)
		}
	}()
	<-done
}
`,
		},
		{
			name:      "t.FailNow in a goroutine",
			path:      "fetch_test.go",
			inspector: "testing",
			kind:      "t_fatal_in_goroutine",
			at:        "t.FailNow()",
			title:     "Replace t.FailNow With t.Fail and Return",
			src: `package fetch

import "testing"

func TestWork(t *testing.T) {
	done := make(chan bool)
	go func() {
		if !<-done {
			t.FailNow()
		}
	}()
	done <- true
}
`,
		},
		{
			name:      "t.Parallel with t.Setenv",
			path:      "config_test.go",
			inspector: "testing",
			kind:      "parallel_setenv_conflict",
			at:        "t.Parallel()",
			title:     "Remove t.Parallel()",
			src: `package config

import (
	"os"
	"testing"
)

func TestMode(t *testing.T) {
	t.Parallel()
	t.Setenv("APP_MODE", "test")
	if os.Getenv("APP_MODE") != "test" {
		t.Fatal("APP_MODE not set")
	}
}
`,
		},
		{
			name:      "test helper without t.Helper",
			path:      "math_test.go",
			inspector: "testing",
			kind:      "missing_test_helper",
			at:        "func assertEqual",
			title:     "Add t.Helper() to assertEqual",
			src: `package math

import "testing"

func assertEqual(t *testing.T, got, want int) {
	if got != want {
		t.Fatalf("got %d, want %d", got, want)
	}
}

func TestAdd(t *testing.T) {
	assertEqual(t, 1+1, 2)
}
`,
		},
		{
			name:      "net.Dial without a timeout",
			inspector: "netdial",
			kind:      "net_dial_without_timeout_or_context",
			at:        "net.Dial(",
			title:     "Use net.DialTimeout With a 10-Second Timeout",
			src: `package probe

import "net"

func ping(addr string) error {
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return err
	}
	return conn.Close()
}
`,
		},
		{
			name:      "transport with keep-alives disabled",
			inspector: "netdial",
			kind:      "http_transport_disable_keepalives_per_request",
			at:        "http.Transport{",
			title:     "Enable Keep-Alives",
			src: `package probe

import "net/http"

func newClient() *http.Client {
	tr := &http.Transport{DisableKeepAlives: true}
	return &http.Client{Transport: tr}
}
`,
		},
		{
			name:      "multi-line transport with keep-alives disabled",
			inspector: "netdial",
			kind:      "http_transport_disable_keepalives_per_request",
			at:        "http.Transport{",
			title:     "Enable Keep-Alives",
			src: `package probe

import "net/http"

func newTransport() *http.Transport {
	return &http.Transport{
		MaxIdleConns:      10,
		DisableKeepAlives: true,
	}
}
`,
		},
		{
			name:      "wildcard listen address",
			inspector: "netdial",
			kind:      "net_listen_wildcard_without_bind_host",
			at:        "net.Listen(",
			title:     "Bind to 127.0.0.1:8080",
			src: `package probe

import "net"

func listen() (net.Listener, error) {
	return net.Listen("tcp", ":8080")
}
`,
		},
		{
			name:      "wildcard http.ListenAndServe address",
			inspector: "netdial",
			kind:      "net_listen_wildcard_without_bind_host",
			at:        "http.ListenAndServe(",
			title:     "Bind to 127.0.0.1:9090",
			src: `package probe

import (
	"log"
	"net/http"
)

func serve(mux *http.ServeMux) {
	log.Fatal(http.ListenAndServe(":9090", mux))
}
`,
		},
		{
			name:      "error formatted with %v",
			inspector: "errwrap",
			kind:      "ERRWRAP_VERB",
			at:        "fmt.Errorf",
			title:     "Wrap the Error With %w",
			src: `package files

import (
	"fmt"
	"os"
)

func open(name string) (*os.File, error) {
	f, err := os.Open(name)
	if err != nil {
		return nil, fmt.Errorf("open %s: %v", name, err)
	}
	return f, nil
}
`,
		},
		{
			name:      "error compared with ==",
			inspector: "errwrap",
			kind:      "ERRWRAP_EQUALITY",
			at:        "err == io.EOF",
			title:     "Use errors.Is",
			src: `package files

import (
	"bufio"
	"io"
)

func lines(r *bufio.Reader) (int, error) {
	n := 0
	for {
		_, err := r.ReadString('\n')
		if err == io.EOF {
			return n, nil
		}
		if err != nil {
			return n, err
		}
		n++
	}
}
`,
		},
		{
			name:      "error compared with != and errors already imported",
			inspector: "errwrap",
			kind:      "ERRWRAP_EQUALITY",
			at:        "err != ErrMissing",
			title:     "Use errors.Is",
			src: `package files

import "errors"

var ErrMissing = errors.New("missing")

func check(err error) bool {
	return err != ErrMissing
}
`,
		},
		{
			name:      "sensitive field serialized",
			inspector: "security",
			kind:      "sensitive_tag",
			at:        "Password string",
			title:     `Add json:"-" Tag`,
			src: `package auth

type Credentials struct {
	User     string ` + "`json:\"user\"`" + `
	Password string ` + "`json:\"password\"`" + `
}
`,
		},
		{
			name:      "sensitive field in a one-line struct",
			inspector: "security",
			kind:      "sensitive_tag",
			at:        "APIToken string",
			title:     `Add json:"-" Tag`,
			src: `package auth

type Session struct{ APIToken string }
`,
		},
		{
			name:      "empty interface",
			inspector: "modernization",
			kind:      "MODERN_ANY",
			at:        "interface{}",
			title:     "Replace interface{} With any",
			src: `package dump

import "fmt"

func describe(v interface{}) string {
	return fmt.Sprint(v)
}
`,
		},
		{
			name:      "early return unclosed file with trailing close",
			inspector: "resource",
			kind:      "RESOURCE_UNCLOSED",
			at:        "os.Open(",
			title:     "Add defer f.Close()",
			src: `package loader

import (
	"errors"
	"os"
)

func loadConfig(path string, abort bool) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	if abort {
		return errors.New("aborted")
	}
	buf := make([]byte, 8)
	_, err = f.Read(buf)
	_ = f.Close()
	return err
}
`,
		},
		{
			name:      "unclosed os.OpenRoot handle",
			inspector: "resource",
			kind:      "RESOURCE_UNCLOSED",
			at:        "os.OpenRoot(",
			title:     "Add defer root.Close()",
			src: `package loader

import "os"

func inspectDir(dir string) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	_, err = root.Stat(".")
	return err
}
`,
		},
		{
			name:      "unclosed sql transaction",
			inspector: "sqltx",
			kind:      "SQL_TX_UNCLOSED",
			at:        "db.BeginTx(",
			title:     "Add defer tx.Rollback()",
			src: `package repo

import (
	"context"
	"database/sql"
	"errors"
)

func writeItem(ctx context.Context, db *sql.DB, valid bool) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if !valid {
		return errors.New("invalid")
	}
	return tx.Commit()
}
`,
		},
		{
			name:      "unstopped ticker",
			inspector: "time",
			kind:      "TICKER_UNSTOPPED",
			at:        "time.NewTicker(",
			title:     "Add defer ticker.Stop()",
			src: `package sched

import "time"

func tickOnce(done <-chan struct{}) {
	ticker := time.NewTicker(time.Second)
	select {
	case <-ticker.C:
	case <-done:
	}
}
`,
		},
		{
			name:      "missing mutex unlock",
			inspector: "sync",
			kind:      "SYNC_LOCK_NO_UNLOCK",
			at:        "mu.Lock()",
			title:     "Add defer mu.Unlock()",
			src: `package lock

import "sync"

func bump(mu *sync.Mutex, n *int) {
	mu.Lock()
	*n++
}
`,
		},
		{
			name:      "missing rwmutex runlock",
			inspector: "sync",
			kind:      "SYNC_LOCK_NO_UNLOCK",
			at:        "rw.RLock()",
			title:     "Add defer rw.RUnlock()",
			src: `package lock

import "sync"

func readVal(rw *sync.RWMutex, n *int) int {
	rw.RLock()
	return *n
}
`,
		},
		{
			name:      "create close before return ReadFile",
			inspector: "resource",
			kind:      "RESOURCE_UNCLOSED",
			at:        "os.Create(",
			title:     "Add defer f.Close()",
			src: `package writer

import "os"

func writeAndRead(path string, fail bool) ([]byte, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	if fail {
		return nil, os.ErrInvalid
	}
	if _, err := f.WriteString("ok"); err != nil {
		return nil, err
	}
	f.Close()
	return os.ReadFile(path)
}
`,
		},
		{
			name:      "nested branch resource reassignment",
			inspector: "resource",
			kind:      "RESOURCE_UNCLOSED",
			at:        "os.Open(p1)",
			title:     "Add defer f.Close()",
			src: `package swap

import "os"

func openWithFallback(p1, p2 string, swap bool) error {
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
`,
		},
		{
			name:      "non-terminating error guard with else on os.Open",
			inspector: "resource",
			kind:      "RESOURCE_UNCLOSED",
			at:        "os.Open(",
			title:     "Add defer f.Close()",
			src: `package logsafe

import (
	"log"
	"os"
)

func openOrLog(path string, fail bool) error {
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
`,
		},
		{
			name:      "non-terminating error guard with else on BeginTx",
			inspector: "sqltx",
			kind:      "SQL_TX_UNCLOSED",
			at:        "db.BeginTx(",
			title:     "Add defer tx.Rollback()",
			src: `package repo

import (
	"context"
	"database/sql"
	"errors"
	"log"
)

func txOrLog(ctx context.Context, db *sql.DB, fail bool) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		log.Println(err)
	} else {
		if fail {
			return errors.New("abort")
		}
		return tx.Commit()
	}
	if fail {
		return errors.New("outer")
	}
	return nil
}
`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := tc.path
			if path == "" {
				path = "fixture.go"
			}
			typeCheckFixture(t, path, tc.src)
			if total, fixable := countFindings(t, tc.inspector, tc.kind, path, tc.src); total != 1 || fixable != 1 {
				t.Fatalf("fixture should raise exactly one fixable %s finding, got %d (%d fixable)", tc.kind, total, fixable)
			}

			line := lineOf(t, tc.src, tc.at)
			fixes, err := ContextualASTQuickFixes("", path, tc.src, line)
			if err != nil {
				t.Fatalf("ContextualASTQuickFixes: %v", err)
			}
			var chosen *ContextualQuickFix
			for i := range fixes {
				if fixes[i].InspectorID == tc.inspector && fixes[i].Title == tc.title {
					chosen = &fixes[i]
					break
				}
			}
			if chosen == nil {
				titles := make([]string, 0, len(fixes))
				for _, f := range fixes {
					titles = append(titles, f.InspectorID+": "+f.Title)
				}
				t.Fatalf("no %s fix titled %q on line %d; offered %q", tc.inspector, tc.title, line, titles)
			}

			typeCheckFixture(t, path, chosen.UpdatedSource)
			if got, _ := countFindings(t, tc.inspector, tc.kind, path, chosen.UpdatedSource); got != 0 {
				t.Fatalf("%s finding still present after %q:\n%s", tc.kind, tc.title, chosen.UpdatedSource)
			}
			if strings.Count(chosen.UpdatedSource, "TODO") > strings.Count(tc.src, "TODO") {
				t.Fatalf("%q writes a TODO instead of fixing the code:\n%s", tc.title, chosen.UpdatedSource)
			}
			if slices.Equal(codeTokens(t, tc.src), codeTokens(t, chosen.UpdatedSource)) {
				t.Fatalf("%q changes only comments or spacing:\n%s", tc.title, chosen.UpdatedSource)
			}
		})
	}
}

func TestContextualQuickFixesAreNotOfferedWhenTheyCannotResolveTheFinding(t *testing.T) {
	cases := []honestFixCase{
		{
			name:      "unvalidated redirect",
			inspector: "httpresp",
			kind:      "unvalidated_http_redirect",
			at:        "http.Redirect(",
			src: `package api

import "net/http"

func login(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, r.URL.Query().Get("next"), http.StatusFound)
}
`,
		},
		{
			name:      "unbounded goroutine",
			inspector: "concurrency",
			kind:      "unbounded_goroutine",
			at:        "go func()",
			src: `package worker

func spawn(jobs []int, out chan<- int) {
	go func() {
		for _, j := range jobs {
			out <- j
		}
	}()
}
`,
		},
		{
			name:      "t.SkipNow in a goroutine",
			path:      "skip_test.go",
			inspector: "testing",
			kind:      "t_fatal_in_goroutine",
			at:        "t.SkipNow()",
			src: `package skip

import "testing"

func TestSkip(t *testing.T) {
	done := make(chan bool)
	go func() {
		if <-done {
			t.SkipNow()
		}
	}()
	done <- true
}
`,
		},
		{
			name:      "discarded cancel on a plain assignment",
			inspector: "concurrency",
			kind:      "missing_cancel_defer",
			at:        "context.WithCancel",
			src: `package worker

import "context"

func rebind(parent context.Context) context.Context {
	ctx := parent
	ctx, _ = context.WithCancel(parent)
	return ctx
}
`,
		},
		{
			name:      "context.Background without a ctx parameter",
			inspector: "concurrency",
			kind:      "context_background_in_func",
			at:        "context.Background()",
			src: `package store

import (
	"context"
	"net/http"
)

func newRequest(url string) (*http.Request, error) {
	return http.NewRequestWithContext(context.Background(), http.MethodGet, url, nil)
}
`,
		},
		{
			name:      "context.Background with an unnamed ctx parameter",
			inspector: "concurrency",
			kind:      "context_background_in_func",
			at:        "context.Background()",
			src: `package store

import (
	"context"
	"net/http"
)

func newRequest(_ context.Context, url string) (*http.Request, error) {
	return http.NewRequestWithContext(context.Background(), http.MethodGet, url, nil)
}
`,
		},
		{
			name:      "header moved above the variable it reads",
			inspector: "httpresp",
			kind:      "writeheader_after_write",
			at:        "w.Write(",
			src: `package api

import "net/http"

func created(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("created"))
	code := http.StatusCreated
	w.WriteHeader(code)
}
`,
		},
		{
			name:      "empty interface mentioned only in a comment",
			inspector: "modernization",
			kind:      "MODERN_ANY",
			at:        "// accepts interface{}",
			src: `package dump

import "fmt"

// accepts interface{} values
func describe(v fmt.Stringer) string {
	var x interface{} = v
	return fmt.Sprint(x)
}
`,
		},
		{
			name:      "resource acquisition inside loop refuses defer",
			inspector: "resource",
			kind:      "RESOURCE_UNCLOSED",
			at:        "os.Open(",
			src: `package loader

import "os"

func scanMany(paths []string) error {
	for _, p := range paths {
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		_ = f
	}
	return nil
}
`,
		},
		{
			name:      "sql transaction inside loop refuses defer",
			inspector: "sqltx",
			kind:      "SQL_TX_UNCLOSED",
			at:        "db.BeginTx(",
			src: `package repo

import (
	"context"
	"database/sql"
	"errors"
)

func batchInsert(ctx context.Context, db *sql.DB, n int) error {
	for i := 0; i < n; i++ {
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if i < 0 {
			return errors.New("bad")
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}
`,
		},
		{
			name:      "ticker created inside loop refuses defer",
			inspector: "time",
			kind:      "TICKER_UNSTOPPED",
			at:        "time.NewTicker(",
			src: `package sched

import "time"

func retryTickers(n int) {
	for i := 0; i < n; i++ {
		tk := time.NewTicker(time.Millisecond)
		<-tk.C
	}
}
`,
		},
		{
			name:      "lock acquired inside loop refuses defer",
			inspector: "sync",
			kind:      "SYNC_LOCK_NO_UNLOCK",
			at:        "mu.Lock()",
			src: `package lock

import "sync"

func countItems(mu *sync.Mutex, n int) {
	total := 0
	for i := 0; i < n; i++ {
		mu.Lock()
		total += i
	}
	_ = total
}
`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := tc.path
			if path == "" {
				path = "fixture.go"
			}
			typeCheckFixture(t, path, tc.src)
			total, fixable := countFindings(t, tc.inspector, tc.kind, path, tc.src)
			if total != 1 {
				t.Fatalf("fixture should raise exactly one %s finding, got %d", tc.kind, total)
			}
			if fixable != 0 && tc.kind != "MODERN_ANY" {
				t.Fatalf("the %s finding should not claim an automatic fix", tc.kind)
			}
			line := lineOf(t, tc.src, tc.at)
			fixes, err := ContextualASTQuickFixes("", path, tc.src, line)
			if err != nil {
				t.Fatalf("ContextualASTQuickFixes: %v", err)
			}
			for _, f := range fixes {
				if f.InspectorID == tc.inspector {
					t.Fatalf("expected no %s fix on line %d, got %q:\n%s", tc.inspector, line, f.Title, f.UpdatedSource)
				}
			}
		})
	}
}
