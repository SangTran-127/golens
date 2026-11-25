package analysis

import (
	"encoding/json"
	"go/format"
	"strings"
	"testing"
)

func TestCryptoSafetyInspectAllCategories(t *testing.T) {
	src := `package auth

import (
	"bytes"
	"crypto/des"
	"crypto/md5"
	"crypto/rc4"
	"crypto/sha1"
	"math/rand"
	"strings"
)

func VerifyAndGenerate(
	userToken, expectedToken string,
	apiKey, validApiKey string,
	hmacSig, expectedSig []byte,
	userOTP, expectedOTP string,
	payload []byte,
	desKey, rc4Key []byte,
) bool {
	h1 := md5.New()
	sum1 := md5.Sum(payload)
	h2 := sha1.New()
	sum2 := sha1.Sum(payload)
	c1, _ := des.NewCipher(desKey)
	c2, _ := rc4.NewCipher(rc4Key)
	_, _, _, _, _, _ = h1, sum1, h2, sum2, c1, c2

	rand.Seed(42)
	nonce := make([]byte, 16)
	_, _ = rand.Read(nonce)
	otpNum := rand.Intn(1000000)
	r1 := rand.Int()
	r2 := rand.Int63()
	r3 := rand.Uint64()
	_, _, _, _ = otpNum, r1, r2, r3

	if userToken == "" || hmacSig == nil {
		return false
	}

	if userToken == expectedToken {
		return true
	}
	if apiKey != validApiKey {
		return false
	}
	if bytes.Equal(hmacSig, expectedSig) {
		return true
	}
	if strings.EqualFold(userOTP, expectedOTP) {
		return true
	}

	return false
}
`

	reqBytes, err := json.Marshal(CryptoSafetyInspectRequest{
		Path:    "auth.go",
		Content: src,
	})
	if err != nil {
		t.Fatalf("failed to marshal inspect request: %v", err)
	}

	raw := InspectCryptoSafety(string(reqBytes))
	var res CryptoSafetyInspectResult
	if err := json.Unmarshal([]byte(raw), &res); err != nil {
		t.Fatalf("failed to unmarshal inspect result: %v\nraw: %s", err, raw)
	}

	if res.Error != "" {
		t.Fatalf("unexpected inspect error: %s", res.Error)
	}
	if res.WeakHashCount != 6 {
		t.Fatalf("expected WeakHashCount=6, got %d", res.WeakHashCount)
	}
	if res.MathRandCount != 6 {
		t.Fatalf("expected MathRandCount=6, got %d", res.MathRandCount)
	}
	if res.TimingCompareCount != 4 {
		t.Fatalf("expected TimingCompareCount=4, got %d", res.TimingCompareCount)
	}
	if len(res.Issues) != 16 {
		t.Fatalf("expected 16 total issues, got %d", len(res.Issues))
	}

	for _, issue := range res.Issues {
		if !issue.CanAutoFix {
			t.Errorf("expected issue %s (%s) to have CanAutoFix=true", issue.ID, issue.Expr)
		}
		switch issue.Category {
		case "weak_hash":
			if issue.Severity != "warning" {
				t.Errorf("expected weak_hash severity 'warning', got %q", issue.Severity)
			}
			if issue.FixTitle != "Upgrade to sha256" {
				t.Errorf("unexpected weak_hash FixTitle: %q", issue.FixTitle)
			}
			if !strings.Contains(issue.Message, "Weak cryptographic primitive") {
				t.Errorf("unexpected weak_hash Message: %q", issue.Message)
			}
		case "math_rand_security":
			if issue.Severity != "error" {
				t.Errorf("expected math_rand_security severity 'error', got %q", issue.Severity)
			}
			if issue.FixTitle != "Replace with crypto/rand safe helper" {
				t.Errorf("unexpected math_rand_security FixTitle: %q", issue.FixTitle)
			}
			if issue.Message != "Non-cryptographic PRNG (math/rand) is predictable and unsafe for tokens, IDs, or secrets" {
				t.Errorf("unexpected math_rand_security Message: %q", issue.Message)
			}
		case "non_constant_time_compare":
			if issue.Severity != "error" {
				t.Errorf("expected non_constant_time_compare severity 'error', got %q", issue.Severity)
			}
			if issue.FixTitle != "Use subtle.ConstantTimeCompare" {
				t.Errorf("unexpected non_constant_time_compare FixTitle: %q", issue.FixTitle)
			}
			if !strings.Contains(issue.Message, "Direct comparison on secret/signature") {
				t.Errorf("unexpected non_constant_time_compare Message: %q", issue.Message)
			}
		default:
			t.Errorf("unexpected category %q", issue.Category)
		}
	}
}

func TestCryptoSafetySingleFixAndFixAll(t *testing.T) {
	src := `package token

import (
	"bytes"
	"crypto/md5"
	"crypto/sha1"
	"math/rand"
)

func IssueAndCheck(secretToken, expectedToken string, sigA, sigB []byte, data []byte) ([]byte, int, bool) {
	h1 := md5.New()
	sum1 := md5.Sum(data)
	h2 := sha1.New()
	sum2 := sha1.Sum(data)
	_, _, _, _ = h1, sum1, h2, sum2

	buf := make([]byte, 16)
	_, _ = rand.Read(buf)
	pinCode := rand.Intn(999999)

	if secretToken == expectedToken {
		return buf, pinCode, true
	}
	if secretToken != expectedToken {
		return buf, pinCode, false
	}
	if bytes.Equal(sigA, sigB) {
		return buf, pinCode, true
	}
	return buf, pinCode, false
}
`

	inspectReqJSON, _ := json.Marshal(CryptoSafetyInspectRequest{
		Path:    "token.go",
		Content: src,
	})
	var initial CryptoSafetyInspectResult
	if err := json.Unmarshal([]byte(InspectCryptoSafety(string(inspectReqJSON))), &initial); err != nil {
		t.Fatalf("failed to unmarshal initial inspect: %v", err)
	}
	if len(initial.Issues) != 9 {
		t.Fatalf("expected 9 initial issues, got %d", len(initial.Issues))
	}

	firstID := initial.Issues[0].ID
	singleFixReqJSON, _ := json.Marshal(CryptoSafetyFixRequest{
		Path:    "token.go",
		Content: src,
		IssueID: firstID,
		All:     false,
	})
	var singleFix CryptoSafetyFixResult
	if err := json.Unmarshal([]byte(FixCryptoSafetyIssue(string(singleFixReqJSON))), &singleFix); err != nil {
		t.Fatalf("failed to unmarshal single fix result: %v", err)
	}
	if singleFix.Error != "" {
		t.Fatalf("unexpected single fix error: %s", singleFix.Error)
	}
	if singleFix.FixedCount != 1 {
		t.Fatalf("expected FixedCount=1, got %d", singleFix.FixedCount)
	}
	if !strings.Contains(singleFix.NewContent, "sha256.New()") {
		t.Fatalf("expected sha256.New() in single fix output:\n%s", singleFix.NewContent)
	}
	if !strings.Contains(singleFix.NewContent, `"crypto/sha256"`) {
		t.Fatalf("expected \"crypto/sha256\" import in single fix output:\n%s", singleFix.NewContent)
	}
	if !strings.Contains(singleFix.NewContent, `"crypto/md5"`) {
		t.Fatalf("expected \"crypto/md5\" import to remain while md5.Sum still exists:\n%s", singleFix.NewContent)
	}

	afterSingleReqJSON, _ := json.Marshal(CryptoSafetyInspectRequest{
		Path:    "token.go",
		Content: singleFix.NewContent,
	})
	var afterSingle CryptoSafetyInspectResult
	_ = json.Unmarshal([]byte(InspectCryptoSafety(string(afterSingleReqJSON))), &afterSingle)
	if len(afterSingle.Issues) != 8 {
		t.Fatalf("expected 8 remaining issues after single fix, got %d", len(afterSingle.Issues))
	}

	fixAllReqJSON, _ := json.Marshal(CryptoSafetyFixRequest{
		Path:    "token.go",
		Content: src,
		All:     true,
	})
	var allFix CryptoSafetyFixResult
	if err := json.Unmarshal([]byte(FixCryptoSafetyIssue(string(fixAllReqJSON))), &allFix); err != nil {
		t.Fatalf("failed to unmarshal fix-all result: %v", err)
	}
	if allFix.Error != "" {
		t.Fatalf("unexpected fix-all error: %s", allFix.Error)
	}
	if allFix.FixedCount != 9 {
		t.Fatalf("expected FixedCount=9, got %d", allFix.FixedCount)
	}

	formatted, fmtErr := format.Source([]byte(allFix.NewContent))
	if fmtErr != nil {
		t.Fatalf("expected syntactically valid Go code after fix-all, got error: %v\ncode:\n%s", fmtErr, allFix.NewContent)
	}
	if string(formatted) != allFix.NewContent {
		t.Fatalf("expected fix-all NewContent to be gofmt-formatted")
	}

	if strings.Contains(allFix.NewContent, `"crypto/md5"`) || strings.Contains(allFix.NewContent, `"crypto/sha1"`) {
		t.Errorf("expected weak hash imports to be removed after fix-all:\n%s", allFix.NewContent)
	}
	if strings.Contains(allFix.NewContent, `"math/rand"`) {
		t.Errorf("expected math/rand import to be removed after fix-all:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, `"crypto/sha256"`) {
		t.Errorf("expected crypto/sha256 import in fix-all output:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, `"crypto/rand"`) {
		t.Errorf("expected crypto/rand import in fix-all output:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, `"crypto/subtle"`) {
		t.Errorf("expected crypto/subtle import in fix-all output:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "subtle.ConstantTimeCompare([]byte(secretToken), []byte(expectedToken)) == 1") {
		t.Errorf("missing ConstantTimeCompare == 1 replacement in:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "subtle.ConstantTimeCompare([]byte(secretToken), []byte(expectedToken)) != 1") {
		t.Errorf("missing ConstantTimeCompare != 1 replacement in:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "subtle.ConstantTimeCompare(sigA, sigB) == 1") {
		t.Errorf("missing ConstantTimeCompare(sigA, sigB) == 1 replacement in:\n%s", allFix.NewContent)
	}

	recheckReqJSON, _ := json.Marshal(CryptoSafetyInspectRequest{
		Path:    "token.go",
		Content: allFix.NewContent,
	})
	var recheck CryptoSafetyInspectResult
	if err := json.Unmarshal([]byte(InspectCryptoSafety(string(recheckReqJSON))), &recheck); err != nil {
		t.Fatalf("failed to unmarshal recheck result: %v", err)
	}
	if recheck.Error != "" {
		t.Fatalf("unexpected recheck error: %s", recheck.Error)
	}
	if len(recheck.Issues) != 0 || recheck.WeakHashCount != 0 || recheck.MathRandCount != 0 || recheck.TimingCompareCount != 0 {
		t.Fatalf("expected 0 issues after fix-all, got %d issues (%+v)\ncode:\n%s", len(recheck.Issues), recheck, allFix.NewContent)
	}
}

func TestCryptoSafetySafePatternsIgnored(t *testing.T) {
	src := `package safe

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
)

func SafeVerify(apiToken, expectedToken string, payload []byte) bool {
	h := sha256.New()
	_ = h
	sum := sha256.Sum256(payload)
	_ = sum

	buf := make([]byte, 32)
	_, _ = rand.Read(buf)

	if apiToken == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(apiToken), []byte(expectedToken)) == 1
}
`

	reqBytes, _ := json.Marshal(CryptoSafetyInspectRequest{
		Path:    "safe.go",
		Content: src,
	})
	var res CryptoSafetyInspectResult
	if err := json.Unmarshal([]byte(InspectCryptoSafety(string(reqBytes))), &res); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}
	if len(res.Issues) != 0 {
		t.Fatalf("expected 0 issues on safe code, got %d: %+v", len(res.Issues), res.Issues)
	}
}

func TestCryptoSafetyHMACProvenanceAndNonCryptoExclusions(t *testing.T) {
	unsafeSrc := `package webhook

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
)

func VerifyWebhook(key, payload, provided, rawDigest []byte, providedHex string) bool {
	mac := hmac.New(sha256.New, key)
	mac.Write(payload)
	expected := mac.Sum(nil)
	if bytes.Equal(provided, expected) {
		return true
	}
	encoded := hex.EncodeToString(mac.Sum(nil))
	if encoded == providedHex {
		return true
	}
	expectedSignature := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	if expectedSignature == providedHex {
		return true
	}
	return string(rawDigest) == string(mac.Sum(nil))
}
`
	reqBytes, _ := json.Marshal(CryptoSafetyInspectRequest{
		Path:    "webhook.go",
		Content: unsafeSrc,
	})
	var res CryptoSafetyInspectResult
	if err := json.Unmarshal([]byte(InspectCryptoSafety(string(reqBytes))), &res); err != nil {
		t.Fatalf("failed to unmarshal result: %v", err)
	}
	if res.TimingCompareCount != 4 {
		t.Fatalf("expected 4 HMAC timing compare diagnostics, got %d (%+v)", res.TimingCompareCount, res.Issues)
	}
	for _, iss := range res.Issues {
		if !strings.Contains(iss.Message, "hmac.Equal") || !strings.Contains(iss.Message, "subtle.ConstantTimeCompare") {
			t.Errorf("expected hmac.Equal / subtle.ConstantTimeCompare guidance in message, got %q", iss.Message)
		}
	}

	safeNonCryptoSrc := `package webhook

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"go/ast"
	"go/token"
	"strings"
)

const DefaultJWTSecret = "dev"

type FileState struct {
	SourceHash  string
	CurrentHash string
	Tok         token.Token
	Kind        int
}

func SafeAndNonCrypto(
	key, payload, provided []byte,
	genDecl *ast.GenDecl,
	state, prev FileState,
	jwtSecret string,
	rawSig []byte,
	authHeader string,
	pkgIdent *ast.Ident,
	hmacAlias, tokenAlias string,
) bool {
	if pkgIdent.Name == hmacAlias || pkgIdent.Name != tokenAlias {
		return false
	}
	pathHashSym := genDecl.Tok.String() + "#" + authHeader
	if pathHashSym == authHeader {
		return false
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(payload)
	expected := mac.Sum(nil)
	if !hmac.Equal(provided, expected) {
		return false
	}
	if subtle.ConstantTimeCompare(provided, expected) != 1 {
		return false
	}
	if genDecl.Tok != token.TYPE || state.Tok == token.DEFINE {
		return false
	}
	if state.SourceHash != prev.SourceHash || state.CurrentHash == prev.CurrentHash {
		return false
	}
	if jwtSecret == DefaultJWTSecret || string(rawSig[:6]) != "SSHSIG" {
		return false
	}
	bearerToken := strings.TrimPrefix(authHeader, "Bearer ")
	if bearerToken == authHeader {
		return false
	}
	return bytes.Equal(rawSig[:4], []byte("SSHS"))
}
`
	safeBytes, _ := json.Marshal(CryptoSafetyInspectRequest{
		Path:    "safe_noncrypto.go",
		Content: safeNonCryptoSrc,
	})
	var safeRes CryptoSafetyInspectResult
	if err := json.Unmarshal([]byte(InspectCryptoSafety(string(safeBytes))), &safeRes); err != nil {
		t.Fatalf("failed to unmarshal safe result: %v", err)
	}
	if len(safeRes.Issues) != 0 {
		t.Fatalf("expected 0 issues on hmac.Equal and non-crypto checks, got %+v", safeRes.Issues)
	}
}
