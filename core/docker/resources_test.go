package docker

import (
	"reflect"
	"strings"
	"testing"
)

func seedResources(s *svcEngine) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.images = []map[string]any{
		{"Id": "sha256:" + hexID("e1"), "RepoTags": []string{"velo-api:latest", "golens/api:dev"}, "Size": 182000000, "Created": 1763222000},
		{"Id": "sha256:" + hexID("e2"), "RepoTags": []string{"redis:7"}, "Size": 41000000, "Created": 1763000000},
		{"Id": "sha256:" + hexID("e9"), "RepoTags": []string{"<none>:<none>"}, "Size": 5000000, "Created": 1762000000},
		{"Id": "sha256:" + hexID("e8"), "RepoTags": []string{"golang:1.27", "golang:latest"}, "Size": 900000000, "Created": 1761000000},
	}
	s.volumes = []map[string]any{
		{"Name": "redisdata", "Driver": "local", "Mountpoint": "/var/lib/docker/volumes/redisdata/_data", "CreatedAt": "2026-11-15T10:00:00Z",
			"Labels": map[string]string{labelProject: "velo"}},
		{"Name": "orphan", "Driver": "local", "Mountpoint": "/var/lib/docker/volumes/orphan/_data", "CreatedAt": "2026-11-14T10:00:00Z"},
	}
}

func TestListImagesAndVolumesWithUsers(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	seedResources(s)
	res := ListObjects("images")
	images, ok := res.Items.([]Image)
	if res.Error != "" || !ok || len(images) != 4 || res.Kind != "images" {
		t.Fatalf("images = %+v", res)
	}
	names := []string{}
	for _, img := range images {
		names = append(names, img.Name)
	}
	if want := []string{"golang:1.27", "redis:7", "velo-api:latest", hexID("e9")[:12]}; !reflect.DeepEqual(names, want) {
		t.Fatalf("image order = %v", names)
	}
	if api := images[2]; !api.InUse || !reflect.DeepEqual(api.UsedBy, []string{"velo-api-1"}) || len(api.Tags) != 2 {
		t.Fatalf("api image = %+v", api)
	}
	if dangling := images[3]; !dangling.Dangling || dangling.InUse || len(dangling.Tags) != 0 || dangling.UsedBy == nil {
		t.Fatalf("dangling = %+v", dangling)
	}
	vres := ListObjects("volume")
	vols, _ := vres.Items.([]Volume)
	if vres.Error != "" || len(vols) != 2 || vols[0].Name != "orphan" || vols[0].InUse || !vols[1].InUse ||
		vols[1].UsedBy[0] != "velo-redis-1" || vols[1].Project != "velo" {
		t.Fatalf("volumes = %+v", vres)
	}
	if bad := ListObjects("networks"); bad.Error == "" {
		t.Fatal("networks are not listed in this phase")
	}
}

func TestRemoveRefusesWhatIsInUse(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	seedResources(s)
	if res := RemoveObject("image", "golens/api:dev"); res.OK || res.Error != "“velo-api:latest” is used by velo-api-1; remove those containers first." {
		t.Fatalf("image in use = %+v", res)
	}
	if res := RemoveObject("volume", "redisdata"); res.OK || res.Error != "Volume “redisdata” is used by velo-redis-1; remove those containers first." {
		t.Fatalf("volume in use = %+v", res)
	}
	if res := RemoveObject("container", "velo-api-1"); res.OK || res.Error != "“velo-api-1” is running; stop it before removing it." {
		t.Fatalf("running container = %+v", res)
	}
	actions, _, _, _ := s.snapshot()
	if len(actions) != 0 {
		t.Fatalf("nothing may be deleted: %q", actions)
	}
}

func TestRemoveDeletesWithoutForce(t *testing.T) {
	s := newSvcEngine(t)
	seedProject(s, "/w")
	seedResources(s)
	for _, c := range []struct{ kind, id string }{
		{"container", "velo-redis-1"}, {"image", "sha256:" + hexID("e8")}, {"volume", "orphan"}, {"volume", "orphan"},
	} {
		if res := RemoveObject(c.kind, c.id); !res.OK {
			t.Fatalf("remove %s %s = %+v", c.kind, c.id, res)
		}
	}
	actions, _, _, _ := s.snapshot()
	want := []string{"delete " + hexID("b2") + " force=0&v=0", "rmi golang:1.27 force=0&noprune=0", "rmi golang:latest force=0&noprune=0", "rmv orphan force=0", "rmv orphan force=0"}
	if !reflect.DeepEqual(actions, want) {
		t.Fatalf("actions = %q", actions)
	}
	if res := ListObjects("images"); len(res.Items.([]Image)) != 3 {
		t.Fatalf("multi-tag image should be gone: %+v", res.Items)
	}
	if res := RemoveObject("secret", "x"); res.OK || !strings.Contains(res.Error, "can’t remove a secret") {
		t.Fatalf("secret = %+v", res)
	}
}
