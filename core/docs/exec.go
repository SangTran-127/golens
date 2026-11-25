package docs

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func hasVendorModules(base string) bool {
	if base == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(base, "vendor", "modules.txt"))
	return err == nil
}

func Environ(opts Options) []string {
	env := os.Environ()
	flags := sanitizeGoFlags(lookupEnv(append(env, opts.Env...), "GOFLAGS"))
	env = append(env, "GOPROXY=off", "GOFLAGS="+flags)
	if opts.Target.GOOS != "" {
		env = append(env, "GOOS="+opts.Target.GOOS)
	}
	if opts.Target.GOARCH != "" {
		env = append(env, "GOARCH="+opts.Target.GOARCH)
	}
	return append(env, opts.Env...)
}

func sanitizeGoFlags(flags string) string {
	var keep []string
	for _, f := range strings.Fields(flags) {
		if f == "-mod=mod" || strings.HasPrefix(f, "-tags=") || strings.HasPrefix(f, "-overlay=") {
			continue
		}
		keep = append(keep, f)
	}
	return strings.Join(keep, " ")
}

func lookupEnv(env []string, key string) string {
	val := ""
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok && k == key {
			val = v
		}
	}
	return val
}

func runGo(ctx context.Context, dir string, opts Options, args []string) ([]byte, string, error) {
	cmd := exec.CommandContext(ctx, "go", args...)
	cmd.Dir = dir
	cmd.Env = Environ(opts)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil && cmd.Process.Pid > 0 {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
	cmd.WaitDelay = 500 * time.Millisecond
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	return out, strings.TrimSpace(stderr.String()), err
}

func withTimeout(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if d <= 0 {
		d = 60 * time.Second
	}
	return context.WithTimeout(ctx, d)
}

func lookupOverlay(overlay map[string]string, path string) (string, bool) {
	if len(overlay) == 0 {
		return "", false
	}
	if content, ok := overlay[path]; ok {
		return content, true
	}
	canon := canonicalRoot(path)
	if canon != "" {
		if content, ok := overlay[canon]; ok {
			return content, true
		}
		for k, v := range overlay {
			if canonicalRoot(k) == canon {
				return v, true
			}
		}
	}
	return "", false
}

func writeOverlay(files map[string]string) (string, func(), error) {
	if len(files) == 0 {
		return "", func() {}, nil
	}
	dir, err := os.MkdirTemp("", "golens-docs-overlay-")
	if err != nil {
		return "", func() {}, err
	}
	cleanup := func() { _ = os.RemoveAll(dir) }
	replace := map[string]string{}
	i := 0
	for path, content := range files {
		tmp := filepath.Join(dir, fmt.Sprintf("%d.go", i))
		i++
		if err := os.WriteFile(tmp, []byte(content), 0o600); err != nil {
			cleanup()
			return "", func() {}, err
		}
		key := canonicalRoot(path)
		if key == "" {
			key = filepath.Clean(path)
		}
		replace[key] = tmp
	}
	data, err := json.Marshal(map[string]any{"Replace": replace})
	if err != nil {
		cleanup()
		return "", func() {}, err
	}
	file := filepath.Join(dir, "overlay.json")
	if err := os.WriteFile(file, data, 0o600); err != nil {
		cleanup()
		return "", func() {}, err
	}
	return file, cleanup, nil
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}
