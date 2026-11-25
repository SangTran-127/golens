package safety

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"golens/core/bridge"
	"golens/core/vmexec"
)

const (
	liveLintTimeout       = 60 * time.Second
	liveLintSource        = "golangci-lint"
	liveLintMaxIssues     = 500
	liveLintMaxMessage    = 2000
	liveLintBinaryRecheck = 30 * time.Second
)

var golangciConfigNames = []string{".golangci.yml", ".golangci.yaml", ".golangci.toml", ".golangci.json"}

type LiveLintDiagnostic struct {
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	EndLine  int    `json:"endLine"`
	EndCol   int    `json:"endCol"`
	Severity int    `json:"severity"`
	Message  string `json:"message"`
	Source   string `json:"source"`
	Code     string `json:"code"`
}

type LiveLintResult struct {
	Status string                          `json:"status"`
	Error  string                          `json:"error,omitempty"`
	Files  map[string][]LiveLintDiagnostic `json:"files"`
}

var (
	lintBinMu      sync.Mutex
	lintBinPath    string
	lintBinChecked time.Time
	lintVersions   = map[string]int{}
	lintGoBinDir   string
	lintGoBinOnce  sync.Once
)

func RunPackageLint(workspaceRoot, packageDir string) string {
	res := runPackageLint(context.Background(), workspaceRoot, packageDir, liveLintTimeout)
	data, err := json.Marshal(res)
	if err != nil {
		return `{"status":"error","error":"could not encode golangci-lint results","files":{}}`
	}
	return string(data)
}

func unavailableLint() LiveLintResult {
	return LiveLintResult{Status: "unavailable", Files: map[string][]LiveLintDiagnostic{}}
}

func runPackageLint(ctx context.Context, workspaceRoot, packageDir string, timeout time.Duration) LiveLintResult {
	if packageDir == "" {
		return unavailableLint()
	}
	packageDir = filepath.Clean(packageDir)
	if workspaceRoot != "" {
		workspaceRoot = filepath.Clean(workspaceRoot)
	}
	moduleRoot := findModuleRoot(packageDir)
	if moduleRoot == "" {
		return unavailableLint()
	}
	config := FindGolangCIConfig(packageDir, workspaceRoot)
	if config == "" {
		return unavailableLint()
	}
	bin := ResolveGolangCILint()
	if bin == "" {
		return unavailableLint()
	}
	files := packageGoFiles(packageDir)
	if len(files) == 0 {
		return unavailableLint()
	}
	if msg := golangciToolchainMismatch(bin); msg != "" {
		return LiveLintResult{Status: "error", Error: msg, Files: map[string][]LiveLintDiagnostic{}}
	}

	target := "."
	if rel, err := filepath.Rel(moduleRoot, packageDir); err == nil && rel != "." {
		target = "./" + filepath.ToSlash(rel)
	}
	args := []string{"run", "--issues-exit-code=0", "--allow-parallel-runners", "--concurrency=2", "--config=" + config}
	if golangciMajorVersion(bin) >= 2 {
		args = append(args, "--output.json.path=stdout", "--show-stats=false")
	} else {
		args = append(args, "--out-format=json")
	}
	args = append(args, target)

	stdout, stderr, err := runLintCommand(ctx, moduleRoot, timeout, bin, args...)
	if errors.Is(err, context.DeadlineExceeded) {
		return LiveLintResult{Status: "error", Error: "timed out after " + timeout.String(), Files: map[string][]LiveLintDiagnostic{}}
	}
	parsed, ok := decodeGolangCILintOutput(stdout)
	if !ok {
		msg := firstMeaningfulLine(stderr)
		if msg == "" {
			msg = firstMeaningfulLine(stdout)
		}
		if msg == "" && err != nil {
			msg = err.Error()
		}
		if msg == "" {
			msg = "no results"
		}
		return LiveLintResult{Status: "error", Error: msg, Files: map[string][]LiveLintDiagnostic{}}
	}

	result := LiveLintResult{Status: "ok", Files: make(map[string][]LiveLintDiagnostic, len(files))}
	for _, f := range files {
		result.Files[f] = []LiveLintDiagnostic{}
	}
	bases := []string{moduleRoot, filepath.Dir(config), workspaceRoot, packageDir}
	lines := map[string][]string{}
	count := 0
	for _, issue := range parsed.Issues {
		if count >= liveLintMaxIssues {
			break
		}
		linter := strings.TrimSpace(issue.FromLinter)
		if linter == "typecheck" || issue.Pos.Filename == "" {
			continue
		}
		file := resolveLintFile(issue.Pos.Filename, bases)
		if _, inPackage := result.Files[file]; !inPackage {
			continue
		}
		src, cached := lines[file]
		if !cached {
			src = readLines(file)
			lines[file] = src
		}
		d := liveLintDiagnostic(issue, src)
		if linter == "" {
			linter = "lint"
		}
		d.Code = linter
		result.Files[file] = append(result.Files[file], d)
		count++
	}
	return result
}

func liveLintDiagnostic(issue golangciLintIssue, src []string) LiveLintDiagnostic {
	line := max(issue.Pos.Line, 1) - 1
	text := ""
	if line < len(src) {
		text = src[line]
	}
	startByte, endByte := lintRange(text, issue.Pos.Column)
	severity := 2
	if strings.EqualFold(strings.TrimSpace(issue.Severity), "error") {
		severity = 1
	}
	msg := strings.TrimSpace(issue.Text)
	if len(msg) > liveLintMaxMessage {
		msg = msg[:liveLintMaxMessage]
	}
	return LiveLintDiagnostic{
		Line:     line,
		Col:      utf16Len(text[:startByte]),
		EndLine:  line,
		EndCol:   utf16Len(text[:endByte]),
		Severity: severity,
		Message:  msg,
		Source:   liveLintSource,
	}
}

func lintRange(text string, column int) (int, int) {
	if text == "" {
		return 0, 0
	}
	if column <= 0 || column > len(text) {
		start := len(text) - len(strings.TrimLeftFunc(text, unicode.IsSpace))
		end := len(strings.TrimRightFunc(text, unicode.IsSpace))
		if end <= start {
			return 0, len(text)
		}
		return start, end
	}
	start := column - 1
	for !utf8.RuneStart(text[start]) && start > 0 {
		start--
	}
	end := start
	for end < len(text) {
		r, size := utf8.DecodeRuneInString(text[end:])
		if !isLintTokenRune(r) {
			break
		}
		end += size
	}
	if end > start {
		return start, end
	}
	begin := start
	for begin > 0 {
		r, size := utf8.DecodeLastRuneInString(text[:begin])
		if !isLintTokenRune(r) {
			break
		}
		begin -= size
	}
	if begin < start {
		return begin, start
	}
	_, size := utf8.DecodeRuneInString(text[start:])
	return start, start + size
}

func isLintTokenRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '.'
}

func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

func readLines(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		out = append(out, strings.TrimSuffix(sc.Text(), "\r"))
	}
	return out
}

func resolveLintFile(name string, bases []string) string {
	if strings.HasPrefix(name, "/workspaces/") && len(bases) > 0 && bases[0] != "" {
		name = vmexec.GuestToHostPath(bases[0], name)
	}
	if filepath.IsAbs(name) {
		return filepath.Clean(name)
	}
	for _, base := range bases {
		if base == "" {
			continue
		}
		candidate := filepath.Join(base, name)
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return filepath.Join(bases[0], name)
}

func packageGoFiles(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".go") {
			files = append(files, filepath.Join(dir, e.Name()))
		}
	}
	return files
}

func findModuleRoot(dir string) string {
	for {
		if st, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil && !st.IsDir() {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

func FindGolangCIConfig(dir, workspaceRoot string) string {
	dir = filepath.Clean(dir)
	for {
		for _, name := range golangciConfigNames {
			candidate := filepath.Join(dir, name)
			if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
				return candidate
			}
		}
		if workspaceRoot == "" || dir == workspaceRoot {
			return ""
		}
		parent := filepath.Dir(dir)
		if parent == dir || !strings.HasPrefix(parent, workspaceRoot) {
			return ""
		}
		dir = parent
	}
}

func ResolveGolangCILint() string {
	lintBinMu.Lock()
	defer lintBinMu.Unlock()
	if lintBinPath != "" {
		if isExecutable(lintBinPath) {
			return lintBinPath
		}
		lintBinPath = ""
	}
	if !lintBinChecked.IsZero() && time.Since(lintBinChecked) < liveLintBinaryRecheck {
		return ""
	}
	lintBinChecked = time.Now()
	if p, err := exec.LookPath("golangci-lint"); err == nil && p != "" {
		lintBinPath = p
		return p
	}
	for _, dir := range golangciInstallDirs() {
		candidate := filepath.Join(dir, "golangci-lint")
		if isExecutable(candidate) {
			lintBinPath = candidate
			return candidate
		}
	}
	return ""
}

func golangciInstallDirs() []string {
	var dirs []string
	if gobin := os.Getenv("GOBIN"); gobin != "" {
		dirs = append(dirs, gobin)
	}
	for _, p := range filepath.SplitList(os.Getenv("GOPATH")) {
		if p != "" {
			dirs = append(dirs, filepath.Join(p, "bin"))
		}
	}
	if goBin := goToolPath(); goBin != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		var out []byte
		var err error
		if !bridge.IsHostMode() && bridge.GetVsockDialer() != nil {
			cmd := vmexec.CommandContext(ctx, "go", "env", "GOBIN", "GOPATH")
			out, err = cmd.CombinedOutput()
		} else {
			err = bridge.ErrDialerUnset
		}
		if err != nil && bridge.CanFallbackToHost(err) {
			hostCmd := exec.CommandContext(ctx, goBin, "env", "GOBIN", "GOPATH")
			out, err = hostCmd.CombinedOutput()
		}
		if err == nil {
			parts := strings.Split(strings.TrimSpace(string(out)), "\n")
			if len(parts) > 0 && strings.TrimSpace(parts[0]) != "" {
				dirs = append(dirs, strings.TrimSpace(parts[0]))
			}
			if len(parts) > 1 {
				for _, p := range filepath.SplitList(strings.TrimSpace(parts[1])) {
					if p != "" {
						dirs = append(dirs, filepath.Join(p, "bin"))
					}
				}
			}
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		dirs = append(dirs, filepath.Join(home, "go", "bin"))
	}
	return append(dirs, "/opt/homebrew/bin", "/usr/local/bin")
}

func goToolPath() string {
	if p, err := exec.LookPath("go"); err == nil {
		return p
	}
	for _, p := range []string{"/usr/local/go/bin/go", "/opt/homebrew/bin/go", "/usr/local/bin/go"} {
		if isExecutable(p) {
			return p
		}
	}
	return ""
}

func goBinDir() string {
	lintGoBinOnce.Do(func() {
		if p := goToolPath(); p != "" {
			lintGoBinDir = filepath.Dir(p)
		}
	})
	return lintGoBinDir
}

func isExecutable(path string) bool {
	st, err := os.Stat(path)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}

var golangciVersionPattern = regexp.MustCompile(`version v?(\d+)\.`)

func golangciMajorVersion(bin string) int {
	lintBinMu.Lock()
	if v, ok := lintVersions[bin]; ok {
		lintBinMu.Unlock()
		return v
	}
	lintBinMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := vmexec.CommandContext(ctx, bin, "--version")
	out, err := cmd.CombinedOutput()
	if err != nil && bridge.CanFallbackToHost(err) {
		hostCmd := exec.CommandContext(ctx, bin, "--version")
		out, _ = hostCmd.CombinedOutput()
	}
	major := parseGolangCIMajorVersion(string(out))
	lintBinMu.Lock()
	lintVersions[bin] = major
	lintBinMu.Unlock()
	return major
}

var (
	goMinorPattern       = regexp.MustCompile(`go1\.(\d+)`)
	lintBuiltWith        = map[string]int{}
	toolchainMinorOnce   sync.Once
	toolchainMinorCached int
)

func golangciToolchainMismatch(bin string) string {
	built := golangciBuiltWithMinor(bin)
	toolchain := toolchainGoMinor()
	if built == 0 || toolchain == 0 || built >= toolchain {
		return ""
	}
	return "installed golangci-lint was built with go1." + strconv.Itoa(built) + " and cannot analyze code for go1." +
		strconv.Itoa(toolchain) + "; install a golangci-lint release built with go1." + strconv.Itoa(toolchain) + " or newer"
}

func golangciBuiltWithMinor(bin string) int {
	lintBinMu.Lock()
	if v, ok := lintBuiltWith[bin]; ok {
		lintBinMu.Unlock()
		return v
	}
	lintBinMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := vmexec.CommandContext(ctx, bin, "--version")
	out, err := cmd.CombinedOutput()
	if err != nil && bridge.CanFallbackToHost(err) {
		hostCmd := exec.CommandContext(ctx, bin, "--version")
		out, _ = hostCmd.CombinedOutput()
	}
	minor := parseBuiltWithGoMinor(string(out))
	lintBinMu.Lock()
	lintBuiltWith[bin] = minor
	lintBinMu.Unlock()
	return minor
}

func parseBuiltWithGoMinor(out string) int {
	idx := strings.Index(out, "built with ")
	if idx < 0 {
		return 0
	}
	return parseGoMinor(out[idx:])
}

func parseGoMinor(s string) int {
	m := goMinorPattern.FindStringSubmatch(s)
	if len(m) < 2 {
		return 0
	}
	minor, _ := strconv.Atoi(m[1])
	return minor
}

func toolchainGoMinor() int {
	toolchainMinorOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		cmd := vmexec.CommandContext(ctx, "go", "env", "GOVERSION")
		out, err := cmd.CombinedOutput()
		if err != nil && bridge.CanFallbackToHost(err) {
			goBin := goToolPath()
			if goBin == "" {
				goBin = "go"
			}
			hostCmd := exec.CommandContext(ctx, goBin, "env", "GOVERSION")
			out, err = hostCmd.CombinedOutput()
		}
		if err == nil {
			toolchainMinorCached = parseGoMinor(string(out))
		}
	})
	return toolchainMinorCached
}

func parseGolangCIMajorVersion(out string) int {
	m := golangciVersionPattern.FindStringSubmatch(out)
	if len(m) < 2 {
		return 1
	}
	if major, err := strconv.Atoi(m[1]); err == nil && major > 0 {
		return major
	}
	return 1
}

func runLintCommand(parentCtx context.Context, dir string, timeout time.Duration, bin string, args ...string) ([]byte, []byte, error) {
	ctx, cancel := context.WithTimeout(parentCtx, timeout)
	defer cancel()

	guestDir := vmexec.HostToGuestPath(dir, dir)
	vmCmd := vmexec.CommandContext(ctx, bin, args...)
	vmCmd.Dir = guestDir
	vmCmd.Env = vmexec.DefaultVMEnv("arm64", map[string]string{"GOMEMLIMIT": "1GiB"})

	var vmStdout, vmStderr bytes.Buffer
	vmCmd.Stdout = &vmStdout
	vmCmd.Stderr = &vmStderr
	vmErr := vmCmd.Run()
	if vmErr != nil && bridge.CanFallbackToHost(vmErr) {
		hostBin := bin
		if !filepath.IsAbs(hostBin) {
			if resolved := ResolveGolangCILint(); resolved != "" {
				hostBin = resolved
			}
		}
		hostCmd := exec.CommandContext(ctx, hostBin, args...)
		hostCmd.Dir = dir
		hostCmd.Env = append(os.Environ(), "GOMEMLIMIT=1GiB")
		var hostStdout, hostStderr bytes.Buffer
		hostCmd.Stdout = &hostStdout
		hostCmd.Stderr = &hostStderr
		hostErr := hostCmd.Run()
		if ctx.Err() == context.DeadlineExceeded {
			return hostStdout.Bytes(), hostStderr.Bytes(), context.DeadlineExceeded
		}
		return hostStdout.Bytes(), hostStderr.Bytes(), hostErr
	}
	if ctx.Err() == context.DeadlineExceeded {
		return vmStdout.Bytes(), vmStderr.Bytes(), context.DeadlineExceeded
	}
	return vmStdout.Bytes(), vmStderr.Bytes(), vmErr
}

func firstMeaningfulLine(data []byte) string {
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "level=info") || strings.HasPrefix(line, "level=warning") {
			continue
		}
		line = strings.TrimPrefix(line, "level=error msg=")
		line = strings.TrimPrefix(strings.Trim(line, `"`), "Error: ")
		if len(line) > 300 {
			line = line[:300]
		}
		return line
	}
	return ""
}
