package lsp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

const (
	moduleNotesBudget  = 60 * time.Second
	maxModuleNoteFiles = 16
	maxModuleNotes     = 500
)

type ModuleNote struct {
	Path       string   `json:"path"`
	Version    string   `json:"version"`
	Line       int      `json:"line"`
	Deprecated string   `json:"deprecated,omitempty"`
	Retracted  []string `json:"retracted,omitempty"`
}

var moduleNotesErrorTTL = 30 * time.Second

type moduleNotesEntry struct {
	stamp   string
	json    string
	expires time.Time
}

type moduleNotesCall struct {
	stamp string
	done  chan struct{}
	json  string
}

var moduleNotesCache = struct {
	sync.Mutex
	entries  map[string]moduleNotesEntry
	inflight map[string]*moduleNotesCall
}{entries: map[string]moduleNotesEntry{}, inflight: map[string]*moduleNotesCall{}}

var runGoListUpdates = func(dir string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), moduleNotesBudget)
	defer cancel()
	guestDir := vmexec.HostToGuestPath(dir, dir)
	cmd := vmexec.CommandContext(ctx, "go", "list", "-m", "-u", "-e", "-json", "all")
	cmd.Dir = guestDir
	cmd.Env = vmexec.DefaultVMEnv("arm64", map[string]string{"GOFLAGS": "-mod=readonly"})
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil && bridge.CanFallbackToHost(err) {
		stdout.Reset()
		stderr.Reset()
		hostCmd := exec.CommandContext(ctx, "go", "list", "-m", "-u", "-e", "-json", "all")
		hostCmd.Dir = dir
		hostCmd.Env = append(os.Environ(), "GOFLAGS=-mod=readonly")
		hostCmd.Stdout = &stdout
		hostCmd.Stderr = &stderr
		err = hostCmd.Run()
	}
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return stdout.Bytes(), errors.New(msg)
	}
	return stdout.Bytes(), nil
}

func requireLines(gomod []byte) map[string]int {
	lines := map[string]int{}
	inBlock := false
	for i, raw := range strings.Split(string(gomod), "\n") {
		line := strings.TrimSpace(raw)
		if j := strings.Index(line, "//"); j >= 0 {
			line = strings.TrimSpace(line[:j])
		}
		fields := strings.Fields(line)
		switch {
		case len(fields) == 0:
			continue
		case inBlock && fields[0] == ")":
			inBlock = false
		case fields[0] == "require" && len(fields) >= 2 && fields[1] == "(":
			inBlock = true
		case fields[0] == "require" && len(fields) >= 3:
			lines[fields[1]] = i + 1
		case inBlock && len(fields) >= 2:
			lines[fields[0]] = i + 1
		}
	}
	return lines
}

func firstModuleError(stream []byte) string {
	dec := json.NewDecoder(bytes.NewReader(stream))
	for {
		var m struct {
			Error *struct{ Err string }
		}
		if dec.Decode(&m) != nil {
			return ""
		}
		if m.Error != nil && m.Error.Err != "" {
			return m.Error.Err
		}
	}
}

func parseModuleNotes(stream, gomod []byte) []ModuleNote {
	lines := requireLines(gomod)
	notes := make([]ModuleNote, 0)
	dec := json.NewDecoder(bytes.NewReader(stream))
	for len(notes) < maxModuleNotes {
		var m struct {
			Path       string
			Version    string
			Main       bool
			Deprecated string
			Retracted  []string
		}
		if dec.Decode(&m) != nil {
			break
		}
		line, ok := lines[m.Path]
		if m.Main || !ok || (m.Deprecated == "" && len(m.Retracted) == 0) {
			continue
		}
		notes = append(notes, ModuleNote{Path: m.Path, Version: m.Version, Line: line, Deprecated: m.Deprecated, Retracted: m.Retracted})
	}
	return notes
}

func ModuleNotes(gomodPath string) string {
	fi, err := os.Stat(gomodPath)
	if err != nil {
		return `{"notes":[],"error":"go.mod not found"}`
	}
	stamp := fi.ModTime().String()
	moduleNotesCache.Lock()
	if e, ok := moduleNotesCache.entries[gomodPath]; ok && e.stamp == stamp && (e.expires.IsZero() || time.Now().Before(e.expires)) {
		moduleNotesCache.Unlock()
		return e.json
	}
	if c, ok := moduleNotesCache.inflight[gomodPath]; ok && c.stamp == stamp {
		moduleNotesCache.Unlock()
		<-c.done
		return c.json
	}
	c := &moduleNotesCall{stamp: stamp, done: make(chan struct{})}
	moduleNotesCache.inflight[gomodPath] = c
	moduleNotesCache.Unlock()

	result, failed := computeModuleNotes(gomodPath)
	c.json = result

	moduleNotesCache.Lock()
	if moduleNotesCache.inflight[gomodPath] == c {
		delete(moduleNotesCache.inflight, gomodPath)
	}
	entry := moduleNotesEntry{stamp: stamp, json: result}
	if failed {
		entry.expires = time.Now().Add(moduleNotesErrorTTL)
	}
	if !failed || moduleNotesErrorTTL > 0 {
		if _, exists := moduleNotesCache.entries[gomodPath]; !exists && len(moduleNotesCache.entries) >= maxModuleNoteFiles {
			clear(moduleNotesCache.entries)
		}
		moduleNotesCache.entries[gomodPath] = entry
	}
	moduleNotesCache.Unlock()
	close(c.done)
	return result
}

func computeModuleNotes(gomodPath string) (string, bool) {
	gomod, err := os.ReadFile(gomodPath)
	var out []byte
	if err == nil {
		out, err = runGoListUpdates(filepath.Dir(gomodPath))
	}
	if err != nil {
		notes := make([]ModuleNote, 0)
		if len(out) > 0 {
			notes = parseModuleNotes(out, gomod)
		}
		b, _ := json.Marshal(map[string]any{"notes": notes, "error": err.Error()})
		return string(b), true
	}
	if msg := firstModuleError(out); msg != "" {
		b, _ := json.Marshal(map[string]any{"notes": parseModuleNotes(out, gomod), "error": msg})
		return string(b), true
	}
	b, _ := json.Marshal(map[string]any{"notes": parseModuleNotes(out, gomod)})
	return string(b), false
}
