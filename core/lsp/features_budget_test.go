package lsp

import (
	"testing"
	"time"
)

func TestRemoteBudgetsAreAtLeastLocal(t *testing.T) {
	for m, local := range localBudgets {
		remote, ok := remoteBudgets[m]
		if !ok {
			t.Errorf("%s has no remote budget", m)
			continue
		}
		if remote < local {
			t.Errorf("%s: remote %v < local %v", m, remote, local)
		}
	}
	for _, dead := range []string{"textDocument/hover", "textDocument/inlayHint"} {
		if _, ok := localBudgets[dead]; ok {
			t.Errorf("%s budget has no core caller", dead)
		}
	}
	if requestBudget(true, "codeAction/resolve") <= requestBudget(true, "textDocument/codeAction") {
		t.Error("codeAction/resolve should get more time than the action list")
	}
	if requestBudget(false, "unknown") != 5*time.Second || requestBudget(true, "unknown") != 10*time.Second {
		t.Error("fallback budgets changed")
	}
}
