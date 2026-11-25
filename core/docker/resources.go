package docker

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

type Image struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Tags     []string `json:"tags"`
	Size     int64    `json:"size"`
	Created  int64    `json:"created"`
	Dangling bool     `json:"dangling"`
	InUse    bool     `json:"inUse"`
	UsedBy   []string `json:"usedBy"`
}

type Volume struct {
	Name       string   `json:"name"`
	Driver     string   `json:"driver"`
	Mountpoint string   `json:"mountpoint"`
	Created    string   `json:"created"`
	Project    string   `json:"project,omitempty"`
	InUse      bool     `json:"inUse"`
	UsedBy     []string `json:"usedBy"`
}

type ListResult struct {
	Kind  string `json:"kind"`
	Items any    `json:"items"`
	Error string `json:"error,omitempty"`
}

type apiImage struct {
	ID       string   `json:"Id"`
	RepoTags []string `json:"RepoTags"`
	Size     int64    `json:"Size"`
	Created  int64    `json:"Created"`
}

type apiVolume struct {
	Name       string            `json:"Name"`
	Driver     string            `json:"Driver"`
	Mountpoint string            `json:"Mountpoint"`
	CreatedAt  string            `json:"CreatedAt"`
	Labels     map[string]string `json:"Labels"`
}

func normalizeKind(kind string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(kind)), "s")
}

func realTags(tags []string) []string {
	out := []string{}
	for _, t := range tags {
		if t != "" && t != "<none>:<none>" {
			out = append(out, t)
		}
	}
	return out
}

func containerName(a apiContainer) string {
	if len(a.Names) > 0 {
		return strings.TrimPrefix(a.Names[0], "/")
	}
	return shortID(a.ID)
}

func imageUsers(list []apiContainer) map[string][]string {
	users := map[string][]string{}
	for _, a := range list {
		users[a.ImageID] = append(users[a.ImageID], containerName(a))
	}
	return users
}

func volumeUsers(list []apiContainer) map[string][]string {
	users := map[string][]string{}
	for _, a := range list {
		for _, m := range a.Mounts {
			if m.Type == "volume" && m.Name != "" {
				users[m.Name] = append(users[m.Name], containerName(a))
			}
		}
	}
	return users
}

func sortedNames(names []string) []string {
	if names == nil {
		return []string{}
	}
	sort.Strings(names)
	return names
}

func ListObjects(kind string) ListResult {
	k := normalizeKind(kind)
	res := ListResult{Kind: k + "s", Items: []any{}}
	if k == "network" {
		res.Kind = k
	}
	if k != "image" && k != "volume" && k != "network" {
		res.Error = fmt.Sprintf("GoLens can’t list %s.", kind)
		return res
	}
	ctx, cancel := context.WithTimeout(context.Background(), engineTimeout(actionTimeout))
	defer cancel()
	c, err := engineClient(ctx)
	if err != nil {
		res.Error = plainError(err)
		return res
	}
	containers, err := listContainers(ctx, c, nil)
	if err != nil {
		forgetClient(err)
		res.Error = plainError(err)
		return res
	}
	if k == "image" {
		items, err := listImages(ctx, c, imageUsers(containers))
		res.Items = items
		if err != nil {
			res.Error = plainError(err)
		}
		return res
	}
	if k == "network" {
		items, err := listNetworks(ctx, c, containers)
		res.Items = items
		if err != nil {
			res.Error = plainError(err)
		}
		return res
	}
	items, err := listVolumes(ctx, c, volumeUsers(containers))
	res.Items = items
	if err != nil {
		res.Error = plainError(err)
	}
	return res
}

func listImages(ctx context.Context, c *Client, users map[string][]string) ([]Image, error) {
	var raw []apiImage
	if err := c.GetJSON(ctx, "/images/json", nil, &raw); err != nil {
		return []Image{}, err
	}
	out := make([]Image, 0, len(raw))
	for _, a := range raw {
		img := Image{ID: a.ID, Tags: realTags(a.RepoTags), Size: a.Size, Created: a.Created, UsedBy: sortedNames(users[a.ID])}
		img.Dangling = len(img.Tags) == 0
		img.InUse = len(img.UsedBy) > 0
		if img.Dangling {
			img.Name = shortID(a.ID)
		} else {
			img.Name = img.Tags[0]
		}
		out = append(out, img)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Dangling != out[j].Dangling {
			return !out[i].Dangling
		}
		if out[i].Name != out[j].Name {
			return out[i].Name < out[j].Name
		}
		return out[i].ID < out[j].ID
	})
	return out, nil
}

func listVolumes(ctx context.Context, c *Client, users map[string][]string) ([]Volume, error) {
	var raw struct {
		Volumes []apiVolume `json:"Volumes"`
	}
	if err := c.GetJSON(ctx, "/volumes", nil, &raw); err != nil {
		return []Volume{}, err
	}
	out := make([]Volume, 0, len(raw.Volumes))
	for _, a := range raw.Volumes {
		v := Volume{Name: a.Name, Driver: a.Driver, Mountpoint: a.Mountpoint, Created: a.CreatedAt,
			Project: a.Labels[labelProject], UsedBy: sortedNames(users[a.Name])}
		v.InUse = len(v.UsedBy) > 0
		out = append(out, v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func joinNames(names []string) string {
	switch len(names) {
	case 0:
		return ""
	case 1:
		return names[0]
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}

func RemoveObject(kind, id string) ActionResult {
	k := normalizeKind(kind)
	ctx, cancel := context.WithTimeout(context.Background(), engineTimeout(actionTimeout*2))
	defer cancel()
	c, err := engineClient(ctx)
	if err != nil {
		return ActionResult{Error: plainError(err)}
	}
	switch k {
	case "container":
		err = removeContainer(ctx, c, id)
	case "image":
		err = removeImage(ctx, c, id)
	case "volume":
		err = removeVolume(ctx, c, id)
	case "network":
		err = removeNetwork(ctx, c, id)
	default:
		return ActionResult{Error: fmt.Sprintf("GoLens can’t remove a %s.", kind)}
	}
	if err != nil {
		forgetClient(err)
		return ActionResult{Error: plainError(err)}
	}
	return ActionResult{OK: true}
}

func removeContainer(ctx context.Context, c *Client, id string) error {
	in, err := inspectContainer(ctx, c, id)
	if isNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	name := strings.TrimPrefix(in.Name, "/")
	if in.State.Running || in.State.Restarting || in.State.Paused {
		return fmt.Errorf("“%s” is running; stop it before removing it.", name)
	}
	resp, err := c.Do(ctx, http.MethodDelete, "/containers/"+in.ID, url.Values{"v": {"0"}, "force": {"0"}}, nil)
	if err != nil {
		if isNotFound(err) {
			return nil
		}
		return removeError(name, err)
	}
	resp.Body.Close()
	return nil
}

func removeImage(ctx context.Context, c *Client, id string) error {
	var img apiImage
	if err := c.GetJSON(ctx, "/images/"+id+"/json", nil, &img); err != nil {
		if isNotFound(err) {
			return nil
		}
		return err
	}
	tags := realTags(img.RepoTags)
	name := shortID(img.ID)
	if len(tags) > 0 {
		name = tags[0]
	}
	containers, err := listContainers(ctx, c, nil)
	if err != nil {
		return err
	}
	if users := sortedNames(imageUsers(containers)[img.ID]); len(users) > 0 {
		return fmt.Errorf("“%s” is used by %s; remove those containers first.", name, joinNames(users))
	}
	refs := tags
	if len(refs) == 0 {
		refs = []string{img.ID}
	}
	for _, ref := range refs {
		resp, err := c.Do(ctx, http.MethodDelete, "/images/"+ref, url.Values{"force": {"0"}, "noprune": {"0"}}, nil)
		if err != nil {
			if isNotFound(err) {
				continue
			}
			return removeError(name, err)
		}
		resp.Body.Close()
	}
	return nil
}

func removeVolume(ctx context.Context, c *Client, name string) error {
	containers, err := listContainers(ctx, c, nil)
	if err != nil {
		return err
	}
	if users := sortedNames(volumeUsers(containers)[name]); len(users) > 0 {
		return fmt.Errorf("Volume “%s” is used by %s; remove those containers first.", name, joinNames(users))
	}
	resp, err := c.Do(ctx, http.MethodDelete, "/volumes/"+name, url.Values{"force": {"0"}}, nil)
	if err != nil {
		if isNotFound(err) {
			return nil
		}
		return removeError(name, err)
	}
	resp.Body.Close()
	return nil
}

func removeError(name string, err error) error {
	if _, ok := err.(*APIError); ok {
		return fmt.Errorf("Couldn’t remove “%s”. %s", name, plainError(err))
	}
	return err
}
