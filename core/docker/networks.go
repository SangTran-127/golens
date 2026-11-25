package docker

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"sort"
)

type NetworkInfo struct {
	ID         string   `json:"id"`
	Name       string   `json:"name"`
	Driver     string   `json:"driver"`
	Scope      string   `json:"scope"`
	BuiltIn    bool     `json:"builtIn"`
	Containers []string `json:"containers"`
	Created    string   `json:"created"`
}

type apiNetwork struct {
	ID      string            `json:"Id"`
	Name    string            `json:"Name"`
	Driver  string            `json:"Driver"`
	Scope   string            `json:"Scope"`
	Created string            `json:"Created"`
	Labels  map[string]string `json:"Labels"`
}

var builtInNetworks = map[string]bool{"bridge": true, "host": true, "none": true}

type networkUse struct {
	all     map[string][]string
	running map[string]int
}

func networkUsers(list []apiContainer) networkUse {
	use := networkUse{all: map[string][]string{}, running: map[string]int{}}
	for _, a := range list {
		for name, n := range a.NetworkSettings.Networks {
			key := n.NetworkID
			if key == "" {
				key = name
			}
			use.all[key] = append(use.all[key], containerName(a))
			if a.State == "running" || a.State == "paused" || a.State == "restarting" {
				use.running[key]++
			}
		}
	}
	return use
}

func (u networkUse) users(n apiNetwork) []string {
	names := append(append([]string{}, u.all[n.ID]...), u.all[n.Name]...)
	return sortedNames(names)
}

func listAPINetworks(ctx context.Context, c *Client, q url.Values) ([]apiNetwork, error) {
	var raw []apiNetwork
	if err := c.GetJSON(ctx, "/networks", q, &raw); err != nil {
		return nil, err
	}
	return raw, nil
}

func listNetworks(ctx context.Context, c *Client, containers []apiContainer) ([]NetworkInfo, error) {
	raw, err := listAPINetworks(ctx, c, nil)
	if err != nil {
		return []NetworkInfo{}, err
	}
	use := networkUsers(containers)
	out := make([]NetworkInfo, 0, len(raw))
	for _, a := range raw {
		out = append(out, NetworkInfo{ID: a.ID, Name: a.Name, Driver: a.Driver, Scope: a.Scope, BuiltIn: builtInNetworks[a.Name],
			Containers: use.users(a), Created: a.Created})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].BuiltIn != out[j].BuiltIn {
			return !out[i].BuiltIn
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

func removeNetwork(ctx context.Context, c *Client, id string) error {
	var n apiNetwork
	if err := c.GetJSON(ctx, "/networks/"+url.PathEscape(id), nil, &n); err != nil {
		if isNotFound(err) {
			return nil
		}
		return err
	}
	if builtInNetworks[n.Name] {
		return fmt.Errorf("“%s” is built into Docker and can’t be removed.", n.Name)
	}
	containers, err := listContainers(ctx, c, nil)
	if err != nil {
		return err
	}
	if users := networkUsers(containers).users(n); len(users) > 0 {
		return fmt.Errorf("Network “%s” is used by %s; remove those containers first.", n.Name, joinNames(users))
	}
	resp, err := c.Do(ctx, http.MethodDelete, "/networks/"+url.PathEscape(n.ID), nil, nil)
	if err != nil {
		if isNotFound(err) {
			return nil
		}
		return removeError(n.Name, err)
	}
	resp.Body.Close()
	return nil
}
