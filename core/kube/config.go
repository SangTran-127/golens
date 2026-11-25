package kube

import (
	"encoding/json"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golens/core/docker"

	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

type ContextInfo struct {
	Name       string `json:"name"`
	Cluster    string `json:"cluster"`
	User       string `json:"user"`
	Namespace  string `json:"namespace"`
	Server     string `json:"server"`
	Local      bool   `json:"local"`
	Current    bool   `json:"current"`
	AuthPlugin string `json:"authPlugin,omitempty"`
}

type ContextsReply struct {
	Available bool          `json:"available"`
	Current   string        `json:"current"`
	Contexts  []ContextInfo `json:"contexts"`
	Error     *Error        `json:"error,omitempty"`
}

func loadingRules() *clientcmd.ClientConfigLoadingRules {
	r := clientcmd.NewDefaultClientConfigLoadingRules()
	r.MigrationRules = nil
	return r
}

func existingFiles(r *clientcmd.ClientConfigLoadingRules) []string {
	var out []string
	for _, p := range r.GetLoadingPrecedence() {
		if st, err := os.Stat(p); err == nil && st.Mode().IsRegular() {
			out = append(out, p)
		}
	}
	return out
}

func loadConfig() (*clientcmdapi.Config, bool, error) {
	r := loadingRules()
	if len(existingFiles(r)) == 0 {
		return clientcmdapi.NewConfig(), false, nil
	}
	cfg, err := r.Load()
	if err != nil {
		return nil, true, &Error{Kind: KindConfig, Message: "GoLens couldn’t read your kubeconfig: " + firstLine(err.Error())}
	}
	return cfg, true, nil
}

func Contexts() ContextsReply {
	cfg, ok, err := loadConfig()
	reply := ContextsReply{Available: ok, Contexts: []ContextInfo{}}
	if err != nil {
		reply.Error = asError(err)
		return reply
	}
	reply.Current = cfg.CurrentContext
	for name, c := range cfg.Contexts {
		info := ContextInfo{Name: name, Cluster: c.Cluster, User: c.AuthInfo, Namespace: namespaceOf(c), Current: name == cfg.CurrentContext}
		if cl := cfg.Clusters[c.Cluster]; cl != nil {
			info.Server = cl.Server
		}
		if u := cfg.AuthInfos[c.AuthInfo]; u != nil && u.Exec != nil {
			info.AuthPlugin = filepath.Base(u.Exec.Command)
		}
		info.Local = looksLocal(name, info.Server)
		reply.Contexts = append(reply.Contexts, info)
	}
	sort.Slice(reply.Contexts, func(i, j int) bool { return reply.Contexts[i].Name < reply.Contexts[j].Name })
	return reply
}

func namespaceOf(c *clientcmdapi.Context) string {
	if c != nil && c.Namespace != "" {
		return c.Namespace
	}
	return "default"
}

var localContextPrefixes = []string{"kind-", "k3d-", "minikube", "docker-desktop", "docker-for-desktop", "orbstack", "rancher-desktop", "colima"}

func looksLocal(name, server string) bool {
	for _, p := range localContextPrefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	u, err := url.Parse(server)
	if err != nil || u.Hostname() == "" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	switch {
	case host == "localhost", strings.HasSuffix(host, ".localhost"), host == "kubernetes.docker.internal", host == "host.docker.internal",
		strings.HasSuffix(host, ".local"):
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

type resolved struct {
	name      string
	namespace string
	server    string
	rest      *rest.Config
	exec      *clientcmdapi.ExecConfig
	key       string
}

func resolveContext(name string) (*resolved, error) {
	cfg, ok, err := loadConfig()
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, &Error{Kind: KindConfig, Message: "No kubeconfig file was found."}
	}
	if name == "" {
		name = cfg.CurrentContext
	}
	c := cfg.Contexts[name]
	if c == nil {
		return nil, &Error{Kind: KindConfig, Message: "The context “" + name + "” isn’t in your kubeconfig."}
	}
	r := &resolved{name: name, namespace: namespaceOf(c)}
	if cl := cfg.Clusters[c.Cluster]; cl != nil {
		r.server = cl.Server
	}
	if u := cfg.AuthInfos[c.AuthInfo]; u != nil && u.Exec != nil {
		ex := u.Exec.DeepCopy()
		plugin := filepath.Base(ex.Command)
		path := docker.LookPath(ex.Command)
		if path == "" {
			return nil, pluginMissing(name, plugin)
		}
		ex.Command = path
		if !hasEnv(ex.Env, "PATH") {
			ex.Env = append(ex.Env, clientcmdapi.ExecEnvVar{Name: "PATH", Value: extendedPATH()})
		}
		u.Exec = ex
		r.exec = ex
	}
	key, err := json.Marshal([]any{c, cfg.Clusters[c.Cluster], cfg.AuthInfos[c.AuthInfo]})
	if err != nil {
		return nil, &Error{Kind: KindConfig, Message: "The context “" + name + "” can’t be used: " + firstLine(err.Error())}
	}
	r.key = string(key)
	rc, err := clientcmd.NewNonInteractiveClientConfig(*cfg, name, &clientcmd.ConfigOverrides{}, nil).ClientConfig()
	if err != nil {
		return nil, &Error{Kind: KindConfig, Server: r.server, Message: "The context “" + name + "” can’t be used: " + firstLine(err.Error())}
	}
	r.rest = rc
	return r, nil
}

func hasEnv(env []clientcmdapi.ExecEnvVar, name string) bool {
	for _, e := range env {
		if e.Name == name {
			return true
		}
	}
	return false
}

func extendedPATH() string {
	for _, kv := range docker.Env() {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			return v
		}
	}
	return os.Getenv("PATH")
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = strings.TrimSpace(s[:i])
	}
	return s
}
