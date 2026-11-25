package docker

import (
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func seedDiskUsage(s *svcEngine) {
	df := map[string]any{
		"Containers": []map[string]any{
			{"Id": hexID("a1"), "State": "running", "SizeRw": 1000},
			{"Id": hexID("b2"), "State": "exited", "SizeRw": 2000},
			{"Id": hexID("c3"), "State": "created", "SizeRw": 300},
			{"Id": hexID("d4"), "State": "paused", "SizeRw": 4000},
			{"Id": hexID("d5"), "State": "dead", "SizeRw": -1},
		},
		"Images": []map[string]any{
			{"Id": "sha256:" + hexID("e1"), "RepoTags": []string{"velo-api:latest"}, "Size": 182000000, "SharedSize": 0, "Containers": 1},
			{"Id": "sha256:" + hexID("e7"), "RepoTags": []string{"<none>:<none>"}, "Size": 7000000, "SharedSize": 2000000, "Containers": 0},
			{"Id": "sha256:" + hexID("e8"), "RepoTags": nil, "Size": 3000000, "SharedSize": -1, "Containers": 0},
			{"Id": "sha256:" + hexID("e9"), "RepoTags": []string{}, "Size": 5000000, "SharedSize": 0, "Containers": 1},
			{"Id": "sha256:" + hexID("ea"), "RepoTags": []string{}, "Size": 9000000, "SharedSize": 0, "Containers": 0},
			{"Id": "sha256:" + hexID("eb"), "ParentId": "sha256:" + hexID("ea"), "RepoTags": []string{"child:1"}, "Size": 9100000, "SharedSize": 9000000, "Containers": 0},
		},
		"Volumes": []map[string]any{
			{"Name": "redisdata", "Driver": "local", "UsageData": map[string]any{"Size": 50000, "RefCount": 1}},
			{"Name": "orphan", "Driver": "local", "UsageData": map[string]any{"Size": 70000, "RefCount": 0}},
			{"Name": hexID("f1"), "Driver": "local", "UsageData": map[string]any{"Size": 10, "RefCount": 0}},
			{"Name": "nfs", "Driver": "local", "Options": map[string]string{"type": "nfs"}, "UsageData": map[string]any{"Size": -1, "RefCount": 0}},
			{"Name": "plugin", "Driver": "rexray", "UsageData": map[string]any{"Size": -1, "RefCount": 0}},
		},
		"BuildCache": []map[string]any{
			{"ID": "c1", "Size": 100, "InUse": true, "Shared": false},
			{"ID": "c2", "Size": 200, "InUse": false, "Shared": false},
			{"ID": "c3", "Size": 400, "InUse": false, "Shared": true},
			{"ID": "c4", "Size": 800, "InUse": false, "Shared": false},
		},
	}
	s.Handle("GET /v"+s.APIVersionPinned()+"/system/df", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, df) })
}

func TestDiskUsageCountsWhatPruneRemoves(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	s.setState(hexID("d4"), "exited", "Exited (0) 1 minute ago")
	seedNetworks(s)
	seedDiskUsage(s)
	du := TakeDiskUsage()
	want := []DiskCategory{
		{Kind: PruneContainers, Count: 3, Bytes: 2300},
		{Kind: PruneImages, Count: 2, Bytes: 8000000},
		{Kind: PruneVolumes, Count: 2, Bytes: 70010},
		{Kind: PruneNetworks, Count: 2},
		{Kind: PruneBuildCache, Count: 3, Bytes: 1000},
	}
	if du.Error != "" || !reflect.DeepEqual(du.Categories, want) {
		t.Fatalf("disk usage = %+v", du)
	}
	if got, fixture := jsonKeys(t, du), jsonKeys(t, ffiFixtures()["disk-usage-response"]); !reflect.DeepEqual(got, fixture) {
		t.Fatalf("disk usage keys %v, fixture %v", got, fixture)
	}
	actions, _, _, _ := s.snapshot()
	if len(actions) != 0 {
		t.Fatalf("disk usage must not change anything: %q", actions)
	}
}

type pruneCall struct {
	path    string
	filters map[string][]string
	all     string
}

func seedPrune(t *testing.T, s *fakeEngine) func() []pruneCall {
	var mu sync.Mutex
	var calls []pruneCall
	v := "/v" + s.APIVersionPinned()
	record := func(r *http.Request) {
		var f map[string][]string
		if raw := r.URL.Query().Get("filters"); raw != "" {
			if err := json.Unmarshal([]byte(raw), &f); err != nil {
				t.Errorf("filters %q: %v", raw, err)
			}
		}
		mu.Lock()
		calls = append(calls, pruneCall{path: strings.TrimPrefix(r.URL.Path, v), filters: f, all: r.URL.Query().Get("all")})
		mu.Unlock()
	}
	s.Handle("POST "+v+"/containers/prune", func(w http.ResponseWriter, r *http.Request) {
		record(r)
		writeJSON(w, map[string]any{"ContainersDeleted": []string{hexID("b2"), hexID("c3")}, "SpaceReclaimed": 2300})
	})
	s.Handle("GET "+v+"/images/json", func(w http.ResponseWriter, r *http.Request) {
		record(r)
		writeJSON(w, []map[string]any{{"Id": "sha256:" + hexID("e7")}, {"Id": "sha256:" + hexID("e8")}})
	})
	s.Handle("POST "+v+"/images/prune", func(w http.ResponseWriter, r *http.Request) {
		record(r)
		writeJSON(w, map[string]any{"ImagesDeleted": []map[string]string{
			{"Untagged": "sha256:" + hexID("e7")}, {"Deleted": "sha256:" + hexID("e7")}, {"Deleted": "sha256:" + hexID("71")},
			{"Deleted": "sha256:" + hexID("e8")}, {"Deleted": "sha256:" + hexID("72")},
		}, "SpaceReclaimed": 8000000})
	})
	s.Handle("POST "+v+"/volumes/prune", func(w http.ResponseWriter, r *http.Request) {
		record(r)
		writeJSON(w, map[string]any{"VolumesDeleted": []string{"orphan", hexID("f1")}, "SpaceReclaimed": 70010})
	})
	s.Handle("POST "+v+"/networks/prune", func(w http.ResponseWriter, r *http.Request) {
		record(r)
		writeJSON(w, map[string]any{"NetworksDeleted": []string{"stale", "parked"}})
	})
	s.Handle("POST "+v+"/build/prune", func(w http.ResponseWriter, r *http.Request) {
		record(r)
		writeJSON(w, map[string]any{"CachesDeleted": []string{"c2", "c3", "c4"}, "SpaceReclaimed": 1000})
	})
	return func() []pruneCall {
		mu.Lock()
		defer mu.Unlock()
		out := calls
		calls = nil
		return out
	}
}

func TestPruneEachKind(t *testing.T) {
	f := newFakeEngine(t, nil)
	t.Setenv("DOCKER_HOST", "unix://"+f.Socket)
	resetServicesState(t)
	calls := seedPrune(t, f)
	label := []string{"golens.smoke=1"}
	cases := []struct {
		kind, label string
		want        PruneResult
		calls       []pruneCall
	}{
		{PruneContainers, "", PruneResult{Kind: PruneContainers, Removed: 2, Bytes: 2300}, []pruneCall{{path: "/containers/prune"}}},
		{PruneContainers, "golens.smoke=1", PruneResult{Kind: PruneContainers, Removed: 2, Bytes: 2300},
			[]pruneCall{{path: "/containers/prune", filters: map[string][]string{"label": label}}}},
		{PruneImages, "", PruneResult{Kind: PruneImages, Removed: 2, Bytes: 8000000}, []pruneCall{
			{path: "/images/json", filters: map[string][]string{"dangling": {"true"}}},
			{path: "/images/prune", filters: map[string][]string{"dangling": {"true"}}}}},
		{PruneImages, "golens.smoke=1", PruneResult{Kind: PruneImages, Removed: 2, Bytes: 8000000}, []pruneCall{
			{path: "/images/json", filters: map[string][]string{"dangling": {"true"}, "label": label}},
			{path: "/images/prune", filters: map[string][]string{"dangling": {"true"}, "label": label}}}},
		{PruneVolumes, "", PruneResult{Kind: PruneVolumes, Removed: 2, Bytes: 70010},
			[]pruneCall{{path: "/volumes/prune", filters: map[string][]string{"all": {"true"}}}}},
		{PruneVolumes, "golens.smoke=1", PruneResult{Kind: PruneVolumes, Removed: 2, Bytes: 70010},
			[]pruneCall{{path: "/volumes/prune", filters: map[string][]string{"all": {"true"}, "label": label}}}},
		{PruneNetworks, "", PruneResult{Kind: PruneNetworks, Removed: 2}, []pruneCall{{path: "/networks/prune"}}},
		{PruneNetworks, "golens.smoke=1", PruneResult{Kind: PruneNetworks, Removed: 2},
			[]pruneCall{{path: "/networks/prune", filters: map[string][]string{"label": label}}}},
		{PruneBuildCache, "", PruneResult{Kind: PruneBuildCache, Removed: 3, Bytes: 1000}, []pruneCall{{path: "/build/prune", all: "1"}}},
		{PruneBuildCache, "golens.smoke=1", PruneResult{Kind: PruneBuildCache,
			Error: "Build cache has no labels, so GoLens can’t limit its clean-up to “golens.smoke=1”; nothing was removed."}, nil},
		{"everything", "", PruneResult{Kind: "everything", Error: "GoLens can’t clean up “everything”."}, nil},
	}
	for _, c := range cases {
		got := Prune(PruneOptions{Kind: c.kind, Label: c.label})
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("Prune(%s, %q) = %+v, want %+v", c.kind, c.label, got, c.want)
		}
		if got := calls(); !reflect.DeepEqual(got, c.calls) {
			t.Errorf("Prune(%s, %q) requests = %+v, want %+v", c.kind, c.label, got, c.calls)
		}
	}
}

func TestPruneVolumesOnOldEngineLeavesOutAll(t *testing.T) {
	f := newFakeEngine(t, func(f *fakeEngine) { f.APIVersion = "1.41" })
	t.Setenv("DOCKER_HOST", "unix://"+f.Socket)
	resetServicesState(t)
	var got string
	f.Handle("POST /v1.41/volumes/prune", func(w http.ResponseWriter, r *http.Request) {
		got = r.URL.RawQuery
		writeJSON(w, map[string]any{"VolumesDeleted": []string{}, "SpaceReclaimed": 0})
	})
	if res := Prune(PruneOptions{Kind: PruneVolumes}); res.Error != "" || got != "" {
		t.Fatalf("old engine prune = %+v, query %q", res, got)
	}
}
