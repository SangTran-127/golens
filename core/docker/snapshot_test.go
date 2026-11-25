package docker

import "context"

type Snapshot struct {
	Engine     EngineState `json:"engine"`
	Containers []Container `json:"containers"`
	Projects   []Project   `json:"projects"`
}

func TakeSnapshot(scope Scope) Snapshot {
	ctx, cancel := context.WithTimeout(context.Background(), engineTimeout(snapshotTimeout))
	defer cancel()
	snap := Snapshot{Containers: []Container{}, Projects: []Project{}}
	c, err := engineClient(ctx)
	if err == nil {
		var list []apiContainer
		list, err = listContainers(ctx, c, nil)
		for _, a := range list {
			snap.Containers = append(snap.Containers, containerFromAPI(a))
		}
	}
	if err != nil {
		forgetClient(err)
	}
	sortContainers(snap.Containers)
	snap.Projects = groupProjects(snap.Containers, scope)
	snap.Engine = engineStateFor(c, err)
	return snap
}
