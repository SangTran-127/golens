package analysis

import (
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

func TestInspectHTTPRespSafety_DetectsAllCategories(t *testing.T) {
	src := `package api

import (
	"encoding/json"
	"fmt"
	"net/http"
)

func HandleUser(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "hello")
	w.WriteHeader(http.StatusCreated)
}

func HandleJSON(w http.ResponseWriter, r *http.Request) {
	_ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func HandleRedirect(w http.ResponseWriter, r *http.Request) {
	http.Redirect(w, r, r.URL.Query().Get("next"), http.StatusFound)
}
`
	report, err := InspectHTTPRespSafety("handler.go", src)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if report.TotalIssues != 3 {
		t.Fatalf("expected 3 issues, got %d", report.TotalIssues)
	}
	if report.WriteHeaderCount != 1 {
		t.Fatalf("expected WriteHeaderCount=1, got %d", report.WriteHeaderCount)
	}
	if report.MissingContentTypeCount != 1 {
		t.Fatalf("expected MissingContentTypeCount=1, got %d", report.MissingContentTypeCount)
	}
	if report.UnvalidatedRedirectCount != 1 {
		t.Fatalf("expected UnvalidatedRedirectCount=1, got %d", report.UnvalidatedRedirectCount)
	}

	fixRes, err := ApplyHTTPRespSafetyFix("handler.go", src, "", true)
	if err != nil {
		t.Fatalf("ApplyHTTPRespSafetyFix failed: %v", err)
	}
	if fixRes.AppliedCount != 2 {
		t.Fatalf("expected 2 fixes applied, got %d", fixRes.AppliedCount)
	}
	if fixRes.Report.UnvalidatedRedirectCount != 1 || len(fixRes.Report.Issues) != 1 {
		t.Fatalf("expected only the redirect finding to remain, got %+v", fixRes.Report.Issues)
	}
	if !strings.Contains(fixRes.NewContent, `w.Header().Set("Content-Type", "application/json; charset=utf-8")`) {
		t.Fatalf("expected Content-Type header in fixed content:\n%s", fixRes.NewContent)
	}
	writeHeaderIdx := strings.Index(fixRes.NewContent, "w.WriteHeader(http.StatusCreated)")
	fprintlnIdx := strings.Index(fixRes.NewContent, `fmt.Fprintln(w, "hello")`)
	if writeHeaderIdx == -1 || fprintlnIdx == -1 || writeHeaderIdx > fprintlnIdx {
		t.Fatalf("expected WriteHeader moved before Fprintln:\n%s", fixRes.NewContent)
	}
	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "handler.go", fixRes.NewContent, parser.AllErrors); err != nil {
		t.Fatalf("fixed HTTP response code failed to parse: %v\n%s", err, fixRes.NewContent)
	}
}
