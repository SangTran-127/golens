package remote

import (
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const (
	localTar = "COPYFILE_DISABLE=1 /usr/bin/tar --no-mac-metadata --no-xattrs --format=gnutar"
	appName  = "app"
	pidName  = "golens.pid"
	relayBin = "golens-relay"
)

type Plan struct {
	Target     Target
	Probe      Probe
	Name       string
	Project    string
	ModuleRoot string
	RunDir     string
	BuildFlags []string
	Args       []string
	Env        map[string]string
	LocalTmp   string
	Debug      bool
	InTarget   bool
	DebugAddr  string
	RelayDir   string
	TestPkg    *TestPackage
	TestArgs   []string
}

type TestPackage struct {
	ImportPath string
	Dir        string
}

var envKeyRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

func CgoEnabled(env map[string]string) bool {
	return strings.TrimSpace(env["CGO_ENABLED"]) == "1"
}

func (p Plan) Base() string {
	return p.Probe.Base
}

func (p Plan) Stage() string {
	return path.Join(p.Probe.Base, Slug(p.Project), Slug(p.Name))
}

func (p Plan) RunStage() string  { return path.Join(p.Stage(), "run") }
func (p Plan) TestStage() string { return path.Join(p.Stage(), "test") }
func (p Plan) SrcStage() string  { return path.Join(p.Stage(), "src") }
func (p Plan) BinDir() string    { return path.Join(p.Probe.Base, "bin") }

func (p Plan) PkgRel() string {
	return relSlash(p.ModuleRoot, p.RunDir)
}

func realPath(p string) string {
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func relSlash(root, dir string) string {
	rel, err := filepath.Rel(realPath(root), realPath(dir))
	if err != nil || strings.HasPrefix(rel, "..") {
		return "."
	}
	return filepath.ToSlash(rel)
}

func (p Plan) platform() string {
	if p.Probe.GOARM != "" {
		return "linux/" + p.Probe.GOARCH + "v" + p.Probe.GOARM
	}
	return "linux/" + p.Probe.GOARCH
}

func (p Plan) crossEnv() []string {
	env := []string{"CGO_ENABLED=0", "GOOS=linux", "GOARCH=" + p.Probe.GOARCH}
	if p.Probe.GOARM != "" {
		env = append(env, "GOARM="+p.Probe.GOARM)
	}
	return append(env, p.goEnv()...)
}

func (p Plan) goEnv() []string {
	var out []string
	for k, v := range p.Env {
		if !envKeyRe.MatchString(k) {
			continue
		}
		switch k {
		case "GOOS", "GOARCH", "GOARM", "CGO_ENABLED":
			continue
		}
		if strings.HasPrefix(k, "GO") || strings.HasPrefix(k, "CGO_") {
			out = append(out, k+"="+v)
		}
	}
	sort.Strings(out)
	return out
}

func (p Plan) exports() string {
	keys := make([]string, 0, len(p.Env))
	for k := range p.Env {
		if envKeyRe.MatchString(k) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString("export " + k + "=" + Quote(p.Env[k]) + "; ")
	}
	return b.String()
}

func (p Plan) buildFlags() []string {
	flags := append([]string(nil), p.BuildFlags...)
	if p.Debug {
		flags = append(flags, "-gcflags=all=-N -l")
	}
	return flags
}

func (p Plan) cdWorkDir(fallback string) string {
	wd := strings.TrimSpace(p.Target.WorkDir)
	if wd == "" {
		if fallback == "" {
			return ""
		}
		return "cd " + Quote(fallback) + " || exit 1; "
	}
	if wd == "~" {
		return `cd "$HOME" || exit 1; `
	}
	if strings.HasPrefix(wd, "~/") {
		return `cd "$HOME"/` + Quote(wd[2:]) + " || exit 1; "
	}
	return "cd " + Quote(wd) + " || exit 1; "
}

func say(line string) string {
	return "printf '%s\\n' " + Quote(line) + "\n"
}

func (p Plan) tr() Transport {
	return NewTransport(p.Target)
}

func (p Plan) remote(script string) string {
	return QuoteArgv(p.tr().Shell(script))
}

func extract(dir string) string {
	return "mkdir -p " + Quote(dir) + " && tar -x -m -f - -C " + Quote(dir)
}

func scriptHeader() string {
	return "set -o pipefail\n"
}

func (p Plan) syncSources() string {
	src := p.SrcStage()
	var b strings.Builder
	b.WriteString(say("Copying sources to " + p.Target.Label() + "…"))
	b.WriteString("cd " + Quote(p.ModuleRoot) + " || exit 1\n")
	b.WriteString(localTar + " --exclude .git --exclude .golens --exclude node_modules --exclude .build -cf - . | ")
	b.WriteString(p.remote("rm -rf " + Quote(src) + " && " + extract(src)))
	b.WriteString(" || exit 1\n")
	return b.String()
}

func (p Plan) buildProgram() string {
	var b strings.Builder
	if p.InTarget {
		b.WriteString(p.syncSources())
		b.WriteString(say("Building " + p.Name + " on " + p.Target.Label() + "…"))
		argv := append([]string{"go", "build"}, p.buildFlags()...)
		if p.TestPkg != nil {
			argv = append([]string{"go", "test", "-c"}, p.buildFlags()...)
		}
		argv = append(argv, "-o", path.Join(p.RunStage(), appName), ".")
		script := remotePathPrefix() + "mkdir -p " + Quote(p.RunStage()) + " && cd " + Quote(path.Join(p.SrcStage(), p.PkgRel())) + " || exit 1; " + p.exports() + "export CGO_ENABLED=1; exec " + QuoteArgv(argv)
		b.WriteString(p.remote(script) + " || exit 1\n")
		return b.String()
	}
	b.WriteString(say("Building " + p.Name + " for " + p.platform() + "…"))
	b.WriteString("cd " + Quote(p.RunDir) + " || exit 1\n")
	argv := append([]string{"env"}, p.crossEnv()...)
	if p.TestPkg != nil {
		argv = append(argv, "go", "test", "-c")
	} else {
		argv = append(argv, "go", "build")
	}
	argv = append(argv, p.buildFlags()...)
	argv = append(argv, "-o", path.Join(p.LocalTmp, appName), ".")
	b.WriteString(QuoteArgv(argv) + " || exit 1\n")
	if p.TestPkg != nil {
		b.WriteString(p.syncSources())
	}
	b.WriteString(say("Copying " + p.Name + " to " + p.Target.Label() + "…"))
	b.WriteString(localTar + " -C " + Quote(p.LocalTmp) + " -cf - " + appName + " | " + p.remote(extract(p.RunStage())) + " || exit 1\n")
	return b.String()
}

func (p Plan) copyRelay() string {
	if p.RelayDir == "" {
		return ""
	}
	return localTar + " -C " + Quote(p.RelayDir) + " -cf - " + relayBin + " | " + p.remote(extract(p.BinDir())) + " || exit 1\n"
}

func (p Plan) launch(pidDir, command string) string {
	return remotePathPrefix() + StopScript(pidDir) + "; mkdir -p " + Quote(pidDir) + "; echo $$ > " + Quote(path.Join(pidDir, pidName)) + "; " + command
}

func (p Plan) RunScript() string {
	var b strings.Builder
	b.WriteString(scriptHeader())
	b.WriteString(p.buildProgram())
	bin := path.Join(p.RunStage(), appName)
	fallback := ""
	args := p.Args
	if p.TestPkg != nil {
		fallback = path.Join(p.SrcStage(), p.PkgRel())
		args = p.TestArgs
	} else if p.InTarget && p.Target.Kind == KindSSH {
		fallback = path.Join(p.SrcStage(), p.PkgRel())
	}
	if p.Debug {
		b.WriteString(p.copyRelay())
		b.WriteString(say("Starting Delve on " + p.Target.Label() + "…"))
		argv := append([]string{p.Probe.Dlv, "exec", "--headless", "--listen=" + p.DebugAddr, "--accept-multiclient", "--api-version=2", "--check-go-version=false", bin, "--"}, args...)
		b.WriteString("exec " + p.remote(p.launch(p.RunStage(), p.cdWorkDir(fallback)+p.exports()+"exec "+QuoteArgv(argv))) + "\n")
		return b.String()
	}
	b.WriteString(say("Running " + p.Name + " on " + p.Target.Label() + "…"))
	argv := append([]string{bin}, args...)
	b.WriteString("exec " + p.remote(p.launch(p.RunStage(), p.cdWorkDir(fallback)+p.exports()+"exec "+QuoteArgv(argv))) + "\n")
	return b.String()
}

func StopScript(stage string) string {
	pid := Quote(path.Join(stage, pidName))
	return `P=` + pid + `; if [ -f "$P" ]; then p=$(cat "$P"); kill -TERM "$p" 2>/dev/null; i=0; ` +
		`while kill -0 "$p" 2>/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; ` +
		`kill -KILL "$p" 2>/dev/null; rm -f "$P"; fi; ` +
		`for d in /proc/[0-9]*; do n=${d#/proc/}; [ "$n" = "$$" ] || [ "$n" = "$PPID" ] && continue; ` +
		`c=$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null) || continue; ` +
		`case "$c" in *` + Quote(stage) + `/*) kill -KILL "$n" 2>/dev/null;; esac; done; true`
}

func (p Plan) TestScript(pkgs []TestPackage, testArgs []string) string {
	var b strings.Builder
	b.WriteString(scriptHeader())
	stage := p.TestStage()
	if p.InTarget {
		b.WriteString(p.syncSources())
		b.WriteString(say("Testing on " + p.Target.Label() + "…"))
		rels := make([]string, 0, len(pkgs))
		for _, pkg := range pkgs {
			rels = append(rels, "./"+relSlash(p.ModuleRoot, pkg.Dir))
		}
		argv := append([]string{"go", "test", "-json"}, p.BuildFlags...)
		argv = append(argv, goTestFlags(testArgs)...)
		argv = append(argv, rels...)
		cmd := "cd " + Quote(p.SrcStage()) + " || exit 1; " + p.exports() + "export CGO_ENABLED=1; exec " + QuoteArgv(argv)
		b.WriteString("exec " + p.remote(p.launch(stage, cmd)) + " 2>&1\n")
		return b.String()
	}
	b.WriteString(say("Building tests for " + p.platform() + "…"))
	b.WriteString("cd " + Quote(p.ModuleRoot) + " || exit 1\n")
	bins := path.Join(p.LocalTmp, "bin")
	b.WriteString("mkdir -p " + Quote(bins) + " || exit 1\n")
	for i, pkg := range pkgs {
		argv := append([]string{"env"}, p.crossEnv()...)
		argv = append(argv, "go", "test", "-c")
		argv = append(argv, p.buildFlags()...)
		argv = append(argv, "-o", path.Join(bins, testBinName(i)), pkg.ImportPath)
		b.WriteString(QuoteArgv(argv) + " || exit 1\n")
	}
	b.WriteString(p.syncSources())
	b.WriteString(localTar + " -C " + Quote(p.LocalTmp) + " -cf - bin | " + p.remote("rm -rf "+Quote(path.Join(stage, "bin"))+" && "+extract(stage)) + " || exit 1\n")
	b.WriteString("status=0\n")
	for i, pkg := range pkgs {
		name := testBinName(i)
		bin := path.Join(stage, "bin", name)
		argv := append([]string{bin, "-test.v=test2json", "-test.paniconexit0", "-test.timeout=10m0s"}, testArgs...)
		cmd := "cd " + Quote(path.Join(p.SrcStage(), relSlash(p.ModuleRoot, pkg.Dir))) + " || exit 1; " + p.exports() + "exec " + QuoteArgv(argv)
		b.WriteString("if [ -f " + Quote(path.Join(bins, name)) + " ]; then\n")
		b.WriteString("  " + p.remote(p.launch(stage, cmd)) + " 2>&1 | go tool test2json -t -p " + Quote(pkg.ImportPath) + " || status=1\n")
		b.WriteString("fi\n")
	}
	b.WriteString("exit $status\n")
	return b.String()
}

func testBinName(i int) string {
	return "pkg" + itoa(i) + ".test"
}

func itoa(i int) string {
	const digits = "0123456789"
	if i < 10 {
		return digits[i : i+1]
	}
	return itoa(i/10) + digits[i%10:i%10+1]
}

func goTestFlags(testArgs []string) []string {
	out := make([]string, 0, len(testArgs))
	for _, a := range testArgs {
		out = append(out, strings.Replace(a, "-test.", "-", 1))
	}
	return out
}

func (p Plan) InstallDelveScript() string {
	var b strings.Builder
	b.WriteString(scriptHeader())
	mod := path.Join(p.LocalTmp, "dlvmod")
	out := path.Join(p.LocalTmp, "dlvbin")
	b.WriteString(say("Building Delve for " + p.platform() + "…"))
	b.WriteString("mkdir -p " + Quote(mod) + " " + Quote(out) + " && cd " + Quote(mod) + " || exit 1\n")
	b.WriteString("export GOFLAGS=-mod=mod GOWORK=off\n")
	b.WriteString("go mod init golens.local/dlvbuild >/dev/null 2>&1 || exit 1\n")
	b.WriteString("go get github.com/go-delve/delve@latest || exit 1\n")
	argv := append([]string{"env"}, p.crossEnvOnly()...)
	argv = append(argv, "go", "build", "-o", path.Join(out, "dlv"), "github.com/go-delve/delve/cmd/dlv")
	b.WriteString(QuoteArgv(argv) + " || exit 1\n")
	b.WriteString(say("Copying Delve to " + p.Target.Label() + "…"))
	b.WriteString(localTar + " -C " + Quote(out) + " -cf - dlv | " + p.remote(extract(p.BinDir())) + " || exit 1\n")
	b.WriteString(say("Delve is installed at " + path.Join(p.BinDir(), "dlv") + ". Choose Debug to start debugging on " + p.Target.Label() + "."))
	return b.String()
}

func (p Plan) crossEnvOnly() []string {
	env := []string{"CGO_ENABLED=0", "GOOS=linux", "GOARCH=" + p.Probe.GOARCH}
	if p.Probe.GOARM != "" {
		env = append(env, "GOARM="+p.Probe.GOARM)
	}
	return env
}

func TestArgs(pattern, benchPattern string, short bool) []string {
	var args []string
	if short {
		args = append(args, "-test.short")
	}
	switch {
	case benchPattern != "":
		args = append(args, "-test.run=^$", "-test.bench="+benchPattern, "-test.benchmem")
	case pattern != "":
		args = append(args, "-test.run="+pattern)
	}
	return args
}

func SubstitutePath(p Plan) []map[string]string {
	if !p.InTarget {
		return nil
	}
	return []map[string]string{{"from": p.ModuleRoot, "to": p.SrcStage()}}
}
