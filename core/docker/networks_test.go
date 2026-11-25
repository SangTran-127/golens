package docker

import (
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func seedNetworks(s *svcEngine) {
	nets := []map[string]any{
		{"Id": hexID("n1"), "Name": "bridge", "Driver": "bridge", "Scope": "local", "Created": "2026-11-01T10:00:00Z"},
		{"Id": hexID("n2"), "Name": "host", "Driver": "host", "Scope": "local", "Created": "2026-11-01T10:00:00Z"},
		{"Id": hexID("n3"), "Name": "none", "Driver": "null", "Scope": "local", "Created": "2026-11-01T10:00:00Z"},
		{"Id": hexID("n4"), "Name": "velo_default", "Driver": "bridge", "Scope": "local", "Created": "2026-11-15T10:00:00Z"},
		{"Id": hexID("n5"), "Name": "stale", "Driver": "bridge", "Scope": "local", "Created": "2026-11-14T10:00:00Z", "Labels": map[string]string{"golens.smoke": "1"}},
		{"Id": hexID("n6"), "Name": "parked", "Driver": "bridge", "Scope": "local", "Created": "2026-11-13T10:00:00Z"},
		{"Id": hexID("n7"), "Name": "ingress", "Driver": "overlay", "Scope": "swarm", "Created": "2026-11-12T10:00:00Z"},
	}
	v := "/v" + s.APIVersionPinned()
	find := func(ref string) map[string]any {
		for _, n := range nets {
			if n["Id"] == ref || n["Name"] == ref || strings.HasPrefix(n["Id"].(string), ref) {
				return n
			}
		}
		return nil
	}
	s.Handle("GET "+v+"/networks", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, nets) })
	s.Handle("GET "+v+"/networks/{id}", func(w http.ResponseWriter, r *http.Request) {
		if n := find(r.PathValue("id")); n != nil {
			writeJSON(w, n)
			return
		}
		notFound(w, "network")
	})
	s.Handle("DELETE "+v+"/networks/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.actions = append(s.actions, "rmnet "+r.PathValue("id"))
		s.mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	})
	s.mu.Lock()
	for _, c := range s.containers {
		switch c.Name {
		case "velo-api-1", "velo-redis-1":
			c.Networks = map[string]string{"velo_default": hexID("n4")}
		case "scratch":
			c.Networks = map[string]string{"bridge": hexID("n1"), "parked": hexID("n6")}
		}
	}
	s.mu.Unlock()
}

func TestListNetworksWithAttachedContainers(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	s.setState(hexID("d4"), "exited", "Exited (0) 1 minute ago")
	seedNetworks(s)
	res := ListObjects("network")
	nets, ok := res.Items.([]NetworkInfo)
	if res.Error != "" || !ok || res.Kind != "network" {
		t.Fatalf("networks = %+v", res)
	}
	if got, fixture := jsonKeys(t, res), jsonKeys(t, ffiFixtures()["list-networks-response"]); !reflect.DeepEqual(got, fixture) {
		t.Fatalf("network keys %v, fixture %v", got, fixture)
	}
	got := map[string]NetworkInfo{}
	order := []string{}
	for _, n := range nets {
		got[n.Name] = n
		order = append(order, n.Name)
	}
	if want := []string{"ingress", "parked", "stale", "velo_default", "bridge", "host", "none"}; !reflect.DeepEqual(order, want) {
		t.Fatalf("order = %v", order)
	}
	if n := got["velo_default"]; n.BuiltIn || n.Driver != "bridge" || n.Scope != "local" || n.ID != hexID("n4") ||
		!reflect.DeepEqual(n.Containers, []string{"velo-api-1", "velo-redis-1"}) || n.Created != "2026-11-15T10:00:00Z" {
		t.Fatalf("velo_default = %+v", n)
	}
	if n := got["bridge"]; !n.BuiltIn || !reflect.DeepEqual(n.Containers, []string{"scratch"}) {
		t.Fatalf("bridge = %+v", n)
	}
	if n := got["stale"]; n.BuiltIn || n.Containers == nil || len(n.Containers) != 0 {
		t.Fatalf("stale = %+v", n)
	}
	if !got["host"].BuiltIn || !got["none"].BuiltIn || got["ingress"].BuiltIn {
		t.Fatalf("built-in flags = %+v", got)
	}
}

func TestRemoveNetworkRefusesBuiltInAndAttached(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	s.setState(hexID("d4"), "exited", "Exited (0) 1 minute ago")
	seedNetworks(s)
	if res := RemoveObject("network", "bridge"); res.OK || res.Error != "“bridge” is built into Docker and can’t be removed." {
		t.Fatalf("bridge = %+v", res)
	}
	if res := RemoveObject("network", "velo_default"); res.OK || res.Error != "Network “velo_default” is used by velo-api-1 and velo-redis-1; remove those containers first." {
		t.Fatalf("velo_default = %+v", res)
	}
	if res := RemoveObject("network", "parked"); res.OK || !strings.Contains(res.Error, "used by scratch") {
		t.Fatalf("network of a stopped container = %+v", res)
	}
	actions, _, _, _ := s.snapshot()
	if len(actions) != 0 {
		t.Fatalf("nothing may be removed: %q", actions)
	}
	if res := RemoveObject("network", "stale"); !res.OK {
		t.Fatalf("stale = %+v", res)
	}
	if res := RemoveObject("network", "missing"); !res.OK {
		t.Fatalf("an already removed network = %+v", res)
	}
	actions, _, _, _ = s.snapshot()
	if want := []string{"rmnet " + hexID("n5")}; !reflect.DeepEqual(actions, want) {
		t.Fatalf("actions = %q", actions)
	}
}
