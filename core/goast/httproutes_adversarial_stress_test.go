package goast

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// ============================================================================
// EMPIRICAL ADVERSARIAL STRESS TEST SUITE (TRACK 47.3)
// ============================================================================

// 1. Deeply Nested Route Groups (3+ to 5 levels) with Shadowed Variables & Chaining
func TestEmpirical_DeeplyNestedRouteGroups_5Levels(t *testing.T) {
	t.Run("Chi_5Levels_With_Shadowed_Closure_Variables", func(t *testing.T) {
		src := `package main

type Router interface{}

func setupChi5Levels(r Router) {
	r.Route("/level1", func(r Router) {
		r.Get("/l1", hL1)
		r.Route("/level2", func(r Router) {
			r.Get("/l2", hL2)
			r.Route("/level3", func(r Router) {
				r.Get("/l3", hL3)
				r.Route("/level4", func(r Router) {
					r.Get("/l4", hL4)
					r.Route("/level5", func(r Router) {
						r.Get("/l5", hL5)
					})
					r.Get("/after-l5", hAfterL5)
				})
				r.Get("/after-l4", hAfterL4)
			})
			r.Get("/after-l3", hAfterL3)
		})
		r.Get("/after-l2", hAfterL2)
	})
	r.Get("/after-l1", hAfterL1)
}
`
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Scan failed for 5-level chi: %v", err)
		}

		expected := map[string]string{
			"/level1/l1":                                "GET",
			"/level1/level2/l2":                         "GET",
			"/level1/level2/level3/l3":                  "GET",
			"/level1/level2/level3/level4/l4":           "GET",
			"/level1/level2/level3/level4/level5/l5":    "GET",
			"/level1/level2/level3/level4/after-l5":     "GET",
			"/level1/level2/level3/after-l4":            "GET",
			"/level1/level2/after-l3":                   "GET",
			"/level1/after-l2":                          "GET",
			"/after-l1":                                 "GET",
		}

		if len(routes) != len(expected) {
			t.Fatalf("Expected %d routes for 5-level chi, got %d: %v", len(expected), len(routes), routes)
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
				t.Errorf("5-level chi route missing: expected %s %s among detected routes: %v", method, path, routes)
			}
		}
	})

	t.Run("Gin_5Levels_Variable_Assignments_And_Chaining", func(t *testing.T) {
		src := `package main

type Engine interface{}

func setupGin5Levels(r Engine) {
	g1 := r.Group("/api")
	g2 := g1.Group("/v1")
	g3 := g2.Group("/orgs")
	g4 := g3.Group("/:orgId")
	g5 := g4.Group("/teams")
	g5.GET("/:teamId", hTeam)
	g4.GET("/stats", hStats)
	g3.GET("/list", hList)

	// Chaining 5 levels
	r.Group("/ch1").Group("/ch2").Group("/ch3").Group("/ch4").POST("/ch5", hCh)

	// Chaining with middleware With / Use
	r.With(m1).With(m2).Group("/api/v2").Use(m3).GET("/users", hUsers)
}
`
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Scan failed for 5-level gin: %v", err)
		}

		expected := map[string]string{
			"/api/v1/orgs/:orgId/teams/:teamId": "GET",
			"/api/v1/orgs/:orgId/stats":         "GET",
			"/api/v1/orgs/list":                 "GET",
			"/ch1/ch2/ch3/ch4/ch5":              "POST",
			"/api/v2/users":                     "GET",
		}

		if len(routes) != len(expected) {
			t.Fatalf("Expected %d routes for 5-level gin, got %d: %v", len(expected), len(routes), routes)
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
				t.Errorf("5-level gin route missing: expected %s %s among routes: %v", method, path, routes)
			}
		}
	})
}

// 2. Mixed Method Registrations on the Exact Same Route Path
func TestEmpirical_MixedMethods_SamePath(t *testing.T) {
	t.Run("Chi_All_Methods_Same_Path", func(t *testing.T) {
		src := `package main

type Router interface{}

func setupChi(r Router) {
	r.Get("/items/{id}", getHandler)
	r.Post("/items/{id}", postHandler)
	r.Put("/items/{id}", putHandler)
	r.Delete("/items/{id}", deleteHandler)
	r.Patch("/items/{id}", patchHandler)
	r.Options("/items/{id}", optionsHandler)
	r.Head("/items/{id}", headHandler)
}

type Payload struct {
	Name string ` + "`json:\"name\"`" + `
}

func postHandler() { var p Payload; _ = p }
func putHandler() { var p Payload; _ = p }
func patchHandler() { var p Payload; _ = p }
`
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Scan failed: %v", err)
		}

		expectedMethods := []string{"GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"}
		if len(routes) != len(expectedMethods) {
			t.Fatalf("Expected %d routes, got %d: %v", len(expectedMethods), len(routes), routes)
		}

		for i, m := range expectedMethods {
			r := routes[i]
			if r.Method != m || r.Path != "/items/{id}" {
				t.Errorf("Route[%d] mismatch: got %s %s, want %s /items/{id}", i, r.Method, r.Path, m)
			}
			if len(r.PathParams) != 1 || r.PathParams[0] != "id" {
				t.Errorf("Route[%d] params mismatch: got %v, want [id]", i, r.PathParams)
			}

			// Mutating methods must have sample request body; read-only must be empty
			if m == "POST" || m == "PUT" || m == "PATCH" {
				if r.SampleRequestBodyJSON == "" || !strings.Contains(r.SampleRequestBodyJSON, `"name": "sample_name"`) {
					t.Errorf("Mutating method %s missing sample body: %s", m, r.SampleRequestBodyJSON)
				}
			} else {
				if r.SampleRequestBodyJSON != "" {
					t.Errorf("Non-mutating method %s should have empty sample body, got: %s", m, r.SampleRequestBodyJSON)
				}
			}
		}
	})

	t.Run("NetHTTP_Go122_All_Methods_Same_Path", func(t *testing.T) {
		src := `package main

import "net/http"

func setup(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/resource/{id}", getH)
	mux.HandleFunc("POST /api/resource/{id}", postH)
	mux.HandleFunc("PUT /api/resource/{id}", putH)
	mux.HandleFunc("DELETE /api/resource/{id}", delH)
	mux.HandleFunc("PATCH /api/resource/{id}", patchH)
	mux.HandleFunc("OPTIONS /api/resource/{id}", optH)
	mux.HandleFunc("HEAD /api/resource/{id}", headH)
}
`
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Scan failed: %v", err)
		}

		expectedMethods := []string{"GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"}
		if len(routes) != len(expectedMethods) {
			t.Fatalf("Expected %d routes, got %d", len(expectedMethods), len(routes))
		}

		for i, m := range expectedMethods {
			r := routes[i]
			if r.Method != m || r.Path != "/api/resource/{id}" {
				t.Errorf("net/http route[%d] mismatch: got %s %s, want %s /api/resource/{id}", i, r.Method, r.Path, m)
			}
		}
	})
}

// 3. Slashes in Paths: leading, trailing, and duplicate slashes (//users//profile///)
func TestEmpirical_SlashesNormalization(t *testing.T) {
	src := `package main

type Engine interface{}

func setup(r Engine) {
	r.GET("//users//profile///", h1)
	r.POST("///orders////create///", h2)
	r.DELETE("no-leading-slash", h3)
	r.GET("///", h4)

	// Chained with dirty slashes
	r.Group("///api///").Group("///v1///").GET("///items///", h5)
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan failed for slashes: %v", err)
	}

	expected := []struct {
		method string
		path   string
	}{
		{"GET", "/users/profile/"},
		{"POST", "/orders/create/"},
		{"DELETE", "/no-leading-slash"},
		{"GET", "/"},
		{"GET", "/api/v1/items/"},
	}

	if len(routes) != len(expected) {
		t.Fatalf("Expected %d routes, got %d: %v", len(expected), len(routes), routes)
	}

	for i, want := range expected {
		got := routes[i]
		if got.Method != want.method || got.Path != want.path {
			t.Errorf("Route[%d] mismatch: got %s %s, want %s %s", i, got.Method, got.Path, want.method, want.path)
		}
		// Invariant: No path may ever contain double slashes '//'
		if strings.Contains(got.Path, "//") {
			t.Fatalf("Route[%d] contains uncollapsed double slash: %s", i, got.Path)
		}
		// Invariant: Path must start with '/'
		if !strings.HasPrefix(got.Path, "/") {
			t.Fatalf("Route[%d] does not start with '/': %s", i, got.Path)
		}
	}
}

// 4. Circular and Deeply Recursive Struct Payload Generation (Depth Guard <= 100)
func TestEmpirical_CircularAndDeeplyRecursiveStructs(t *testing.T) {
	t.Run("Mutual_2Way_Recursion", func(t *testing.T) {
		src := `package main

type StructA struct {
	Name string   ` + "`json:\"name\"`" + `
	B    *StructB ` + "`json:\"b\"`" + `
}

type StructB struct {
	Title string   ` + "`json:\"title\"`" + `
	A     *StructA ` + "`json:\"a\"`" + `
}

func setup(r Router) {
	r.Post("/mutual", handleMutual)
}

func handleMutual() {
	var a StructA
	_ = a
}
`
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Scan failed: %v", err)
		}
		if len(routes) != 1 {
			t.Fatalf("Expected 1 route, got %d", len(routes))
		}
		payload := routes[0].SampleRequestBodyJSON
		if payload == "" {
			t.Fatalf("Sample body empty for mutual recursion")
		}

		var m map[string]any
		if err := json.Unmarshal([]byte(payload), &m); err != nil {
			t.Fatalf("Mutual recursion payload is invalid JSON: %v\nPayload:\n%s", err, payload)
		}

		if m["name"] != "sample_name" {
			t.Errorf("Expected name=sample_name, got %v", m["name"])
		}
	})

	t.Run("Mutual_3Way_Recursion", func(t *testing.T) {
		src := `package main

type NodeX struct {
	XVal string ` + "`json:\"x_val\"`" + `
	Y    *NodeY ` + "`json:\"y\"`" + `
}
type NodeY struct {
	YVal string ` + "`json:\"y_val\"`" + `
	Z    *NodeZ ` + "`json:\"z\"`" + `
}
type NodeZ struct {
	ZVal string ` + "`json:\"z_val\"`" + `
	X    *NodeX ` + "`json:\"x\"`" + `
}

func setup(r Router) {
	r.Post("/triple", handleTriple)
}

func handleTriple() {
	var node NodeX
	_ = node
}
`
		routes, err := ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Scan failed: %v", err)
		}
		payload := routes[0].SampleRequestBodyJSON
		var m map[string]any
		if err := json.Unmarshal([]byte(payload), &m); err != nil {
			t.Fatalf("Triple recursion payload is invalid JSON: %v\nPayload:\n%s", err, payload)
		}
		if m["x_val"] != "sample_x_val" {
			t.Errorf("Expected x_val, got %v", m["x_val"])
		}
	})

	t.Run("DeeplyNestedChain_50_Structs_Depth_Guard", func(t *testing.T) {
		// Generate 50 chained structs: S0 -> S1 -> S2 -> ... -> S49
		var sb strings.Builder
		sb.WriteString("package main\n\n")
		for i := 0; i < 50; i++ {
			if i < 49 {
				sb.WriteString(fmt.Sprintf("type S%d struct {\n\tVal int `json:\"val_%d\"`\n\tNext *S%d `json:\"next\"`\n}\n", i, i, i+1))
			} else {
				sb.WriteString(fmt.Sprintf("type S%d struct {\n\tVal int `json:\"val_%d\"`\n}\n", i, i))
			}
		}
		sb.WriteString("\nfunc setup(r Router) {\n\tr.Post(\"/deep\", handleDeep)\n}\n")
		sb.WriteString("func handleDeep() {\n\tvar s S0\n\t_ = s\n}\n")

		start := time.Now()
		routes, err := ScanGoHTTPRoutes(sb.String())
		elapsed := time.Since(start)

		if err != nil {
			t.Fatalf("Scan failed for 50-level struct chain: %v", err)
		}
		if elapsed > 200*time.Millisecond {
			t.Errorf("Depth guard took too long: %v (budget 200ms)", elapsed)
		}
		if len(routes) != 1 {
			t.Fatalf("Expected 1 route, got %d", len(routes))
		}
		payload := routes[0].SampleRequestBodyJSON
		if payload == "" {
			t.Fatalf("Sample body empty for deep struct chain")
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(payload), &m); err != nil {
			t.Fatalf("Deep chain payload invalid JSON: %v", err)
		}
		if m["val_0"] != float64(1) {
			t.Errorf("Expected val_0=1, got %v", m["val_0"])
		}
	})
}

// 5. Inferred Request Body JSON Validity and Strict Determinism Across 100 Runs
func TestEmpirical_JSONPayloadValidityAndDeterminism_100Runs(t *testing.T) {
	src := `package main

type ComplexPayload struct {
	ID        int64              ` + "`json:\"id\"`" + `
	UUID      string             ` + "`json:\"uuid\"`" + `
	Score     float64            ` + "`json:\"score\"`" + `
	Enabled   bool               ` + "`json:\"enabled\"`" + `
	Tags      []string           ` + "`json:\"tags\"`" + `
	Counts    []int              ` + "`json:\"counts\"`" + `
	Sub       SubPayload         ` + "`json:\"sub\"`" + `
	OmitMe    string             ` + "`json:\"-\"`" + `
	Renamed   string             ` + "`json:\"custom_field_name,omitempty\"`" + `
}

type SubPayload struct {
	Details string ` + "`json:\"details\"`" + `
}

func setup(r Router) {
	r.Post("/complex", handleComplex)
}

func handleComplex() {
	var req ComplexPayload
	_ = req
}
`
	const iterations = 100
	results := make([]string, iterations)
	var wg sync.WaitGroup
	wg.Add(iterations)

	for i := 0; i < iterations; i++ {
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
		t.Fatalf("Base iteration failed or empty: %s", base)
	}

	// 1. Strict byte-for-byte determinism check across all 100 concurrent runs
	for i := 1; i < iterations; i++ {
		if results[i] != base {
			t.Fatalf("Nondeterminism detected at run %d!\nRun 0:\n%s\nRun %d:\n%s", i, base, i, results[i])
		}
	}

	// 2. JSON syntax validity check
	if !json.Valid([]byte(base)) {
		t.Fatalf("Generated sample JSON is not valid RFC 8259 JSON:\n%s", base)
	}

	// 3. Unmarshal and assert expected fields
	var m map[string]any
	if err := json.Unmarshal([]byte(base), &m); err != nil {
		t.Fatalf("Failed to unmarshal sample JSON: %v", err)
	}

	if m["id"] != float64(1) {
		t.Errorf("Expected id=1, got %v", m["id"])
	}
	if m["uuid"] != "sample_uuid" {
		t.Errorf("Expected uuid=sample_uuid, got %v", m["uuid"])
	}
	if m["score"] != float64(1.0) {
		t.Errorf("Expected score=1.0, got %v", m["score"])
	}
	if m["enabled"] != true {
		t.Errorf("Expected enabled=true, got %v", m["enabled"])
	}
	if m["custom_field_name"] != "sample_custom_field_name" {
		t.Errorf("Expected custom_field_name, got %v", m["custom_field_name"])
	}
	if _, exists := m["-"]; exists {
		t.Errorf("Found field '-' which should be omitted: %v", m)
	}
	if _, exists := m["omitme"]; exists {
		t.Errorf("Found field 'omitme' which should be omitted by json:\"-\": %v", m)
	}

	sub, ok := m["sub"].(map[string]any)
	if !ok || sub["details"] != "sample_details" {
		t.Errorf("Nested sub payload mismatch: %v", m["sub"])
	}
}

// 6. HTTP Client Execution Edge Cases & Timeout Protection
func TestEmpirical_HTTPExecution_EdgeCases(t *testing.T) {
	t.Run("NonExistentPort_ConnectionRefused", func(t *testing.T) {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatalf("net.Listen failed: %v", err)
		}
		port := l.Addr().(*net.TCPAddr).Port
		_ = l.Close()

		_, err = ExecuteGoHTTPRequest(fmt.Sprintf("http://127.0.0.1:%d/ping", port), "GET", "", "", 1)
		if err == nil {
			t.Fatalf("Expected connection refused error, got nil")
		}
	})

	t.Run("Immediate_Timeout_Cancellation", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(500 * time.Millisecond)
			w.WriteHeader(http.StatusOK)
		}))
		defer server.Close()

		start := time.Now()
		_, err := ExecuteLocalHTTPRequest(server.URL+"/slow", "GET", nil, "", 20*time.Millisecond)
		elapsed := time.Since(start)

		if err == nil {
			t.Fatalf("Expected timeout error, got nil")
		}
		if elapsed > 200*time.Millisecond {
			t.Errorf("Timeout took too long to abort: %v, want < 200ms", elapsed)
		}
	})

	t.Run("Body_Automatic_ContentType_JSON", func(t *testing.T) {
		var receivedCT string
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			receivedCT = r.Header.Get("Content-Type")
			w.WriteHeader(http.StatusOK)
		}))
		defer server.Close()

		_, err := ExecuteLocalHTTPRequest(server.URL+"/json", "POST", nil, `{"hello":"world"}`, 2*time.Second)
		if err != nil {
			t.Fatalf("Request failed: %v", err)
		}
		if receivedCT != "application/json" {
			t.Errorf("Content-Type not auto-detected as application/json: %q", receivedCT)
		}
	})
}
