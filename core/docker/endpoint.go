package docker

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

const (
	KindUnix = "unix"
	KindSSH  = "ssh"
	KindTCP  = "tcp"
)

type Endpoint struct {
	Kind          string `json:"kind"`
	Host          string `json:"host"`
	Socket        string `json:"socket,omitempty"`
	Context       string `json:"context"`
	Source        string `json:"source"`
	TLS           bool   `json:"-"`
	SkipTLSVerify bool   `json:"-"`
	CAFile        string `json:"-"`
	CertFile      string `json:"-"`
	KeyFile       string `json:"-"`
}

func (ep Endpoint) Address() string {
	if ep.Socket != "" {
		return ep.Socket
	}
	return ep.Host
}

func (ep Endpoint) Transport() string {
	if ep.Kind == KindTCP && ep.TLS {
		return "tls"
	}
	return ep.Kind
}

const defaultContextName = "default"

var systemSocket = "/var/run/docker.sock"

type cliConfig struct {
	CurrentContext      string   `json:"currentContext"`
	CLIPluginsExtraDirs []string `json:"cliPluginsExtraDirs"`
}

type contextMeta struct {
	Name     string `json:"Name"`
	Metadata struct {
		Description string `json:"Description"`
	} `json:"Metadata"`
	Endpoints map[string]struct {
		Host          string `json:"Host"`
		SkipTLSVerify bool   `json:"SkipTLSVerify"`
	} `json:"Endpoints"`
}

var chosenContext struct {
	sync.Mutex
	name string
}

func chosenContextName() string {
	chosenContext.Lock()
	defer chosenContext.Unlock()
	return chosenContext.name
}

func configDir() string {
	if d := os.Getenv("DOCKER_CONFIG"); d != "" {
		return d
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".docker")
}

func readCLIConfig() cliConfig {
	var cfg cliConfig
	dir := configDir()
	if dir == "" {
		return cfg
	}
	if data, err := os.ReadFile(filepath.Join(dir, "config.json")); err == nil {
		_ = json.Unmarshal(data, &cfg)
	}
	return cfg
}

func contextDirName(name string) string {
	sum := sha256.Sum256([]byte(name))
	return hex.EncodeToString(sum[:])
}

func readContextMeta(name string) (contextMeta, error) {
	var meta contextMeta
	dir := configDir()
	if dir == "" {
		return meta, fmt.Errorf("no Docker config folder")
	}
	data, err := os.ReadFile(filepath.Join(dir, "contexts", "meta", contextDirName(name), "meta.json"))
	if err != nil {
		return meta, err
	}
	if err := json.Unmarshal(data, &meta); err != nil {
		return meta, err
	}
	if meta.Endpoints["docker"].Host == "" {
		return meta, fmt.Errorf("context %q has no docker endpoint", name)
	}
	return meta, nil
}

func existingFile(p string) string {
	if st, err := os.Stat(p); err == nil && !st.IsDir() {
		return p
	}
	return ""
}

func contextEndpoint(name string, meta contextMeta) (Endpoint, error) {
	docker := meta.Endpoints["docker"]
	ep, err := parseHost(docker.Host)
	ep.Context = name
	if ep.Kind != KindTCP {
		return ep, err
	}
	tlsDir := filepath.Join(configDir(), "contexts", "tls", contextDirName(name), "docker")
	ep.CAFile = existingFile(filepath.Join(tlsDir, "ca.pem"))
	ep.CertFile = existingFile(filepath.Join(tlsDir, "cert.pem"))
	ep.KeyFile = existingFile(filepath.Join(tlsDir, "key.pem"))
	ep.SkipTLSVerify = docker.SkipTLSVerify
	ep.TLS = ep.TLS || ep.SkipTLSVerify || ep.CAFile != "" || ep.CertFile != ""
	return ep, err
}

func envHostEndpoint(host string) (Endpoint, error) {
	ep, err := parseHost(host)
	if ep.Kind != KindTCP {
		return ep, err
	}
	verify := os.Getenv("DOCKER_TLS_VERIFY") != ""
	if verify || os.Getenv("DOCKER_TLS") != "" {
		ep.TLS = true
		ep.SkipTLSVerify = !verify
		dir := os.Getenv("DOCKER_CERT_PATH")
		if dir == "" {
			dir = configDir()
		}
		ep.CAFile = existingFile(filepath.Join(dir, "ca.pem"))
		ep.CertFile = existingFile(filepath.Join(dir, "cert.pem"))
		ep.KeyFile = existingFile(filepath.Join(dir, "key.pem"))
	}
	return ep, err
}

func providerSockets() []string {
	var socks []string
	if home, err := os.UserHomeDir(); err == nil {
		socks = append(socks,
			filepath.Join(home, ".orbstack", "run", "docker.sock"),
			filepath.Join(home, ".docker", "run", "docker.sock"),
			filepath.Join(home, ".colima", "default", "docker.sock"),
			filepath.Join(home, ".config", "colima", "default", "docker.sock"),
			filepath.Join(home, ".rd", "docker.sock"),
		)
	}
	return append(socks, systemSocket)
}

func parseHost(host string) (Endpoint, error) {
	switch {
	case strings.HasPrefix(host, "unix://"):
		path := strings.TrimPrefix(host, "unix://")
		if path == "" {
			return Endpoint{}, fmt.Errorf("Docker host %q names no socket path.", host)
		}
		return Endpoint{Kind: KindUnix, Host: host, Socket: path}, nil
	case strings.HasPrefix(host, "ssh://"):
		return Endpoint{Kind: KindSSH, Host: host}, nil
	case strings.HasPrefix(host, "tcp://"), strings.HasPrefix(host, "http://"):
		return Endpoint{Kind: KindTCP, Host: host}, nil
	case strings.HasPrefix(host, "https://"):
		return Endpoint{Kind: KindTCP, Host: host, TLS: true}, nil
	}
	return Endpoint{}, fmt.Errorf("Docker host %q isn’t a unix://, ssh:// or tcp:// address.", host)
}

func ResolveEndpoint() (Endpoint, error) {
	name, source := chosenContextName(), "golens"
	if name == "" {
		if host := os.Getenv("DOCKER_HOST"); host != "" {
			ep, err := envHostEndpoint(host)
			ep.Context, ep.Source = defaultContextName, "DOCKER_HOST"
			return ep, err
		}
		name, source = os.Getenv("DOCKER_CONTEXT"), "DOCKER_CONTEXT"
		if name == "" {
			name, source = readCLIConfig().CurrentContext, "config"
		}
	}
	if name != "" && name != defaultContextName {
		if meta, err := readContextMeta(name); err == nil {
			ep, err := contextEndpoint(name, meta)
			ep.Source = source
			return ep, err
		}
	} else {
		name = defaultContextName
		if host := os.Getenv("DOCKER_HOST"); host != "" {
			ep, err := envHostEndpoint(host)
			ep.Context, ep.Source = name, "DOCKER_HOST"
			return ep, err
		}
	}
	return defaultSocketEndpoint(name), nil
}

func defaultSocketEndpoint(name string) Endpoint {
	for _, s := range providerSockets() {
		if _, err := os.Stat(s); err == nil {
			return Endpoint{Kind: KindUnix, Host: "unix://" + s, Socket: s, Context: name, Source: "socket"}
		}
	}
	return Endpoint{Kind: KindUnix, Host: "unix://" + systemSocket, Socket: systemSocket, Context: name, Source: "default"}
}

type ContextInfo struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Endpoint    string `json:"endpoint"`
	Transport   string `json:"transport"`
	Current     bool   `json:"current"`
}

type ContextList struct {
	Current  string        `json:"current"`
	Contexts []ContextInfo `json:"contexts"`
	Error    string        `json:"error,omitempty"`
}

func CurrentContext() string {
	ep, _ := ResolveEndpoint()
	if ep.Context == "" {
		return defaultContextName
	}
	return ep.Context
}

func knownContext(name string) bool {
	if name == defaultContextName {
		return true
	}
	_, err := readContextMeta(name)
	return err == nil
}

func Contexts() ContextList {
	current := CurrentContext()
	def := ContextInfo{Name: defaultContextName, Description: "Current DOCKER_HOST based configuration"}
	if host := os.Getenv("DOCKER_HOST"); host != "" {
		ep, _ := envHostEndpoint(host)
		def.Endpoint, def.Transport = host, ep.Transport()
	} else {
		ep := defaultSocketEndpoint(defaultContextName)
		def.Endpoint, def.Transport = ep.Host, ep.Transport()
	}
	out := ContextList{Current: current, Contexts: []ContextInfo{def}}
	dir := configDir()
	var entries []os.DirEntry
	if dir != "" {
		var err error
		entries, err = os.ReadDir(filepath.Join(dir, "contexts", "meta"))
		if err != nil && !os.IsNotExist(err) {
			out.Error = plainError(fmt.Errorf("GoLens couldn’t read the Docker contexts: %v", rootCause(err)))
		}
	}
	var named []ContextInfo
	for _, e := range entries {
		data, err := os.ReadFile(filepath.Join(dir, "contexts", "meta", e.Name(), "meta.json"))
		if err != nil {
			continue
		}
		var meta contextMeta
		if json.Unmarshal(data, &meta) != nil || meta.Name == "" || meta.Name == defaultContextName || meta.Endpoints["docker"].Host == "" {
			continue
		}
		ep, _ := contextEndpoint(meta.Name, meta)
		named = append(named, ContextInfo{Name: meta.Name, Description: meta.Metadata.Description, Endpoint: meta.Endpoints["docker"].Host, Transport: ep.Transport()})
	}
	sort.Slice(named, func(i, j int) bool { return named[i].Name < named[j].Name })
	out.Contexts = append(out.Contexts, named...)
	for i := range out.Contexts {
		out.Contexts[i].Current = out.Contexts[i].Name == current
	}
	return out
}
