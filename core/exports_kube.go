package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"

	"golens/core/kube"
)

func kubeJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"ok":false,"error":{"kind":"other","message":"GoLens could not encode the Kubernetes response."}}`)
	}
	return C.CString(string(b))
}

// Ownership: none; reads local kubeconfig files only; returns a C.malloc'd JSON {available, current, contexts, error} freed with FreeGoCString.
//
//export KubeContexts
func KubeContexts() *C.char {
	return kubeJSON(kube.Contexts())
}

// Ownership: argument is copied; blocks up to 15 s; returns a C.malloc'd JSON {context, defaultNamespace, namespaces, error} freed with FreeGoCString.
//
//export KubeNamespaces
func KubeNamespaces(cContext *C.char) *C.char {
	return kubeJSON(kube.Namespaces(C.GoString(cContext)))
}

// Ownership: arguments are copied; returns the watch id; batches arrive on the "services.kube.batch" status topic.
//
//export KubeWatchStart
func KubeWatchStart(cContext, cNamespace, cKinds *C.char) C.longlong {
	var kinds []string
	_ = json.Unmarshal([]byte(C.GoString(cKinds)), &kinds)
	return C.longlong(kube.WatchStart(C.GoString(cContext), C.GoString(cNamespace), kinds))
}

// Ownership: none; closes the watch and its cluster connections.
//
//export KubeWatchStop
func KubeWatchStop(watchID C.longlong) {
	kube.WatchStop(int64(watchID))
}

// Ownership: arguments are copied; blocks up to 30 s; returns a C.malloc'd JSON Details freed with FreeGoCString.
//
//export KubeDetails
func KubeDetails(cContext, cNamespace, cKind, cName *C.char) *C.char {
	return kubeJSON(kube.DetailsOf(C.GoString(cContext), C.GoString(cNamespace), C.GoString(cKind), C.GoString(cName)))
}

// Ownership: arguments are copied; returns the stream id or 0; lines arrive on the "services.kube.logs" status topic.
//
//export KubeLogsOpen
func KubeLogsOpen(cContext, cNamespace, cPod, cContainer *C.char, previous C.int, tail C.int) C.longlong {
	return C.longlong(kube.LogsOpen(kube.LogsOptions{
		Context: C.GoString(cContext), Namespace: C.GoString(cNamespace), Pod: C.GoString(cPod),
		Container: C.GoString(cContainer), Previous: previous != 0, Tail: int(tail),
	}))
}

// Ownership: none; no further events are sent for the stream.
//
//export KubeLogsClose
func KubeLogsClose(streamID C.longlong) {
	kube.LogsClose(int64(streamID))
}

// Ownership: arguments are copied; blocks up to 15 s; deletes a pod the UI confirmed; returns a C.malloc'd JSON {ok, error} freed with FreeGoCString.
//
//export KubeDeletePod
func KubeDeletePod(cContext, cNamespace, cName *C.char) *C.char {
	return kubeJSON(kube.DeletePod(C.GoString(cContext), C.GoString(cNamespace), C.GoString(cName)))
}

// Ownership: arguments are copied; blocks up to 15 s; restarts a deployment the UI confirmed; returns a C.malloc'd JSON {ok, error} freed with FreeGoCString.
//
//export KubeRolloutRestart
func KubeRolloutRestart(cContext, cNamespace, cName *C.char) *C.char {
	return kubeJSON(kube.RolloutRestart(C.GoString(cContext), C.GoString(cNamespace), C.GoString(cName)))
}
