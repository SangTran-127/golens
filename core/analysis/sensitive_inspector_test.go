package analysis

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectSensitiveData_AllThreeCategories(t *testing.T) {
	src := `package auth

import (
	"fmt"
	"log"
	"log/slog"
)

type Credentials struct {
	Username string ` + "`json:\"username\"`" + `
	Password string ` + "`json:\"password\"`" + `
	APIKey   string
	secret   string
}

func login(c Credentials, token string) {
	fmt.Println("logging in", c.Password)
	log.Printf("token=%s", token)
	slog.Info("auth", "secret", c.secret)
}
`

	report, err := InspectSensitiveData("", "/workspace/auth.go", src, false)
	if err != nil {
		t.Fatalf("InspectSensitiveData failed: %v", err)
	}

	if report.TagLeakCount != 2 {
		t.Errorf("expected TagLeakCount=2, got %d", report.TagLeakCount)
	}
	if report.StringerMissingCount != 1 {
		t.Errorf("expected StringerMissingCount=1, got %d", report.StringerMissingCount)
	}
	if report.LogLeakCount != 3 {
		t.Errorf("expected LogLeakCount=3, got %d", report.LogLeakCount)
	}
	if report.TotalFindings != 6 {
		t.Fatalf("expected TotalFindings=6, got %d: %+v", report.TotalFindings, report.Findings)
	}

	var foundTagPassword, foundTagAPIKey, foundStringer, foundLogField, foundLogVar, foundSlog bool
	for _, f := range report.Findings {
		switch f.Kind {
		case "sensitive_tag":
			if f.StructName == "Credentials" && f.FieldName == "Password" {
				foundTagPassword = true
				if f.Title != "Sensitive field Credentials.Password is serialized without redaction" {
					t.Errorf("unexpected tag title: %q", f.Title)
				}
				if f.QuickFixTitle != `Add json:"-" Tag` {
					t.Errorf("unexpected tag quickFixTitle: %q", f.QuickFixTitle)
				}
			}
			if f.StructName == "Credentials" && f.FieldName == "APIKey" {
				foundTagAPIKey = true
			}
		case "sensitive_stringer":
			if f.StructName == "Credentials" {
				foundStringer = true
				if f.Title != "Credentials prints sensitive field Password because it has no redacting String method" {
					t.Errorf("unexpected stringer title: %q", f.Title)
				}
				if f.QuickFixTitle != "Generate redacted String() method" {
					t.Errorf("unexpected stringer quickFixTitle: %q", f.QuickFixTitle)
				}
			}
		case "sensitive_log":
			if f.FieldName == "c.Password" {
				foundLogField = true
				if f.Title != "Sensitive value c.Password is written to a log or output" {
					t.Errorf("unexpected log title: %q", f.Title)
				}
				if f.QuickFixTitle != `Redact logged argument as "[REDACTED]"` {
					t.Errorf("unexpected log quickFixTitle: %q", f.QuickFixTitle)
				}
			}
			if f.FieldName == "token" {
				foundLogVar = true
			}
			if f.FieldName == "c.secret" {
				foundSlog = true
			}
		}
	}

	if !foundTagPassword || !foundTagAPIKey || !foundStringer || !foundLogField || !foundLogVar || !foundSlog {
		t.Errorf("missing expected findings: tagPassword=%v tagAPIKey=%v stringer=%v logField=%v logVar=%v slog=%v",
			foundTagPassword, foundTagAPIKey, foundStringer, foundLogField, foundLogVar, foundSlog)
	}
}

func TestInspectSensitiveData_CleanRedactedCode(t *testing.T) {
	src := `package auth

import "fmt"

type Account struct {
	ID       string ` + "`json:\"id\"`" + `
	Password string ` + "`json:\"-\"`" + `
	SSN      string ` + "`json:\"-\" yaml:\"-\"`" + `
}

func (a Account) String() string {
	return "Account{[REDACTED]}"
}

func audit(a Account) {
	fmt.Println("Account ID:", a.ID)
}
`

	report, err := InspectSensitiveData("", "account.go", src, false)
	if err != nil {
		t.Fatalf("InspectSensitiveData failed: %v", err)
	}
	if report.TotalFindings != 0 {
		t.Fatalf("expected 0 findings for redacted code, got %d: %+v", report.TotalFindings, report.Findings)
	}
}

func TestFixSensitiveDataIssue_AllThreeKindsProduceValidGoCode(t *testing.T) {
	src := `package auth

import "fmt"

type UserConfig struct {
	Username     string ` + "`json:\"username\"`" + `
	Password     string ` + "`json:\"password,omitempty\"`" + `
	ClientSecret string
}

func PrintConfig(cfg UserConfig, accessKey string) {
	fmt.Println(cfg.Password, accessKey)
}
`

	fset := token.NewFileSet()
	if _, err := parser.ParseFile(fset, "config.go", src, parser.ParseComments); err != nil {
		t.Fatalf("initial source should be valid Go: %v", err)
	}

	// 1. Fix sensitive_tag on line 7 (Password with existing json tag)
	fixed1, err := FixSensitiveDataIssue("config.go", src, 7, "sensitive_tag", "Password")
	if err != nil {
		t.Fatalf("FixSensitiveDataIssue(sensitive_tag line 7) failed: %v", err)
	}
	if !strings.Contains(fixed1, "Password     string `json:\"-\"`") {
		t.Errorf("expected Password tag replaced with json:\"-\", got:\n%s", fixed1)
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "config.go", fixed1, parser.ParseComments); err != nil {
		t.Fatalf("fixed1 is not valid Go: %v\n%s", err, fixed1)
	}

	// 2. Fix sensitive_tag on line 8 (ClientSecret without tag)
	fixed2, err := FixSensitiveDataIssue("config.go", fixed1, 8, "sensitive_tag", "ClientSecret")
	if err != nil {
		t.Fatalf("FixSensitiveDataIssue(sensitive_tag line 8) failed: %v", err)
	}
	if !strings.Contains(fixed2, "ClientSecret string `json:\"-\"`") {
		t.Errorf("expected ClientSecret tag added as json:\"-\", got:\n%s", fixed2)
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "config.go", fixed2, parser.ParseComments); err != nil {
		t.Fatalf("fixed2 is not valid Go: %v\n%s", err, fixed2)
	}

	// 3. Fix sensitive_log on line 12 (cfg.Password and accessKey)
	fixed3, err := FixSensitiveDataIssue("config.go", fixed2, 12, "sensitive_log", "cfg.Password")
	if err != nil {
		t.Fatalf("FixSensitiveDataIssue(sensitive_log cfg.Password) failed: %v", err)
	}
	fixed3b, err := FixSensitiveDataIssue("config.go", fixed3, 12, "sensitive_log", "accessKey")
	if err != nil {
		t.Fatalf("FixSensitiveDataIssue(sensitive_log accessKey) failed: %v", err)
	}
	if !strings.Contains(fixed3b, `fmt.Println("[REDACTED]", "[REDACTED]")`) {
		t.Errorf("expected both sensitive args redacted on line 12, got:\n%s", fixed3b)
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "config.go", fixed3b, parser.ParseComments); err != nil {
		t.Fatalf("fixed3b is not valid Go: %v\n%s", err, fixed3b)
	}

	// 4. Fix sensitive_stringer on UserConfig (line 5)
	fixed4, err := FixSensitiveDataIssue("config.go", fixed3b, 5, "sensitive_stringer", "UserConfig")
	if err != nil {
		t.Fatalf("FixSensitiveDataIssue(sensitive_stringer) failed: %v", err)
	}
	if !strings.Contains(fixed4, `func (s UserConfig) String() string`) || !strings.Contains(fixed4, `return "UserConfig{[REDACTED]}"`) {
		t.Errorf("expected String() method generated for UserConfig, got:\n%s", fixed4)
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "config.go", fixed4, parser.ParseComments); err != nil {
		t.Fatalf("fixed4 is not valid Go: %v\n%s", err, fixed4)
	}

	// Re-inspect after all fixes: should have 0 findings
	recheck, err := InspectSensitiveData("", "config.go", fixed4, false)
	if err != nil {
		t.Fatalf("re-inspect failed: %v", err)
	}
	if recheck.TotalFindings != 0 {
		t.Errorf("expected 0 findings after applying all fixes, got %d: %+v", recheck.TotalFindings, recheck.Findings)
	}
}

func TestInspectSensitiveData_WorkspaceExcludesTestsAndVendor(t *testing.T) {
	tmpDir := t.TempDir()

	prodFile := filepath.Join(tmpDir, "service.go")
	prodCode := `package service

type PaymentCard struct {
	CreditCard string ` + "`json:\"credit_card\"`" + `
}
`
	if err := os.WriteFile(prodFile, []byte(prodCode), 0644); err != nil {
		t.Fatal(err)
	}

	testFile := filepath.Join(tmpDir, "service_test.go")
	testCode := `package service

import "fmt"

func TestPayment(t *testing.T) {
	secret := "test-only"
	fmt.Println(secret)
}
`
	if err := os.WriteFile(testFile, []byte(testCode), 0644); err != nil {
		t.Fatal(err)
	}

	vendorDir := filepath.Join(tmpDir, "vendor", "pkg")
	if err := os.MkdirAll(vendorDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vendorDir, "vendor.go"), []byte(`package pkg
type V struct { Password string }
`), 0644); err != nil {
		t.Fatal(err)
	}

	report, err := InspectSensitiveData(tmpDir, prodFile, "", true)
	if err != nil {
		t.Fatalf("InspectSensitiveData workspace failed: %v", err)
	}

	if report.TagLeakCount != 1 || report.StringerMissingCount != 1 || report.LogLeakCount != 0 {
		t.Fatalf("expected only service.go findings (1 tag, 1 stringer, 0 log), got %+v", report)
	}
}

func TestInspectSensitiveData_DetectsUnredactedStringerAndStructCompositeLog(t *testing.T) {
	src := "package main\n\nimport \"fmt\"\n\ntype Credentials struct {\n\tPassword string `json:\"-\"`\n}\n\nfunc (c Credentials) String() string {\n\treturn c.Password\n}\n\nfunc main() {\n\tfmt.Println(Credentials{Password: \"qa-demo-secret\"})\n}\n"

	report, err := InspectSensitiveData("", "main.go", src, false)
	if err != nil {
		t.Fatalf("InspectSensitiveData failed: %v", err)
	}
	if report.StringerMissingCount != 1 || report.LogLeakCount != 1 || report.TotalFindings != 2 {
		t.Fatalf("expected 1 unredacted stringer + 1 composite log leak (total 2), got %+v", report)
	}

	fixed, err := FixSensitiveDataIssue("main.go", src, 5, "sensitive_stringer", "Credentials")
	if err != nil {
		t.Fatalf("FixSensitiveDataIssue(sensitive_stringer) failed: %v", err)
	}
	if strings.Contains(fixed, "return c.Password") || !strings.Contains(fixed, `return "Credentials{[REDACTED]}"`) {
		t.Fatalf("expected unredacted String() to be replaced with redacted String(), got:\n%s", fixed)
	}
}
