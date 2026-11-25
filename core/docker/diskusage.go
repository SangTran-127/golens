package docker

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	PruneContainers = "containers"
	PruneImages     = "images"
	PruneVolumes    = "volumes"
	PruneNetworks   = "networks"
	PruneBuildCache = "buildCache"
)

var (
	diskUsageTimeout = 60 * time.Second
	pruneTimeout     = 10 * time.Minute
)

type DiskCategory struct {
	Kind  string `json:"kind"`
	Count int    `json:"count"`
	Bytes int64  `json:"bytes"`
}

type DiskUsage struct {
	Categories []DiskCategory `json:"categories"`
	Error      string         `json:"error,omitempty"`
}

type PruneOptions struct {
	Kind  string `json:"kind"`
	Label string `json:"label,omitempty"`
}

type PruneResult struct {
	Kind    string `json:"kind"`
	Removed int    `json:"removed"`
	Bytes   int64  `json:"bytes"`
	Error   string `json:"error,omitempty"`
}

type apiDiskUsage struct {
	Images []struct {
		ID         string   `json:"Id"`
		ParentID   string   `json:"ParentId"`
		RepoTags   []string `json:"RepoTags"`
		Size       int64    `json:"Size"`
		SharedSize int64    `json:"SharedSize"`
		Containers int64    `json:"Containers"`
	} `json:"Images"`
	Containers []struct {
		ID     string `json:"Id"`
		State  string `json:"State"`
		SizeRw int64  `json:"SizeRw"`
	} `json:"Containers"`
	Volumes []struct {
		Name      string            `json:"Name"`
		Driver    string            `json:"Driver"`
		Options   map[string]string `json:"Options"`
		UsageData *struct {
			Size     int64 `json:"Size"`
			RefCount int64 `json:"RefCount"`
		} `json:"UsageData"`
	} `json:"Volumes"`
	BuildCache []struct {
		ID     string `json:"ID"`
		Size   int64  `json:"Size"`
		InUse  bool   `json:"InUse"`
		Shared bool   `json:"Shared"`
	} `json:"BuildCache"`
}

func containerStopped(state string) bool {
	switch state {
	case "running", "paused", "restarting", "removing":
		return false
	}
	return true
}

func diskCategories(df apiDiskUsage) []DiskCategory {
	containers := DiskCategory{Kind: PruneContainers}
	for _, c := range df.Containers {
		if containerStopped(c.State) {
			containers.Count++
			containers.Bytes += max(c.SizeRw, 0)
		}
	}
	parents := map[string]bool{}
	for _, img := range df.Images {
		if img.ParentID != "" {
			parents[img.ParentID] = true
		}
	}
	images := DiskCategory{Kind: PruneImages}
	for _, img := range df.Images {
		if len(realTags(img.RepoTags)) == 0 && img.Containers <= 0 && !parents[img.ID] {
			images.Count++
			images.Bytes += max(img.Size-max(img.SharedSize, 0), 0)
		}
	}
	volumes := DiskCategory{Kind: PruneVolumes}
	for _, v := range df.Volumes {
		if v.Driver != "local" || len(v.Options) > 0 || v.UsageData == nil || v.UsageData.RefCount > 0 {
			continue
		}
		volumes.Count++
		volumes.Bytes += max(v.UsageData.Size, 0)
	}
	cache := DiskCategory{Kind: PruneBuildCache}
	for _, b := range df.BuildCache {
		if b.InUse {
			continue
		}
		cache.Count++
		if !b.Shared {
			cache.Bytes += max(b.Size, 0)
		}
	}
	return []DiskCategory{containers, images, volumes, {Kind: PruneNetworks}, cache}
}

func prunableNetworks(networks []apiNetwork, containers []apiContainer) []apiNetwork {
	use := networkUsers(containers)
	var out []apiNetwork
	for _, n := range networks {
		if builtInNetworks[n.Name] || n.Scope == "swarm" || use.running[n.ID]+use.running[n.Name] > 0 {
			continue
		}
		out = append(out, n)
	}
	return out
}

func TakeDiskUsage() DiskUsage {
	ctx, cancel := context.WithTimeout(context.Background(), diskUsageTimeout)
	defer cancel()
	res := DiskUsage{Categories: []DiskCategory{}}
	c, err := engineClient(ctx)
	if err != nil {
		res.Error = plainError(err)
		return res
	}
	var df apiDiskUsage
	if err := c.GetJSON(ctx, "/system/df", nil, &df); err != nil {
		forgetClient(err)
		res.Error = plainError(err)
		return res
	}
	res.Categories = diskCategories(df)
	networks, err := listAPINetworks(ctx, c, nil)
	var containers []apiContainer
	if err == nil {
		containers, err = listContainers(ctx, c, nil)
	}
	if err != nil {
		res.Error = plainError(err)
		return res
	}
	for i := range res.Categories {
		if res.Categories[i].Kind == PruneNetworks {
			res.Categories[i].Count = len(prunableNetworks(networks, containers))
		}
	}
	return res
}

func pruneFilters(label string, extra map[string][]string) url.Values {
	f := map[string][]string{}
	for k, v := range extra {
		f[k] = v
	}
	if label != "" {
		f["label"] = []string{label}
	}
	if len(f) == 0 {
		return url.Values{}
	}
	return url.Values{"filters": {filtersParam(f)}}
}

func postJSON(ctx context.Context, c *Client, path string, q url.Values, out any) error {
	resp, err := c.Do(ctx, http.MethodPost, path, q, nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return c.wrap(err, time.Time{})
	}
	return nil
}

func Prune(opts PruneOptions) PruneResult {
	kind := strings.TrimSpace(opts.Kind)
	label := strings.TrimSpace(opts.Label)
	res := PruneResult{Kind: kind}
	switch kind {
	case PruneContainers, PruneImages, PruneVolumes, PruneNetworks, PruneBuildCache:
	default:
		res.Error = fmt.Sprintf("GoLens can’t clean up “%s”.", opts.Kind)
		return res
	}
	if kind == PruneBuildCache && label != "" {
		res.Error = fmt.Sprintf("Build cache has no labels, so GoLens can’t limit its clean-up to “%s”; nothing was removed.", label)
		return res
	}
	ctx, cancel := context.WithTimeout(context.Background(), pruneTimeout)
	defer cancel()
	c, err := engineClient(ctx)
	if err != nil {
		res.Error = plainError(err)
		return res
	}
	err = prune(ctx, c, kind, label, &res)
	if err != nil {
		forgetClient(err)
		res.Error = plainError(err)
	}
	return res
}

func prune(ctx context.Context, c *Client, kind, label string, res *PruneResult) error {
	var reply struct {
		ContainersDeleted []string `json:"ContainersDeleted"`
		ImagesDeleted     []struct {
			Deleted string `json:"Deleted"`
		} `json:"ImagesDeleted"`
		VolumesDeleted  []string `json:"VolumesDeleted"`
		NetworksDeleted []string `json:"NetworksDeleted"`
		CachesDeleted   []string `json:"CachesDeleted"`
		SpaceReclaimed  int64    `json:"SpaceReclaimed"`
	}
	switch kind {
	case PruneContainers:
		if err := postJSON(ctx, c, "/containers/prune", pruneFilters(label, nil), &reply); err != nil {
			return err
		}
		res.Removed = len(reply.ContainersDeleted)
	case PruneImages:
		filters := pruneFilters(label, map[string][]string{"dangling": {"true"}})
		var before []apiImage
		listErr := c.GetJSON(ctx, "/images/json", filters, &before)
		if err := postJSON(ctx, c, "/images/prune", filters, &reply); err != nil {
			return err
		}
		deleted := map[string]bool{}
		for _, d := range reply.ImagesDeleted {
			if d.Deleted != "" {
				deleted[d.Deleted] = true
			}
		}
		if listErr != nil {
			res.Removed = len(deleted)
		}
		for _, img := range before {
			if deleted[img.ID] {
				res.Removed++
			}
		}
	case PruneVolumes:
		var extra map[string][]string
		if compareAPIVersion(c.APIVersion, "1.42") >= 0 {
			extra = map[string][]string{"all": {"true"}}
		}
		if err := postJSON(ctx, c, "/volumes/prune", pruneFilters(label, extra), &reply); err != nil {
			return err
		}
		res.Removed = len(reply.VolumesDeleted)
	case PruneNetworks:
		if err := postJSON(ctx, c, "/networks/prune", pruneFilters(label, nil), &reply); err != nil {
			return err
		}
		res.Removed = len(reply.NetworksDeleted)
	case PruneBuildCache:
		if err := postJSON(ctx, c, "/build/prune", url.Values{"all": {"1"}}, &reply); err != nil {
			return err
		}
		res.Removed = len(reply.CachesDeleted)
	}
	res.Bytes = reply.SpaceReclaimed
	return nil
}
