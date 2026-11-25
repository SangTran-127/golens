package analysis

import (
	"strings"
	"testing"
)

func TestInspectCookieCORSSafety_DetectsAllCategories(t *testing.T) {
	src := `package auth

import "net/http"

func loginHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Credentials", "true")
	w.Header().Set("Content-Type", "application/json")
	http.SetCookie(w, &http.Cookie{Name: "sid", Value: "secret-token"})
	w.Write([]byte("{}"))
}
`
	res, err := InspectCookieCORSSafety(CookieCORSSafetyRequest{
		FilePath: "auth.go",
		Content:  src,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Summary.TotalIssues != 3 {
		t.Fatalf("expected 3 issues, got %d: %+v", res.Summary.TotalIssues, res.Issues)
	}
	if res.Summary.CookieMissingFlagsCount != 1 {
		t.Fatalf("expected 1 cookieMissingFlagsCount, got %d", res.Summary.CookieMissingFlagsCount)
	}
	if res.Summary.CORSWildcardCredentialsCount != 1 {
		t.Fatalf("expected 1 corsWildcardCredentialsCount, got %d", res.Summary.CORSWildcardCredentialsCount)
	}
	if res.Summary.MissingNoSniffHeaderCount != 1 {
		t.Fatalf("expected 1 missingNoSniffHeaderCount, got %d", res.Summary.MissingNoSniffHeaderCount)
	}

	fixRes := ApplyCookieCORSSafetyFixes(CookieCORSSafetyFixRequest{
		FilePath: "auth.go",
		Content:  src,
	})
	if fixRes.AppliedCount != 3 {
		t.Fatalf("expected 3 fixes applied, got %d", fixRes.AppliedCount)
	}
	if !strings.Contains(fixRes.ModifiedContent, "HttpOnly: true, Secure: true, SameSite: http.SameSiteLaxMode") {
		t.Fatalf("expected hardened cookie flags, got:\n%s", fixRes.ModifiedContent)
	}
	if !strings.Contains(fixRes.ModifiedContent, `"Access-Control-Allow-Origin", "https://trusted.example.com"`) {
		t.Fatalf("expected trusted CORS origin, got:\n%s", fixRes.ModifiedContent)
	}
	if !strings.Contains(fixRes.ModifiedContent, `"X-Content-Type-Options", "nosniff"`) {
		t.Fatalf("expected nosniff header, got:\n%s", fixRes.ModifiedContent)
	}
	if len(fixRes.RemainingIssues) != 0 {
		t.Fatalf("expected 0 remaining issues after fix, got %d: %+v", len(fixRes.RemainingIssues), fixRes.RemainingIssues)
	}
}
