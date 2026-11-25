package database

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	historyCap       = 1000
	historySlack     = 200
	historyTextLimit = 64 << 10
	historyDefaultN  = 100
)

type HistoryEntry struct {
	ID            string       `json:"id"`
	Text          string       `json:"text"`
	Time          string       `json:"time"`
	DurationMs    float64      `json:"durationMs"`
	RowCount      *int64       `json:"rowCount"`
	Error         string       `json:"error,omitempty"`
	Source        string       `json:"source"`
	TextTruncated bool         `json:"textTruncated,omitempty"`
	Parameters    []ParamValue `json:"parameters,omitempty"`
}

type HistoryRequest struct {
	DataSourceID string `json:"dataSourceId"`
	Query        string `json:"query"`
	Limit        int    `json:"limit"`
	Delete       string `json:"delete,omitempty"`
	Clear        bool   `json:"clear,omitempty"`
}

type HistoryResult struct {
	Entries []HistoryEntry `json:"entries"`
	Error   *Error         `json:"error"`
}

var historyState = struct {
	mu     sync.Mutex
	root   string
	counts map[string]int
}{counts: map[string]int{}}

var bundleIDPattern = regexp.MustCompile(`<key>CFBundleIdentifier</key>\s*<string>([^<]+)</string>`)

func defaultHistoryRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	folder := "GoLens"
	if exe, err := os.Executable(); err == nil {
		plist := filepath.Join(filepath.Dir(filepath.Dir(exe)), "Info.plist")
		if b, err := os.ReadFile(plist); err == nil {
			if m := bundleIDPattern.FindSubmatch(b); m != nil {
				folder = strings.TrimSpace(string(m[1]))
			}
		}
	}
	return filepath.Join(home, "Library", "Application Support", folder, "QueryHistory")
}

func SetHistoryDirectory(dir string) OKResult {
	historyState.mu.Lock()
	defer historyState.mu.Unlock()
	historyState.root = dir
	historyState.counts = map[string]int{}
	return OKResult{OK: dir != ""}
}

func historyRootLocked() string {
	if historyState.root == "" {
		historyState.root = defaultHistoryRoot()
	}
	return historyState.root
}

func historyPath(root, dataSourceID string) string {
	safe := strings.Map(func(r rune) rune {
		if r == '/' || r == '\\' || r == 0 || r == ':' {
			return '_'
		}
		return r
	}, dataSourceID)
	if safe == "" || safe == "." || safe == ".." {
		safe = "_"
	}
	return filepath.Join(root, safe+".jsonl")
}

func newHistoryID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func historyEntry(text, source string, sr StatementResult, params []ParamValue, at time.Time) HistoryEntry {
	e := HistoryEntry{ID: newHistoryID(), Text: text, Time: at.Format(time.RFC3339), DurationMs: sr.DurationMs, Source: source}
	if len(e.Text) > historyTextLimit {
		cut := historyTextLimit
		for cut > 0 && !utf8.RuneStart(e.Text[cut]) {
			cut--
		}
		e.Text, e.TextTruncated = e.Text[:cut], true
	}
	switch {
	case sr.Error != nil:
		e.Error = sr.Error.Message
	case sr.RowsAffected != nil:
		n := *sr.RowsAffected
		e.RowCount = &n
	case sr.ResultID != "":
		n := sr.RowsFetched
		e.RowCount = &n
	}
	for _, p := range params {
		if p.Secret {
			e.Parameters = append(e.Parameters, ParamValue{Name: p.Name, Secret: true})
			continue
		}
		e.Parameters = append(e.Parameters, ParamValue{Name: p.Name, Value: p.Value, IsNull: p.IsNull})
	}
	return e
}

func recordHistory(dataSourceID string, entries ...HistoryEntry) {
	if dataSourceID == "" || len(entries) == 0 {
		return
	}
	historyState.mu.Lock()
	defer historyState.mu.Unlock()
	root := historyRootLocked()
	if root == "" || os.MkdirAll(root, 0o700) != nil {
		return
	}
	path := historyPath(root, dataSourceID)
	n, ok := historyState.counts[path]
	if !ok {
		n = len(readHistoryFile(path))
	}
	var buf bytes.Buffer
	for _, e := range entries {
		b, err := json.Marshal(e)
		if err != nil {
			continue
		}
		buf.Write(b)
		buf.WriteByte('\n')
		n++
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return
	}
	_ = f.Chmod(0o600)
	_, werr := f.Write(buf.Bytes())
	cerr := f.Close()
	if werr != nil || cerr != nil {
		delete(historyState.counts, path)
		return
	}
	historyState.counts[path] = n
	if n > historyCap+historySlack {
		compactHistoryLocked(path, nil)
	}
}

func readHistoryFile(path string) []HistoryEntry {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []HistoryEntry
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), historyTextLimit*8)
	for sc.Scan() {
		var e HistoryEntry
		if json.Unmarshal(sc.Bytes(), &e) == nil && e.ID != "" {
			out = append(out, e)
		}
	}
	return out
}

func compactHistoryLocked(path string, drop func(HistoryEntry) bool) {
	all := readHistoryFile(path)
	kept := make([]HistoryEntry, 0, min(len(all), historyCap))
	for _, e := range all {
		if drop == nil || !drop(e) {
			kept = append(kept, e)
		}
	}
	if len(kept) > historyCap {
		kept = kept[len(kept)-historyCap:]
	}
	var buf bytes.Buffer
	for _, e := range kept {
		b, err := json.Marshal(e)
		if err == nil {
			buf.Write(b)
			buf.WriteByte('\n')
		}
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".history-*")
	if err != nil {
		delete(historyState.counts, path)
		return
	}
	_ = tmp.Chmod(0o600)
	_, werr := tmp.Write(buf.Bytes())
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmp.Name(), path) != nil {
		_ = os.Remove(tmp.Name())
		delete(historyState.counts, path)
		return
	}
	historyState.counts[path] = len(kept)
}

func History(req HistoryRequest) HistoryResult {
	out := HistoryResult{Entries: []HistoryEntry{}}
	if req.DataSourceID == "" {
		out.Error = newError("internal", "GoLens needs a data source to show its query history.")
		return out
	}
	historyState.mu.Lock()
	defer historyState.mu.Unlock()
	root := historyRootLocked()
	if root == "" {
		return out
	}
	path := historyPath(root, req.DataSourceID)
	switch {
	case req.Clear:
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			out.Error = newError("internal", "GoLens could not clear the query history.")
		}
		historyState.counts[path] = 0
		return out
	case req.Delete != "":
		if _, err := os.Stat(path); err == nil {
			compactHistoryLocked(path, func(e HistoryEntry) bool { return e.ID == req.Delete })
		}
	}
	all := readHistoryFile(path)
	if len(all) > historyCap {
		all = all[len(all)-historyCap:]
	}
	limit := req.Limit
	if limit <= 0 {
		limit = historyDefaultN
	}
	query := strings.ToLower(strings.TrimSpace(req.Query))
	for i := len(all) - 1; i >= 0 && len(out.Entries) < limit; i-- {
		if query != "" && !strings.Contains(strings.ToLower(all[i].Text), query) {
			continue
		}
		out.Entries = append(out.Entries, all[i])
	}
	return out
}
