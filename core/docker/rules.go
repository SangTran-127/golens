package docker

import (
	"encoding/json"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const (
	sourceDockerfile = "Dockerfile"
	sourceHadolint   = "hadolint"

	sevError   = 1
	sevWarning = 2
	sevInfo    = 3

	cacheMounts      = "--mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build"
	nonrootUser      = "USER 65532:65532"
	maxMainFixes     = 3
	defaultIgnore    = ".git\nbin/\ndist/\n*.test\n*.out\ncoverage*\n.env*\n.golens*\n.idea/\n.vscode/\nnode_modules/\nDockerfile*\ndocker-compose*\ncompose*.y*ml\n"
	emptyFindingJSON = `{"findings":[]}`
)

type Edit struct {
	Line    int    `json:"line"`
	Col     int    `json:"col"`
	EndLine int    `json:"endLine"`
	EndCol  int    `json:"endCol"`
	NewText string `json:"newText"`
}

type CreateFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

type Fix struct {
	Title      string      `json:"title"`
	Edits      []Edit      `json:"edits"`
	CreateFile *CreateFile `json:"createFile,omitempty"`
}

type Finding struct {
	Line     int    `json:"line"`
	Col      int    `json:"col"`
	EndLine  int    `json:"endLine"`
	EndCol   int    `json:"endCol"`
	Severity int    `json:"severity"`
	Code     string `json:"code"`
	Source   string `json:"source"`
	Message  string `json:"message"`
	Fixes    []Fix  `json:"fixes"`
}

type Report struct {
	Findings []Finding `json:"findings"`
}

func InspectJSON(dockerfilePath, content string) (out string) {
	defer func() {
		if recover() != nil {
			out = emptyFindingJSON
		}
	}()
	b, err := json.Marshal(Report{Findings: Inspect(dockerfilePath, content)})
	if err != nil {
		return emptyFindingJSON
	}
	return string(b)
}

func Inspect(dockerfilePath, content string) []Finding {
	in := &inspector{df: parseDockerfile(content), findings: []Finding{}}
	if filepath.IsAbs(dockerfilePath) {
		in.ctxDir = filepath.Dir(dockerfilePath)
		in.base = filepath.Base(dockerfilePath)
		facts := loadContextFacts(in.ctxDir, in.base)
		in.mod, in.scan, in.ignores = facts.mod, facts.scan, facts.ignores
	}
	if len(in.df.stages) > 0 {
		in.run()
	}
	in.findings = append(in.findings, hadolintFindings(in.df, in.ctxDir, content)...)
	sort.SliceStable(in.findings, func(i, j int) bool {
		a, b := in.findings[i], in.findings[j]
		if a.Line != b.Line {
			return a.Line < b.Line
		}
		return a.Col < b.Col
	})
	return in.findings
}

type inspector struct {
	df       *dockerfile
	ctxDir   string
	base     string
	mod      *goModule
	scan     *goScan
	ignores  []ignoreFile
	findings []Finding
}

func (in *inspector) add(sp span, sev int, code, msg string, fixes ...Fix) {
	if fixes == nil {
		fixes = []Fix{}
	}
	in.findings = append(in.findings, Finding{
		Line: sp.line, Col: sp.col, EndLine: sp.endLine, EndCol: sp.endCol,
		Severity: sev, Code: code, Source: sourceDockerfile, Message: msg, Fixes: fixes,
	})
}

func (in *inspector) run() {
	final := in.df.stages[len(in.df.stages)-1]
	finalName, _, _ := splitImage(final.root().image)
	minimalFinal := isStaticImage(finalName)
	cgoReason := in.cgoReason()

	in.checkGoVersion()
	if minimalFinal && cgoReason == "" {
		in.checkCgoDisabled(final)
	}
	if minimalFinal && cgoReason != "" {
		in.add(in.imageSpan(final), sevWarning, "DF003", fmt.Sprintf(
			"This module uses cgo (%s), but %s has no C library, so the binary won’t start. Use gcr.io/distroless/base-debian12 as the final image.",
			cgoReason, final.root().image))
	}
	for _, s := range in.df.stages {
		in.checkModDownloadOrder(s)
		in.checkMainPackages(s)
	}
	in.checkCacheMounts()
	in.checkDockerignore()
	in.checkUser(final)
	in.checkTags()
}

func (in *inspector) imageSpan(s *stage) span {
	return in.df.argSpan(s.from, s.imageOff, len(s.image))
}

func (in *inspector) cgoReason() string {
	switch {
	case in.mod == nil:
		return ""
	case in.mod.sqlite:
		return "go.mod requires github.com/mattn/go-sqlite3"
	case in.scan != nil && in.scan.cgoFile != "":
		return fmt.Sprintf(`%s imports "C"`, in.scan.cgoFile)
	}
	return ""
}

func splitImage(ref string) (name, tag, digest string) {
	if i := strings.Index(ref, "@"); i >= 0 {
		ref, digest = ref[:i], ref[i+1:]
	}
	if c := strings.LastIndex(ref, ":"); c > strings.LastIndex(ref, "/") {
		ref, tag = ref[:c], ref[c+1:]
	}
	return ref, tag, digest
}

func isStaticImage(name string) bool {
	name = strings.ToLower(name)
	return name == "scratch" || strings.Contains(name, "distroless/static")
}

func (in *inspector) checkGoVersion() {
	if in.mod == nil {
		return
	}
	required, directive := in.mod.required()
	req := versionParts(required)
	if len(req) == 0 {
		return
	}
	for _, s := range in.df.stages {
		if s.parent != nil {
			continue
		}
		name, tag, _ := splitImage(s.image)
		if path.Base(strings.ToLower(name)) != "golang" {
			continue
		}
		ver := versionPrefixRe.FindString(tag)
		img := versionParts(ver)
		if len(img) == 0 || imageCovers(img, req) {
			continue
		}
		newVer := strings.Join(strings.Split(versionPrefixRe.FindString(required), ".")[:min(len(img), len(req))], ".")
		sp := in.df.argSpan(s.from, s.imageOff+len(name)+1, len(ver))
		in.add(sp, sevError, "DF001", fmt.Sprintf(
			"%s:%s is older than Go %s required by go.mod (%s); the build will fail or download another toolchain.",
			name, tag, required, directive),
			Fix{Title: fmt.Sprintf("Use %s:%s%s", name, newVer, tag[len(ver):]), Edits: []Edit{in.replace(sp, newVer)}})
	}
}

type goCmd struct {
	inst   *instruction
	kind   string
	off    int
	length int
	args   []word
}

func isSeparator(w word) bool {
	return w.raw != "" && strings.Trim(w.raw, ";&|") == ""
}

func goCommands(inst *instruction) []goCmd {
	if inst.cmd != "RUN" {
		return nil
	}
	toks := tokenize(inst.args)
	var cmds []goCmd
	for i := 0; i < len(toks); i++ {
		if path.Base(toks[i].val) != "go" {
			continue
		}
		var kind string
		last := i
		switch {
		case i+1 < len(toks) && toks[i+1].val == "build":
			kind, last = "build", i+1
		case i+2 < len(toks) && toks[i+1].val == "mod" && toks[i+2].val == "download":
			kind, last = "download", i+2
		default:
			continue
		}
		j := last + 1
		for j < len(toks) && !isSeparator(toks[j]) {
			j++
		}
		cmds = append(cmds, goCmd{
			inst: inst, kind: kind, off: toks[i].off,
			length: toks[last].off + len(toks[last].raw) - toks[i].off,
			args:   toks[last+1 : j],
		})
		i = j
	}
	return cmds
}

func stageCommands(s *stage, kind string) []goCmd {
	var out []goCmd
	for _, inst := range s.insts {
		for _, c := range goCommands(inst) {
			if c.kind == kind {
				out = append(out, c)
			}
		}
	}
	return out
}

var cgoOffRe = regexp.MustCompile(`CGO_ENABLED(?:=|\s+)["']?0\b`)

func (in *inspector) checkCgoDisabled(final *stage) {
	for _, s := range in.df.stages {
		if s == final {
			continue
		}
		builds := stageCommands(s, "build")
		if len(builds) == 0 {
			continue
		}
		name, tag, _ := splitImage(s.root().image)
		if strings.Contains(strings.ToLower(name+":"+tag), "alpine") || cgoDisabled(s) {
			continue
		}
		b := builds[0]
		in.add(in.df.argSpan(b.inst, b.off, b.length), sevWarning, "DF002", fmt.Sprintf(
			"go build runs with cgo enabled on %s, but the final image %s has no C library, so the binary may not start. Set CGO_ENABLED=0.",
			s.root().image, final.root().image),
			Fix{Title: "Insert ENV CGO_ENABLED=0", Edits: []Edit{in.df.insertAfter(s.from, in.df.lineIndent(s.from.line)+"ENV CGO_ENABLED=0")}})
	}
}

func cgoDisabled(s *stage) bool {
	for _, st := range s.chain() {
		for _, inst := range st.insts {
			if (inst.cmd == "ENV" || inst.cmd == "ARG" || inst.cmd == "RUN") && cgoOffRe.MatchString(inst.args) {
				return true
			}
		}
	}
	return false
}

func copySources(inst *instruction) ([]word, bool) {
	var out []word
	fromOther := false
	for _, w := range tokenize(inst.args) {
		if strings.HasPrefix(w.val, "--") && len(out) == 0 {
			if strings.HasPrefix(w.val, "--from") {
				fromOther = true
			}
			continue
		}
		out = append(out, w)
	}
	return out, fromOther
}

func copiesWholeContext(inst *instruction) (word, bool) {
	if inst.cmd != "COPY" && inst.cmd != "ADD" {
		return word{}, false
	}
	ws, fromOther := copySources(inst)
	if fromOther || len(ws) < 2 {
		return word{}, false
	}
	for _, w := range ws[:len(ws)-1] {
		if w.val != "." && w.val != "./" {
			return word{}, false
		}
	}
	return ws[0], true
}

func (in *inspector) checkModDownloadOrder(s *stage) {
	downloaded := false
	for _, inst := range s.insts {
		cmds := goCommands(inst)
		hasBuild := false
		for _, c := range cmds {
			if c.kind == "download" {
				downloaded = true
			} else {
				hasBuild = true
			}
		}
		if hasBuild || downloaded {
			return
		}
		src, ok := copiesWholeContext(inst)
		if !ok {
			continue
		}
		if len(stageCommands(s, "build")) == 0 {
			return
		}
		var fixes []Fix
		if in.mod != nil && in.mod.root == in.ctxDir {
			indent := in.df.lineIndent(inst.line)
			mods := "go.mod go.sum"
			if !in.mod.hasGoSum {
				mods = "go.mod"
			}
			text := fmt.Sprintf("%sCOPY %s ./\n%sRUN go mod download\n", indent, mods, indent)
			fixes = append(fixes, Fix{Title: "Download modules before COPY . .", Edits: []Edit{{Line: inst.line, EndLine: inst.line, NewText: text}}})
		}
		in.add(in.df.argSpan(inst, src.off, len(inst.args)-src.off), sevWarning, "DF004",
			"COPY . . runs before go mod download, so every source change downloads all modules again. Copy go.mod and go.sum and download first.",
			fixes...)
		return
	}
}

var buildValueFlags = map[string]bool{
	"o": true, "p": true, "asmflags": true, "buildmode": true, "compiler": true, "gccgoflags": true,
	"gcflags": true, "installsuffix": true, "ldflags": true, "mod": true, "modfile": true, "overlay": true,
	"pgo": true, "pkgdir": true, "tags": true, "toolexec": true, "covermode": true, "coverpkg": true,
}

func (in *inspector) checkMainPackages(s *stage) {
	if in.scan == nil || !in.scan.complete {
		return
	}
	contextCopied, workdirMoved := false, false
	for _, inst := range s.insts {
		if _, ok := copiesWholeContext(inst); ok {
			contextCopied, workdirMoved = true, false
		}
		if inst.cmd == "WORKDIR" && contextCopied {
			workdirMoved = true
		}
		if workdirMoved || strings.Contains(inst.args, "cd ") {
			continue
		}
		for _, c := range goCommands(inst) {
			if c.kind == "build" {
				in.checkBuildTargets(c)
			}
		}
	}
}

func (in *inspector) checkBuildTargets(c goCmd) {
	var targets []word
	for j := 0; j < len(c.args); j++ {
		a := c.args[j].val
		if strings.HasPrefix(a, "-") {
			flag := strings.TrimLeft(a, "-")
			if flag == "C" || strings.HasPrefix(flag, "C=") {
				return
			}
			if !strings.Contains(flag, "=") && buildValueFlags[flag] {
				j++
			}
			continue
		}
		if (a == "." || strings.HasPrefix(a, "./")) && !strings.Contains(a, "...") && !strings.HasSuffix(a, ".go") && !strings.ContainsAny(a, "$*") {
			targets = append(targets, c.args[j])
		}
	}
	for _, t := range targets {
		rel := filepath.ToSlash(filepath.Clean(t.val))
		if in.scan.mains[rel] {
			continue
		}
		msg := fmt.Sprintf("%s is not a main package, so go build produces no binary.", t.val)
		_, ctxErr := os.Stat(filepath.Join(in.ctxDir, filepath.FromSlash(rel)))
		modErr := ctxErr
		if in.mod != nil && in.mod.root != in.ctxDir {
			_, modErr = os.Stat(filepath.Join(in.mod.root, filepath.FromSlash(rel)))
		}
		if ctxErr != nil && modErr != nil {
			msg = fmt.Sprintf("%s does not exist in the build context.", t.val)
		}
		sp := in.df.argSpan(c.inst, t.off, len(t.raw))
		var fixes []Fix
		for _, m := range in.mainList() {
			target := "./" + m
			if m == "." {
				target = "."
			}
			fixes = append(fixes, Fix{Title: "Build " + target, Edits: []Edit{in.replace(sp, target)}})
		}
		in.add(sp, sevError, "DF005", msg, fixes...)
	}
}

func (in *inspector) mainList() []string {
	var mains []string
	for m := range in.scan.mains {
		mains = append(mains, m)
	}
	sort.Strings(mains)
	if len(mains) > maxMainFixes {
		mains = mains[:maxMainFixes]
	}
	return mains
}

func (in *inspector) checkCacheMounts() {
	for _, inst := range in.df.insts {
		cmds := goCommands(inst)
		if len(cmds) == 0 || hasCacheMount(inst) {
			continue
		}
		c := cmds[0]
		at := in.df.argSpan(inst, 0, 0)
		in.add(in.df.argSpan(inst, c.off, c.length), sevInfo, "DF006",
			"Without a BuildKit cache mount, every build downloads modules and recompiles all packages again.",
			Fix{Title: "Add Go cache mounts", Edits: []Edit{{Line: at.line, Col: at.col, EndLine: at.line, EndCol: at.col, NewText: cacheMounts + " "}}})
	}
}

func hasCacheMount(inst *instruction) bool {
	for _, w := range tokenize(inst.args) {
		if !strings.HasPrefix(w.val, "--") {
			return false
		}
		if strings.HasPrefix(w.val, "--mount=") && strings.Contains(w.val, "type=cache") {
			return true
		}
	}
	return false
}

func (in *inspector) checkDockerignore() {
	if in.ctxDir == "" {
		return
	}
	at := in.df.keywordSpan(in.df.stages[0].from)
	for _, f := range in.ignores {
		name, p, text := f.name, f.path, f.content
		if ignoresGit(text) {
			return
		}
		if text != "" && !strings.HasSuffix(text, "\n") {
			text += "\n"
		}
		in.add(at, sevInfo, "DF007", fmt.Sprintf("%s doesn’t exclude .git, so the repository history is sent with every build.", name),
			Fix{Title: "Add .git to " + name, Edits: []Edit{}, CreateFile: &CreateFile{Path: p, Content: text + ".git\n"}})
		return
	}
	in.add(at, sevWarning, "DF007",
		"No .dockerignore in the build context, so .git, build output and local env files are sent to the builder and COPY . . puts them in the image.",
		Fix{Title: "Create .dockerignore", Edits: []Edit{}, CreateFile: &CreateFile{Path: filepath.Join(in.ctxDir, ".dockerignore"), Content: defaultIgnore}})
}

func ignoresGit(text string) bool {
	ignored := false
	for _, line := range strings.Split(text, "\n") {
		p := strings.TrimSpace(line)
		if p == "" || strings.HasPrefix(p, "#") {
			continue
		}
		negate := strings.HasPrefix(p, "!")
		p = strings.TrimPrefix(p, "!")
		p = strings.TrimPrefix(strings.TrimSuffix(p, "/"), "/")
		p = strings.TrimPrefix(p, "**/")
		if ok, _ := filepath.Match(p, ".git"); ok || p == "**" {
			ignored = !negate
		}
	}
	return ignored
}

func (in *inspector) checkUser(final *stage) {
	for _, s := range final.chain() {
		for _, inst := range s.insts {
			if inst.cmd == "USER" {
				return
			}
		}
	}
	name, tag, _ := splitImage(final.root().image)
	if strings.Contains(strings.ToLower(name+":"+tag), "nonroot") {
		return
	}
	var fixes []Fix
	lower := strings.ToLower(name)
	if lower == "scratch" || strings.Contains(lower, "distroless") {
		last := final.from
		if len(final.insts) > 0 {
			last = final.insts[len(final.insts)-1]
		}
		fixes = append(fixes, Fix{Title: "Run as " + nonrootUser, Edits: []Edit{in.df.insertAfter(last, nonrootUser)}})
	}
	in.add(in.imageSpan(final), sevWarning, "DF008",
		"The final stage runs as root. Add a USER so a compromised process doesn’t run as root in the container.", fixes...)
}

func (in *inspector) checkTags() {
	for _, s := range in.df.stages {
		if s.parent != nil || s.image == "" || strings.Contains(s.image, "$") || strings.EqualFold(s.image, "scratch") {
			continue
		}
		name, tag, digest := splitImage(s.image)
		if digest != "" || (tag != "" && tag != "latest") {
			continue
		}
		in.add(in.imageSpan(s), sevWarning, "DF009", fmt.Sprintf(
			"%s isn’t pinned to a version, so builds change whenever a new image is published. Use a version tag such as %s:<version>.",
			s.image, name))
	}
}

func (in *inspector) replace(sp span, text string) Edit {
	return Edit{Line: sp.line, Col: sp.col, EndLine: sp.endLine, EndCol: sp.endCol, NewText: text}
}

func (df *dockerfile) insertAfter(inst *instruction, text string) Edit {
	if next := inst.endLine + 1; next < len(df.lines) {
		return Edit{Line: next, EndLine: next, NewText: text + "\n"}
	}
	last := df.lines[inst.endLine]
	c := utf16Col(last, len(last))
	return Edit{Line: inst.endLine, Col: c, EndLine: inst.endLine, EndCol: c, NewText: "\n" + text}
}

func hadolintFindings(df *dockerfile, dir, content string) []Finding {
	bin := LookPath("hadolint")
	if bin == "" || strings.TrimSpace(content) == "" {
		return nil
	}
	out, _, err := runCLI(5*time.Second, dir, content, bin, "--no-fail", "-f", "json", "-")
	if err != nil {
		return nil
	}
	var items []struct {
		Line    int    `json:"line"`
		Column  int    `json:"column"`
		Level   string `json:"level"`
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if json.Unmarshal([]byte(out), &items) != nil {
		return nil
	}
	var findings []Finding
	for _, it := range items {
		line := min(max(it.Line-1, 0), len(df.lines)-1)
		text := df.lines[line]
		start := len(text) - len(strings.TrimLeft(text, " \t"))
		if it.Column > 1 {
			start = runeByteOffset(text, it.Column-1)
		}
		sev := sevInfo
		switch it.Level {
		case "error":
			sev = sevError
		case "warning":
			sev = sevWarning
		}
		findings = append(findings, Finding{
			Line: line, Col: utf16Col(text, start), EndLine: line, EndCol: utf16Col(text, len(text)),
			Severity: sev, Code: it.Code, Source: sourceHadolint, Message: it.Message, Fixes: []Fix{},
		})
	}
	return findings
}
