package goast

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/bridge"
)

func TestEscapeParseOutput(t *testing.T) {
	raw := strings.Join([]string{
		"# example.com/demo/ledger",
		"ledger/ledger.go:25:9: &Account{...} escapes to heap",
		"ledger/ledger.go:25:9: &Account{...} escapes to heap",
		"ledger/ledger.go:24:6: can inline NewAccount",
		"ledger/ledger.go:24:17: leaking param: owner",
		"ledger/ledger.go:30:2: moved to heap: acc",
		"ledger/ledger.go:35:14: & scratch does not escape",
		"./main.go:18:13: inlining call to ledger.NewAccount",
	}, "\n")

	workDir := "/workspace/demo"
	targetFile := "/workspace/demo/ledger/ledger.go"

	items := ParseEscapeOutput(raw, workDir, targetFile)
	if len(items) != 5 {
		t.Fatalf("expected 5 items for target file, got %d: %+v", len(items), items)
	}

	if items[0].Line != 24 || items[0].Col != 6 || items[0].Kind != "inline" {
		t.Errorf("unexpected item[0]: %+v", items[0])
	}
	if items[0].Summary != "can inline NewAccount" {
		t.Errorf("unexpected summary for item[0]: %q", items[0].Summary)
	}

	if items[1].Line != 24 || items[1].Col != 17 || items[1].Kind != "leak" || items[1].Subject != "owner" {
		t.Errorf("unexpected item[1]: %+v", items[1])
	}
	if items[1].Summary != "↗ leaks param: owner" {
		t.Errorf("unexpected summary for item[1]: %q", items[1].Summary)
	}

	if items[2].Line != 25 || items[2].Col != 9 || items[2].Kind != "heap" || items[2].Subject != "&Account{...}" {
		t.Errorf("unexpected item[2]: %+v", items[2])
	}
	if items[2].Summary != "↗ heap: &Account{...}" {
		t.Errorf("unexpected summary for item[2]: %q", items[2].Summary)
	}

	if items[3].Line != 30 || items[3].Col != 2 || items[3].Kind != "heap" || items[3].Subject != "acc" {
		t.Errorf("unexpected item[3]: %+v", items[3])
	}
	if items[3].Summary != "↗ heap: acc" {
		t.Errorf("unexpected summary for item[3]: %q", items[3].Summary)
	}

	if items[4].Line != 35 || items[4].Col != 14 || items[4].Kind != "stack" {
		t.Errorf("unexpected item[4]: %+v", items[4])
	}
	if items[4].Summary != "stack: & scratch does not escape" {
		t.Errorf("unexpected summary for item[4]: %q", items[4].Summary)
	}

	allItems := ParseEscapeOutput(raw, workDir, "")
	if len(allItems) != 6 {
		t.Fatalf("expected 6 items across all files, got %d", len(allItems))
	}
}

func TestEscapeAnalyzeEndToEnd(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	tmpDir := t.TempDir()

	goMod := "module example.com/escapedemo\n\ngo 1.22\n"
	if err := os.WriteFile(filepath.Join(tmpDir, "go.mod"), []byte(goMod), 0644); err != nil {
		t.Fatalf("failed to write go.mod: %v", err)
	}

	src := strings.Join([]string{
		"package escapedemo",
		"",
		"type Item struct {",
		"\tName  string",
		"\tValue int",
		"}",
		"",
		"func NewItem(name string, v int) *Item {",
		"\treturn &Item{Name: name, Value: v}",
		"}",
		"",
	}, "\n")

	filePath := filepath.Join(tmpDir, "item.go")
	if err := os.WriteFile(filePath, []byte(src), 0644); err != nil {
		t.Fatalf("failed to write item.go: %v", err)
	}

	rawJSON, err := AnalyzeEscape(tmpDir, filePath)
	if err != nil {
		t.Fatalf("AnalyzeEscape returned error: %v", err)
	}

	var res EscapeAnalysisResult
	if err := json.Unmarshal([]byte(rawJSON), &res); err != nil {
		t.Fatalf("failed to unmarshal EscapeAnalysisResult: %v (raw=%s)", err, rawJSON)
	}

	if res.Error != "" {
		t.Fatalf("unexpected result error: %s", res.Error)
	}
	if len(res.Items) == 0 {
		t.Fatalf("expected non-empty escape items, got 0")
	}

	foundHeapOnLine9 := false
	for _, item := range res.Items {
		if item.Kind == "heap" && item.Line == 9 && item.Summary != "" {
			foundHeapOnLine9 = true
			if !strings.Contains(item.Summary, "↗ heap:") {
				t.Errorf("expected heap summary prefix on line 9, got %q", item.Summary)
			}
		}
	}
	if !foundHeapOnLine9 {
		t.Fatalf("expected a heap escape item on line 9, got items: %+v", res.Items)
	}
}
