package lsp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golens/core/bridge"
	"golens/core/cmd/golens-vm-agent/guestres"
	"golens/core/vmexec"
)

const (
	GoplsMemoryLimit    = "256MiB"
	initializeBudget    = 30 * time.Second
	shutdownBudget      = 2 * time.Second
	exitWait            = 2 * time.Second
	restartBackoffMin   = time.Second
	restartBackoffMax   = 30 * time.Second
	restartStableUptime = time.Minute
)

var traceLSP = os.Getenv("GOLENS_LSP_TRACE") != ""

type serverCaps struct {
	SyncKind      int
	SemanticFull  bool
	SemanticRange bool
	Formatting    bool
	CodeActions   bool
	TokenTypes    []string

	InteractiveCommands bool
}

type server struct {
	root     string
	cmd      *exec.Cmd
	c        *conn
	caps     serverCaps
	exited   chan struct{}
	started  time.Time
	mu       sync.Mutex
	stopped  bool
	sent     string
	isRemote bool
	rwc      io.ReadWriteCloser
	ready    *readiness
	paths    *URITranslator

	liveMemoryLimit bool
}

func settingsJSONFor(isRemote bool) string {
	b, _ := json.Marshal(goplsSettingsFor(isRemote))
	return string(b)
}

func settingsJSON() string {
	return settingsJSONFor(isCurrentRemote())
}

func (s *server) noteSettings(js string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sent == js {
		return false
	}
	s.sent = js
	return true
}

type lifecycle struct {
	run     sync.Mutex
	mu      sync.Mutex
	root    string
	roots   []string
	gen     int
	backoff time.Duration
	srv     *server
}

var life lifecycle

func setupPATH() {
	path := os.Getenv("PATH")
	parts := strings.Split(path, ":")
	have := make(map[string]bool, len(parts))
	for _, p := range parts {
		have[p] = true
	}
	var extra []string
	if home, err := os.UserHomeDir(); err == nil {
		extra = append(extra, filepath.Join(home, "go", "bin"))
	}
	extra = append(extra, "/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin")
	for _, p := range extra {
		if !have[p] {
			if path == "" {
				path = p
			} else {
				path += ":" + p
			}
		}
	}
	_ = os.Setenv("PATH", path)
}

const hostCoreSoftMemoryLimit = 384 << 20

func InitGoLensCore() {
	setupPATH()
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(100)
	}
	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(hostCoreSoftMemoryLimit)
	}
}

func pathToURI(p string) string {
	return (&url.URL{Scheme: "file", Path: p}).String()
}

func uriToPath(u string) string {
	parsed, err := url.Parse(u)
	if err != nil || parsed.Scheme != "file" {
		return strings.TrimPrefix(u, "file://")
	}
	return parsed.Path
}

var userOptions struct {
	sync.Mutex
	analyses    map[string]bool
	hints       map[string]bool
	goos        string
	goarch      string
	buildTags   string
	annotations map[string]bool
}

const maxUserOptions = 64

func notifySettingsChanged() {
	if srv := current(); srv != nil && srv.noteSettings(settingsJSONFor(srv.isRemote)) {
		_ = srv.c.notify("workspace/didChangeConfiguration", map[string]any{"settings": map[string]any{"gopls": goplsSettingsFor(srv.isRemote)}})
	}
}

func SetUserOptions(analyses, hints map[string]bool) {
	if len(analyses) > maxUserOptions || len(hints) > maxUserOptions {
		return
	}
	userOptions.Lock()
	userOptions.analyses, userOptions.hints = analyses, hints
	if analyses["escapeAnalysis"] || hints["escapeAnalysis"] || analyses["escape"] || hints["escape"] {
		userOptions.annotations = map[string]bool{"escape": true}
	} else if _, has := hints["escape"]; has {
		userOptions.annotations = nil
	} else if _, has := hints["escapeAnalysis"]; has {
		userOptions.annotations = nil
	} else if _, has := analyses["escapeAnalysis"]; has {
		userOptions.annotations = nil
	}
	userOptions.Unlock()
	notifySettingsChanged()
}

func SetBuildTarget(goos, goarch, buildTags string) {
	userOptions.Lock()
	userOptions.goos = strings.TrimSpace(goos)
	userOptions.goarch = strings.TrimSpace(goarch)
	userOptions.buildTags = strings.TrimSpace(buildTags)
	userOptions.Unlock()
	notifySettingsChanged()
}

var (
	defaultAnalyses = map[string]bool{"SA1000": true, "ST1005": true, "SA4006": true}
	defaultHints    = map[string]bool{"ignoredError": true, "assignVariableTypes": true, "rangeVariableTypes": true, "parameterNames": true}
)

func mergeOptions(defaults, user map[string]bool) map[string]bool {
	out := make(map[string]bool, len(defaults)+len(user))
	for k, v := range defaults {
		out[k] = v
	}
	for k, v := range user {
		out[k] = v
	}
	return out
}

func isCurrentRemote() bool {
	life.mu.Lock()
	defer life.mu.Unlock()
	return life.srv != nil && life.srv.isRemote
}

const goplsBallastBytes = 100 * 1000 * 1000

var remoteGoplsMemoryLimit atomic.Int64

func goplsMemoryLimitForGuest(meminfo []byte) int64 {
	step, ceiling := currentGuestStep()
	return goplsMemoryLimitForTotal(guestres.UsableAtStep(guestres.ParseMemTotal(meminfo), guestres.ParseBalloonPages(meminfo), step, ceiling))
}

func goplsMemoryLimitForTotal(total uint64) int64 {
	if total == 0 {
		return 0
	}
	return int64(guestres.LSPBudgetFor(total).GoMemLimit) + goplsBallastBytes
}

var meminfoRetryDelay = 300 * time.Millisecond

func probeGuestGoplsMemoryLimit() {
	var failures []string
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(meminfoRetryDelay)
		}
		out, err := readGuestMeminfo()
		if err != nil {
			failures = append(failures, err.Error())
			continue
		}
		limit := goplsMemoryLimitForGuest(out)
		remoteGoplsMemoryLimit.Store(limit)
		if limit > 0 {
			bridge.Debug(fmt.Sprintf("gopls memoryLimit %d MiB (guest budget plus the gopls heap ballast)%s", limit>>20, retriedNote(failures)))
		}
		return
	}
	remoteGoplsMemoryLimit.Store(0)
	bridge.Debug("gopls memoryLimit not set: reading guest meminfo failed: " + strings.Join(failures, "; "))
}

func retriedNote(failures []string) string {
	if len(failures) == 0 {
		return ""
	}
	return fmt.Sprintf(" after %d failed reads: %s", len(failures), strings.Join(failures, "; "))
}

var readGuestMeminfo = func() ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := vmexec.CommandContext(ctx, "cat", "/proc/meminfo", "/proc/vmstat")
	cmd.Dir = "/"
	cmd.DialTimeout = 2 * time.Second
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return nil, fmt.Errorf("%w (%s)", err, msg)
		}
		return nil, err
	}
	return out, nil
}

func goplsSettings() map[string]any {
	return goplsSettingsFor(isCurrentRemote())
}

func goplsSettingsFor(isRemote bool) map[string]any {
	userOptions.Lock()
	analyses := mergeOptions(defaultAnalyses, userOptions.analyses)
	hints := mergeOptions(defaultHints, userOptions.hints)
	goos := userOptions.goos
	goarch := userOptions.goarch
	buildTags := userOptions.buildTags
	escapeEnabled := userOptions.annotations["escape"] || userOptions.hints["escape"] || userOptions.hints["escapeAnalysis"] || userOptions.analyses["escapeAnalysis"]
	userOptions.Unlock()
	delete(hints, "escape")
	delete(hints, "escapeAnalysis")
	delete(analyses, "escapeAnalysis")
	settings := map[string]any{
		"analyses":                       analyses,
		"hints":                          hints,
		"experimentalPostfixCompletions": true,
		"completeUnimported":             true,
		"deepCompletion":                 true,
		"usePlaceholders":                true,
		"semanticTokens":                 true,
		"symbolScope":                    "workspace",
		"gofumpt":                        false,
		"directoryFilters": []string{
			"-**/node_modules",
			"-**/.git",
			"-**/.next",
			"-**/.build",
			"-**/.venv",
			"-**/venv",
			"-**/__pycache__",
			"-**/.golens",
			"-**/DerivedData",
		},
		"codelenses": map[string]bool{
			"generate": true, "regenerate_cgo": true, "tidy": true, "upgrade_dependency": true,
			"vendor": true, "vulncheck": true, "run_govulncheck": false, "test": false,
		},
	}
	env := map[string]string{}
	if isRemote {
		env["GOCACHE"] = "/cache/gobuild"
		env["GOMODCACHE"] = "/cache/gomod"
	}
	if goos != "" {
		env["GOOS"] = goos
	}
	if goarch != "" {
		env["GOARCH"] = goarch
	}
	if len(env) > 0 {
		settings["env"] = env
	}
	if buildTags != "" {
		settings["buildFlags"] = []string{"-tags=" + buildTags}
	}
	if escapeEnabled {
		settings["annotations"] = map[string]bool{"escape": true, "nil": true}
	}
	if isRemote {
		if limit := remoteGoplsMemoryLimit.Load(); limit > 0 {
			settings["memoryLimit"] = limit
		}
	}
	return settings
}

func clientCapabilities() map[string]any {
	return map[string]any{
		"general": map[string]any{"positionEncodings": []string{"utf-16"}},
		"workspace": map[string]any{
			"configuration":    true,
			"workspaceFolders": true,
			"applyEdit":        true,
			"workspaceEdit":    map[string]any{"documentChanges": true, "resourceOperations": []string{"create"}},
			"executeCommand":   map[string]any{},
		},
		"experimental": map[string]any{
			"interactiveResolve": map[string]any{"inputTypes": []string{"string", "bool", "number", "enum", "lazyEnum"}},
		},
		"window": map[string]any{"workDoneProgress": true},
		"textDocument": map[string]any{
			"synchronization":    map[string]any{"didSave": false, "dynamicRegistration": false},
			"publishDiagnostics": map[string]any{"relatedInformation": false, "versionSupport": true},
			"completion": map[string]any{
				"completionItem": map[string]any{
					"snippetSupport":          true,
					"deprecatedSupport":       true,
					"labelDetailsSupport":     true,
					"insertReplaceSupport":    true,
					"documentationFormat":     []string{"plaintext", "markdown"},
					"insertTextModeSupport":   map[string]any{"valueSet": []int{1}},
					"commitCharactersSupport": false,
				},
				"contextSupport": true,
			},
			"hover": map[string]any{"contentFormat": []string{"markdown", "plaintext"}},
			"signatureHelp": map[string]any{
				"signatureInformation": map[string]any{
					"documentationFormat":  []string{"markdown", "plaintext"},
					"parameterInformation": map[string]any{"labelOffsetSupport": true},
				},
			},
			"definition":     map[string]any{"linkSupport": false},
			"references":     map[string]any{},
			"documentSymbol": map[string]any{"hierarchicalDocumentSymbolSupport": true},
			"rename":         map[string]any{"prepareSupport": false},
			"codeAction": map[string]any{
				"codeActionLiteralSupport": map[string]any{
					"codeActionKind": map[string]any{
						"valueSet": []string{"", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.move", "refactor.rewrite", "source", "source.organizeImports", "source.fixAll", "source.addTest"},
					},
				},
				"isPreferredSupport": true,
				"dataSupport":        true,
				"resolveSupport":     map[string]any{"properties": []string{"edit"}},
				"disabledSupport":    true,
			},
			"codeLens":        map[string]any{},
			"formatting":      map[string]any{},
			"rangeFormatting": map[string]any{},
			"inlayHint":       map[string]any{},
			"semanticTokens": map[string]any{
				"requests":       map[string]any{"full": true, "range": true},
				"tokenTypes":     []string{"namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable", "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator", "decorator", "label"},
				"tokenModifiers": []string{"declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification", "documentation", "defaultLibrary"},
				"formats":        []string{"relative"},
			},
		},
	}
}

func parseCaps(raw json.RawMessage) serverCaps {
	var r struct {
		Capabilities struct {
			TextDocumentSync       json.RawMessage `json:"textDocumentSync"`
			SemanticTokensProvider *struct {
				Full   json.RawMessage `json:"full"`
				Range  json.RawMessage `json:"range"`
				Legend struct {
					TokenTypes []string `json:"tokenTypes"`
				} `json:"legend"`
			} `json:"semanticTokensProvider"`
			DocumentFormattingProvider json.RawMessage `json:"documentFormattingProvider"`
			CodeActionProvider         json.RawMessage `json:"codeActionProvider"`
			Experimental               struct {
				InteractiveResolveProvider struct {
					Kinds []string `json:"kinds"`
				} `json:"interactiveResolveProvider"`
			} `json:"experimental"`
		} `json:"capabilities"`
	}
	caps := serverCaps{SyncKind: 1}
	if json.Unmarshal(raw, &r) != nil {
		return caps
	}
	syncRaw := r.Capabilities.TextDocumentSync
	var kind int
	if json.Unmarshal(syncRaw, &kind) == nil {
		caps.SyncKind = kind
	} else {
		var o struct {
			Change int `json:"change"`
		}
		if json.Unmarshal(syncRaw, &o) == nil {
			caps.SyncKind = o.Change
		}
	}
	enabled := func(v json.RawMessage) bool {
		s := strings.TrimSpace(string(v))
		return s != "" && s != "false" && s != "null"
	}
	if st := r.Capabilities.SemanticTokensProvider; st != nil {
		caps.SemanticFull = enabled(st.Full)
		caps.SemanticRange = enabled(st.Range)
		caps.TokenTypes = st.Legend.TokenTypes
	}
	caps.Formatting = enabled(r.Capabilities.DocumentFormattingProvider)
	caps.CodeActions = enabled(r.Capabilities.CodeActionProvider)
	for _, k := range r.Capabilities.Experimental.InteractiveResolveProvider.Kinds {
		caps.InteractiveCommands = caps.InteractiveCommands || k == "command"
	}
	return caps
}

func OpenWorkspace(root string) {
	life.mu.Lock()
	known := slices.Contains(life.roots, root)
	if known && life.root == root {
		life.mu.Unlock()
		return
	}
	serving := len(life.roots) > 0
	life.root = root
	if !known {
		life.roots = append(life.roots, root)
	}
	srv := life.srv
	switch {
	case serving && srv != nil && !srv.isRemote:
		life.mu.Unlock()
		if !known {
			bridge.Debug("Workspace folder added: " + root)
			srv.changeFolders([]string{root}, nil)
		}
		projectModules.refresh(root)
		return
	case known && (srv == nil || srv.root == root):
		life.mu.Unlock()
		return
	}
	life.gen++
	life.backoff = 0
	gen := life.gen
	life.mu.Unlock()
	bridge.Debug("Workspace opened: " + root)
	projectModules.refresh(root)
	go runServer(gen, 0)
}

func CloseWorkspaceFolder(root string) {
	life.mu.Lock()
	i := slices.Index(life.roots, root)
	if i < 0 {
		life.mu.Unlock()
		return
	}
	life.roots = slices.Delete(life.roots, i, i+1)
	projectModules.forget(root)
	if len(life.roots) == 0 {
		life.mu.Unlock()
		CloseWorkspace()
		return
	}
	wasActive := life.root == root
	if wasActive {
		life.root = life.roots[len(life.roots)-1]
	}
	srv := life.srv
	if srv != nil && !srv.isRemote {
		life.mu.Unlock()
		bridge.Debug("Workspace folder removed: " + root)
		srv.changeFolders(nil, []string{root})
		return
	}
	if !wasActive {
		life.mu.Unlock()
		return
	}
	life.gen++
	gen := life.gen
	life.mu.Unlock()
	go runServer(gen, 0)
}

func OpenWorkspaceRoots() []string {
	life.mu.Lock()
	defer life.mu.Unlock()
	return slices.Clone(life.roots)
}

func RootForPath(path string) string {
	life.mu.Lock()
	defer life.mu.Unlock()
	return rootForPathLocked(path)
}

func OwningRoot(path string) string {
	life.mu.Lock()
	defer life.mu.Unlock()
	return owningRootLocked(path)
}

func owningRootLocked(path string) string {
	best := ""
	for _, r := range life.roots {
		if (path == r || strings.HasPrefix(path, r+"/")) && len(r) > len(best) {
			best = r
		}
	}
	return best
}

func rootForPathLocked(path string) string {
	best := owningRootLocked(path)
	if best == "" {
		return life.root
	}
	return best
}

func (s *server) changeFolders(added, removed []string) {
	folders := func(roots []string) []map[string]string {
		out := []map[string]string{}
		for _, r := range roots {
			_, f := workspaceFoldersFor(r)
			out = append(out, f...)
		}
		return out
	}
	_ = s.c.notify("workspace/didChangeWorkspaceFolders", map[string]any{
		"event": map[string]any{"added": folders(added), "removed": folders(removed)},
	})
}

func CloseWorkspace() {
	life.mu.Lock()
	life.root = ""
	life.roots = nil
	life.gen++
	gen := life.gen
	life.mu.Unlock()
	go runServer(gen, 0)
}

func Shutdown() {
	life.mu.Lock()
	life.root = ""
	life.roots = nil
	life.gen++
	srv := life.srv
	life.srv = nil
	life.mu.Unlock()
	if srv != nil {
		srv.stop()
	}
}

func runServer(gen int, delay time.Duration) {
	if delay > 0 {
		time.Sleep(delay)
	}
	life.run.Lock()
	defer life.run.Unlock()
	life.mu.Lock()
	if gen != life.gen {
		life.mu.Unlock()
		return
	}
	old, root, roots := life.srv, life.root, slices.Clone(life.roots)
	life.srv = nil
	life.mu.Unlock()
	if old != nil {
		old.stop()
	}
	if root == "" {
		reportServerState("stopped", "")
		return
	}
	if delay > 0 {
		reportServerState("restarting", "")
	} else {
		reportServerState("starting", "")
	}
	srv, err := startServer(root, roots)
	life.mu.Lock()
	if err != nil {
		bridge.Debug("gopls failed to start: " + err.Error())
		if gen == life.gen {
			if errors.Is(err, errGoplsNotFound) {
				reportServerState("missing", "")
			} else {
				reason := err.Error()
				if errors.Is(err, errWorkspaceNotVisible) {
					reason = "The project folder is not visible inside the Linux VM yet."
				}
				scheduleRestartLocked(gen)
				reportServerState("crashed", fmt.Sprintf("%s|%d", reason, int(life.backoff.Seconds())))
			}
		}
		life.mu.Unlock()
		return
	}
	if gen != life.gen {
		life.mu.Unlock()
		srv.stop()
		return
	}
	life.srv = srv
	life.mu.Unlock()
	go watchServer(srv)
	if OnServerStarted != nil {
		OnServerStarted(srv.root, srv.paths)
	}
}

var OnServerStarted func(root string, paths *URITranslator)

func watchServer(srv *server) {
	<-srv.exited
	srv.mu.Lock()
	intentional := srv.stopped
	srv.mu.Unlock()
	srv.closeReadiness()
	if intentional {
		return
	}
	docs.detach(srv)
	srv.c.close()
	life.mu.Lock()
	defer life.mu.Unlock()
	if life.srv != srv {
		return
	}
	life.srv = nil
	if time.Since(srv.started) > restartStableUptime {
		life.backoff = 0
	}
	bridge.Debug("gopls exited unexpectedly; restarting")
	scheduleRestartLocked(life.gen)
	reportServerState("crashed", fmt.Sprintf("exited unexpectedly|%d", int(life.backoff.Seconds())))
}

var errGoplsNotFound = errors.New("gopls not found in PATH")

func reportServerState(state, detail string) {
	b, _ := json.Marshal(map[string]string{"state": state, "detail": detail})
	bridge.Status("languageServer", string(b))
}

func RestartServer() {
	life.mu.Lock()
	life.backoff = 0
	gen, root := life.gen, life.root
	life.mu.Unlock()
	if root != "" {
		go runServer(gen, 0)
	}
}

func scheduleRestartLocked(gen int) {
	if life.backoff == 0 {
		life.backoff = restartBackoffMin
	} else {
		life.backoff = min(life.backoff*2, restartBackoffMax)
	}
	go runServer(gen, life.backoff)
}

func startServer(root string, roots []string) (*server, error) {
	cleanRoot := filepath.Clean(root)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	rawConn, err := bridge.DialSandboxVsockWithRetry(ctx, 2001, 10*time.Second)
	if err != nil {
		if bridge.CanFallbackToHost(err) {
			return startLocalServer(cleanRoot, roots)
		}
		return nil, fmt.Errorf("failed to connect to gopls in micro-vm (vsock :2001): %w", err)
	}
	ensureGuestInodeReclaimer()
	ensureGuestPressureWatcher()
	probeGuestGoplsMemoryLimit()

	shareCtx, shareCancel := context.WithTimeout(context.Background(), shareWaitBudget+10*time.Second)
	slug, err := newShareWaiter().wait(shareCtx, vmexec.WorkspaceSlugCandidates(cleanRoot))
	shareCancel()
	if err != nil {
		_ = rawConn.Close()
		return nil, fmt.Errorf("%w: %s", errWorkspaceNotVisible, cleanRoot)
	}

	share := vmexec.HostShareRoots()
	translator := NewURITranslatorWithRoots(TranslatorRoots{
		HostWorkspace:  cleanRoot,
		GuestWorkspace: vmexec.GuestWorkspacesRoot + "/" + slug,
		HostModCache:   share.ModCache,
		HostGoroot:     share.Goroot,
	})
	rewritingConn := NewRewritingConn(rawConn, translator)

	s := &server{
		root:     cleanRoot,
		c:        newConn(),
		exited:   make(chan struct{}),
		started:  time.Now(),
		isRemote: true,
		rwc:      rewritingConn,
		paths:    translator,
		ready:    newReadiness(true, reportServerState),
	}
	s.c.isRemote = true
	s.c.onDiag = func(path string, payload []byte) { bridge.Diagnostics(path, string(payload)) }
	s.c.onProgress = s.ready.progress
	s.c.onFatal = func(err error) {
		bridge.Debug("killing gopls: " + err.Error())
		_ = rewritingConn.Close()
	}

	go s.c.writeLoop(rewritingConn)
	go func() {
		s.c.readLoop(rewritingConn)
		s.c.close()
		_ = rewritingConn.Close()
		close(s.exited)
	}()

	initRootURI, wsFolders := workspaceFoldersFor(cleanRoot)
	res, err := s.c.call("initialize", map[string]any{
		"processId":             os.Getpid(),
		"clientInfo":            map[string]string{"name": "GoLens"},
		"rootUri":               initRootURI,
		"workspaceFolders":      wsFolders,
		"capabilities":          clientCapabilities(),
		"initializationOptions": goplsSettingsFor(true),
	}, initializeBudget, "")
	s.noteSettings(settingsJSONFor(true))
	if err != nil {
		s.kill()
		return nil, fmt.Errorf("initialize: %w", err)
	}
	s.caps = parseCaps(res)
	s.liveMemoryLimit = goplsAppliesMemoryLimitLive(res)
	if err := s.c.notify("initialized", map[string]any{}); err != nil {
		s.kill()
		return nil, err
	}
	bridge.Debug(fmt.Sprintf("gopls initialized (remote vsock :2001, guest root %s, sync kind %d, GOMEMLIMIT sized by guest memory)", translator.GuestWorkspaceRoot, s.caps.SyncKind))
	docs.attach(s)
	s.ready.initializedSent(len(wsFolders))
	return s, nil
}

func startLocalServer(root string, roots []string) (*server, error) {
	goplsPath, err := exec.LookPath("gopls")
	if err != nil {
		return nil, errGoplsNotFound
	}
	cmd := exec.Command(goplsPath, "serve")
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "GOMEMLIMIT="+GoplsMemoryLimit, "GOFLAGS=-p=2")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	s := &server{root: root, cmd: cmd, c: newConn(), exited: make(chan struct{}), started: time.Now(), ready: newReadiness(false, reportServerState)}
	s.c.onDiag = func(path string, payload []byte) { bridge.Diagnostics(path, string(payload)) }
	s.c.onProgress = s.ready.progress
	s.c.onFatal = func(err error) {
		bridge.Debug("killing gopls: " + err.Error())
		if cmd.Process != nil && cmd.Process.Pid > 0 {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			_ = cmd.Process.Kill()
		}
	}
	go s.c.writeLoop(stdin)
	go func() {
		s.c.readLoop(stdout)
		s.c.close()
	}()
	go func() {
		_ = cmd.Wait()
		close(s.exited)
	}()

	initRootURI, wsFolders := workspaceFoldersForRoots(root, roots)
	res, err := s.c.call("initialize", map[string]any{
		"processId":             os.Getpid(),
		"clientInfo":            map[string]string{"name": "GoLens"},
		"rootUri":               initRootURI,
		"workspaceFolders":      wsFolders,
		"capabilities":          clientCapabilities(),
		"initializationOptions": goplsSettingsFor(false),
	}, initializeBudget, "")
	s.noteSettings(settingsJSONFor(false))
	if err != nil {
		s.kill()
		return nil, fmt.Errorf("initialize: %w", err)
	}
	s.caps = parseCaps(res)
	if err := s.c.notify("initialized", map[string]any{}); err != nil {
		s.kill()
		return nil, err
	}
	bridge.Debug(fmt.Sprintf("gopls initialized (local pid %d, sync kind %d, GOMEMLIMIT=%s)", cmd.Process.Pid, s.caps.SyncKind, GoplsMemoryLimit))
	docs.attach(s)
	s.ready.initializedSent(len(wsFolders))
	return s, nil
}

func (s *server) closeReadiness() {
	if s.ready != nil {
		s.ready.close()
	}
}

func (s *server) kill() {
	s.mu.Lock()
	s.stopped = true
	s.mu.Unlock()
	s.closeReadiness()
	if s.isRemote {
		if s.rwc != nil {
			_ = s.rwc.Close()
		}
	} else if s.cmd != nil && s.cmd.Process != nil && s.cmd.Process.Pid > 0 {
		_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
		_ = s.cmd.Process.Kill()
	}
	<-s.exited
	s.c.close()
}

func (s *server) stop() {
	s.mu.Lock()
	if s.stopped {
		s.mu.Unlock()
		return
	}
	s.stopped = true
	s.mu.Unlock()
	s.closeReadiness()
	docs.detach(s)
	_, _ = s.c.call("shutdown", nil, shutdownBudget, "")
	_ = s.c.notify("exit", nil)
	select {
	case <-s.exited:
	case <-time.After(exitWait):
		if s.isRemote {
			if s.rwc != nil {
				_ = s.rwc.Close()
			}
		} else if s.cmd != nil && s.cmd.Process != nil && s.cmd.Process.Pid > 0 {
			_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
			_ = s.cmd.Process.Kill()
		}
		<-s.exited
	}
	if !s.isRemote && s.cmd != nil && s.cmd.Process != nil && s.cmd.Process.Pid > 0 {
		_ = syscall.Kill(-s.cmd.Process.Pid, syscall.SIGKILL)
	}
	if s.rwc != nil {
		_ = s.rwc.Close()
	}
	s.c.close()
	bridge.Debug("gopls stopped for " + s.root)
}

func ServerPID() int {
	life.mu.Lock()
	defer life.mu.Unlock()
	if life.srv == nil {
		return 0
	}
	if life.srv.isRemote && !life.srv.stopped {
		return 2001
	}
	if life.srv.cmd == nil || life.srv.cmd.Process == nil {
		return 0
	}
	return life.srv.cmd.Process.Pid
}

func GetActiveDir() string {
	life.mu.Lock()
	defer life.mu.Unlock()
	return life.root
}
