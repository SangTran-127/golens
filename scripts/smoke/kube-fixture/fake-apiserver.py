#!/usr/bin/env python3
"""A tiny Kubernetes API stand-in for the Kubernetes journey.

Serves namespaces "api" (two pods, one deployment, one service) and "locked" (every list is
forbidden), holds watches open as close-delimited streams and logs each request, and each watch
opening and closing, with a millisecond timestamp to the requests file:

  <ms> GET <path>?<query>
  <ms> WATCH open <namespace> <kind>
  <ms> WATCH close <namespace> <kind>

Usage: fake-apiserver.py <port> <requests-log>
"""
import json
import select
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(sys.argv[1])
LOG = open(sys.argv[2], "a", buffering=1)
LOCK = threading.Lock()


def log(line):
    with LOCK:
        LOG.write(f"{int(time.time() * 1000)} {line}\n")


def meta(name, ns, labels=None, owner=None):
    m = {"name": name, "namespace": ns, "resourceVersion": "10", "creationTimestamp": "2026-11-16T08:00:00Z",
         "labels": labels or {}}
    if owner:
        m["ownerReferences"] = [{"kind": "ReplicaSet", "name": owner, "controller": True}]
    return m


def pod(name, running=True):
    status = {"phase": "Running", "podIP": "10.1.0.7", "qosClass": "BestEffort",
              "conditions": [{"type": "Ready", "status": "True" if running else "False"}]}
    if running:
        status["containerStatuses"] = [{"name": "app", "image": "api:1", "ready": True, "restartCount": 0,
                                        "state": {"running": {"startedAt": "2026-11-16T08:00:05Z"}}}]
    else:
        status["containerStatuses"] = [{"name": "app", "image": "api:1", "ready": False, "restartCount": 4,
                                        "state": {"waiting": {"reason": "CrashLoopBackOff", "message": "back-off"}},
                                        "lastState": {"terminated": {"reason": "Error", "exitCode": 1,
                                                                     "finishedAt": "2026-11-16T08:10:00Z"}}}]
    return {"kind": "Pod", "apiVersion": "v1", "metadata": meta(name, "api", {"app": "api"}, "api-7d9f8"),
            "spec": {"nodeName": "node-1", "containers": [{"name": "app", "image": "api:1",
                                                           "ports": [{"containerPort": 8080, "protocol": "TCP"}]}]},
            "status": status}


OBJECTS = {
    "pods": [pod("api-7d9f8-a1"), pod("api-7d9f8-b2", running=False)],
    "deployments": [{"kind": "Deployment", "apiVersion": "apps/v1", "metadata": meta("api", "api", {"app": "api"}),
                     "spec": {"replicas": 2, "selector": {"matchLabels": {"app": "api"}}, "strategy": {"type": "RollingUpdate"},
                              "template": {"spec": {"containers": [{"name": "app", "image": "api:1"}]}}},
                     "status": {"replicas": 2, "readyReplicas": 1, "updatedReplicas": 2, "availableReplicas": 1,
                                "unavailableReplicas": 1}}],
    "services": [{"kind": "Service", "apiVersion": "v1", "metadata": meta("api-svc", "api"),
                  "spec": {"type": "ClusterIP", "clusterIP": "10.0.0.9", "selector": {"app": "api"},
                           "ports": [{"name": "http", "port": 80, "targetPort": 8080, "protocol": "TCP"}]}}],
}
KIND_NAMES = {"pods": "Pod", "deployments": "Deployment", "services": "Service"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, code, body, close=False):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if close:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def forbidden(self, verb, resource, ns):
        where = f'in the namespace "{ns}"' if ns else "at the cluster scope"
        self.send_json(403, {"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "Forbidden", "code": 403,
                             "message": f'{resource} is forbidden: User "smoke" cannot {verb} resource "{resource}" {where}'})

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        log(f"GET {url.path}?{url.query}")
        parts = [p for p in url.path.split("/") if p]
        if url.path == "/api/v1/namespaces":
            self.forbidden("list", "namespaces", "")
            return
        if url.path in ("/version", "/api", "/apis"):
            self.send_json(200, {"major": "1", "minor": "31", "gitVersion": "v1.31.0"})
            return
        ns, kind, name, sub = None, None, None, None
        if len(parts) >= 5 and parts[:3] == ["api", "v1", "namespaces"]:
            ns, kind = parts[3], parts[4]
            name = parts[5] if len(parts) > 5 else None
            sub = parts[6] if len(parts) > 6 else None
        elif len(parts) >= 6 and parts[:4] == ["apis", "apps", "v1", "namespaces"]:
            ns, kind = parts[4], parts[5]
            name = parts[6] if len(parts) > 6 else None
        if kind is None:
            self.send_json(404, {"kind": "Status", "status": "Failure", "reason": "NotFound", "code": 404, "message": "not found"})
            return
        if ns == "locked":
            self.forbidden("watch" if query.get("watch") else "list", kind, ns)
            return
        if kind == "events":
            self.send_json(200, {"kind": "EventList", "items": [{"metadata": meta("ev1", ns), "type": "Warning", "reason": "BackOff",
                                                                 "message": "Back-off restarting failed container app",
                                                                 "count": 7, "lastTimestamp": "2026-11-16T08:11:00Z",
                                                                 "source": {"component": "kubelet"}}]})
            return
        items = OBJECTS.get(kind, []) if ns == "api" else []
        if name and sub == "log":
            self.send_log(query)
            return
        if name:
            found = [o for o in items if o["metadata"]["name"] == name]
            if found:
                self.send_json(200, found[0])
            else:
                self.send_json(404, {"kind": "Status", "status": "Failure", "reason": "NotFound", "code": 404,
                                     "message": f'{kind} "{name}" not found', "details": {"name": name, "kind": kind}})
            return
        if query.get("watch"):
            self.hold_watch(ns, kind)
            return
        self.send_json(200, {"kind": KIND_NAMES.get(kind, "Object") + "List", "metadata": {"resourceVersion": "10"}, "items": items})

    def send_log(self, query):
        body = "".join(f"fake api line {i}\n" for i in range(1, 6)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def hold_watch(self, ns, kind):
        log(f"WATCH open {ns} {kind}")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        sock = self.connection
        last = time.time()
        try:
            while True:
                readable, _, _ = select.select([sock], [], [], 0.25)
                if readable:
                    if sock.recv(1, socket.MSG_PEEK) == b"":
                        break
                if time.time() - last > 5:
                    event = {"type": "BOOKMARK", "object": {"kind": KIND_NAMES.get(kind, "Object"), "apiVersion": "v1",
                                                            "metadata": {"resourceVersion": "10"}}}
                    self.wfile.write((json.dumps(event) + "\n").encode())
                    self.wfile.flush()
                    last = time.time()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        log(f"WATCH close {ns} {kind}")
        self.close_connection = True


ThreadingHTTPServer.daemon_threads = True
server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
log("READY")
server.serve_forever()
