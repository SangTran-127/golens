package docker

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type resolverHome struct {
	t    *testing.T
	home string
}

func newResolverHome(t *testing.T) resolverHome {
	home := shortTempDir(t)
	t.Setenv("HOME", home)
	t.Setenv("DOCKER_HOST", "")
	t.Setenv("DOCKER_CONTEXT", "")
	t.Setenv("DOCKER_CONFIG", "")
	old := systemSocket
	systemSocket = filepath.Join(home, "var-run-docker.sock")
	t.Cleanup(func() { systemSocket = old })
	return resolverHome{t: t, home: home}
}

func (h resolverHome) write(rel, content string) string {
	h.t.Helper()
	p := filepath.Join(h.home, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		h.t.Fatal(err)
	}
	return p
}

func (h resolverHome) context(name, host string) {
	h.write(filepath.Join(".docker", "contexts", "meta", contextDirName(name), "meta.json"),
		`{"Name":"`+name+`","Metadata":{},"Endpoints":{"docker":{"Host":"`+host+`","SkipTLSVerify":false}}}`)
}

func resolve(t *testing.T) Endpoint {
	t.Helper()
	ep, err := ResolveEndpoint()
	if err != nil {
		t.Fatalf("ResolveEndpoint: %v", err)
	}
	return ep
}

func TestContextDirNameMatchesDockerCLIDigest(t *testing.T) {
	if got := contextDirName("orbstack"); got != "2d89b732b01a00a2d1675ed3cee9fd0f965daadf90603c989dd3afd4569c6896" {
		t.Fatalf("contextDirName(orbstack) = %s", got)
	}
}

func TestResolveOrder(t *testing.T) {
	h := newResolverHome(t)
	h.write(".docker/config.json", `{"auths":{},"currentContext":"orbstack"}`)
	h.context("orbstack", "unix:///ctx/orbstack.sock")
	h.context("colima", "unix:///ctx/colima.sock")
	orb := h.write(".orbstack/run/docker.sock", "")

	t.Setenv("DOCKER_HOST", "unix:///env/host.sock")
	t.Setenv("DOCKER_CONTEXT", "colima")
	if ep := resolve(t); ep.Socket != "/env/host.sock" || ep.Source != "DOCKER_HOST" || ep.Context != "default" {
		t.Fatalf("DOCKER_HOST should win: %+v", ep)
	}

	t.Setenv("DOCKER_HOST", "")
	if ep := resolve(t); ep.Socket != "/ctx/colima.sock" || ep.Context != "colima" || ep.Source != "DOCKER_CONTEXT" {
		t.Fatalf("DOCKER_CONTEXT should win over config: %+v", ep)
	}

	t.Setenv("DOCKER_CONTEXT", "")
	if ep := resolve(t); ep.Socket != "/ctx/orbstack.sock" || ep.Context != "orbstack" || ep.Source != "config" {
		t.Fatalf("config currentContext should be used: %+v", ep)
	}

	h.write(".docker/config.json", `{"currentContext":"gone"}`)
	if ep := resolve(t); ep.Socket != orb || ep.Context != "gone" || ep.Source != "socket" {
		t.Fatalf("missing context meta should fall back to provider sockets: %+v", ep)
	}

	h.write(".docker/config.json", `{}`)
	if ep := resolve(t); ep.Socket != orb || ep.Context != "default" {
		t.Fatalf("no context should use provider sockets: %+v", ep)
	}
}

func TestResolveDockerConfigOverride(t *testing.T) {
	h := newResolverHome(t)
	alt := filepath.Join(h.home, "alt")
	t.Setenv("DOCKER_CONFIG", alt)
	h.write("alt/config.json", `{"currentContext":"desktop-linux"}`)
	h.write(filepath.Join("alt", "contexts", "meta", contextDirName("desktop-linux"), "meta.json"),
		`{"Name":"desktop-linux","Endpoints":{"docker":{"Host":"unix:///alt/docker.sock"}}}`)
	if ep := resolve(t); ep.Socket != "/alt/docker.sock" || ep.Context != "desktop-linux" {
		t.Fatalf("DOCKER_CONFIG folder should be read: %+v", ep)
	}
}

func TestResolveProviderSocketOrder(t *testing.T) {
	h := newResolverHome(t)
	sys := h.write("var-run-docker.sock", "")
	if ep := resolve(t); ep.Socket != sys || ep.Source != "socket" {
		t.Fatalf("system socket should be found last: %+v", ep)
	}
	rd := h.write(".rd/docker.sock", "")
	if ep := resolve(t); ep.Socket != rd {
		t.Fatalf("Rancher Desktop before the system socket: %+v", ep)
	}
	colima := h.write(".colima/default/docker.sock", "")
	if ep := resolve(t); ep.Socket != colima {
		t.Fatalf("Colima before Rancher Desktop: %+v", ep)
	}
	desktop := h.write(".docker/run/docker.sock", "")
	if ep := resolve(t); ep.Socket != desktop {
		t.Fatalf("Docker Desktop before Colima: %+v", ep)
	}
	orb := h.write(".orbstack/run/docker.sock", "")
	if ep := resolve(t); ep.Socket != orb {
		t.Fatalf("OrbStack first: %+v", ep)
	}
}

func TestResolveNothingFoundUsesSystemSocket(t *testing.T) {
	newResolverHome(t)
	ep := resolve(t)
	if ep.Kind != KindUnix || ep.Socket != systemSocket || ep.Source != "default" || ep.Context != "default" {
		t.Fatalf("fallback = %+v", ep)
	}
}

func TestResolveKinds(t *testing.T) {
	h := newResolverHome(t)
	h.write(".docker/config.json", `{"currentContext":"vps"}`)
	h.context("vps", "ssh://root@example.com")
	ep := resolve(t)
	if ep.Kind != KindSSH || ep.Host != "ssh://root@example.com" || ep.Context != "vps" {
		t.Fatalf("ssh context = %+v", ep)
	}
	old := SSHDialer
	t.Cleanup(func() { SSHDialer = old })
	SSHDialer = nil
	_, err := NewClient(ep)
	if err == nil || !strings.Contains(err.Error(), "ssh://root@example.com") || !strings.Contains(err.Error(), "can’t open SSH connections") {
		t.Fatalf("ssh endpoint without a dialer should be refused clearly: %v", err)
	}
	SSHDialer = func(context.Context, string) (net.Conn, error) { return nil, errors.New("unused") }
	if c, err := NewClient(ep); err != nil || c.scheme != "http" {
		t.Fatalf("ssh endpoint with a dialer = %+v, %v", c, err)
	}

	t.Setenv("DOCKER_HOST", "tcp://10.0.0.2:2376")
	ep = resolve(t)
	if ep.Kind != KindTCP || ep.TLS || ep.Transport() != "tcp" {
		t.Fatalf("tcp host = %+v", ep)
	}
	if c, err := NewClient(ep); err != nil || c.scheme != "http" {
		t.Fatalf("plain tcp client = %+v, %v", c, err)
	}

	t.Setenv("DOCKER_HOST", "npipe:////./pipe/docker_engine")
	if _, err := ResolveEndpoint(); err == nil {
		t.Fatal("an unknown scheme should fail")
	}
}
