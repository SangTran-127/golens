package docker

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const cliWaitDelay = time.Second

func searchDirs() []string {
	var dirs []string
	seen := map[string]bool{}
	add := func(d string) {
		if d != "" && !seen[d] {
			seen[d] = true
			dirs = append(dirs, d)
		}
	}
	for _, d := range filepath.SplitList(os.Getenv("PATH")) {
		add(d)
	}
	add("/opt/homebrew/bin")
	add("/usr/local/bin")
	if home, err := os.UserHomeDir(); err == nil {
		add(filepath.Join(home, ".orbstack", "bin"))
	}
	add("/Applications/Docker.app/Contents/Resources/bin")
	return dirs
}

func isExecutable(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular() && st.Mode()&0o111 != 0
}

func LookPath(name string) string {
	if name == "" {
		return ""
	}
	if strings.Contains(name, "/") {
		if isExecutable(name) {
			return name
		}
		return ""
	}
	for _, d := range searchDirs() {
		if p := filepath.Join(d, name); isExecutable(p) {
			return p
		}
	}
	return ""
}

func Env() []string {
	env := os.Environ()
	path := "PATH=" + strings.Join(searchDirs(), string(os.PathListSeparator))
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			env[i] = path
			return cliContextEnv(env)
		}
	}
	return cliContextEnv(append(env, path))
}

func runCLI(timeout time.Duration, dir, stdin, bin string, args ...string) (string, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.WaitDelay = cliWaitDelay
	cmd.Env = Env()
	if st, err := os.Stat(dir); dir != "" && err == nil && st.IsDir() {
		cmd.Dir = dir
	}
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil && ctx.Err() == context.DeadlineExceeded {
		err = fmt.Errorf("%s %s timed out after %s", filepath.Base(bin), strings.Join(args, " "), timeout)
		if strings.TrimSpace(stderr.String()) == "" {
			stderr.WriteString(err.Error())
		}
	}
	return stdout.String(), stderr.String(), err
}

func BuildSummaryHook(bin string, argv []string) func() []string {
	tag := buildTag(argv)
	if tag == "" {
		return nil
	}
	start := time.Now()
	return func() []string {
		elapsed := time.Since(start).Round(100 * time.Millisecond)
		out, _, err := runCLI(5*time.Second, "", "", bin, "image", "inspect", "-f", "{{.Size}}", tag)
		if size, perr := strconv.ParseInt(strings.TrimSpace(out), 10, 64); err == nil && perr == nil {
			return []string{fmt.Sprintf("Built %s · %s in %s", tag, humanSize(size), elapsed)}
		}
		return []string{fmt.Sprintf("Built %s in %s", tag, elapsed)}
	}
}

func buildTag(argv []string) string {
	if len(argv) < 2 || filepath.Base(argv[0]) != "docker" {
		return ""
	}
	args := argv[1:]
	switch {
	case args[0] == "build":
		args = args[1:]
	case len(args) > 1 && (args[0] == "buildx" || args[0] == "image") && args[1] == "build":
		args = args[2:]
	default:
		return ""
	}
	for i, a := range args {
		switch {
		case (a == "-t" || a == "--tag") && i+1 < len(args):
			return args[i+1]
		case strings.HasPrefix(a, "-t="):
			return a[3:]
		case strings.HasPrefix(a, "--tag="):
			return a[6:]
		}
	}
	return ""
}

func humanSize(n int64) string {
	const unit = 1000
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	v := float64(n)
	for _, u := range []string{"kB", "MB", "GB", "TB"} {
		v /= unit
		if v < unit {
			return fmt.Sprintf("%.1f %s", v, u)
		}
	}
	return fmt.Sprintf("%.1f PB", v/unit)
}
