package analysis

import (
	"strings"
	"testing"
)

func TestInspectNetDialSafety_DetectsAllCategories(t *testing.T) {
	src := `package netprobe

import (
	"net"
	"net/http"
)

func connectAndServe() error {
	conn, err := net.Dial("tcp", "example.com:443")
	if err != nil {
		return err
	}
	defer conn.Close()
	tr := &http.Transport{DisableKeepAlives: true}
	_ = tr
	return http.ListenAndServe(":9090", nil)
}
`
	res, err := InspectNetDialSafety(NetDialSafetyRequest{
		FilePath: "netprobe.go",
		Content:  src,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Summary.TotalIssues != 3 {
		t.Fatalf("expected 3 issues, got %d: %+v", res.Summary.TotalIssues, res.Issues)
	}
	if res.Summary.DialWithoutTimeoutCount != 1 {
		t.Fatalf("expected 1 dialWithoutTimeoutCount, got %d", res.Summary.DialWithoutTimeoutCount)
	}
	if res.Summary.PerRequestTransportCount != 1 {
		t.Fatalf("expected 1 perRequestTransportCount, got %d", res.Summary.PerRequestTransportCount)
	}
	if res.Summary.WildcardListenBindCount != 1 {
		t.Fatalf("expected 1 wildcardListenBindCount, got %d", res.Summary.WildcardListenBindCount)
	}

	fixRes := ApplyNetDialSafetyFixes(NetDialSafetyFixRequest{
		FilePath: "netprobe.go",
		Content:  src,
	})
	if fixRes.AppliedCount != 3 {
		t.Fatalf("expected 3 fixes applied, got %d", fixRes.AppliedCount)
	}
	if !strings.Contains(fixRes.ModifiedContent, `net.DialTimeout("tcp", "example.com:443", 10*time.Second)`) {
		t.Fatalf("expected net.DialTimeout fix, got:\n%s", fixRes.ModifiedContent)
	}
	if !strings.Contains(fixRes.ModifiedContent, "DisableKeepAlives: false") {
		t.Fatalf("expected DisableKeepAlives: false fix, got:\n%s", fixRes.ModifiedContent)
	}
	if !strings.Contains(fixRes.ModifiedContent, `http.ListenAndServe("127.0.0.1:9090", nil)`) {
		t.Fatalf("expected explicit 127.0.0.1:9090 bind fix, got:\n%s", fixRes.ModifiedContent)
	}
}
