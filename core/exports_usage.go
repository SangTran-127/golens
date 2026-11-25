package main

import "C"

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"golens/core/bridge"
	"golens/core/lsp"
	"golens/core/usageindex"
	"golens/core/vmexec"
)

var usageIndex = newUsageIndexes(func(msg string) { bridge.Debug(msg) })

func init() {
	lsp.OnServerStarted = func(root string, paths *lsp.URITranslator) {
		usageIndex.Start(root, usageIndexOptions(paths), paths == nil)
	}
}

// Ownership: path is copied; returns a C.malloc'd JSON {state, reason?, counts?: [{line, col, count, impls?: [{file, line, col, endCol}]}]}
//
//export UsageCounts
func UsageCounts(cPath *C.char) *C.char {
	b, _ := json.Marshal(usageIndex.Query(C.GoString(cPath)))
	return C.CString(string(b))
}

// Ownership: no pointers involved; 0 drops the usage index, 1 builds it for the open workspace.
//
//export SetUsageIndexEnabled
func SetUsageIndexEnabled(enabled C.int) {
	usageIndex.SetEnabled(enabled != 0)
}

func usageIndexOptions(paths *lsp.URITranslator) usageindex.Options {
	opts := usageindex.Options{Overlay: lsp.OpenDocumentContent}
	if paths == nil {
		opts.RunGo = runHostGo
	} else {
		opts.RunGo = func(ctx context.Context, dir string, args ...string) ([]byte, error) {
			return runGuestGo(ctx, paths, dir, args)
		}
	}
	return opts
}

func runHostGo(ctx context.Context, dir string, args ...string) ([]byte, error) {
	if len(args) > 0 && args[0] == "list" {
		tmp, err := os.MkdirTemp("", "golens-usage-overlay-")
		if err != nil {
			return nil, err
		}
		defer os.RemoveAll(tmp)
		overlay, err := writeListOverlay(tmp, lsp.OpenDocumentPaths(), lsp.OpenDocumentContent)
		if err != nil {
			return nil, err
		}
		if overlay != "" {
			args = append([]string{"list", "-overlay=" + overlay}, args[1:]...)
		}
	}
	cmd := exec.CommandContext(ctx, "go", args...)
	cmd.Dir = dir
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	return out, usageindex.Retryable(usageindex.CommandError(err, stderr.Bytes()))
}

func runGuestGo(ctx context.Context, paths *lsp.URITranslator, dir string, args []string) ([]byte, error) {
	if filepath.Clean(dir) != paths.HostWorkspaceRoot {
		return nil, fmt.Errorf("usage index: %s is not the workspace root %s", dir, paths.HostWorkspaceRoot)
	}
	cmd := vmexec.CommandContext(ctx, "go", args...)
	cmd.Dir = paths.GuestWorkspaceRoot
	cmd.Env = vmexec.DefaultVMEnv("arm64", nil)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, usageindex.Retryable(usageindex.CommandError(err, stderr.Bytes()))
	}
	if args[0] != "list" {
		return out, nil
	}
	return mapGuestListOutput(paths, out)
}

func writeListOverlay(dir string, paths []string, content func(string) ([]byte, bool)) (string, error) {
	replace := map[string]string{}
	for _, p := range paths {
		if filepath.Ext(p) != ".go" {
			continue
		}
		buf, ok := content(p)
		if !ok {
			continue
		}
		if disk, err := os.ReadFile(p); err == nil && bytes.Equal(disk, buf) {
			continue
		}
		f := filepath.Join(dir, strconv.Itoa(len(replace))+".go")
		if err := os.WriteFile(f, buf, 0o600); err != nil {
			return "", err
		}
		replace[p] = f
	}
	if len(replace) == 0 {
		return "", nil
	}
	b, err := json.Marshal(map[string]map[string]string{"Replace": replace})
	if err != nil {
		return "", err
	}
	file := filepath.Join(dir, "overlay.json")
	return file, os.WriteFile(file, b, 0o600)
}

func mapGuestListOutput(paths *lsp.URITranslator, out []byte) ([]byte, error) {
	out = paths.RewriteGuestToHost(out)
	roots := [][2]string{
		{paths.HostWorkspaceRoot, paths.GuestWorkspaceRoot},
		{paths.HostModCache, paths.GuestModCache},
		{paths.HostGoroot, paths.GuestGoroot},
	}
	checked := map[string]bool{}
	dec := json.NewDecoder(bytes.NewReader(out))
	for {
		var p struct{ Dir string }
		if err := dec.Decode(&p); errors.Is(err, io.EOF) {
			return out, nil
		} else if err != nil {
			return nil, fmt.Errorf("usage index: decode go list output: %w", err)
		}
		if p.Dir == "" {
			continue
		}
		i := slices.IndexFunc(roots, func(r [2]string) bool {
			return r[0] != "" && (p.Dir == r[0] || strings.HasPrefix(p.Dir, r[0]+"/"))
		})
		if i < 0 {
			return nil, fmt.Errorf("usage index: go list reports %s, which has no host counterpart", p.Dir)
		}
		if host := roots[i][0]; !checked[host] {
			if _, err := os.ReadDir(host); err != nil {
				return nil, fmt.Errorf("usage index: guest root %s maps to %s, which the app cannot read: %w", roots[i][1], host, err)
			}
			checked[host] = true
		}
	}
}
