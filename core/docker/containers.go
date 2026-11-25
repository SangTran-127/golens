package docker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	labelProject     = "com.docker.compose.project"
	labelService     = "com.docker.compose.service"
	labelWorkingDir  = "com.docker.compose.project.working_dir"
	labelConfigFiles = "com.docker.compose.project.config_files"
)

var (
	snapshotTimeout = 2 * time.Second
	actionTimeout   = 5 * time.Second
	stopGrace       = 10
)

type EngineState struct {
	State      string `json:"state"`
	Reason     string `json:"reason,omitempty"`
	Error      string `json:"error,omitempty"`
	Endpoint   string `json:"endpoint"`
	Context    string `json:"context"`
	Provider   string `json:"provider"`
	APIVersion string `json:"apiVersion,omitempty"`
	Issue      *Issue `json:"issue,omitempty"`
}

type Port struct {
	IP          string `json:"ip,omitempty"`
	PrivatePort int    `json:"privatePort"`
	PublicPort  int    `json:"publicPort,omitempty"`
	Type        string `json:"type"`
}

type Container struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Image       string   `json:"image"`
	ImageID     string   `json:"imageId"`
	Command     string   `json:"command"`
	Created     int64    `json:"created"`
	State       string   `json:"state"`
	Status      string   `json:"status"`
	ExitCode    *int     `json:"exitCode,omitempty"`
	Health      string   `json:"health,omitempty"`
	Ports       []Port   `json:"ports"`
	Project     string   `json:"project,omitempty"`
	Service     string   `json:"service,omitempty"`
	ProjectDir  string   `json:"projectDir,omitempty"`
	ConfigFiles []string `json:"configFiles,omitempty"`
}

type Project struct {
	Name         string   `json:"name"`
	WorkingDir   string   `json:"workingDir"`
	ConfigFiles  []string `json:"configFiles"`
	ContainerIDs []string `json:"containerIds"`
	Running      int      `json:"running"`
	ThisProject  bool     `json:"thisProject"`
}

type Scope struct {
	Workspace   string `json:"workspace"`
	ComposeFile string `json:"composeFile"`
}

type ActionResult struct {
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
}

type apiContainer struct {
	ID      string   `json:"Id"`
	Names   []string `json:"Names"`
	Image   string   `json:"Image"`
	ImageID string   `json:"ImageID"`
	Command string   `json:"Command"`
	Created int64    `json:"Created"`
	State   string   `json:"State"`
	Status  string   `json:"Status"`
	Ports   []struct {
		IP          string `json:"IP"`
		PrivatePort int    `json:"PrivatePort"`
		PublicPort  int    `json:"PublicPort"`
		Type        string `json:"Type"`
	} `json:"Ports"`
	Labels map[string]string `json:"Labels"`
	Mounts []struct {
		Type string `json:"Type"`
		Name string `json:"Name"`
	} `json:"Mounts"`
	NetworkSettings struct {
		Networks map[string]struct {
			NetworkID string `json:"NetworkID"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}

var clientCache struct {
	sync.Mutex
	c *Client
}

func engineClient(ctx context.Context) (*Client, error) {
	ep, err := ResolveEndpoint()
	if err != nil {
		return nil, &EngineError{Reason: ReasonUnsupported, Message: err.Error(), Err: err}
	}
	clientCache.Lock()
	c := clientCache.c
	clientCache.Unlock()
	if c != nil && c.Endpoint == ep {
		return c, nil
	}
	c, err = Connect(ctx, ep)
	if err != nil {
		return nil, err
	}
	clientCache.Lock()
	clientCache.c = c
	clientCache.Unlock()
	return c, nil
}

func forgetClient(err error) {
	var ee *EngineError
	if errors.As(err, &ee) {
		clientCache.Lock()
		clientCache.c = nil
		clientCache.Unlock()
	}
}

func engineStateFor(c *Client, err error) EngineState {
	ep := Endpoint{}
	if c != nil {
		ep = c.Endpoint
	} else {
		ep, _ = ResolveEndpoint()
	}
	provider, _ := providerFor(ep)
	st := EngineState{State: "running", Endpoint: ep.Host, Context: ep.Context, Provider: provider}
	if c != nil {
		st.APIVersion = c.APIVersion
	}
	if err != nil {
		st.State, st.Error, st.Reason = "down", plainError(err), ReasonDown
		var ee *EngineError
		if errors.As(err, &ee) {
			st.Reason, st.Issue = ee.Reason, ee.Issue
			if ee.Issue != nil {
				st.Error = ee.Issue.Message
			}
		}
	}
	return st
}

var remoteTimeout = 12 * time.Second

func timeoutFor(ep Endpoint, d time.Duration) time.Duration {
	if ep.Kind != KindUnix && d < remoteTimeout {
		return remoteTimeout
	}
	return d
}

func engineTimeout(d time.Duration) time.Duration {
	ep, err := ResolveEndpoint()
	if err != nil {
		return d
	}
	return timeoutFor(ep, d)
}

func plainError(err error) string {
	if err == nil {
		return ""
	}
	msg := strings.TrimSpace(err.Error())
	if msg == "" {
		return "Docker Engine returned an error."
	}
	r, size := utf8.DecodeRuneInString(msg)
	msg = string(unicode.ToUpper(r)) + msg[size:]
	if !strings.HasSuffix(msg, ".") {
		msg += "."
	}
	return msg
}

func filtersParam(f map[string][]string) string {
	b, _ := json.Marshal(f)
	return string(b)
}

func listContainers(ctx context.Context, c *Client, ids []string) ([]apiContainer, error) {
	q := url.Values{"all": {"1"}}
	if len(ids) > 0 {
		q.Set("filters", filtersParam(map[string][]string{"id": ids}))
	}
	var list []apiContainer
	if err := c.GetJSON(ctx, "/containers/json", q, &list); err != nil {
		return nil, err
	}
	if len(ids) > 0 {
		want := map[string]bool{}
		for _, id := range ids {
			want[id] = true
		}
		kept := list[:0]
		for _, a := range list {
			if want[a.ID] {
				kept = append(kept, a)
			}
		}
		list = kept
	}
	return list, nil
}

var (
	exitedRE = regexp.MustCompile(`^Exited \((-?\d+)\)`)
	healthRE = regexp.MustCompile(`\((healthy|unhealthy|health: starting)\)`)
)

func containerFromAPI(a apiContainer) Container {
	c := Container{
		ID: a.ID, Image: a.Image, ImageID: a.ImageID, Command: a.Command, Created: a.Created,
		State: a.State, Status: a.Status, Ports: []Port{},
		Project: a.Labels[labelProject], Service: a.Labels[labelService], ProjectDir: a.Labels[labelWorkingDir],
		ConfigFiles: splitConfigFiles(a.Labels[labelConfigFiles]),
	}
	if len(a.Names) > 0 {
		c.Name = strings.TrimPrefix(a.Names[0], "/")
	}
	if m := exitedRE.FindStringSubmatch(a.Status); m != nil {
		if code, err := strconv.Atoi(m[1]); err == nil {
			c.ExitCode = &code
		}
	}
	if m := healthRE.FindStringSubmatch(a.Status); m != nil {
		c.Health = strings.TrimPrefix(m[1], "health: ")
	}
	seen := map[Port]bool{}
	for _, p := range a.Ports {
		port := Port{PrivatePort: p.PrivatePort, PublicPort: p.PublicPort, Type: p.Type}
		if seen[port] {
			continue
		}
		seen[port] = true
		if p.IP != "0.0.0.0" && p.IP != "::" {
			port.IP = p.IP
		}
		c.Ports = append(c.Ports, port)
	}
	sortPorts(c.Ports)
	return c
}

func sortPorts(ports []Port) {
	sort.Slice(ports, func(i, j int) bool {
		if ports[i].PrivatePort != ports[j].PrivatePort {
			return ports[i].PrivatePort < ports[j].PrivatePort
		}
		if ports[i].Type != ports[j].Type {
			return ports[i].Type < ports[j].Type
		}
		return ports[i].PublicPort < ports[j].PublicPort
	})
}

func splitConfigFiles(s string) []string {
	if s == "" {
		return nil
	}
	var out []string
	for _, f := range strings.Split(s, ",") {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

func sortContainers(list []Container) {
	sort.Slice(list, func(i, j int) bool {
		if list[i].Project != list[j].Project {
			return list[i].Project < list[j].Project
		}
		return list[i].Name < list[j].Name
	})
}

func (s Scope) matches(workingDir string, configFiles []string) bool {
	if s.ComposeFile != "" {
		want := filepath.Clean(s.ComposeFile)
		for _, f := range configFiles {
			if filepath.Clean(f) == want {
				return true
			}
		}
	}
	if s.Workspace != "" && workingDir != "" {
		ws, wd := filepath.Clean(s.Workspace), filepath.Clean(workingDir)
		return wd == ws || strings.HasPrefix(wd, ws+string(filepath.Separator))
	}
	return false
}

func groupProjects(list []Container, scope Scope) []Project {
	byName := map[string]*Project{}
	var order []string
	for _, c := range list {
		if c.Project == "" {
			continue
		}
		p := byName[c.Project]
		if p == nil {
			p = &Project{Name: c.Project, WorkingDir: c.ProjectDir, ConfigFiles: c.ConfigFiles, ContainerIDs: []string{}}
			if p.ConfigFiles == nil {
				p.ConfigFiles = []string{}
			}
			byName[c.Project] = p
			order = append(order, c.Project)
		}
		p.ContainerIDs = append(p.ContainerIDs, c.ID)
		if c.State == "running" {
			p.Running++
		}
		if scope.matches(c.ProjectDir, c.ConfigFiles) {
			p.ThisProject = true
		}
	}
	out := make([]Project, 0, len(order))
	for _, name := range order {
		out = append(out, *byName[name])
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].ThisProject != out[j].ThisProject {
			return out[i].ThisProject
		}
		return out[i].Name < out[j].Name
	})
	return out
}

type apiInspect struct {
	ID      string   `json:"Id"`
	Created string   `json:"Created"`
	Path    string   `json:"Path"`
	Args    []string `json:"Args"`
	Name    string   `json:"Name"`
	Image   string   `json:"Image"`
	State   struct {
		Status     string `json:"Status"`
		Running    bool   `json:"Running"`
		Paused     bool   `json:"Paused"`
		Restarting bool   `json:"Restarting"`
		OOMKilled  bool   `json:"OOMKilled"`
		ExitCode   int    `json:"ExitCode"`
		Error      string `json:"Error"`
		StartedAt  string `json:"StartedAt"`
		FinishedAt string `json:"FinishedAt"`
		Health     *struct {
			Status string `json:"Status"`
		} `json:"Health"`
	} `json:"State"`
	HostConfig struct {
		RestartPolicy struct {
			Name              string `json:"Name"`
			MaximumRetryCount int    `json:"MaximumRetryCount"`
		} `json:"RestartPolicy"`
	} `json:"HostConfig"`
	Mounts []struct {
		Type        string `json:"Type"`
		Name        string `json:"Name"`
		Source      string `json:"Source"`
		Destination string `json:"Destination"`
		Mode        string `json:"Mode"`
		RW          bool   `json:"RW"`
	} `json:"Mounts"`
	Config struct {
		Image      string            `json:"Image"`
		Env        []string          `json:"Env"`
		Labels     map[string]string `json:"Labels"`
		Tty        bool              `json:"Tty"`
		WorkingDir string            `json:"WorkingDir"`
	} `json:"Config"`
	NetworkSettings struct {
		Ports map[string][]struct {
			HostIP   string `json:"HostIp"`
			HostPort string `json:"HostPort"`
		} `json:"Ports"`
		Networks map[string]struct {
			IPAddress  string   `json:"IPAddress"`
			Gateway    string   `json:"Gateway"`
			MacAddress string   `json:"MacAddress"`
			Aliases    []string `json:"Aliases"`
		} `json:"Networks"`
	} `json:"NetworkSettings"`
}

type KeyValue struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

type Mount struct {
	Type        string `json:"type"`
	Name        string `json:"name,omitempty"`
	Source      string `json:"source"`
	Destination string `json:"destination"`
	Mode        string `json:"mode,omitempty"`
	ReadOnly    bool   `json:"readOnly"`
}

type Network struct {
	Name       string   `json:"name"`
	IPAddress  string   `json:"ipAddress"`
	Gateway    string   `json:"gateway"`
	MacAddress string   `json:"macAddress,omitempty"`
	Aliases    []string `json:"aliases"`
}

type ContainerDetails struct {
	ID            string     `json:"id"`
	Name          string     `json:"name"`
	Image         string     `json:"image"`
	ImageID       string     `json:"imageId"`
	Created       string     `json:"created"`
	State         string     `json:"state"`
	ExitCode      int        `json:"exitCode"`
	OOMKilled     bool       `json:"oomKilled"`
	StateError    string     `json:"stateError,omitempty"`
	StartedAt     string     `json:"startedAt"`
	FinishedAt    string     `json:"finishedAt"`
	Health        string     `json:"health,omitempty"`
	RestartPolicy string     `json:"restartPolicy"`
	Command       string     `json:"command"`
	WorkingDir    string     `json:"workingDir"`
	TTY           bool       `json:"tty"`
	Project       string     `json:"project,omitempty"`
	Service       string     `json:"service,omitempty"`
	Ports         []Port     `json:"ports"`
	Env           []KeyValue `json:"env"`
	Mounts        []Mount    `json:"mounts"`
	Networks      []Network  `json:"networks"`
	Labels        []KeyValue `json:"labels"`
}

type InspectResult struct {
	Container *ContainerDetails `json:"container,omitempty"`
	Error     string            `json:"error,omitempty"`
}

func inspectContainer(ctx context.Context, c *Client, id string) (apiInspect, error) {
	var in apiInspect
	err := c.GetJSON(ctx, "/containers/"+id+"/json", nil, &in)
	return in, err
}

func isNotFound(err error) bool {
	var ae *APIError
	return errors.As(err, &ae) && ae.StatusCode == http.StatusNotFound
}

func detailsFromAPI(in apiInspect) ContainerDetails {
	d := ContainerDetails{
		ID: in.ID, Name: strings.TrimPrefix(in.Name, "/"), Image: in.Config.Image, ImageID: in.Image,
		Created: in.Created, State: in.State.Status, ExitCode: in.State.ExitCode, OOMKilled: in.State.OOMKilled,
		StateError: in.State.Error, StartedAt: in.State.StartedAt, FinishedAt: in.State.FinishedAt,
		Command: commandLine(append([]string{in.Path}, in.Args...)), WorkingDir: in.Config.WorkingDir, TTY: in.Config.Tty,
		Project: in.Config.Labels[labelProject], Service: in.Config.Labels[labelService],
		Ports: []Port{}, Env: []KeyValue{}, Mounts: []Mount{}, Networks: []Network{}, Labels: []KeyValue{},
	}
	if in.State.Health != nil {
		d.Health = in.State.Health.Status
	}
	rp := in.HostConfig.RestartPolicy
	d.RestartPolicy = rp.Name
	if d.RestartPolicy == "" {
		d.RestartPolicy = "no"
	}
	if rp.Name == "on-failure" && rp.MaximumRetryCount > 0 {
		d.RestartPolicy = fmt.Sprintf("on-failure:%d", rp.MaximumRetryCount)
	}
	for spec, bindings := range in.NetworkSettings.Ports {
		num, proto, _ := strings.Cut(spec, "/")
		private, _ := strconv.Atoi(num)
		if proto == "" {
			proto = "tcp"
		}
		if len(bindings) == 0 {
			d.Ports = append(d.Ports, Port{PrivatePort: private, Type: proto})
			continue
		}
		seen := map[int]bool{}
		for _, b := range bindings {
			public, _ := strconv.Atoi(b.HostPort)
			if seen[public] {
				continue
			}
			seen[public] = true
			p := Port{PrivatePort: private, PublicPort: public, Type: proto}
			if b.HostIP != "" && b.HostIP != "0.0.0.0" && b.HostIP != "::" {
				p.IP = b.HostIP
			}
			d.Ports = append(d.Ports, p)
		}
	}
	sortPorts(d.Ports)
	for _, kv := range in.Config.Env {
		k, v, _ := strings.Cut(kv, "=")
		d.Env = append(d.Env, KeyValue{Key: k, Value: v})
	}
	for _, m := range in.Mounts {
		d.Mounts = append(d.Mounts, Mount{Type: m.Type, Name: m.Name, Source: m.Source, Destination: m.Destination, Mode: m.Mode, ReadOnly: !m.RW})
	}
	for name, n := range in.NetworkSettings.Networks {
		aliases := n.Aliases
		if aliases == nil {
			aliases = []string{}
		}
		d.Networks = append(d.Networks, Network{Name: name, IPAddress: n.IPAddress, Gateway: n.Gateway, MacAddress: n.MacAddress, Aliases: aliases})
	}
	sort.Slice(d.Networks, func(i, j int) bool { return d.Networks[i].Name < d.Networks[j].Name })
	for k, v := range in.Config.Labels {
		d.Labels = append(d.Labels, KeyValue{Key: k, Value: v})
	}
	sort.Slice(d.Labels, func(i, j int) bool { return d.Labels[i].Key < d.Labels[j].Key })
	return d
}

func commandLine(argv []string) string {
	parts := make([]string, 0, len(argv))
	for _, a := range argv {
		if a == "" {
			continue
		}
		if strings.ContainsAny(a, " \t\n\"'\\$") {
			a = strconv.Quote(a)
		}
		parts = append(parts, a)
	}
	return strings.Join(parts, " ")
}

func InspectContainer(id string) InspectResult {
	ctx, cancel := context.WithTimeout(context.Background(), engineTimeout(actionTimeout))
	defer cancel()
	c, err := engineClient(ctx)
	if err != nil {
		return InspectResult{Error: plainError(err)}
	}
	in, err := inspectContainer(ctx, c, id)
	if err != nil {
		forgetClient(err)
		if isNotFound(err) {
			return InspectResult{Error: fmt.Sprintf("Container %s no longer exists.", shortID(id))}
		}
		return InspectResult{Error: plainError(err)}
	}
	d := detailsFromAPI(in)
	return InspectResult{Container: &d}
}

func shortID(id string) string {
	id = strings.TrimPrefix(id, "sha256:")
	if len(id) > 12 && isHex(id) {
		return id[:12]
	}
	return id
}

func isHex(s string) bool {
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return false
		}
	}
	return true
}

func containerLabel(ctx context.Context, c *Client, id string) string {
	if in, err := inspectContainer(ctx, c, id); err == nil && in.Name != "" {
		return "“" + strings.TrimPrefix(in.Name, "/") + "”"
	}
	return "“" + shortID(id) + "”"
}

func ContainerAction(id, action string) ActionResult {
	var path string
	q := url.Values{}
	timeout := engineTimeout(actionTimeout)
	switch action {
	case "start":
		path = "/start"
	case "stop", "restart":
		path = "/" + action
		q.Set("t", strconv.Itoa(stopGrace))
		timeout += time.Duration(stopGrace) * time.Second
	default:
		return ActionResult{Error: fmt.Sprintf("GoLens can’t %s a container.", action)}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c, err := engineClient(ctx)
	if err != nil {
		return ActionResult{Error: plainError(err)}
	}
	resp, err := c.Do(ctx, http.MethodPost, "/containers/"+id+path, q, nil)
	if err == nil {
		resp.Body.Close()
		return ActionResult{OK: true}
	}
	var ae *APIError
	if errors.As(err, &ae) && ae.StatusCode == http.StatusNotModified {
		return ActionResult{OK: true}
	}
	forgetClient(err)
	return ActionResult{Error: actionError(c, id, action, err, timeout)}
}

func actionError(c *Client, id, action string, err error, timeout time.Duration) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if isNotFound(err) {
		return fmt.Sprintf("Container %s no longer exists.", shortID(id))
	}
	name := containerLabel(ctx, c, id)
	var ee *EngineError
	if errors.As(err, &ee) && ee.Reason == ReasonTimeout {
		return fmt.Sprintf("Couldn’t %s %s. The engine didn’t respond within %d seconds.", action, name, int(timeout.Seconds()))
	}
	if errors.As(err, &ee) {
		return ee.Message
	}
	return fmt.Sprintf("Couldn’t %s %s. %s", action, name, plainError(err))
}
