package docker

import (
	"reflect"
	"strings"
	"testing"
)

func TestClassifyProvider(t *testing.T) {
	cases := []struct{ ctx, endpoint, provider, app string }{
		{"orbstack", "unix:///Users/me/.orbstack/run/docker.sock", "OrbStack", "/Applications/OrbStack.app"},
		{"desktop-linux", "unix:///Users/me/.docker/run/docker.sock", "Docker Desktop", "/Applications/Docker.app"},
		{"default", "unix:///Users/me/.docker/run/docker.sock", "Docker Desktop", "/Applications/Docker.app"},
		{"colima", "unix:///Users/me/.colima/default/docker.sock", "Colima", ""},
		{"rancher-desktop", "unix:///Users/me/.rd/docker.sock", "Rancher Desktop", "/Applications/Rancher Desktop.app"},
		{"default", "unix:///var/run/docker.sock", "", ""},
		{"vps", "ssh://root@example.com", "", ""},
	}
	for _, c := range cases {
		p, app := classifyProvider(c.ctx, c.endpoint)
		if p != c.provider || app != c.app {
			t.Errorf("classifyProvider(%q, %q) = %q, %q", c.ctx, c.endpoint, p, app)
		}
	}
}

func TestBuildTag(t *testing.T) {
	cases := map[string][]string{
		"app:dev": {"docker", "build", "-f", "Dockerfile", "-t", "app:dev", "."},
		"a:1":     {"/opt/homebrew/bin/docker", "buildx", "build", "--tag=a:1", "."},
		"b":       {"docker", "image", "build", "-t=b", "."},
		"":        {"docker", "compose", "build", "-t", "x"},
	}
	for want, argv := range cases {
		if got := buildTag(argv); got != want {
			t.Errorf("buildTag(%v) = %q, want %q", argv, got, want)
		}
	}
	if BuildSummaryHook("docker", []string{"docker", "build", "."}) != nil {
		t.Fatal("untagged build should have no summary hook")
	}
}

func TestHumanSize(t *testing.T) {
	got := []string{humanSize(512), humanSize(12_345_678), humanSize(1_500_000_000)}
	if want := []string{"512 B", "12.3 MB", "1.5 GB"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("humanSize = %v", got)
	}
}

func TestEnvExtendsPath(t *testing.T) {
	t.Setenv("PATH", "/usr/bin")
	var path string
	for _, kv := range Env() {
		if strings.HasPrefix(kv, "PATH=") {
			path = kv
		}
	}
	if !strings.HasPrefix(path, "PATH=/usr/bin:") || !strings.Contains(path, "/opt/homebrew/bin") {
		t.Fatalf("PATH = %q", path)
	}
}
