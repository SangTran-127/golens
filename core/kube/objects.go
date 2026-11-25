package kube

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	ToneOK      = "ok"
	ToneWarning = "warning"
	ToneFailure = "failure"
	ToneNeutral = "neutral"
)

type apiOwner struct {
	Kind       string `json:"kind"`
	Name       string `json:"name"`
	Controller *bool  `json:"controller"`
}

type apiMeta struct {
	Name              string            `json:"name"`
	Namespace         string            `json:"namespace"`
	ResourceVersion   string            `json:"resourceVersion"`
	CreationTimestamp string            `json:"creationTimestamp"`
	DeletionTimestamp *string           `json:"deletionTimestamp"`
	Labels            map[string]string `json:"labels"`
	OwnerReferences   []apiOwner        `json:"ownerReferences"`
}

type apiListMeta struct {
	ResourceVersion string `json:"resourceVersion"`
	Continue        string `json:"continue"`
}

type apiPort struct {
	Name          string `json:"name"`
	ContainerPort int    `json:"containerPort"`
	Protocol      string `json:"protocol"`
}

type apiContainer struct {
	Name      string    `json:"name"`
	Image     string    `json:"image"`
	Ports     []apiPort `json:"ports"`
	Resources struct {
		Requests map[string]string `json:"requests"`
		Limits   map[string]string `json:"limits"`
	} `json:"resources"`
}

type apiWaiting struct {
	Reason  string `json:"reason"`
	Message string `json:"message"`
}

type apiRunning struct {
	StartedAt string `json:"startedAt"`
}

type apiTerminated struct {
	Reason     string `json:"reason"`
	Message    string `json:"message"`
	ExitCode   int    `json:"exitCode"`
	Signal     int    `json:"signal"`
	FinishedAt string `json:"finishedAt"`
}

type apiContainerState struct {
	Waiting    *apiWaiting    `json:"waiting"`
	Running    *apiRunning    `json:"running"`
	Terminated *apiTerminated `json:"terminated"`
}

type apiContainerStatus struct {
	Name         string            `json:"name"`
	Image        string            `json:"image"`
	Ready        bool              `json:"ready"`
	RestartCount int               `json:"restartCount"`
	State        apiContainerState `json:"state"`
	LastState    apiContainerState `json:"lastState"`
}

type apiCondition struct {
	Type               string `json:"type"`
	Status             string `json:"status"`
	Reason             string `json:"reason"`
	Message            string `json:"message"`
	LastTransitionTime string `json:"lastTransitionTime"`
}

type apiPod struct {
	Metadata apiMeta `json:"metadata"`
	Spec     struct {
		NodeName       string         `json:"nodeName"`
		Containers     []apiContainer `json:"containers"`
		InitContainers []apiContainer `json:"initContainers"`
	} `json:"spec"`
	Status struct {
		Phase                 string               `json:"phase"`
		Reason                string               `json:"reason"`
		Message               string               `json:"message"`
		PodIP                 string               `json:"podIP"`
		QOSClass              string               `json:"qosClass"`
		Conditions            []apiCondition       `json:"conditions"`
		ContainerStatuses     []apiContainerStatus `json:"containerStatuses"`
		InitContainerStatuses []apiContainerStatus `json:"initContainerStatuses"`
	} `json:"status"`
}

type apiDeployment struct {
	Metadata apiMeta `json:"metadata"`
	Spec     struct {
		Replicas *int `json:"replicas"`
		Paused   bool `json:"paused"`
		Selector struct {
			MatchLabels map[string]string `json:"matchLabels"`
		} `json:"selector"`
		Strategy struct {
			Type string `json:"type"`
		} `json:"strategy"`
		Template struct {
			Spec struct {
				Containers []apiContainer `json:"containers"`
			} `json:"spec"`
		} `json:"template"`
	} `json:"spec"`
	Status struct {
		Replicas            int            `json:"replicas"`
		ReadyReplicas       int            `json:"readyReplicas"`
		UpdatedReplicas     int            `json:"updatedReplicas"`
		AvailableReplicas   int            `json:"availableReplicas"`
		UnavailableReplicas int            `json:"unavailableReplicas"`
		Conditions          []apiCondition `json:"conditions"`
	} `json:"status"`
}

type apiServicePort struct {
	Name       string `json:"name"`
	Port       int    `json:"port"`
	TargetPort any    `json:"targetPort"`
	Protocol   string `json:"protocol"`
	NodePort   int    `json:"nodePort"`
}

type apiService struct {
	Metadata apiMeta `json:"metadata"`
	Spec     struct {
		Type        string            `json:"type"`
		ClusterIP   string            `json:"clusterIP"`
		ExternalIPs []string          `json:"externalIPs"`
		Ports       []apiServicePort  `json:"ports"`
		Selector    map[string]string `json:"selector"`
	} `json:"spec"`
	Status struct {
		LoadBalancer struct {
			Ingress []struct {
				IP       string `json:"ip"`
				Hostname string `json:"hostname"`
			} `json:"ingress"`
		} `json:"loadBalancer"`
	} `json:"status"`
}

type apiEvent struct {
	Metadata       apiMeta `json:"metadata"`
	Type           string  `json:"type"`
	Reason         string  `json:"reason"`
	Message        string  `json:"message"`
	Count          int     `json:"count"`
	FirstTimestamp string  `json:"firstTimestamp"`
	LastTimestamp  string  `json:"lastTimestamp"`
	EventTime      string  `json:"eventTime"`
	Source         struct {
		Component string `json:"component"`
	} `json:"source"`
	ReportingComponent string `json:"reportingComponent"`
	Series             *struct {
		Count            int    `json:"count"`
		LastObservedTime string `json:"lastObservedTime"`
	} `json:"series"`
}

type Owner struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
}

type Port struct {
	Name     string `json:"name,omitempty"`
	Port     int    `json:"port"`
	Protocol string `json:"protocol"`
}

type Pod struct {
	Name       string            `json:"name"`
	Namespace  string            `json:"namespace"`
	Phase      string            `json:"phase"`
	Status     string            `json:"status"`
	Tone       string            `json:"tone"`
	Ready      int               `json:"ready"`
	Total      int               `json:"total"`
	Restarts   int               `json:"restarts"`
	Created    string            `json:"created"`
	Node       string            `json:"node,omitempty"`
	Containers []string          `json:"containers"`
	Ports      []Port            `json:"ports"`
	Labels     map[string]string `json:"labels"`
	Owner      *Owner            `json:"owner,omitempty"`
}

type Deployment struct {
	Name      string            `json:"name"`
	Namespace string            `json:"namespace"`
	Desired   int               `json:"desired"`
	Ready     int               `json:"ready"`
	Updated   int               `json:"updated"`
	Available int               `json:"available"`
	Paused    bool              `json:"paused"`
	Tone      string            `json:"tone"`
	Created   string            `json:"created"`
	Selector  map[string]string `json:"selector"`
}

type ServicePort struct {
	Name       string `json:"name,omitempty"`
	Port       int    `json:"port"`
	TargetPort string `json:"targetPort"`
	Protocol   string `json:"protocol"`
	NodePort   int    `json:"nodePort,omitempty"`
}

type Service struct {
	Name      string            `json:"name"`
	Namespace string            `json:"namespace"`
	Type      string            `json:"type"`
	ClusterIP string            `json:"clusterIP"`
	Ports     []ServicePort     `json:"ports"`
	Created   string            `json:"created"`
	Selector  map[string]string `json:"selector"`
}

type Namespace struct {
	Name  string `json:"name"`
	Phase string `json:"phase"`
}

type Event struct {
	Type     string `json:"type"`
	Reason   string `json:"reason"`
	Message  string `json:"message"`
	Count    int    `json:"count"`
	LastSeen string `json:"lastSeen"`
	Source   string `json:"source"`
}

func controllerOf(m apiMeta) *Owner {
	for _, o := range m.OwnerReferences {
		if o.Controller != nil && *o.Controller {
			return &Owner{Kind: o.Kind, Name: o.Name}
		}
	}
	return nil
}

func nonNilLabels(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}

func terminatedReason(t *apiTerminated) string {
	switch {
	case t.Reason != "":
		return t.Reason
	case t.Signal != 0:
		return "Signal:" + strconv.Itoa(t.Signal)
	default:
		return "ExitCode:" + strconv.Itoa(t.ExitCode)
	}
}

func podStatus(p *apiPod) (status string, ready, restarts int) {
	status = p.Status.Phase
	if p.Status.Reason != "" {
		status = p.Status.Reason
	}
	initializing := false
	for i, cs := range p.Status.InitContainerStatuses {
		restarts += cs.RestartCount
		switch {
		case cs.State.Terminated != nil && cs.State.Terminated.ExitCode == 0:
			continue
		case cs.State.Terminated != nil:
			status = "Init:" + terminatedReason(cs.State.Terminated)
		case cs.State.Waiting != nil && cs.State.Waiting.Reason != "" && cs.State.Waiting.Reason != "PodInitializing":
			status = "Init:" + cs.State.Waiting.Reason
		default:
			status = fmt.Sprintf("Init:%d/%d", i, len(p.Spec.InitContainers))
		}
		initializing = true
		break
	}
	hasRunning := false
	for i := len(p.Status.ContainerStatuses) - 1; i >= 0; i-- {
		cs := p.Status.ContainerStatuses[i]
		restarts += cs.RestartCount
		if cs.Ready {
			ready++
		}
		if initializing {
			continue
		}
		switch {
		case cs.State.Waiting != nil && cs.State.Waiting.Reason != "":
			status = cs.State.Waiting.Reason
		case cs.State.Terminated != nil:
			status = terminatedReason(cs.State.Terminated)
		case cs.State.Running != nil && cs.Ready:
			hasRunning = true
		}
	}
	if !initializing && status == "Completed" && hasRunning {
		status = "Running"
	}
	if p.Metadata.DeletionTimestamp != nil {
		status = "Terminating"
		if p.Status.Reason == "NodeLost" {
			status = "Unknown"
		}
	}
	return status, ready, restarts
}

var failureReasons = []string{
	"CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "InvalidImageName", "ErrImageNeverPull",
	"CreateContainerConfigError", "CreateContainerError", "RunContainerError", "OOMKilled", "Error",
	"Evicted", "Failed", "ContainerCannotRun", "DeadlineExceeded", "Signal:", "ExitCode:",
}

func podTone(status string, ready, total int) string {
	for _, r := range failureReasons {
		if strings.Contains(status, r) {
			return ToneFailure
		}
	}
	switch status {
	case "Running":
		if ready == total {
			return ToneOK
		}
		return ToneWarning
	case "Completed", "Succeeded":
		return ToneNeutral
	}
	return ToneWarning
}

func podFromAPI(p *apiPod) Pod {
	status, ready, restarts := podStatus(p)
	row := Pod{
		Name: p.Metadata.Name, Namespace: p.Metadata.Namespace, Phase: p.Status.Phase, Status: status,
		Ready: ready, Total: len(p.Spec.Containers), Restarts: restarts, Created: p.Metadata.CreationTimestamp,
		Node: p.Spec.NodeName, Containers: []string{}, Ports: []Port{}, Labels: nonNilLabels(p.Metadata.Labels),
		Owner: controllerOf(p.Metadata),
	}
	for _, c := range p.Spec.Containers {
		row.Containers = append(row.Containers, c.Name)
		for _, port := range c.Ports {
			row.Ports = append(row.Ports, Port{Name: port.Name, Port: port.ContainerPort, Protocol: protocolOr(port.Protocol)})
		}
	}
	row.Tone = podTone(status, ready, row.Total)
	return row
}

func protocolOr(p string) string {
	if p == "" {
		return "TCP"
	}
	return p
}

func deploymentFromAPI(d *apiDeployment) Deployment {
	desired := 1
	if d.Spec.Replicas != nil {
		desired = *d.Spec.Replicas
	}
	row := Deployment{
		Name: d.Metadata.Name, Namespace: d.Metadata.Namespace, Desired: desired, Ready: d.Status.ReadyReplicas,
		Updated: d.Status.UpdatedReplicas, Available: d.Status.AvailableReplicas, Paused: d.Spec.Paused,
		Created: d.Metadata.CreationTimestamp, Selector: nonNilLabels(d.Spec.Selector.MatchLabels),
	}
	switch {
	case deploymentFailed(d):
		row.Tone = ToneFailure
	case desired == 0:
		row.Tone = ToneNeutral
	case row.Ready >= desired && d.Status.UnavailableReplicas == 0:
		row.Tone = ToneOK
	default:
		row.Tone = ToneWarning
	}
	return row
}

func deploymentFailed(d *apiDeployment) bool {
	for _, c := range d.Status.Conditions {
		if c.Type == "Progressing" && c.Status == "False" && c.Reason == "ProgressDeadlineExceeded" {
			return true
		}
		if c.Type == "ReplicaFailure" && c.Status == "True" {
			return true
		}
	}
	return false
}

func targetPortString(v any) string {
	switch t := v.(type) {
	case float64:
		return strconv.Itoa(int(t))
	case string:
		return t
	}
	return ""
}

func serviceFromAPI(s *apiService) Service {
	row := Service{
		Name: s.Metadata.Name, Namespace: s.Metadata.Namespace, Type: s.Spec.Type, ClusterIP: s.Spec.ClusterIP,
		Ports: []ServicePort{}, Created: s.Metadata.CreationTimestamp, Selector: nonNilLabels(s.Spec.Selector),
	}
	if row.Type == "" {
		row.Type = "ClusterIP"
	}
	for _, p := range s.Spec.Ports {
		tp := targetPortString(p.TargetPort)
		if tp == "" {
			tp = strconv.Itoa(p.Port)
		}
		row.Ports = append(row.Ports, ServicePort{Name: p.Name, Port: p.Port, TargetPort: tp, Protocol: protocolOr(p.Protocol), NodePort: p.NodePort})
	}
	return row
}

func eventFromAPI(e *apiEvent) Event {
	ev := Event{Type: e.Type, Reason: e.Reason, Message: strings.TrimSpace(e.Message), Count: e.Count, Source: e.Source.Component}
	if ev.Source == "" {
		ev.Source = e.ReportingComponent
	}
	ev.LastSeen = e.LastTimestamp
	if e.Series != nil {
		ev.Count = max(ev.Count, e.Series.Count)
		if e.Series.LastObservedTime != "" {
			ev.LastSeen = e.Series.LastObservedTime
		}
	}
	for _, t := range []string{e.EventTime, e.FirstTimestamp, e.Metadata.CreationTimestamp} {
		if ev.LastSeen == "" {
			ev.LastSeen = t
		}
	}
	ev.Count = max(ev.Count, 1)
	return ev
}

func sortEventsNewestFirst(events []Event) {
	at := func(s string) time.Time {
		t, _ := time.Parse(time.RFC3339Nano, s)
		return t
	}
	sort.SliceStable(events, func(i, j int) bool { return at(events[i].LastSeen).After(at(events[j].LastSeen)) })
}
