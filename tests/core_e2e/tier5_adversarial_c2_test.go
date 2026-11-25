package core_e2e

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"golens/core/goast"
)

// ============================================================================
// CHALLENGER GROUP C R2: EMPIRICAL ADVERSARIAL STRESS TEST SUITE
// Track 47.3: Zero-Config HTTP Route Code Lens & Request Exerciser
// ============================================================================

// 1. Deep 5-level nested router groups with shadowed receiver names & chaining
func TestAdversarial_C2_DeepNestedRouteGroups(t *testing.T) {
	src := `package main

type Router interface{}

func setupHierarchy(r Router) {
	r.Route("/api", func(r Router) {
		r.Route("/v1", func(r Router) {
			r.Route("/tenants/{tenantId}", func(r Router) {
				r.Route("/workspaces/{wsId}", func(r Router) {
					r.Get("/overview", getOverview)
					r.Post("/deploy", deployService)
				})
				r.Get("/quota", getQuota)
			})
			r.Get("/ping", getPing)
		})
		r.Get("/health", getHealth)
	})
	r.Get("/root-ping", getRootPing)
}
`
	routes, err := goast.ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanGoHTTPRoutes failed: %v", err)
	}

	expected := map[string]string{
		"/api/v1/tenants/{tenantId}/workspaces/{wsId}/overview": "GET",
		"/api/v1/tenants/{tenantId}/workspaces/{wsId}/deploy":   "POST",
		"/api/v1/tenants/{tenantId}/quota":                      "GET",
		"/api/v1/ping":                                          "GET",
		"/api/health":                                           "GET",
		"/root-ping":                                            "GET",
	}

	if len(routes) != len(expected) {
		t.Fatalf("Expected %d routes, got %d: %v", len(expected), len(routes), routes)
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
			t.Errorf("Expected route %s %s missing in routes: %v", method, path, routes)
		}
	}
}

// 2. Comprehensive HTTP Method Matrix (All 7 methods across Gin, Echo, Chi, and net/http)
func TestAdversarial_C2_AllHTTPMethodsRecognition(t *testing.T) {
	methods := []string{"GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"}

	t.Run("Gin_AllMethods", func(t *testing.T) {
		src := `package main
type Engine interface{}
func routes(g Engine) {
	g.GET("/test", h)
	g.POST("/test", h)
	g.PUT("/test", h)
	g.DELETE("/test", h)
	g.PATCH("/test", h)
	g.OPTIONS("/test", h)
	g.HEAD("/test", h)
}
`
		res, err := goast.ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Gin scan error: %v", err)
		}
		if len(res) != len(methods) {
			t.Fatalf("Gin expected %d methods, got %d", len(methods), len(res))
		}
		for i, m := range methods {
			if res[i].Method != m {
				t.Errorf("Gin method[%d] = %s, want %s", i, res[i].Method, m)
			}
		}
	})

	t.Run("Echo_AllMethods", func(t *testing.T) {
		src := `package main
type Engine interface{}
func routes(e Engine) {
	e.GET("/echo", h)
	e.POST("/echo", h)
	e.PUT("/echo", h)
	e.DELETE("/echo", h)
	e.PATCH("/echo", h)
	e.OPTIONS("/echo", h)
	e.HEAD("/echo", h)
}
`
		res, err := goast.ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Echo scan error: %v", err)
		}
		if len(res) != len(methods) {
			t.Fatalf("Echo expected %d methods, got %d", len(methods), len(res))
		}
		for i, m := range methods {
			if res[i].Method != m {
				t.Errorf("Echo method[%d] = %s, want %s", i, res[i].Method, m)
			}
		}
	})

	t.Run("Chi_AllMethods", func(t *testing.T) {
		src := `package main
type Router interface{}
func routes(r Router) {
	r.Get("/chi", h)
	r.Post("/chi", h)
	r.Put("/chi", h)
	r.Delete("/chi", h)
	r.Patch("/chi", h)
	r.Options("/chi", h)
	r.Head("/chi", h)
}
`
		res, err := goast.ScanGoHTTPRoutes(src)
		if err != nil {
			t.Fatalf("Chi scan error: %v", err)
		}
		if len(res) != len(methods) {
			t.Fatalf("Chi expected %d methods, got %d", len(methods), len(res))
		}
		for i, m := range methods {
			if res[i].Method != m {
				t.Errorf("Chi method[%d] = %s, want %s", i, res[i].Method, m)
			}
		}
	})
}

// 3. Slash Normalization: Leading, Trailing, and Intermediate Slashes
func TestAdversarial_C2_SlashSequenceNormalization(t *testing.T) {
	src := `package main
type Engine interface{}
func setup(r Engine) {
	r.GET("///users///:id////profile///", h)
	r.POST("root-only", h)
	r.PUT("///", h)
}
`
	routes, err := goast.ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan error: %v", err)
	}
	if len(routes) != 3 {
		t.Fatalf("Expected 3 routes, got %d", len(routes))
	}

	if routes[0].Path != "/users/:id/profile/" {
		t.Errorf("Path 0 mismatch: %q, want %q", routes[0].Path, "/users/:id/profile/")
	}
	if routes[1].Path != "/root-only" {
		t.Errorf("Path 1 mismatch: %q, want %q", routes[1].Path, "/root-only")
	}
	if routes[2].Path != "/" {
		t.Errorf("Path 2 mismatch: %q, want %q", routes[2].Path, "/")
	}

	for _, r := range routes {
		if strings.Contains(r.Path, "//") {
			t.Fatalf("Found uncollapsed duplicate slash in %q", r.Path)
		}
		if !strings.HasPrefix(r.Path, "/") {
			t.Fatalf("Missing leading slash in %q", r.Path)
		}
	}
}

// 4. Recursive Struct Payload Termination Guard
func TestAdversarial_C2_RecursiveStructPayloadGuard(t *testing.T) {
	src := `package main

type LinkedListNode struct {
	Val  int             ` + "`json:\"val\"`" + `
	Next *LinkedListNode ` + "`json:\"next\"`" + `
}

func setup(r Router) {
	r.Post("/node", handleNode)
}

func handleNode() {
	var n LinkedListNode
	_ = n
}
`
	routes, err := goast.ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected 1 route, got %d", len(routes))
	}

	payload := routes[0].SampleRequestBodyJSON
	if payload == "" {
		t.Fatalf("Expected non-empty sample JSON body")
	}

	var parsed map[string]any
	if err := json.Unmarshal([]byte(payload), &parsed); err != nil {
		t.Fatalf("Invalid JSON produced for recursive struct: %v", err)
	}

	if parsed["val"] != float64(1) {
		t.Errorf("Expected val=1, got %v", parsed["val"])
	}
}

// 5. Concurrency & Byte-for-Byte Determinism Stress Test
func TestAdversarial_C2_ConcurrentDeterminismStress(t *testing.T) {
	src := `package main

type Account struct {
	ID        int64     ` + "`json:\"id\"`" + `
	Email     string    ` + "`json:\"email\"`" + `
	Balance   float64   ` + "`json:\"balance\"`" + `
	Verified  bool      ` + "`json:\"verified\"`" + `
	Roles     []string  ` + "`json:\"roles\"`" + `
	Profile   Profile   ` + "`json:\"profile\"`" + `
	Internal  string    ` + "`json:\"-\"`" + `
}

type Profile struct {
	Bio string ` + "`json:\"bio\"`" + `
}

func setup(mux Mux) {
	mux.HandleFunc("POST /api/v1/accounts", handleAccount)
}

func handleAccount() {
	var acc Account
	_ = acc
}
`
	const goroutines = 50
	outputs := make([]string, goroutines)
	var wg sync.WaitGroup
	wg.Add(goroutines)

	for i := 0; i < goroutines; i++ {
		idx := i
		go func() {
			defer wg.Done()
			routes, err := goast.ScanGoHTTPRoutes(src)
			if err != nil || len(routes) == 0 {
				outputs[idx] = "ERROR"
				return
			}
			outputs[idx] = routes[0].SampleRequestBodyJSON
		}()
	}
	wg.Wait()

	base := outputs[0]
	if base == "" || base == "ERROR" {
		t.Fatalf("Base output invalid: %q", base)
	}

	for i := 1; i < goroutines; i++ {
		if outputs[i] != base {
			t.Fatalf("Nondeterministic payload at goroutine %d:\nGot:\n%s\nWant:\n%s", i, outputs[i], base)
		}
	}
}

// 6. Live Local Request Exerciser Guardrails
func TestAdversarial_C2_LiveLocalRequestExerciser(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("X-Track", "47.3")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"result":"created"}`))
	}))
	defer ts.Close()

	res, err := goast.ExecuteLocalHTTPRequest(ts.URL, "POST", nil, `{"name":"test"}`, 2*time.Second)
	if err != nil {
		t.Fatalf("ExecuteLocalHTTPRequest failed: %v", err)
	}
	if res.StatusCode != 201 {
		t.Errorf("StatusCode = %d; want 201", res.StatusCode)
	}
	if res.Headers["X-Track"] != "47.3" {
		t.Errorf("Header X-Track = %q; want 47.3", res.Headers["X-Track"])
	}
	if !strings.Contains(res.Body, `"result":"created"`) {
		t.Errorf("Body mismatch: %s", res.Body)
	}
}
