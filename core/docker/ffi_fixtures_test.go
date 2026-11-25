package docker

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

var updateFixtures = flag.Bool("update", false, "rewrite the golden FFI fixtures")

func fixtureContainers() []Container {
	ws := "/Users/me/src/velo"
	raw := []apiContainer{
		{ID: hexID("a1"), Names: []string{"/velo-api-1"}, Image: "velo-api", ImageID: "sha256:" + hexID("e1"), Command: "/app/server",
			Created: 1763222400, State: "running", Status: "Up 2 minutes (healthy)", Labels: composeLabels("velo", "api", ws)},
		{ID: hexID("b2"), Names: []string{"/velo-redis-1"}, Image: "redis:7", ImageID: "sha256:" + hexID("e2"), Command: "docker-entrypoint.sh redis-server",
			Created: 1763222300, State: "exited", Status: "Exited (1) 2 minutes ago", Labels: composeLabels("velo", "redis", ws)},
		{ID: hexID("d4"), Names: []string{"/scratch"}, Image: "alpine", ImageID: "sha256:" + hexID("e3"), Command: "sh",
			Created: 1763200000, State: "running", Status: "Up 6 hours", Labels: map[string]string{}},
	}
	raw[0].Ports = append(raw[0].Ports, struct {
		IP          string `json:"IP"`
		PrivatePort int    `json:"PrivatePort"`
		PublicPort  int    `json:"PublicPort"`
		Type        string `json:"Type"`
	}{IP: "0.0.0.0", PrivatePort: 8080, PublicPort: 8080, Type: "tcp"})
	out := []Container{}
	for _, a := range raw {
		out = append(out, containerFromAPI(a))
	}
	sortContainers(out)
	return out
}

func fixtureEngine() EngineState {
	return EngineState{State: "running", Endpoint: "unix:///Users/me/.orbstack/run/docker.sock", Context: "orbstack", Provider: "OrbStack", APIVersion: "1.51"}
}

func ffiFixtures() map[string]any {
	containers := fixtureContainers()
	down := EngineState{State: "down", Reason: ReasonDown, Error: "Docker Engine isn’t running at /Users/me/.orbstack/run/docker.sock.",
		Endpoint: "unix:///Users/me/.orbstack/run/docker.sock", Context: "orbstack", Provider: "OrbStack"}
	reconnecting := down
	reconnecting.State = "reconnecting"
	restarted := containers[2]
	restarted.State, restarted.Status = "running", "Up Less than a second"
	restarted.ExitCode = nil
	scope := Scope{Workspace: "/Users/me/src/velo", ComposeFile: "/Users/me/src/velo/compose.yaml"}
	inspect := detailsFromAPI(apiInspectFixture())
	return map[string]any{
		"snapshot-request":              scope,
		"snapshot-response":             Snapshot{Engine: fixtureEngine(), Containers: containers, Projects: groupProjects(containers, scope)},
		"snapshot-response-engine-down": Snapshot{Engine: down, Containers: []Container{}, Projects: []Project{}},
		"watch-start-request":           []string{"containers", "images", "volumes"},
		"event-batch-reset": Batch{Seq: 1, Reset: true, Upserts: containers, Removals: []string{}, Invalidated: []string{"images", "volumes"},
			Engine: fixtureEngine()},
		"event-batch": Batch{Seq: 2, Upserts: []Container{restarted}, Removals: []string{hexID("d4")}, Invalidated: []string{"images"},
			Engine: fixtureEngine()},
		"event-batch-reconnecting":        Batch{Seq: 3, Upserts: []Container{}, Removals: []string{}, Invalidated: []string{}, Engine: reconnecting},
		"container-action-response-ok":    ActionResult{OK: true},
		"container-action-response-error": ActionResult{Error: "Couldn’t stop “velo-api-1”. The engine didn’t respond within 15 seconds."},
		"inspect-response":                InspectResult{Container: &inspect},
		"inspect-response-error":          InspectResult{Error: "Container 0123456789ab no longer exists."},
		"logs-open-request":               []string{hexID("a1"), hexID("b2")},
		"event-logs": LogsEvent{Stream: 4, Lines: []LogLine{
			{Text: "listening on :8080"}, {Text: "warning: debug mode", Stderr: true}}},
		"event-logs-merged": LogsEvent{Stream: 5, Dropped: 120, Lines: []LogLine{
			{Text: "listening on :8080", Prefix: "api"}, {Text: "Ready to accept connections", Prefix: "redis"}}},
		"event-logs-closed-removed": LogsEvent{Stream: 4, Lines: []LogLine{}, Closed: true, Reason: "removed"},
		"event-logs-closed-error": LogsEvent{Stream: 4, Lines: []LogLine{}, Closed: true, Reason: "error",
			Error: "Docker Engine isn’t running at /Users/me/.orbstack/run/docker.sock."},
		"list-images-response": ListResult{Kind: "images", Items: []Image{
			{ID: "sha256:" + hexID("e1"), Name: "velo-api:latest", Tags: []string{"velo-api:latest", "golens/api:dev"}, Size: 182000000,
				Created: 1763222000, InUse: true, UsedBy: []string{"velo-api-1"}},
			{ID: "sha256:" + hexID("e9"), Name: hexID("e9")[:12], Tags: []string{}, Size: 5000000, Created: 1762000000, Dangling: true, UsedBy: []string{}},
		}},
		"list-volumes-response": ListResult{Kind: "volumes", Items: []Volume{
			{Name: "orphan", Driver: "local", Mountpoint: "/var/lib/docker/volumes/orphan/_data", Created: "2026-11-14T10:00:00Z", UsedBy: []string{}},
			{Name: "redisdata", Driver: "local", Mountpoint: "/var/lib/docker/volumes/redisdata/_data", Created: "2026-11-15T10:00:00Z",
				Project: "velo", InUse: true, UsedBy: []string{"velo-redis-1"}},
		}},
		"list-response-error":    ListResult{Kind: "images", Items: []any{}, Error: "Docker Engine isn’t running at /Users/me/.orbstack/run/docker.sock."},
		"remove-request":         map[string]string{"kind": "image", "id": "sha256:" + hexID("e1")},
		"remove-response-ok":     ActionResult{OK: true},
		"remove-response-in-use": ActionResult{Error: "“velo-api:latest” is used by velo-api-1; remove those containers first."},
		"start-terminal-command-request": []string{"docker", "exec", "-it", hexID("a1"), "sh", "-c",
			"if command -v bash >/dev/null; then exec bash; else exec sh; fi"},
		"snapshot-response-engine-issue": Snapshot{Engine: remoteIssueEngine(), Containers: []Container{}, Projects: []Project{}},
		"list-networks-response": ListResult{Kind: "network", Items: []NetworkInfo{
			{ID: hexID("n4"), Name: "velo_default", Driver: "bridge", Scope: "local", Containers: []string{"velo-api-1", "velo-redis-1"}, Created: "2026-11-15T10:00:00Z"},
			{ID: hexID("n1"), Name: "bridge", Driver: "bridge", Scope: "local", BuiltIn: true, Containers: []string{}, Created: "2026-11-01T10:00:00Z"},
		}},
		"remove-network-response-in-use": ActionResult{Error: "Network “velo_default” is used by velo-api-1 and velo-redis-1; remove those containers first."},
		"disk-usage-response": DiskUsage{Categories: []DiskCategory{
			{Kind: PruneContainers, Count: 3, Bytes: 2300}, {Kind: PruneImages, Count: 2, Bytes: 8000000}, {Kind: PruneVolumes, Count: 2, Bytes: 70010},
			{Kind: PruneNetworks, Count: 2}, {Kind: PruneBuildCache, Count: 3, Bytes: 1000}}},
		"disk-usage-response-error": DiskUsage{Categories: []DiskCategory{}, Error: "Docker Engine isn’t running at /Users/me/.orbstack/run/docker.sock."},
		"prune-request":             PruneOptions{Kind: PruneVolumes, Label: "golens.smoke=1"},
		"prune-response":            PruneResult{Kind: PruneVolumes, Removed: 2, Bytes: 70010},
		"prune-response-error": PruneResult{Kind: PruneBuildCache,
			Error: "Build cache has no labels, so GoLens can’t limit its clean-up to “golens.smoke=1”; nothing was removed."},
		"event-stats":              StatsEvent{Stream: 3, ID: hexID("a1"), CPUPercent: 3.2, MemoryBytes: 44040192, MemoryLimitBytes: 8221675520},
		"event-stats-closed":       StatsEvent{Stream: 3, ID: hexID("a1"), Closed: true},
		"event-stats-closed-error": StatsEvent{Stream: 3, ID: hexID("a1"), Closed: true, Error: "No such container: " + hexID("a1") + "."},
		"contexts-response": ContextList{Current: "orbstack", Contexts: []ContextInfo{
			{Name: "default", Description: "Current DOCKER_HOST based configuration", Endpoint: "unix:///var/run/docker.sock", Transport: "unix"},
			{Name: "orbstack", Description: "OrbStack", Endpoint: "unix:///Users/me/.orbstack/run/docker.sock", Transport: "unix", Current: true},
			{Name: "secure", Endpoint: "tcp://10.0.0.5:2376", Transport: "tls"},
			{Name: "vps", Endpoint: "ssh://deploy@vps.example", Transport: "ssh"},
		}},
		"use-context-response-ok":    ActionResult{OK: true},
		"use-context-response-error": ActionResult{Error: "There’s no Docker context named “staging”."},
	}
}

func remoteIssueEngine() EngineState {
	msg := "vps.example isn’t in your known_hosts yet, and GoLens won’t trust a new host on its own. Connect once in Terminal, check the fingerprint and answer yes, then run again."
	return EngineState{State: "down", Reason: ReasonDown, Error: msg, Endpoint: "ssh://deploy@vps.example", Context: "vps",
		Issue: &Issue{Code: "hostKeyUnknown", Title: "Unknown Host Key", Message: msg, Fix: "openTerminal", FixTitle: "Connect in Terminal",
			Command: "ssh deploy@vps.example exit"}}
}

func apiInspectFixture() apiInspect {
	var in apiInspect
	data := `{"Id":"` + hexID("a1") + `","Created":"2026-11-15T15:59:58.5Z","Path":"/app/server","Args":["--addr",":8080"],"Name":"/velo-api-1",
	"Image":"sha256:` + hexID("e1") + `","State":{"Status":"running","Running":true,"ExitCode":0,"StartedAt":"2026-11-15T16:00:00.123456789Z",
	"FinishedAt":"0001-01-01T00:00:00Z","Health":{"Status":"healthy"}},"HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}},
	"Mounts":[{"Type":"volume","Name":"pgdata","Source":"/var/lib/docker/volumes/pgdata/_data","Destination":"/data","Mode":"z","RW":true},
	{"Type":"bind","Source":"/Users/me/src/velo/config","Destination":"/etc/velo","Mode":"ro","RW":false}],
	"Config":{"Image":"velo-api","Env":["DATABASE_URL=postgres://app:s3cret@db/app","PORT=8080"],"Tty":false,"WorkingDir":"/app",
	"Labels":{"com.docker.compose.project":"velo","com.docker.compose.service":"api"}},
	"NetworkSettings":{"Ports":{"8080/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"},{"HostIp":"::","HostPort":"8080"}],"9090/tcp":null},
	"Networks":{"velo_default":{"IPAddress":"172.18.0.2","Gateway":"172.18.0.1","MacAddress":"02:42:ac:12:00:02","Aliases":["api","velo-api-1"]}}}}`
	if err := json.Unmarshal([]byte(data), &in); err != nil {
		panic(err)
	}
	return in
}

func marshalFixture(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func checkGolden(t *testing.T, path string, want []byte) {
	t.Helper()
	if *updateFixtures {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, want, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s is missing; run go test ./docker -run FFIFixtures -update: %v", path, err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("%s is out of date; run go test ./docker -run FFIFixtures -update", path)
	}
}

func TestFFIFixtures(t *testing.T) {
	fixtures := ffiFixtures()
	dir := filepath.Join("testdata", "ffi")
	for name, v := range fixtures {
		b, err := marshalFixture(v)
		if err != nil {
			t.Fatal(err)
		}
		checkGolden(t, filepath.Join(dir, name+".json"), b)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if _, ok := fixtures[strings.TrimSuffix(e.Name(), ".json")]; !ok {
			t.Errorf("stale fixture %s", e.Name())
		}
	}
}

func TestFFIRequestFixturesDecodeStrictly(t *testing.T) {
	targets := map[string]any{
		"snapshot-request":               &Scope{},
		"watch-start-request":            &[]string{},
		"logs-open-request":              &[]string{},
		"remove-request":                 &struct{ Kind, ID string }{},
		"start-terminal-command-request": &[]string{},
		"prune-request":                  &PruneOptions{},
	}
	for name, target := range targets {
		b, err := os.ReadFile(filepath.Join("testdata", "ffi", name+".json"))
		if err != nil {
			t.Fatal(err)
		}
		dec := json.NewDecoder(bytes.NewReader(b))
		dec.DisallowUnknownFields()
		if err := dec.Decode(target); err != nil {
			t.Errorf("%s: %v", name, err)
		}
	}
	if kinds := watchKinds([]string{"containers", "images", "volumes"}); len(kinds) != 3 {
		t.Fatalf("watch kinds = %v", kinds)
	}
}

func jsonKeys(t *testing.T, v any) []string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var generic any
	json.Unmarshal(b, &generic)
	set := map[string]bool{}
	var walk func(prefix string, v any)
	walk = func(prefix string, v any) {
		switch x := v.(type) {
		case map[string]any:
			for k, child := range x {
				set[prefix+"."+k] = true
				walk(prefix+"."+k, child)
			}
		case []any:
			for _, child := range x {
				walk(prefix+"[]", child)
			}
		}
	}
	walk("", generic)
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func TestFFIFixturesMatchLiveShapes(t *testing.T) {
	s := newSvcEngine(t)
	ws := "/Users/me/src/velo"
	s.add(&svcContainer{ID: hexID("a1"), Name: "velo-api-1", Image: "velo-api", ImageID: "sha256:" + hexID("e1"),
		Status: "Up 2 minutes (healthy)", Labels: composeLabels("velo", "api", ws), Env: []string{"PORT=8080"},
		Ports: []map[string]any{{"IP": "0.0.0.0", "PrivatePort": 8080, "PublicPort": 8080, "Type": "tcp"}}})
	s.add(&svcContainer{ID: hexID("b2"), Name: "velo-redis-1", Image: "redis:7", ImageID: "sha256:" + hexID("e2"),
		State: "exited", Status: "Exited (1) 2 minutes ago", Labels: composeLabels("velo", "redis", ws)})
	s.add(&svcContainer{ID: hexID("d4"), Name: "scratch", Image: "alpine", ImageID: "sha256:" + hexID("e3"), Labels: map[string]string{}})
	fixtures := ffiFixtures()
	live := TakeSnapshot(Scope{Workspace: ws})
	live.Engine.Provider = "OrbStack"
	if got, want := jsonKeys(t, live), jsonKeys(t, fixtures["snapshot-response"]); !reflect.DeepEqual(got, want) {
		t.Fatalf("snapshot keys\n got %v\nwant %v", got, want)
	}
	if got, want := jsonKeys(t, InspectContainer("velo-api-1")), jsonKeys(t, fixtures["inspect-response"]); !reflect.DeepEqual(got, want) {
		t.Fatalf("inspect keys\n got %v\nwant %v", got, want)
	}
}
