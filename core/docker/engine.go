package docker

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type EngineStatus struct {
	State          string `json:"state"`
	CLIPath        string `json:"cliPath"`
	CLIVersion     string `json:"cliVersion"`
	ComposeVersion string `json:"composeVersion"`
	Context        string `json:"context"`
	Endpoint       string `json:"endpoint"`
	ServerVersion  string `json:"serverVersion"`
	Provider       string `json:"provider"`
	ProviderApp    string `json:"providerApp"`
	Error          string `json:"error"`
}

var statusTimeout = 2 * time.Second

var composeCache struct {
	sync.Mutex
	version string
	missing bool
	err     string
}

func Status(dir string) EngineStatus {
	st := EngineStatus{State: "missingCLI"}
	ep, epErr := ResolveEndpoint()
	st.Context, st.Endpoint = ep.Context, ep.Host
	st.Provider, st.ProviderApp = providerFor(ep)
	composeCache.Lock()
	composeMissing, composeErr := composeCache.missing, composeCache.err
	st.ComposeVersion = composeCache.version
	composeCache.Unlock()
	if st.ComposeVersion == "" && composePluginPath() != "" {
		st.ComposeVersion = "Installed"
	}
	cli := LookPath("docker")
	if cli == "" {
		st.Error = "docker was not found on PATH, /opt/homebrew/bin, /usr/local/bin, ~/.orbstack/bin or Docker.app."
		return st
	}
	st.CLIPath = cli

	server, err := probeEngine(ep, epErr)
	st.ServerVersion = server
	switch {
	case composeMissing:
		st.State = "missingCompose"
		st.Error = composeErr
	case err != nil:
		st.State = "engineDown"
		st.Error = err.Error()
	default:
		st.State = "ok"
	}
	return st
}

func probeEngine(ep Endpoint, epErr error) (string, error) {
	if epErr != nil {
		return "", epErr
	}
	c, err := NewClient(ep)
	if err != nil {
		return "", err
	}
	c.CloseAfter = true
	ctx, cancel := context.WithTimeout(context.Background(), timeoutFor(ep, statusTimeout))
	defer cancel()
	if err := c.Negotiate(ctx); err != nil {
		return "", err
	}
	v, err := c.Version(ctx)
	if err != nil {
		return "", err
	}
	return v.Version, nil
}

func providerFor(ep Endpoint) (provider, app string) {
	provider, app = classifyProvider(ep.Context, ep.Host)
	if provider == "" && ep.Socket != "" {
		if target, err := os.Readlink(ep.Socket); err == nil {
			provider, app = classifyProvider("", target)
		}
	}
	if _, err := os.Stat(app); app == "" || err != nil {
		app = ""
	}
	return provider, app
}

func ComposeVersion(dir string) (string, error) {
	composeCache.Lock()
	cached := composeCache.version
	composeCache.Unlock()
	if cached != "" {
		return cached, nil
	}
	cli := LookPath("docker")
	if cli == "" {
		return "", errors.New("docker was not found on PATH, /opt/homebrew/bin, /usr/local/bin, ~/.orbstack/bin or Docker.app.")
	}
	out, errOut, err := runCLI(10*time.Second, dir, "", cli, "compose", "version", "--short")
	version := strings.TrimSpace(out)
	composeCache.Lock()
	defer composeCache.Unlock()
	if err != nil || version == "" {
		msg := strings.TrimSpace(errOut)
		if msg == "" {
			msg = "The docker compose plugin isn’t installed."
		}
		composeCache.missing, composeCache.err = true, msg
		return "", errors.New(msg)
	}
	composeCache.version, composeCache.missing, composeCache.err = version, false, ""
	return version, nil
}

func composePluginPath() string {
	dirs := []string{}
	if d := configDir(); d != "" {
		dirs = append(dirs, filepath.Join(d, "cli-plugins"))
	}
	dirs = append(dirs, readCLIConfig().CLIPluginsExtraDirs...)
	dirs = append(dirs,
		"/usr/local/lib/docker/cli-plugins",
		"/usr/local/libexec/docker/cli-plugins",
		"/usr/lib/docker/cli-plugins",
		"/usr/libexec/docker/cli-plugins",
		"/opt/homebrew/lib/docker/cli-plugins",
		"/Applications/Docker.app/Contents/Resources/cli-plugins",
	)
	for _, d := range dirs {
		if p := filepath.Join(d, "docker-compose"); isExecutable(p) {
			return p
		}
	}
	return ""
}

func statusCLI(dir string) EngineStatus {
	st := EngineStatus{State: "missingCLI"}
	cli := LookPath("docker")
	if cli == "" {
		st.Error = "docker was not found on PATH, /opt/homebrew/bin, /usr/local/bin, ~/.orbstack/bin or Docker.app."
		return st
	}
	st.CLIPath = cli

	var (
		wg                     sync.WaitGroup
		versionOut, versionErr string
		versionFailed          bool
		composeOut, composeErr string
		composeFailed          bool
		contextName, endpoint  string
	)
	wg.Go(func() {
		out, errOut, err := runCLI(4*time.Second, dir, "", cli, "version", "--format", `{{.Client.Version}}{{"\n"}}{{if .Server}}{{.Server.Version}}{{end}}`)
		versionOut, versionErr, versionFailed = out, errOut, err != nil
	})
	wg.Go(func() {
		out, errOut, err := runCLI(3*time.Second, dir, "", cli, "compose", "version", "--short")
		composeOut, composeErr, composeFailed = out, errOut, err != nil
	})
	wg.Go(func() {
		out, _, err := runCLI(3*time.Second, dir, "", cli, "context", "show")
		if err != nil {
			return
		}
		contextName = strings.TrimSpace(out)
		if contextName == "" {
			return
		}
		out, _, err = runCLI(2*time.Second, dir, "", cli, "context", "inspect", "--format", "{{.Endpoints.docker.Host}}", contextName)
		if err == nil {
			endpoint = strings.TrimSpace(out)
		}
	})
	wg.Wait()

	versions := strings.SplitN(strings.TrimSpace(versionOut), "\n", 2)
	st.CLIVersion = strings.TrimSpace(versions[0])
	if len(versions) > 1 {
		st.ServerVersion = strings.TrimSpace(versions[1])
	}
	st.ComposeVersion = strings.TrimSpace(composeOut)
	st.Context = contextName
	st.Endpoint = endpoint
	if host := os.Getenv("DOCKER_HOST"); host != "" && st.Endpoint == "" {
		st.Endpoint = host
	}
	provider, app := classifyProvider(st.Context, st.Endpoint)
	if provider == "" {
		if sock, ok := strings.CutPrefix(st.Endpoint, "unix://"); ok {
			if target, err := os.Readlink(sock); err == nil {
				provider, app = classifyProvider("", target)
			}
		}
	}
	st.Provider = provider
	if _, err := os.Stat(app); app != "" && err == nil {
		st.ProviderApp = app
	}

	switch {
	case composeFailed || st.ComposeVersion == "":
		st.State = "missingCompose"
		st.Error = strings.TrimSpace(composeErr)
	case versionFailed || st.ServerVersion == "":
		st.State = "engineDown"
		st.Error = strings.TrimSpace(versionErr)
	default:
		st.State = "ok"
	}
	return st
}

func StatusJSON(dir string) string {
	b, err := json.Marshal(Status(dir))
	if err != nil {
		return `{"state":"missingCLI","error":"failed to encode status"}`
	}
	return string(b)
}

func classifyProvider(contextName, endpoint string) (provider, app string) {
	s := strings.ToLower(contextName + " " + endpoint)
	switch {
	case strings.Contains(s, "orbstack"):
		return "OrbStack", "/Applications/OrbStack.app"
	case strings.Contains(s, "colima"):
		return "Colima", ""
	case strings.Contains(s, "rancher-desktop") || strings.Contains(s, "/.rd/"):
		return "Rancher Desktop", "/Applications/Rancher Desktop.app"
	case strings.Contains(s, "docker-desktop") || strings.Contains(s, "desktop-linux") || strings.Contains(s, "/.docker/run/docker.sock"):
		return "Docker Desktop", "/Applications/Docker.app"
	}
	return "", ""
}
