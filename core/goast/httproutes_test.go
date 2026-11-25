package goast

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestScanGoHTTPRoutes_NetHTTPGo122(t *testing.T) {
	src := `package main

import "net/http"

func setup() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/orders/{id}", handleOrder)
	mux.HandleFunc("GET /healthz", handleHealth)
	mux.HandleFunc("/legacy", handleLegacy)
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanGoHTTPRoutes failed: %v", err)
	}
	if len(routes) != 3 {
		t.Fatalf("Expected 3 routes, got %d", len(routes))
	}
	if routes[0].Method != "POST" || routes[0].Path != "/api/v1/orders/{id}" {
		t.Errorf("Route 0 mismatch: %s %s", routes[0].Method, routes[0].Path)
	}
	if len(routes[0].PathParams) != 1 || routes[0].PathParams[0] != "id" {
		t.Errorf("Route 0 path params mismatch: %v", routes[0].PathParams)
	}
	if routes[1].Method != "GET" || routes[1].Path != "/healthz" {
		t.Errorf("Route 1 mismatch: %s %s", routes[1].Method, routes[1].Path)
	}
	if routes[2].Method != "GET" || routes[2].Path != "/legacy" {
		t.Errorf("Route 2 default GET mismatch: %s %s", routes[2].Method, routes[2].Path)
	}
}

func TestScanGoHTTPRoutes_ChiAndNestedRouteGroups(t *testing.T) {
	src := `package main

func registerRoutes(r Router) {
	r.Get("/items", getItems)
	r.Post("/items", createItem)
	r.Delete("/items/{id}", deleteItem)

	r.Route("/api/v1", func(sub Router) {
		sub.Get("/users", listUsers)
		sub.Post("/users/{user_id}/activate", activateUser)
	})
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanGoHTTPRoutes failed: %v", err)
	}
	if len(routes) != 5 {
		t.Fatalf("Expected 5 Chi routes, got %d", len(routes))
	}
	if routes[1].Method != "POST" || routes[1].Path != "/items" {
		t.Errorf("Route 1 mismatch: %s %s", routes[1].Method, routes[1].Path)
	}
	if routes[3].Path != "/api/v1/users" {
		t.Errorf("Nested group route 3 mismatch: %s", routes[3].Path)
	}
	if routes[4].Path != "/api/v1/users/{user_id}/activate" || len(routes[4].PathParams) != 1 || routes[4].PathParams[0] != "user_id" {
		t.Errorf("Nested group route 4 mismatch: %s, params: %v", routes[4].Path, routes[4].PathParams)
	}
}

func TestScanGoHTTPRoutes_GinEchoAndPathParams(t *testing.T) {
	src := `package main

func attach(r Engine) {
	r.POST("/login", doLogin)
	r.PUT("/users/:id/profile", updateProfile)
	r.GET("/static/*filepath", serveStatic)

	v1 := r.Group("/v1")
	v1.GET("/stats", getStats)
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanGoHTTPRoutes failed: %v", err)
	}
	if len(routes) != 4 {
		t.Fatalf("Expected 4 routes, got %d", len(routes))
	}
	if routes[1].Method != "PUT" || len(routes[1].PathParams) != 1 || routes[1].PathParams[0] != "id" {
		t.Errorf("Gin colon param mismatch: %s, params: %v", routes[1].Path, routes[1].PathParams)
	}
	if routes[2].Method != "GET" || len(routes[2].PathParams) != 1 || routes[2].PathParams[0] != "filepath" {
		t.Errorf("Gin wildcard param mismatch: %s, params: %v", routes[2].Path, routes[2].PathParams)
	}
	if routes[3].Path != "/v1/stats" {
		t.Errorf("Gin group route mismatch: %s", routes[3].Path)
	}
}

func TestScanGoHTTPRoutes_StructInferredJSONRequestBody(t *testing.T) {
	src := `package main

type CreateUserRequest struct {
	Username string ` + "`json:\"username\"`" + `
	Age      int    ` + "`json:\"age\"`" + `
	Active   bool   ` + "`json:\"active\"`" + `
	Secret   string ` + "`json:\"-\"`" + `
}

func register(mux Mux) {
	mux.HandleFunc("POST /api/v1/users", handleCreateUser)
}

func handleCreateUser() {
	var req CreateUserRequest
	_ = req
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanGoHTTPRoutes failed: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected 1 route, got %d", len(routes))
	}
	sampleJSON := routes[0].SampleRequestBodyJSON
	if sampleJSON == "" {
		t.Fatalf("Expected inferred sample JSON body, got empty")
	}
	if !strings.Contains(sampleJSON, `"username": "sample_username"`) || !strings.Contains(sampleJSON, `"age": 1`) {
		t.Errorf("Inferred JSON body missing fields: %s", sampleJSON)
	}
	if strings.Contains(sampleJSON, "secret") {
		t.Errorf("Field with json:\"-\" should be omitted: %s", sampleJSON)
	}
}

func TestScanGoHTTPRoutes_CriticalDeterminismCheck(t *testing.T) {
	src := `package main

type AlphaRequest struct {
	A string ` + "`json:\"a\"`" + `
	B int    ` + "`json:\"b\"`" + `
}

type BetaRequest struct {
	X string ` + "`json:\"x\"`" + `
	Y int    ` + "`json:\"y\"`" + `
}

type GammaRequest struct {
	Name string ` + "`json:\"name\"`" + `
}

func register(mux Mux) {
	mux.HandleFunc("POST /api/v1/multi", handleMulti)
}

func handleMulti() {
	var req AlphaRequest
	_ = req
}
`
	// Run 100 concurrent iterations; all results must be byte-for-byte identical
	var wg sync.WaitGroup
	results := make([]string, 100)

	for i := 0; i < 100; i++ {
		wg.Add(1)
		idx := i
		go func() {
			defer wg.Done()
			r, err := ScanGoHTTPRoutes(src)
			if err == nil && len(r) > 0 {
				results[idx] = r[0].SampleRequestBodyJSON
			}
		}()
	}
	wg.Wait()

	base := results[0]
	if base == "" {
		t.Fatalf("Baseline sample JSON is empty")
	}
	for i := 1; i < 100; i++ {
		if results[i] != base {
			t.Fatalf("Non-deterministic JSON payload flakiness at run %d: got %s, want %s", i, results[i], base)
		}
	}
}

func TestScanGoHTTPRoutes_GenericAndCircularStructs(t *testing.T) {
	src := `package main

type Node struct {
	Value string ` + "`json:\"value\"`" + `
	Next  *Node  ` + "`json:\"next\"`" + `
}

type GenericEnvelope[T any] struct {
	Code int    ` + "`json:\"code\"`" + `
	Data T      ` + "`json:\"data\"`" + `
}

func setup(mux Mux) {
	mux.HandleFunc("POST /circular", handleNode)
}

func handleNode() {
	var req Node
	_ = req
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected 1 route, got %d", len(routes))
	}
	if !strings.Contains(routes[0].SampleRequestBodyJSON, `"value": "sample_value"`) {
		t.Errorf("Circular struct should resolve base fields without crash: %s", routes[0].SampleRequestBodyJSON)
	}
}

func TestScanGoHTTPRoutes_AdversarialInputs(t *testing.T) {
	// 1. Empty route path
	emptyRoutes, err := ScanGoHTTPRoutes("package main\nfunc setup(m Mux) { m.HandleFunc(\"\", h) }")
	if err != nil || len(emptyRoutes) != 0 {
		t.Errorf("Empty route path should yield 0 routes, got %d (%v)", len(emptyRoutes), err)
	}

	// 2. Non-string route literal
	malformedRoutes, err := ScanGoHTTPRoutes("package main\nfunc setup(m Mux) { m.HandleFunc(12345, h) }")
	if err != nil || len(malformedRoutes) != 0 {
		t.Errorf("Non-string route registration should be skipped, got %d (%v)", len(malformedRoutes), err)
	}

	// 3. Unknown HTTP method
	unknownRoutes, err := ScanGoHTTPRoutes("package main\nfunc setup(m Mux) { m.HandleFunc(\"UNKNOWN /custom\", h) }")
	if err != nil || len(unknownRoutes) != 1 || unknownRoutes[0].Method != "UNKNOWN" {
		t.Errorf("Expected UNKNOWN method route, got %v (%v)", unknownRoutes, err)
	}

	// 4. http.Get client call should not be detected as Chi route
	clientCallRoutes, err := ScanGoHTTPRoutes("package main\nimport \"net/http\"\nfunc call() { http.Get(\"https://google.com\") }")
	if err != nil || len(clientCallRoutes) != 0 {
		t.Errorf("Client http.Get call should not be detected as route, got %d", len(clientCallRoutes))
	}
}

func TestExecuteGoHTTPRequest_LiveServerAndTimeout(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/slow" {
			time.Sleep(150 * time.Millisecond)
			w.WriteHeader(http.StatusOK)
			return
		}
		w.Header().Set("X-Golens-Header", "Exercised")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"success"}`))
	}))
	defer server.Close()

	// 1. Success execution
	res, err := ExecuteGoHTTPRequest(server.URL+"/healthz", "GET", `{"Accept":"application/json"}`, "", 2)
	if err != nil {
		t.Fatalf("ExecuteGoHTTPRequest failed: %v", err)
	}
	if res.StatusCode != 200 {
		t.Errorf("StatusCode = %d; want 200", res.StatusCode)
	}
	if res.Headers["X-Golens-Header"] != "Exercised" {
		t.Errorf("Header X-Golens-Header mismatch: %s", res.Headers["X-Golens-Header"])
	}
	if !strings.Contains(res.Body, `"status":"success"`) {
		t.Errorf("Body mismatch: %s", res.Body)
	}

	// 2. Timeout exceeded
	_, err = ExecuteLocalHTTPRequest(server.URL+"/slow", "GET", nil, "", 20*time.Millisecond)
	if err == nil {
		t.Errorf("Expected timeout error, got nil")
	}

	// 3. Closed port connection refused
	_, err = ExecuteLocalHTTPRequest("http://127.0.0.1:64999/probe", "GET", nil, "", 100*time.Millisecond)
	if err == nil {
		t.Errorf("Expected connection refused error, got nil")
	}
}

func TestScanGoHTTPRoutes_IgnoresCallsThatAreNotRouteRegistrations(t *testing.T) {
	src := `package main

import "fmt"

type Store struct{ data map[string]string }

func (s *Store) Get(k string) string { return s.data[k] }

func main() {
	s := &Store{}
	fmt.Println(s.Get("a"))
	var v string
	cache.Get("users", &v)
	repo.Post("orders", order)
	client.Get("/users")
	client.R().Post("/login")
	logger.Handle("startup")
	r.Get("/users/{id}", getUser)
}
`
	routes, err := ScanGoHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanGoHTTPRoutes failed: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected only the chi route, got %d: %+v", len(routes), routes)
	}
	if routes[0].Method != "GET" || routes[0].Path != "/users/{id}" || routes[0].Line != 18 {
		t.Errorf("Route mismatch: %s %s line %d", routes[0].Method, routes[0].Path, routes[0].Line)
	}
}
