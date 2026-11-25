package goast

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ----------------------------------------------------------------------------
// 1. Framework Route Syntax Variations (net/http Go 1.22+, chi, gin, echo)
// ----------------------------------------------------------------------------

func TestAdversarial_HTTPRoutes_FrameworkSyntaxVariations(t *testing.T) {
	t.Run("NetHTTP_Go122_And_Legacy", func(t *testing.T) {
		srcNetHTTP := `package main

import "net/http"

func setup(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/items/{id}", handleGet)
	mux.HandleFunc("POST /api/v1/items", handlePost)
	mux.HandleFunc("DELETE /api/v1/items/{id...}", handleDelete)
	mux.HandleFunc(" /no-method", handleNoMethod)
	mux.HandleFunc("/health", handleHealth)
}
`
		routes, err := ScanGoHTTPRoutes(srcNetHTTP)
		if err != nil {
			t.Fatalf("net/http scan failed: %v", err)
		}
		if len(routes) != 5 {
			t.Fatalf("Expected 5 net/http routes, got %d", len(routes))
		}

		expectedNetHTTP := []struct {
			method string
			path   string
			params []string
		}{
			{"GET", "/api/v1/items/{id}", []string{"id"}},
			{"POST", "/api/v1/items", nil},
			{"DELETE", "/api/v1/items/{id...}", []string{"id"}},
			{"GET", "/no-method", nil},
			{"GET", "/health", nil},
		}

		for i, want := range expectedNetHTTP {
			got := routes[i]
			if got.Method != want.method || got.Path != want.path {
				t.Errorf("net/http route[%d] mismatch: got %s %s, want %s %s", i, got.Method, got.Path, want.method, want.path)
			}
			if len(want.params) > 0 {
				if len(got.PathParams) != len(want.params) {
					t.Errorf("net/http route[%d] pathParams count mismatch: got %v, want %v", i, got.PathParams, want.params)
				} else {
					for j, p := range want.params {
						if got.PathParams[j] != p {
							t.Errorf("net/http route[%d] pathParams[%d] mismatch: got %s, want %s", i, j, got.PathParams[j], p)
						}
					}
				}
			}
		}
	})

	t.Run("Chi_Methods_Including_Options", func(t *testing.T) {
		srcChi := `package main

type Router interface{}

func setupChi(r Router) {
	r.Get("/items", getItems)
	r.Post("/items", postItems)
	r.Put("/items/{id}", putItem)
	r.Delete("/items/{id}", deleteItem)
	r.Patch("/items/{id}", patchItem)
	r.Options("/items", optionsItems)
}
`
		routesChi, err := ScanGoHTTPRoutes(srcChi)
		if err != nil {
			t.Fatalf("chi scan failed: %v", err)
		}
		expectedChi := []struct {
			method string
			path   string
		}{
			{"GET", "/items"},
			{"POST", "/items"},
			{"PUT", "/items/{id}"},
			{"DELETE", "/items/{id}"},
			{"PATCH", "/items/{id}"},
			{"OPTIONS", "/items"},
		}

		for _, want := range expectedChi {
			found := false
			for _, got := range routesChi {
				if got.Method == want.method && got.Path == want.path {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("Chi route missing: expected %s %s among detected routes: %v", want.method, want.path, routesChi)
			}
		}
	})

	t.Run("Gin_Methods_Including_Options_And_Head", func(t *testing.T) {
		srcGin := `package main

type GinEngine interface{}

func setupGin(r GinEngine) {
	r.GET("/api/users", getUsers)
	r.POST("/api/users", createUsers)
	r.PUT("/api/users/:id", updateUser)
	r.DELETE("/api/users/:id", deleteUser)
	r.PATCH("/api/users/:id", patchUser)
	r.OPTIONS("/api/users", optionsUser)
	r.HEAD("/api/users", headUser)
}
`
		routesGin, err := ScanGoHTTPRoutes(srcGin)
		if err != nil {
			t.Fatalf("gin scan failed: %v", err)
		}
		expectedGin := []struct {
			method string
			path   string
		}{
			{"GET", "/api/users"},
			{"POST", "/api/users"},
			{"PUT", "/api/users/:id"},
			{"DELETE", "/api/users/:id"},
			{"PATCH", "/api/users/:id"},
			{"OPTIONS", "/api/users"},
			{"HEAD", "/api/users"},
		}

		for _, want := range expectedGin {
			found := false
			for _, got := range routesGin {
				if got.Method == want.method && got.Path == want.path {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("Gin route missing: expected %s %s among detected routes: %v", want.method, want.path, routesGin)
			}
		}
	})

	t.Run("Echo_Methods_Including_Options", func(t *testing.T) {
		srcEcho := `package main

type EchoEngine interface{}

func setupEcho(e EchoEngine) {
	e.GET("/echo/v1", getEcho)
	e.POST("/echo/v1", postEcho)
	e.PUT("/echo/v1/:id", putEcho)
	e.DELETE("/echo/v1/:id", deleteEcho)
	e.PATCH("/echo/v1/:id", patchEcho)
	e.OPTIONS("/echo/v1", optionsEcho)
}
`
		routesEcho, err := ScanGoHTTPRoutes(srcEcho)
		if err != nil {
			t.Fatalf("echo scan failed: %v", err)
		}
		expectedEcho := []struct {
			method string
			path   string
		}{
			{"GET", "/echo/v1"},
			{"POST", "/echo/v1"},
			{"PUT", "/echo/v1/:id"},
			{"DELETE", "/echo/v1/:id"},
			{"PATCH", "/echo/v1/:id"},
			{"OPTIONS", "/echo/v1"},
		}

		for _, want := range expectedEcho {
			found := false
			for _, got := range routesEcho {
				if got.Method == want.method && got.Path == want.path {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("Echo route missing: expected %s %s among detected routes: %v", want.method, want.path, routesEcho)
			}
		}
	})
}

// ----------------------------------------------------------------------------
// 2. Deeply Nested Route Groups (3+ levels)
// ----------------------------------------------------------------------------

func TestAdversarial_HTTPRoutes_NestedRouteGroups(t *testing.T) {
	t.Run("Distinct_Router_Receiver_Names", func(t *testing.T) {
		src := `package main

type Router interface{}

func setupDeepRoutes(r Router) {
	r.Route("/v1", func(r1 Router) {
		r1.Route("/orgs/{orgId}", func(r2 Router) {
			r2.Route("/teams/{teamId}", func(r3 Router) {
				r3.Get("/members", getMembers)
				r3.Post("/members/{memberId}", addMember)
			})
			r2.Get("/details", getOrgDetails)
		})
		r1.Get("/health", getHealth)
	})
}
`
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("deep nested scan failed: %v", err)
		}

		expected := map[string]string{
			"/v1/orgs/{orgId}/teams/{teamId}/members":          "GET",
			"/v1/orgs/{orgId}/teams/{teamId}/members/{memberId}": "POST",
			"/v1/orgs/{orgId}/details":                         "GET",
			"/v1/health":                                       "GET",
		}

		for path, method := range expected {
			found := false
			for _, r := range routes {
				if r.Path == path && r.Method == method {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("Deeply nested route missing: expected %s %s among routes: %v", method, path, routes)
			}
		}
	})

	t.Run("Shadowed_Chi_Router_Parameter_Names", func(t *testing.T) {
		srcShadow := `package main

type Router interface{}

func setupShadow(r Router) {
	r.Route("/v1", func(r Router) {
		r.Route("/orgs", func(r Router) {
			r.Get("/list", getList)
		})
		r.Get("/ping", getPing)
	})
}
`
		routesShadow, err := ScanGoHTTPRoutes(srcShadow)
		if err != nil {
			t.Fatalf("shadow scan failed: %v", err)
		}
		expectedShadow := map[string]string{
			"/v1/orgs/list": "GET",
			"/v1/ping":      "GET",
		}
		for path, method := range expectedShadow {
			found := false
			for _, r := range routesShadow {
				if r.Path == path && r.Method == method {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("Shadowed closure route missing or corrupted: expected %s %s among routes: %v", method, path, routesShadow)
			}
		}
	})

	t.Run("Cross_Function_Router_Prefix_Isolation", func(t *testing.T) {
		srcCrossFunc := `package main

type Router interface{}

func setupA(r Router) {
	r.Route("/api/v1", func(r Router) {
		r.Get("/items", getItems)
	})
}

func setupB(r Router) {
	r.Get("/health", getHealth)
}
`
		routesCross, err := ScanGoHTTPRoutes(srcCrossFunc)
		if err != nil {
			t.Fatalf("cross func scan failed: %v", err)
		}
		for _, r := range routesCross {
			if r.Path == "/api/v1/health" {
				t.Errorf("Cross-function prefix leakage: setupB /health inherited /api/v1 from setupA: %s", r.Path)
			}
		}
	})
}

// ----------------------------------------------------------------------------
// 3. Path Parameter Extraction & Sanitization
// ----------------------------------------------------------------------------

func TestAdversarial_HTTPRoutes_PathParameterExtraction(t *testing.T) {
	cases := []struct {
		path       string
		wantParams []string
	}{
		{"/users/{id}", []string{"id"}},
		{"/files/{filepath...}", []string{"filepath"}},
		{"/api/v1/orgs/{orgId}/repos/{repoName}/commits/{sha...}", []string{"orgId", "repoName", "sha"}},
		{"/api/v2/:user_id/posts/:post_id", []string{"user_id", "post_id"}},
		{"/static/*filepath", []string{"filepath"}},
		{"/hybrid/{org_id}/resource/:res_id/*tail", []string{"org_id", "res_id", "tail"}},
		{"/empty/{}", nil},
		{"/plain/path/without/params", nil},
	}

	for _, c := range cases {
		c := c
		t.Run(c.path, func(t *testing.T) {
			got := ExtractPathParameters(c.path)
			if len(got) != len(c.wantParams) {
				t.Fatalf("ExtractPathParameters(%q) = %v; want %v", c.path, got, c.wantParams)
			}
			for i, p := range c.wantParams {
				if got[i] != p {
					t.Errorf("ExtractPathParameters(%q)[%d] = %q; want %q", c.path, i, got[i], p)
				}
				// Strict sanitization assertion: no parameter should ever contain punctuation
				if strings.ContainsAny(got[i], "{}:*") || strings.HasSuffix(got[i], "...") {
					t.Errorf("ExtractPathParameters(%q) returned unsanitized param name %q", c.path, got[i])
				}
			}
		})
	}
}

// ----------------------------------------------------------------------------
// 4. Deterministic Struct Inference & Circular Struct Protection
// ----------------------------------------------------------------------------

func TestAdversarial_HTTPRoutes_DeterministicStructInference(t *testing.T) {
	src := `package main

type ZetaStruct struct {
	ZField string ` + "`json:\"z_field\"`" + `
	Weight float64 ` + "`json:\"weight\"`" + `
}

type AlphaStruct struct {
	ID        int        ` + "`json:\"id\"`" + `
	Name      string     ` + "`json:\"name\"`" + `
	Active    bool       ` + "`json:\"active\"`" + `
	Tags      []string   ` + "`json:\"tags\"`" + `
	Zeta      ZetaStruct ` + "`json:\"zeta\"`" + `
	Hidden    string     ` + "`json:\"-\"`" + `
}

type BetaStruct struct {
	Count int ` + "`json:\"count\"`" + `
}

func register(r Router) {
	r.Post("/alpha", handleAlpha)
}

func handleAlpha() {
	var req AlphaStruct
	_ = req
}
`
	// Run 50 concurrent iterations to verify 100% byte-for-byte determinism
	const runs = 50
	results := make([]string, runs)
	var wg sync.WaitGroup
	wg.Add(runs)

	for i := 0; i < runs; i++ {
		idx := i
		go func() {
			defer wg.Done()
			routes, err := ScanGoHTTPRoutes(src)
			if err != nil || len(routes) == 0 {
				results[idx] = "ERROR"
				return
			}
			results[idx] = routes[0].SampleRequestBodyJSON
		}()
	}
	wg.Wait()

	base := results[0]
	if base == "" || base == "ERROR" {
		t.Fatalf("Baseline struct sample JSON is invalid or empty: %s", base)
	}

	for i := 1; i < runs; i++ {
		if results[i] != base {
			t.Fatalf("Non-deterministic JSON payload detected at iteration %d:\nGot:\n%s\nWant:\n%s", i, results[i], base)
		}
	}

	// Verify field contents
	if !strings.Contains(base, `"id": 1`) || !strings.Contains(base, `"name": "sample_name"`) {
		t.Errorf("Sample JSON missing primitive fields: %s", base)
	}
	if !strings.Contains(base, `"z_field": "sample_z_field"`) {
		t.Errorf("Sample JSON missing nested struct fields: %s", base)
	}
	if strings.Contains(base, "hidden") {
		t.Errorf("Sample JSON must omit json:\"-\" field: %s", base)
	}
}

func TestAdversarial_HTTPRoutes_CircularStructProtection(t *testing.T) {
	src := `package main

type TreeNode struct {
	Value    string      ` + "`json:\"value\"`" + `
	Children []*TreeNode ` + "`json:\"children\"`" + `
	Parent   *TreeNode   ` + "`json:\"parent\"`" + `
}

func setup(r Router) {
	r.Post("/tree", handleTree)
}

func handleTree() {
	var node TreeNode
	_ = node
}
`
	done := make(chan bool, 1)
	go func() {
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Errorf("Scan error on circular struct: %v", err)
		}
		if len(routes) != 1 {
			t.Errorf("Expected 1 route, got %d", len(routes))
		}
		jsonStr := routes[0].SampleRequestBodyJSON
		if !strings.Contains(jsonStr, `"value": "sample_value"`) {
			t.Errorf("Circular struct sample JSON missing root field: %s", jsonStr)
		}
		done <- true
	}()

	select {
	case <-done:
		// Terminated safely
	case <-time.After(2 * time.Second):
		t.Fatalf("Stack overflow or infinite recursion encountered when parsing circular struct (timeout > 2s)")
	}
}

func TestAdversarial_HTTPRoutes_GenericStructs(t *testing.T) {
	src := `package main

type Response[T any] struct {
	Data T   ` + "`json:\"data\"`" + `
	Code int ` + "`json:\"code\"`" + `
}

func setup(r Router) {
	r.Post("/generic", handleGeneric)
}

func handleGeneric() {
	var resp Response[string]
	_ = resp
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan failed for generic struct: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected 1 route, got %d", len(routes))
	}
	jsonStr := routes[0].SampleRequestBodyJSON
	if jsonStr == "" || jsonStr == "{}" {
		t.Errorf("Generic struct sample JSON should not be empty: %s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"code": 1`) {
		t.Errorf("Generic struct should contain concrete fields: %s", jsonStr)
	}
}

// ----------------------------------------------------------------------------
// 5. HTTP Execution Client Edge Cases
// ----------------------------------------------------------------------------

func TestAdversarial_HTTPExecution_ConnectionRefused(t *testing.T) {
	// Find an unused local port
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("Failed to bind port: %v", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()

	deadURL := fmt.Sprintf("http://127.0.0.1:%d/ping", port)
	_, err = ExecuteGoHTTPRequest(deadURL, "GET", "", "", 1)
	if err == nil {
		t.Fatalf("Expected error for connection refused, got nil")
	}
	if !strings.Contains(err.Error(), "connection refused") && !strings.Contains(err.Error(), "request failed") {
		t.Errorf("Expected human-readable connection refused error, got: %v", err)
	}
}

func TestAdversarial_HTTPExecution_TimeoutContextCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(300 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	// Timeout is 50ms, server sleeps 300ms
	start := time.Now()
	_, err := ExecuteLocalHTTPRequest(server.URL+"/delay", "GET", nil, "", 50*time.Millisecond)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("Expected timeout error, got nil")
	}
	if elapsed > 250*time.Millisecond {
		t.Errorf("Context cancellation did not trigger promptly: took %v, want < 250ms", elapsed)
	}
}

func TestAdversarial_HTTPExecution_GiantResponseBodyCap(t *testing.T) {
	// Server responds with 10MB of data
	const fullSize = 10 * 1024 * 1024
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		w.WriteHeader(http.StatusOK)
		chunk := bytes.Repeat([]byte("A"), 64*1024)
		for written := 0; written < fullSize; written += len(chunk) {
			_, _ = w.Write(chunk)
		}
	}))
	defer server.Close()

	res, err := ExecuteGoHTTPRequest(server.URL+"/giant", "GET", "", "", 5)
	if err != nil {
		t.Fatalf("ExecuteGoHTTPRequest on giant response failed: %v", err)
	}

	const maxExpected = 8 * 1024 * 1024
	if len(res.Body) > maxExpected {
		t.Fatalf("Response body exceeded 8MB guardrail: got %d bytes, max %d bytes", len(res.Body), maxExpected)
	}
	if len(res.Body) != maxExpected {
		t.Errorf("Response body should be capped exactly at 8MB limit: got %d bytes, want %d", len(res.Body), maxExpected)
	}
}
