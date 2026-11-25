package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"golens/core/docker"
	"golens/core/remote"
	"golens/core/runner"
)

func init() {
	docker.SSHDialer = remote.DialDockerSSH
}

func servicesJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"ok":false,"error":"GoLens could not encode the Docker response."}`)
	}
	return C.CString(string(b))
}

// Ownership: argument is copied; returns the watch id; batches arrive on the "services.docker.batch" status topic.
//
//export DockerWatchStart
func DockerWatchStart(cKinds *C.char) C.longlong {
	var kinds []string
	_ = json.Unmarshal([]byte(C.GoString(cKinds)), &kinds)
	return C.longlong(docker.WatchStart(kinds))
}

// Ownership: none; closes the watch and its engine connections.
//
//export DockerWatchStop
func DockerWatchStop(watchID C.longlong) {
	docker.WatchStop(int64(watchID))
}

// Ownership: arguments are copied; blocks up to 15 s for stop and restart; returns a C.malloc'd JSON {ok, error} freed with FreeGoCString.
//
//export DockerContainerAction
func DockerContainerAction(cID, cAction *C.char) *C.char {
	return servicesJSON(docker.ContainerAction(C.GoString(cID), C.GoString(cAction)))
}

// Ownership: argument is copied; blocks; returns a C.malloc'd JSON {container, error} freed with FreeGoCString.
//
//export DockerContainerInspect
func DockerContainerInspect(cID *C.char) *C.char {
	return servicesJSON(docker.InspectContainer(C.GoString(cID)))
}

// Ownership: argument is copied; returns the stream id or 0; lines arrive on the "services.docker.logs" status topic.
//
//export DockerLogsOpen
func DockerLogsOpen(cIDs *C.char, tail C.int) C.longlong {
	var ids []string
	if json.Unmarshal([]byte(C.GoString(cIDs)), &ids) != nil {
		return 0
	}
	return C.longlong(docker.LogsOpen(ids, int(tail)))
}

// Ownership: none; no further events are sent for the stream.
//
//export DockerLogsClose
func DockerLogsClose(streamID C.longlong) {
	docker.LogsClose(int64(streamID))
}

// Ownership: argument is copied; blocks; returns a C.malloc'd JSON {kind, items, error} freed with FreeGoCString.
//
//export DockerList
func DockerList(cKind *C.char) *C.char {
	return servicesJSON(docker.ListObjects(C.GoString(cKind)))
}

// Ownership: arguments are copied; blocks; removes a container, image, volume or network the UI confirmed; returns a C.malloc'd JSON {ok, error} freed with FreeGoCString.
//
//export DockerRemove
func DockerRemove(cKind, cID *C.char) *C.char {
	return servicesJSON(docker.RemoveObject(C.GoString(cKind), C.GoString(cID)))
}

// Ownership: blocks up to 60 s; returns a C.malloc'd JSON {categories:[{kind, count, bytes}], error} freed with FreeGoCString.
//
//export DockerDiskUsage
func DockerDiskUsage() *C.char {
	return servicesJSON(docker.TakeDiskUsage())
}

// Ownership: argument is copied; blocks until the engine finishes one kind; returns a C.malloc'd JSON {kind, removed, bytes, error} freed with FreeGoCString.
//
//export DockerPrune
func DockerPrune(cOptions *C.char) *C.char {
	var opts docker.PruneOptions
	if err := json.Unmarshal([]byte(C.GoString(cOptions)), &opts); err != nil {
		return servicesJSON(docker.PruneResult{Error: "GoLens couldn’t read the clean-up options."})
	}
	return servicesJSON(docker.Prune(opts))
}

// Ownership: argument is copied; returns the stream id or 0; samples arrive at most once per second on the "services.docker.stats" status topic.
//
//export DockerStatsStart
func DockerStatsStart(cID *C.char) C.longlong {
	return C.longlong(docker.StatsStart(C.GoString(cID)))
}

// Ownership: none; no further events are sent for the stream.
//
//export DockerStatsStop
func DockerStatsStop(streamID C.longlong) {
	docker.StatsStop(int64(streamID))
}

// Ownership: reads files only; returns a C.malloc'd JSON {current, contexts:[{name, description, endpoint, transport, current}], error} freed with FreeGoCString.
//
//export DockerContexts
func DockerContexts() *C.char {
	return servicesJSON(docker.Contexts())
}

// Ownership: argument is copied; blocks up to about 1 s while open streams close; never writes the Docker config; returns a C.malloc'd JSON {ok, error} freed with FreeGoCString.
//
//export DockerUseContext
func DockerUseContext(cName *C.char) *C.char {
	return servicesJSON(docker.UseContext(C.GoString(cName)))
}

// Ownership: arguments are copied; returns the console run id of a stream-backed Compose Logs session, or 0 without a compose file.
//
//export DockerComposeLogsRun
func DockerComposeLogsRun(cComposePath, cTitle, cKey *C.char) C.longlong {
	path, title, key := C.GoString(cComposePath), C.GoString(cTitle), C.GoString(cKey)
	if path == "" {
		return 0
	}
	if title == "" {
		title = "Compose Logs"
	}
	if key == "" {
		key = "compose-logs:" + path
	}
	return C.longlong(composeLogsRun(path, title, key))
}

func composeLogsRun(path, title, key string) int64 {
	outR, outW := io.Pipe()
	errR, errW := io.Pipe()
	ctx, cancel := context.WithCancel(context.Background())
	id := runner.StartStream(key, title, filepath.Dir(path), outR, runner.StreamOptions{Stderr: errR, OnStop: cancel})
	go func() {
		defer cancel()
		err := docker.FollowComposeLogs(ctx, path, 200, func(l docker.LogLine) {
			w := outW
			if l.Stderr {
				w = errW
			}
			if _, err := fmt.Fprintf(w, "%s | %s\n", l.Prefix, l.Text); err != nil {
				cancel()
			}
		})
		errW.Close()
		outW.CloseWithError(err)
	}()
	return id
}

// Ownership: arguments are copied; starts a host terminal whose PTY runs argv (a JSON array, argv[0] resolved on the extended PATH) with the StartTerminal callbacks.
//
//export StartTerminalCommand
func StartTerminalCommand(cTermID, cCwd, cArgv *C.char) {
	id, dir, raw := C.GoString(cTermID), C.GoString(cCwd), C.GoString(cArgv)
	go func() {
		var argv []string
		err := json.Unmarshal([]byte(raw), &argv)
		if err == nil {
			err = startTerminalCommand(id, dir, withDockerContext(argv, docker.CLIContextArgs()))
		}
		if err != nil {
			emitTerminal(id, []byte(fmt.Sprintf("Failed to launch terminal: %v\r\n", err)))
		}
	}()
}

func withDockerContext(argv, extra []string) []string {
	if len(extra) == 0 || len(argv) == 0 || filepath.Base(argv[0]) != "docker" {
		return argv
	}
	if len(argv) > 1 && (argv[1] == "-c" || argv[1] == "--context" || strings.HasPrefix(argv[1], "--context=")) {
		return argv
	}
	out := append([]string{argv[0]}, extra...)
	return append(out, argv[1:]...)
}
