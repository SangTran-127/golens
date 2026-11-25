package kube

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	restartedAtAnnotation = "kubectl.kubernetes.io/restartedAt"
	maxEvents             = 100
)

var now = time.Now

type NamespacesReply struct {
	Context          string      `json:"context"`
	DefaultNamespace string      `json:"defaultNamespace"`
	Namespaces       []Namespace `json:"namespaces"`
	Error            *Error      `json:"error,omitempty"`
}

type ActionReply struct {
	OK    bool   `json:"ok"`
	Error *Error `json:"error,omitempty"`
}

type DetailItem struct {
	Label string `json:"label"`
	Value string `json:"value"`
}

type Termination struct {
	Reason     string `json:"reason"`
	ExitCode   int    `json:"exitCode"`
	FinishedAt string `json:"finishedAt"`
}

type ContainerDetail struct {
	Name            string            `json:"name"`
	Image           string            `json:"image"`
	State           string            `json:"state"`
	Reason          string            `json:"reason,omitempty"`
	StartedAt       string            `json:"startedAt,omitempty"`
	Ready           bool              `json:"ready"`
	Restarts        int               `json:"restarts"`
	LastTermination *Termination      `json:"lastTermination,omitempty"`
	Requests        map[string]string `json:"requests"`
	Limits          map[string]string `json:"limits"`
	Ports           []Port            `json:"ports"`
}

type Condition struct {
	Type           string `json:"type"`
	Status         string `json:"status"`
	Reason         string `json:"reason,omitempty"`
	Message        string `json:"message,omitempty"`
	LastTransition string `json:"lastTransition,omitempty"`
}

type Details struct {
	Context     string            `json:"context"`
	Namespace   string            `json:"namespace"`
	Kind        string            `json:"kind"`
	Name        string            `json:"name"`
	Created     string            `json:"created,omitempty"`
	Labels      map[string]string `json:"labels"`
	Overview    []DetailItem      `json:"overview"`
	Containers  []ContainerDetail `json:"containers"`
	Conditions  []Condition       `json:"conditions"`
	Events      []Event           `json:"events"`
	EventsError *Error            `json:"eventsError,omitempty"`
	Error       *Error            `json:"error,omitempty"`
}

func Namespaces(contextName string) NamespacesReply {
	defer releaseClientsIfIdle()
	contextName, def := contextDefaults(contextName, "")
	reply := NamespacesReply{Context: contextName, DefaultNamespace: def, Namespaces: []Namespace{}}
	c, err := clientFor(contextName)
	if err != nil {
		reply.Error = asError(err)
		return reply
	}
	var list struct {
		Items []struct {
			Metadata apiMeta `json:"metadata"`
			Status   struct {
				Phase string `json:"phase"`
			} `json:"status"`
		} `json:"items"`
	}
	err = c.getJSON(context.Background(), request{path: "/api/v1/namespaces", verb: "list", resource: "namespaces"}, &list)
	if err != nil {
		reply.Error = asError(err)
		return reply
	}
	for _, it := range list.Items {
		reply.Namespaces = append(reply.Namespaces, Namespace{Name: it.Metadata.Name, Phase: it.Status.Phase})
	}
	sort.SliceStable(reply.Namespaces, func(i, j int) bool {
		a, b := reply.Namespaces[i].Name, reply.Namespaces[j].Name
		if (a == def) != (b == def) {
			return a == def
		}
		return a < b
	})
	return reply
}

func objectPath(namespace, kind, name string) (path, resource string, ok bool) {
	ns := "/namespaces/" + url.PathEscape(namespace)
	switch normalizeKind(kind) {
	case "pods":
		return "/api/v1" + ns + "/pods/" + url.PathEscape(name), "pods", true
	case "deployments":
		return "/apis/apps/v1" + ns + "/deployments/" + url.PathEscape(name), "deployments", true
	case "services":
		return "/api/v1" + ns + "/services/" + url.PathEscape(name), "services", true
	}
	return "", "", false
}

func mutate(contextName, namespace, kind, name, method, verb, contentType string, body []byte) ActionReply {
	if strings.TrimSpace(name) == "" {
		return ActionReply{Error: &Error{Kind: KindOther, Message: "No object name was given."}}
	}
	defer releaseClientsIfIdle()
	contextName, namespace = contextDefaults(contextName, namespace)
	path, resource, _ := objectPath(namespace, kind, name)
	c, err := clientFor(contextName)
	if err != nil {
		return ActionReply{Error: asError(err)}
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	resp, err := c.do(ctx, request{method: method, path: path, body: body, contentType: contentType, verb: verb, resource: resource, namespace: namespace})
	if err != nil {
		return ActionReply{Error: asError(err)}
	}
	resp.Body.Close()
	return ActionReply{OK: true}
}

func DeletePod(contextName, namespace, name string) ActionReply {
	return mutate(contextName, namespace, "pods", name, http.MethodDelete, "delete", "", nil)
}

func RolloutRestart(contextName, namespace, name string) ActionReply {
	body, _ := json.Marshal(map[string]any{"spec": map[string]any{"template": map[string]any{"metadata": map[string]any{
		"annotations": map[string]string{restartedAtAnnotation: now().Format(time.RFC3339)},
	}}}})
	return mutate(contextName, namespace, "deployments", name, http.MethodPatch, "patch", "application/strategic-merge-patch+json", body)
}

func DetailsOf(contextName, namespace, kind, name string) Details {
	contextName, namespace = contextDefaults(contextName, namespace)
	kind = normalizeKind(kind)
	d := Details{Context: contextName, Namespace: namespace, Kind: kind, Name: name, Labels: map[string]string{},
		Overview: []DetailItem{}, Containers: []ContainerDetail{}, Conditions: []Condition{}, Events: []Event{}}
	path, resource, ok := objectPath(namespace, kind, name)
	if !ok || strings.TrimSpace(name) == "" {
		d.Error = &Error{Kind: KindOther, Message: "GoLens can’t show details of this kind of object."}
		return d
	}
	defer releaseClientsIfIdle()
	c, err := clientFor(contextName)
	if err != nil {
		d.Error = asError(err)
		return d
	}
	ctx := context.Background()
	r := request{path: path, verb: "get", resource: resource, namespace: namespace}
	eventKind := ""
	switch kind {
	case "pods":
		var p apiPod
		if err = c.getJSON(ctx, r, &p); err == nil {
			podDetails(&d, &p)
		}
		eventKind = "Pod"
	case "deployments":
		var dep apiDeployment
		if err = c.getJSON(ctx, r, &dep); err == nil {
			deploymentDetails(&d, &dep)
		}
		eventKind = "Deployment"
	case "services":
		var s apiService
		if err = c.getJSON(ctx, r, &s); err == nil {
			serviceDetails(&d, &s)
		}
		eventKind = "Service"
	}
	if err != nil {
		d.Error = asError(err)
		return d
	}
	d.Events, d.EventsError = loadEvents(ctx, c, namespace, eventKind, name)
	return d
}

func loadEvents(ctx context.Context, c *client, namespace, kind, name string) ([]Event, *Error) {
	var list struct {
		Items []apiEvent `json:"items"`
	}
	q := url.Values{"fieldSelector": {"involvedObject.name=" + name + ",involvedObject.kind=" + kind}}
	err := c.getJSON(ctx, request{path: "/api/v1/namespaces/" + url.PathEscape(namespace) + "/events", query: q,
		verb: "list", resource: "events", namespace: namespace}, &list)
	if err != nil {
		return []Event{}, asError(err)
	}
	events := make([]Event, 0, len(list.Items))
	for i := range list.Items {
		events = append(events, eventFromAPI(&list.Items[i]))
	}
	sortEventsNewestFirst(events)
	if len(events) > maxEvents {
		events = events[:maxEvents]
	}
	return events, nil
}

func baseDetails(d *Details, m apiMeta) {
	d.Created = m.CreationTimestamp
	d.Labels = nonNilLabels(m.Labels)
}

func add(d *Details, label, value string) {
	if value != "" {
		d.Overview = append(d.Overview, DetailItem{Label: label, Value: value})
	}
}

func conditions(in []apiCondition) []Condition {
	out := make([]Condition, 0, len(in))
	for _, c := range in {
		out = append(out, Condition{Type: c.Type, Status: c.Status, Reason: c.Reason, Message: c.Message, LastTransition: c.LastTransitionTime})
	}
	return out
}

func containerSpec(c apiContainer) ContainerDetail {
	cd := ContainerDetail{Name: c.Name, Image: c.Image, Requests: nonNilLabels(c.Resources.Requests), Limits: nonNilLabels(c.Resources.Limits), Ports: []Port{}}
	for _, p := range c.Ports {
		cd.Ports = append(cd.Ports, Port{Name: p.Name, Port: p.ContainerPort, Protocol: protocolOr(p.Protocol)})
	}
	return cd
}

func podDetails(d *Details, p *apiPod) {
	baseDetails(d, p.Metadata)
	row := podFromAPI(p)
	add(d, "Status", row.Status)
	add(d, "Ready", fmt.Sprintf("%d/%d", row.Ready, row.Total))
	add(d, "Restarts", strconv.Itoa(row.Restarts))
	add(d, "Node", p.Spec.NodeName)
	add(d, "Pod IP", p.Status.PodIP)
	add(d, "QoS Class", p.Status.QOSClass)
	if row.Owner != nil {
		add(d, "Controlled By", row.Owner.Kind+" "+row.Owner.Name)
	}
	add(d, "Message", p.Status.Message)
	statuses := map[string]apiContainerStatus{}
	for _, cs := range p.Status.ContainerStatuses {
		statuses[cs.Name] = cs
	}
	for _, c := range p.Spec.Containers {
		cd := containerSpec(c)
		cd.State = "waiting"
		if cs, ok := statuses[c.Name]; ok {
			cd.Ready, cd.Restarts = cs.Ready, cs.RestartCount
			if cs.Image != "" {
				cd.Image = cs.Image
			}
			switch {
			case cs.State.Running != nil:
				cd.State, cd.StartedAt = "running", cs.State.Running.StartedAt
			case cs.State.Terminated != nil:
				cd.State, cd.Reason = "terminated", terminatedReason(cs.State.Terminated)
			case cs.State.Waiting != nil:
				cd.Reason = cs.State.Waiting.Reason
			}
			if t := cs.LastState.Terminated; t != nil {
				cd.LastTermination = &Termination{Reason: terminatedReason(t), ExitCode: t.ExitCode, FinishedAt: t.FinishedAt}
			}
		}
		d.Containers = append(d.Containers, cd)
	}
	d.Conditions = conditions(p.Status.Conditions)
}

func selectorString(m map[string]string) string {
	parts := make([]string, 0, len(m))
	for k, v := range m {
		parts = append(parts, k+"="+v)
	}
	sort.Strings(parts)
	return strings.Join(parts, ", ")
}

func deploymentDetails(d *Details, dep *apiDeployment) {
	baseDetails(d, dep.Metadata)
	row := deploymentFromAPI(dep)
	add(d, "Replicas", fmt.Sprintf("%d desired · %d updated · %d ready · %d available", row.Desired, row.Updated, row.Ready, row.Available))
	add(d, "Strategy", dep.Spec.Strategy.Type)
	add(d, "Selector", selectorString(dep.Spec.Selector.MatchLabels))
	if dep.Spec.Paused {
		add(d, "Rollout", "Paused")
	}
	for _, c := range dep.Spec.Template.Spec.Containers {
		cd := containerSpec(c)
		cd.State = "template"
		d.Containers = append(d.Containers, cd)
	}
	d.Conditions = conditions(dep.Status.Conditions)
}

func serviceDetails(d *Details, s *apiService) {
	baseDetails(d, s.Metadata)
	row := serviceFromAPI(s)
	add(d, "Type", row.Type)
	add(d, "Cluster IP", row.ClusterIP)
	external := append([]string{}, s.Spec.ExternalIPs...)
	for _, in := range s.Status.LoadBalancer.Ingress {
		if in.IP != "" {
			external = append(external, in.IP)
		} else if in.Hostname != "" {
			external = append(external, in.Hostname)
		}
	}
	add(d, "External", strings.Join(external, ", "))
	ports := make([]string, 0, len(row.Ports))
	for _, p := range row.Ports {
		s := fmt.Sprintf("%d → %s/%s", p.Port, p.TargetPort, p.Protocol)
		if p.Name != "" {
			s = p.Name + " " + s
		}
		if p.NodePort != 0 {
			s += fmt.Sprintf(" (node %d)", p.NodePort)
		}
		ports = append(ports, s)
	}
	add(d, "Ports", strings.Join(ports, ", "))
	add(d, "Selector", selectorString(s.Spec.Selector))
}
