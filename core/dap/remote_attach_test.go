package dap

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRemoteAttachCarriesSubstitutePath(t *testing.T) {
	args := attachArguments(RunConfig{RemoteAddr: "api (Compose)", SubstitutePath: []SubstitutePath{{From: "/Users/me/shop", To: "/tmp/golens/shop/api/src"}}})
	b, _ := json.Marshal(args)
	s := string(b)
	if !strings.Contains(s, `"mode":"remote"`) || !strings.Contains(s, `"substitutePath":[{"from":"/Users/me/shop","to":"/tmp/golens/shop/api/src"}]`) {
		t.Fatalf("attach args = %s", s)
	}
	b, _ = json.Marshal(attachArguments(RunConfig{RemoteAddr: "x"}))
	if strings.Contains(string(b), "substitutePath") {
		t.Fatalf("no mapping expected: %s", b)
	}
}

func TestConfigDecodesSubstitutePath(t *testing.T) {
	var c RunConfig
	if err := json.Unmarshal([]byte(`{"remoteAddr":"a","substitutePath":[{"from":"/l","to":"/r"}]}`), &c); err != nil || len(c.SubstitutePath) != 1 || c.SubstitutePath[0].To != "/r" {
		t.Fatalf("decoded %+v %v", c, err)
	}
}
