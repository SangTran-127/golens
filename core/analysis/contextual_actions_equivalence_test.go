package analysis

import (
	"encoding/json"
	"fmt"
	"go/parser"
	"go/token"
	"reflect"
	"strings"
	"testing"
)

func referenceContextualQuickFixes(workspaceDir, filePath, content string, line int) ([]ContextualQuickFix, error) {
	if strings.TrimSpace(content) == "" {
		return nil, nil
	}

	lines := strings.Split(content, "\n")
	if line < 1 || line > len(lines) {
		return nil, nil
	}

	var fixes []ContextualQuickFix
	if strings.Contains(content, "context") || strings.Contains(content, "defer") || strings.Contains(content, "go ") || strings.Contains(content, "sync") {
		if concReportJSON, err := InspectFileConcurrency(filePath, content); err == nil {
			var concReport ConcurrencyReport
			if json.Unmarshal([]byte(concReportJSON), &concReport) == nil {
				for _, f := range concReport.Findings {
					if (f.Line == line || f.Line == line-1 || f.Line == line+1) && f.CanAutoFix {
						if rawFix, fixErr := ApplyConcurrencyQuickFix(filePath, content, f.Line, f.Kind); fixErr == nil {
							var fixRes ConcurrencyFixResult
							if json.Unmarshal([]byte(rawFix), &fixRes) == nil && fixRes.UpdatedSource != "" && fixRes.UpdatedSource != content && fixRes.Title != "" {
								fixes = append(fixes, ContextualQuickFix{
									ID:            fmt.Sprintf("concurrency.%s.%d", f.Kind, f.Line),
									Title:         fixRes.Title,
									Kind:          "quickfix.golens",
									InspectorID:   "concurrency",
									Line:          f.Line,
									UpdatedSource: fixRes.UpdatedSource,
									Summary:       f.Summary,
								})
							}
						}
					}
				}
			}
		}
	}
	if strings.Contains(content, "http") {
		if httpReport, err := InspectHTTPSafety(filePath, content); err == nil && httpReport != nil {
			for _, issue := range httpReport.Issues {
				if (issue.Line == line || issue.Line == line-1 || issue.Line == line+1) && issue.CanAutoFix && issue.FixTitle != "" {
					if fixedSrc, fixErr := ApplyHTTPSafetyFix(filePath, content, issue.Line, issue.Column, issue.Kind); fixErr == nil && fixedSrc != "" && fixedSrc != content {
						fixes = append(fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("http.%s.%d.%d", issue.Kind, issue.Line, issue.Column),
							Title:         issue.FixTitle,
							Kind:          "quickfix.golens",
							InspectorID:   "http",
							Line:          issue.Line,
							UpdatedSource: fixedSrc,
							Summary:       issue.Message,
						})
					}
				}
			}
		}
	}
	if strings.Contains(content, "http") || strings.Contains(content, "ResponseWriter") || strings.Contains(content, "WriteHeader") || strings.Contains(content, "Header") {
		if httpRespReport, err := InspectHTTPRespSafety(filePath, content); err == nil && httpRespReport != nil {
			for _, issue := range httpRespReport.Issues {
				if (issue.Line == line || (line >= issue.Line && line <= issue.EndLine)) && issue.CanAutoFix && issue.FixTitle != "" {
					if fixRes, fixErr := ApplyHTTPRespSafetyFix(filePath, content, issue.ID, false); fixErr == nil && fixRes != nil && fixRes.AppliedCount > 0 {
						if fixRes.NewContent != "" && fixRes.NewContent != content {
							fixes = append(fixes, ContextualQuickFix{
								ID:            fmt.Sprintf("httpresp.%s", issue.ID),
								Title:         issue.FixTitle,
								Kind:          "quickfix.golens",
								InspectorID:   "httpresp",
								Line:          issue.Line,
								UpdatedSource: fixRes.NewContent,
								Summary:       issue.Message,
							})
						}
					}
				}
			}
		}
	}
	if strings.Contains(content, "testing") || strings.Contains(content, "t.") {
		if testReport, err := InspectGoTestingSafety(content, filePath); err == nil {
			for _, issue := range testReport.Issues {
				if issue.Line == line && issue.CanAutoFix && issue.FixTitle != "" {
					if fixRes, fixErr := ApplyGoTestingSafetyFixes(content, filePath, issue.ID, false); fixErr == nil {
						if fixRes.NewContent != "" && fixRes.NewContent != content {
							fixes = append(fixes, ContextualQuickFix{
								ID:            fmt.Sprintf("testing.%s", issue.ID),
								Title:         issue.FixTitle,
								Kind:          "quickfix.golens",
								InspectorID:   "testing",
								Line:          issue.Line,
								UpdatedSource: fixRes.NewContent,
								Summary:       issue.Message,
							})
						}
					}
				}
			}
		}
	}
	if strings.Contains(content, "Dial") || strings.Contains(content, "Listen") || strings.Contains(content, "Transport") {
		if netdialRes, err := InspectNetDialSafety(NetDialSafetyRequest{FilePath: filePath, Content: content}); err == nil {
			for _, issue := range netdialRes.Issues {
				if issue.Line == line && issue.CanAutoFix && issue.QuickFixTitle != "" {
					fixRes := ApplyNetDialSafetyFixes(NetDialSafetyFixRequest{
						FilePath: filePath,
						Content:  content,
						IssueIDs: []string{issue.ID},
					})
					if fixRes.Error == "" && fixRes.AppliedCount > 0 && fixRes.ModifiedContent != "" && fixRes.ModifiedContent != content {
						fixes = append(fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("netdial.%s", issue.ID),
							Title:         issue.QuickFixTitle,
							Kind:          "quickfix.golens",
							InspectorID:   "netdial",
							Line:          issue.Line,
							UpdatedSource: fixRes.ModifiedContent,
							Summary:       issue.Message,
						})
					}
				}
			}
		}
	}
	if strings.Contains(content, "fmt.Errorf") || strings.Contains(content, "err") || strings.Contains(content, "Err") {
		if errReport, err := InspectErrorWrapping("", filePath, content, false); err == nil {
			for _, f := range errReport.Findings {
				if f.Line == line && f.CanQuickFix && f.FixTitle != "" {
					fixedSrc, fixErr := FixErrorWrappingIssue(filePath, content, f.Line, f.Kind, f.TargetName)
					if fixErr == nil && fixedSrc != "" && fixedSrc != content {
						fixes = append(fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("errwrap.%s.%d", f.Kind, f.Line),
							Title:         f.FixTitle,
							Kind:          "quickfix.golens",
							InspectorID:   "errwrap",
							Line:          f.Line,
							UpdatedSource: fixedSrc,
							Summary:       f.Message,
						})
					}
				}
			}
		}
	}

	if hasResourceSafetyPrefilter(content) {
		if resReport, err := InspectResourceAndInjectionRisks("", filePath, content, false); err == nil {
			for _, rf := range resReport.Findings {
				if rf.Kind == "RESOURCE_UNCLOSED" && rf.Line == line && rf.CanQuickFix && rf.TargetName != "" {
					if fixedSrc, fixErr := FixResourceRiskIssue(filePath, content, rf.Line, rf.Kind, rf.TargetName); fixErr == nil && fixedSrc != "" && fixedSrc != content {
						appendContextualFixIfUnique(&fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("resource.%s.%d.%s", rf.Kind, rf.Line, rf.TargetName),
							Title:         fmt.Sprintf("Add defer %s.Close()", rf.TargetName),
							Kind:          "quickfix.golens",
							InspectorID:   "resource",
							Line:          rf.Line,
							UpdatedSource: fixedSrc,
							Summary:       rf.Message,
						})
					}
				}
			}
		}
	}
	if strings.Contains(content, ".Begin(") || strings.Contains(content, ".BeginTx(") {
		fset := token.NewFileSet()
		parsePath := filePath
		if strings.TrimSpace(parsePath) == "" {
			parsePath = "input.go"
		}
		if astFile, err := parser.ParseFile(fset, parsePath, content, parser.ParseComments); err == nil && astFile != nil {
			for _, txIssue := range inspectASTFileSQLTransactions(fset, astFile, content) {
				if txIssue.Line == line && txIssue.CanQuickFix {
					if fixedSrc, title, fixErr := FixSQLTransactionIssue(filePath, content, txIssue.Line); fixErr == nil && fixedSrc != "" && fixedSrc != content && title != "" {
						appendContextualFixIfUnique(&fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("sqltx.SQL_TX_UNCLOSED.%d.%s", txIssue.Line, txIssue.TargetName),
							Title:         title,
							Kind:          "quickfix.golens",
							InspectorID:   "sqltx",
							Line:          txIssue.Line,
							UpdatedSource: fixedSrc,
							Summary:       txIssue.Message,
						})
					}
				}
			}
		}
	}
	if strings.Contains(content, "NewTicker") || strings.Contains(content, "NewTimer") {
		parsePath := filePath
		if strings.TrimSpace(parsePath) == "" {
			parsePath = "input.go"
		}
		timeRep := InspectTimeSafety(TimeSafetyInspectRequest{FilePath: parsePath, Content: content, Scope: "file"})
		if timeRep.Error == "" {
			for _, tf := range timeRep.Findings {
				if tf.Category == "TICKER_UNSTOPPED" && tf.Line == line && tf.CanAutoFix && tf.Replacement != "" {
					fixRes := ApplyTimeSafetyFixes(TimeSafetyFixRequest{FilePath: parsePath, Content: content, FindingID: tf.ID})
					if fixRes.Error == "" && fixRes.AppliedCount > 0 && fixRes.NewContent != "" && fixRes.NewContent != content {
						appendContextualFixIfUnique(&fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("time.%s", tf.ID),
							Title:         "Add " + tf.Replacement,
							Kind:          "quickfix.golens",
							InspectorID:   "time",
							Line:          tf.Line,
							UpdatedSource: fixRes.NewContent,
							Summary:       tf.Message,
						})
					}
				}
			}
		}
	}
	if strings.Contains(content, ".Lock()") || strings.Contains(content, ".RLock()") {
		parsePath := filePath
		if strings.TrimSpace(parsePath) == "" {
			parsePath = defaultSyncInputFile
		}
		syncRep := InspectSyncSafety(SyncSafetyInspectRequest{FilePath: parsePath, Content: content, Scope: "file"})
		if syncRep.Error == "" {
			for _, sf := range syncRep.Findings {
				if sf.Category == "SYNC_LOCK_NO_UNLOCK" && sf.Line == line && sf.CanAutoFix && sf.Replacement != "" {
					fixRes := ApplySyncSafetyFixes(SyncSafetyFixRequest{FilePath: parsePath, Content: content, FindingID: sf.ID})
					if fixRes.Error == "" && fixRes.AppliedCount > 0 && fixRes.NewContent != "" && fixRes.NewContent != content {
						appendContextualFixIfUnique(&fixes, ContextualQuickFix{
							ID:            fmt.Sprintf("sync.%s", sf.ID),
							Title:         "Add " + sf.Replacement,
							Kind:          "quickfix.golens",
							InspectorID:   "sync",
							Line:          sf.Line,
							UpdatedSource: fixRes.NewContent,
							Summary:       sf.Message,
						})
					}
				}
			}
		}
	}

	return fixes, nil
}

func TestContextualASTQuickFixes_MatchesPerInspectorPipeline(t *testing.T) {
	sources := map[string]string{
		"mixed.go": `package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"
)

var ErrNotFound = errors.New("not found")

func worker(ctx context.Context) error {
	c2, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	_ = c2
	go func() {
		for {
		}
	}()
	resp, err := http.Get("https://example.com")
	if err != nil {
		return fmt.Errorf("fetch: %v", err)
	}
	_ = resp
	conn, err := net.Dial("tcp", "example.com:80")
	if err == ErrNotFound {
		return err
	}
	_ = conn
	_ = cancel
	return nil
}

func handler(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("hi"))
	w.WriteHeader(http.StatusOK)
	http.Redirect(w, r, r.URL.Query().Get("next"), http.StatusFound)
}
`,
		"mixed_test.go": `package main

import (
	"os"
	"testing"
)

func helper(t *testing.T, v string) {
	if v == "" {
		t.Fatal("empty")
	}
}

func TestThing(t *testing.T) {
	t.Parallel()
	os.Setenv("X", "1")
	go func() {
		t.Fatal("boom")
	}()
	helper(t, "x")
}
`,
		"mixed_ops.go": `package ops

import (
	"context"
	"database/sql"
	"os"
	"sync"
	"time"
)

func runOps(ctx context.Context, db *sql.DB, mu *sync.Mutex, rw *sync.RWMutex, fail bool) error {
	f, err := os.Open("cfg.json")
	if err != nil {
		return err
	}
	if fail {
		return err
	}
	_ = f.Close()

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if fail {
		return err
	}
	_ = tx.Commit()

	tk := time.NewTicker(time.Second)
	<-tk.C

	mu.Lock()
	rw.RLock()
	return nil
}
`,
		"broken.go": "package main\n\nfunc f() {\n\tctx, cancel := context.WithCancel(context.Background()\n}\n",
	}
	seen := make(map[string]bool)
	for name, src := range sources {
		total := strings.Count(src, "\n") + 1
		for line := 1; line <= total; line++ {
			got, gotErr := ContextualASTQuickFixes("", name, src, line)
			want, wantErr := referenceContextualQuickFixes("", name, src, line)
			if (gotErr == nil) != (wantErr == nil) {
				t.Fatalf("%s:%d error mismatch: got %v want %v", name, line, gotErr, wantErr)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("%s:%d fixes differ\n got %+v\nwant %+v", name, line, got, want)
			}
			for _, fix := range got {
				seen[fix.InspectorID] = true
			}
		}
	}
	for _, id := range []string{"concurrency", "http", "httpresp", "testing", "netdial", "errwrap", "resource", "sqltx", "time", "sync"} {
		if !seen[id] {
			t.Errorf("expected at least one %s quick fix across the samples, saw %v", id, seen)
		}
	}
}
