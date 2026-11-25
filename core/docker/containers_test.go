package docker

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func hexID(seed string) string {
	return strings.Repeat(seed, 64)[:64]
}

func seedProject(s *svcEngine, ws string) (api, redis, shop, plain *svcContainer) {
	api = s.add(&svcContainer{ID: hexID("a1"), Name: "velo-api-1", Image: "velo-api", ImageID: "sha256:" + hexID("e1"),
		Status: "Up 2 minutes (healthy)", Labels: composeLabels("velo", "api", ws),
		Ports: []map[string]any{
			{"IP": "0.0.0.0", "PrivatePort": 8080, "PublicPort": 8080, "Type": "tcp"},
			{"IP": "::", "PrivatePort": 8080, "PublicPort": 8080, "Type": "tcp"},
			{"PrivatePort": 9090, "Type": "tcp"},
		},
		Env:  []string{"DATABASE_URL=postgres://app:s3cret@db/app", "EMPTY="},
		Logs: []fakeLogLine{{Text: "listening on :8080"}, {Stderr: true, Text: "warning: debug mode"}},
	})
	redis = s.add(&svcContainer{ID: hexID("b2"), Name: "velo-redis-1", Image: "redis:7", ImageID: "sha256:" + hexID("e2"),
		State: "exited", Status: "Exited (1) 2 minutes ago", Labels: composeLabels("velo", "redis", ws),
		Mounts: []map[string]any{{"Type": "volume", "Name": "redisdata"}},
		Logs:   []fakeLogLine{{Text: "Ready to accept connections"}},
	})
	shop = s.add(&svcContainer{ID: hexID("c3"), Name: "shop-web-1", Image: "nginx", ImageID: "sha256:" + hexID("e3"),
		Labels: composeLabels("shop", "web", "/Users/me/src/shop"), Logs: []fakeLogLine{{Text: "nginx ready"}}})
	plain = s.add(&svcContainer{ID: hexID("d4"), Name: "scratch", Image: "alpine", ImageID: "sha256:" + hexID("e3"),
		Labels: map[string]string{}, Tty: true, Logs: []fakeLogLine{{Text: "tty line"}}})
	return
}

func TestSnapshotGroupsComposeProjects(t *testing.T) {
	s := newSvcEngine(t)
	ws := "/Users/me/src/velo"
	seedProject(s, ws)
	snap := TakeSnapshot(Scope{Workspace: ws})
	if snap.Engine.State != "running" || snap.Engine.APIVersion != "1.47" || snap.Engine.Endpoint != "unix://"+s.Socket {
		t.Fatalf("engine = %+v", snap.Engine)
	}
	names := []string{}
	for _, c := range snap.Containers {
		names = append(names, c.Name)
	}
	if want := []string{"scratch", "shop-web-1", "velo-api-1", "velo-redis-1"}; !reflect.DeepEqual(names, want) {
		t.Fatalf("containers = %v", names)
	}
	if len(snap.Projects) != 2 || snap.Projects[0].Name != "velo" || !snap.Projects[0].ThisProject || snap.Projects[1].ThisProject {
		t.Fatalf("projects = %+v", snap.Projects)
	}
	if p := snap.Projects[0]; p.Running != 1 || len(p.ContainerIDs) != 2 || p.WorkingDir != ws || p.ConfigFiles[0] != ws+"/compose.yaml" {
		t.Fatalf("velo project = %+v", p)
	}
	api := snap.Containers[2]
	if api.Service != "api" || api.Health != "healthy" || api.ExitCode != nil {
		t.Fatalf("api = %+v", api)
	}
	if want := []Port{{PrivatePort: 8080, PublicPort: 8080, Type: "tcp"}, {PrivatePort: 9090, Type: "tcp"}}; !reflect.DeepEqual(api.Ports, want) {
		t.Fatalf("ports = %+v", api.Ports)
	}
	if redis := snap.Containers[3]; redis.ExitCode == nil || *redis.ExitCode != 1 || redis.State != "exited" {
		t.Fatalf("redis = %+v", redis)
	}
	byFile := TakeSnapshot(Scope{ComposeFile: "/Users/me/src/shop/compose.yaml"})
	if !byFile.Projects[0].ThisProject || byFile.Projects[0].Name != "shop" {
		t.Fatalf("compose file scope = %+v", byFile.Projects)
	}
}

func TestScopeMatchesOnlyInsideWorkspace(t *testing.T) {
	s := Scope{Workspace: "/Users/me/src/velo"}
	cases := map[string]bool{"/Users/me/src/velo": true, "/Users/me/src/velo/deploy": true, "/Users/me/src/velocity": false, "": false}
	for dir, want := range cases {
		if got := s.matches(dir, nil); got != want {
			t.Errorf("matches(%q) = %v", dir, got)
		}
	}
}

func TestSnapshotEngineDown(t *testing.T) {
	t.Setenv("DOCKER_HOST", "unix://"+filepath.Join(shortTempDir(t), "missing.sock"))
	resetServicesState(t)
	snap := TakeSnapshot(Scope{})
	if snap.Engine.State != "down" || snap.Engine.Reason != ReasonDown || !strings.Contains(snap.Engine.Error, "isn’t running") {
		t.Fatalf("engine = %+v", snap.Engine)
	}
	if snap.Containers == nil || snap.Projects == nil {
		t.Fatal("lists must be empty arrays, not null")
	}
}

func TestContainerActions(t *testing.T) {
	s := newSvcEngine(t)
	_, redis, _, _ := seedProject(s, "/w")
	api := hexID("a1")
	for _, action := range []string{"stop", "start", "restart"} {
		if res := ContainerAction(api, action); !res.OK || res.Error != "" {
			t.Fatalf("%s = %+v", action, res)
		}
	}
	if res := ContainerAction(api, "start"); !res.OK {
		t.Fatalf("start of a running container should be ok (304): %+v", res)
	}
	actions, _, _, _ := s.snapshot()
	want := []string{"stop " + api + " t=10", "start " + api + " ", "restart " + api + " t=10", "start " + api + " "}
	if !reflect.DeepEqual(actions, want) {
		t.Fatalf("actions = %q", actions)
	}
	if res := ContainerAction(redis.ID, "remove"); res.OK || !strings.Contains(res.Error, "can’t remove") {
		t.Fatalf("remove through an action must be refused: %+v", res)
	}
	if res := ContainerAction(hexID("ff"), "stop"); res.OK || res.Error != "Container ffffffffffff no longer exists." {
		t.Fatalf("missing = %+v", res)
	}
}

func TestStopTimeoutIsOnePlainSentence(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	oldGrace, oldTimeout := stopGrace, actionTimeout
	stopGrace, actionTimeout = 0, 300*time.Millisecond
	t.Cleanup(func() { stopGrace, actionTimeout = oldGrace, oldTimeout })
	s.mu.Lock()
	s.actionWait = 2 * time.Second
	s.mu.Unlock()
	res := ContainerAction(hexID("a1"), "stop")
	if res.OK || !strings.HasPrefix(res.Error, "Couldn’t stop “velo-api-1”. The engine didn’t respond within ") || strings.Count(res.Error, ".") != 2 {
		t.Fatalf("timeout = %+v", res)
	}
}

func TestInspectIsTrimmed(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/Users/me/src/velo")
	res := InspectContainer("velo-api-1")
	d := res.Container
	if res.Error != "" || d == nil {
		t.Fatalf("inspect = %+v", res)
	}
	if d.Name != "velo-api-1" || d.Image != "velo-api" || d.Command != "/app/server --addr :8080" || d.RestartPolicy != "on-failure:3" ||
		d.Health != "healthy" || d.Service != "api" || d.Project != "velo" || d.State != "running" {
		t.Fatalf("details = %+v", d)
	}
	if want := []KeyValue{{"DATABASE_URL", "postgres://app:s3cret@db/app"}, {"EMPTY", ""}}; !reflect.DeepEqual(d.Env, want) {
		t.Fatalf("env = %+v", d.Env)
	}
	if want := []Port{{PrivatePort: 8080, PublicPort: 8080, Type: "tcp"}, {PrivatePort: 9090, Type: "tcp"}}; !reflect.DeepEqual(d.Ports, want) {
		t.Fatalf("ports = %+v", d.Ports)
	}
	if len(d.Mounts) != 1 || d.Mounts[0].Name != "pgdata" || d.Mounts[0].ReadOnly || len(d.Networks) != 1 || d.Networks[0].IPAddress != "172.18.0.2" {
		t.Fatalf("mounts/networks = %+v %+v", d.Mounts, d.Networks)
	}
	if len(d.Labels) != 4 || d.Labels[0].Key != labelProject {
		t.Fatalf("labels = %+v", d.Labels)
	}
	if res := InspectContainer("nope"); res.Container != nil || res.Error != "Container nope no longer exists." {
		t.Fatalf("missing = %+v", res)
	}
}
