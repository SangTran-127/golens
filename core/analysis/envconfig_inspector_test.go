package analysis

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestEnvConfigSafetyInspectorDetectsAndFixesAllCategories(t *testing.T) {
	src := `package config

import (
	"net/http"
	"os"
	"strconv"
)

func loadAndServe() error {
	dbURL := os.Getenv("DATABASE_URL")
	port, _ := strconv.Atoi(os.Getenv("PORT"))
	_ = dbURL
	_ = port
	return http.ListenAndServe("localhost:8080", nil)
}
`
	reqBytes, _ := json.Marshal(EnvConfigSafetyInspectRequest{
		Content:  src,
		FilePath: "config.go",
	})
	raw := InspectEnvConfigSafety(string(reqBytes))
	var res EnvConfigSafetyInspectResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("unmarshal inspect result: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("unexpected inspect error: %s", res.Error)
	}
	if res.GetenvWithoutLookupOrFallbackCount != 1 {
		t.Fatalf("expected 1 getenv_without_lookupenv_or_fallback, got %d", res.GetenvWithoutLookupOrFallbackCount)
	}
	if res.UncheckedStrconvEnvParseCount != 1 {
		t.Fatalf("expected 1 unchecked_strconv_env_parse, got %d", res.UncheckedStrconvEnvParseCount)
	}
	if res.HardcodedLocalhostInProdConfigCount != 1 {
		t.Fatalf("expected 1 hardcoded_localhost_or_port_in_prod_config, got %d", res.HardcodedLocalhostInProdConfigCount)
	}

	fixReqBytes, _ := json.Marshal(EnvConfigSafetyFixRequest{
		Content:  src,
		FilePath: "config.go",
		All:      true,
	})
	fixRaw := ApplyEnvConfigSafetyFixes(string(fixReqBytes))
	var fixRes EnvConfigSafetyFixResult
	if err := json.Unmarshal([]byte(fixRaw), &fixRes); err != nil {
		t.Fatalf("unmarshal fix result: %v", err)
	}
	if fixRes.Error != "" {
		t.Fatalf("unexpected fix error: %s", fixRes.Error)
	}
	if fixRes.FixedCount != 3 {
		t.Fatalf("expected 3 fixed issues, got %d", fixRes.FixedCount)
	}
	if !strings.Contains(fixRes.NewContent, `os.LookupEnv("DATABASE_URL")`) {
		t.Fatalf("expected LookupEnv guard in fixed code, got:\n%s", fixRes.NewContent)
	}
	if !strings.Contains(fixRes.NewContent, `if portErr != nil`) {
		t.Fatalf("expected portErr check in fixed code, got:\n%s", fixRes.NewContent)
	}
	if !strings.Contains(fixRes.NewContent, `http.ListenAndServe(os.Getenv("LISTEN_ADDR"), nil)`) {
		t.Fatalf("expected LISTEN_ADDR replacement in fixed code, got:\n%s", fixRes.NewContent)
	}

	recheckBytes, _ := json.Marshal(EnvConfigSafetyInspectRequest{
		Content:  fixRes.NewContent,
		FilePath: "config.go",
	})
	var recheck EnvConfigSafetyInspectResult
	_ = json.Unmarshal([]byte(InspectEnvConfigSafety(string(recheckBytes))), &recheck)
	if len(recheck.Issues) != 0 {
		t.Fatalf("expected 0 issues after Fix All, got %d: %+v", len(recheck.Issues), recheck.Issues)
	}
}
