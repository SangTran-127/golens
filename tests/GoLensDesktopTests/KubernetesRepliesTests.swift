import Foundation
import XCTest
import GoLensFoundation

final class KubernetesRepliesTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testContextsDecodeAndResolveTheCurrentContext() throws {
        let list = try decode(KubeContextList.self, """
        {"available":true,"current":"kind-dev","contexts":[
          {"name":"kind-dev","cluster":"kind-dev","user":"kind-dev","namespace":"default","server":"https://127.0.0.1:6443","local":true,"current":true},
          {"name":"prod","cluster":"prod","user":"prod","namespace":"api","server":"https://prod.example:443","local":false,"current":false,"authPlugin":"gke-gcloud-auth-plugin"}
        ]}
        """)
        XCTAssertTrue(list.available)
        XCTAssertEqual(list.contexts.map(\.name), ["kind-dev", "prod"])
        XCTAssertEqual(list.context("prod")?.authPlugin, "gke-gcloud-auth-plugin")
        XCTAssertEqual(list.context("prod")?.namespace, "api")
        XCTAssertEqual(list.resolved(""), "kind-dev")
        XCTAssertEqual(list.resolved("prod"), "prod")
        XCTAssertEqual(list.resolved("gone"), "kind-dev")
        let missing = try decode(KubeContextList.self, #"{"available":false,"current":"","contexts":[]}"#)
        XCTAssertFalse(missing.available)
        XCTAssertEqual(missing.resolved(""), "")
    }

    func testNamespacesForbiddenKeepsTheDefault() throws {
        let list = try decode(KubeNamespaceList.self, """
        {"context":"prod","defaultNamespace":"api","namespaces":[],
         "error":{"kind":"forbidden","message":"Your account can’t list namespaces in this cluster.","verb":"list","resource":"namespaces"}}
        """)
        XCTAssertEqual(list.defaultNamespace, "api")
        XCTAssertTrue(list.error?.isForbidden == true)
        XCTAssertEqual(list.error?.resource, "namespaces")
    }

    func testPodBatchDecodesRowsForItsKind() throws {
        let batch = try decode(KubeBatch.self, """
        {"seq":3,"watch":7,"context":"dev","namespace":"api","kind":"pods","state":"live","reset":true,
         "upserts":[
          {"name":"api-1","namespace":"api","phase":"Running","status":"Running","tone":"ok","ready":2,"total":2,"restarts":0,
           "created":"2026-11-16T08:00:00Z","containers":["app","sidecar"],"ports":[{"port":8080,"protocol":"TCP"},{"name":"metrics","port":9090}],
           "labels":{"app":"api"},"owner":{"kind":"ReplicaSet","name":"api-7d9f8"}},
          {"name":"crash-1","namespace":"api","phase":"Running","status":"CrashLoopBackOff","tone":"failure","ready":0,"total":1,"restarts":5,
           "created":"2026-11-16T08:00:00Z","containers":["app"],"ports":[],"labels":{}}
         ],"removals":[],"total":2,"truncated":false}
        """)
        XCTAssertEqual(batch.kind, .pods)
        XCTAssertEqual(batch.watch, 7)
        XCTAssertTrue(batch.reset)
        XCTAssertEqual(batch.pods.map(\.name), ["api-1", "crash-1"])
        XCTAssertEqual(batch.pods[0].tcpPorts, [8080, 9090])
        XCTAssertTrue(batch.pods[0].hasController)
        XCTAssertFalse(batch.pods[1].hasController)
        XCTAssertEqual(batch.pods[1].tone, .failure)
        XCTAssertTrue(batch.deployments.isEmpty)
        XCTAssertEqual(batch.upsertNames, ["api-1", "crash-1"])
    }

    func testPodDetailReadsLikeKubectl() throws {
        let now = try XCTUnwrap(KubeAge.date("2026-11-16T11:00:00Z"))
        let batch = try decode(KubeBatch.self, """
        {"kind":"pod","upserts":[
          {"name":"api-1","phase":"Running","status":"Running","tone":"ok","ready":2,"total":2,"restarts":0,"created":"2026-11-16T08:00:00Z"},
          {"name":"crash-1","phase":"Running","status":"CrashLoopBackOff","tone":"failure","ready":0,"total":1,"restarts":5,"created":"2026-11-16T08:00:00Z"},
          {"name":"new-1","phase":"Pending","status":"ContainerCreating","tone":"warning","ready":0,"total":1,"restarts":0,"created":"2026-11-16T10:59:48Z"}
        ]}
        """)
        XCTAssertEqual(batch.pods[0].detail(now: now), "2/2 ready · 0 restarts · 3h")
        XCTAssertEqual(batch.pods[1].detail(now: now), "5 restarts")
        XCTAssertEqual(batch.pods[2].detail(now: now), "0/1 ready · 12s")
    }

    func testAgeUsesTheLargestUnit() throws {
        let now = try XCTUnwrap(KubeAge.date("2026-11-16T11:00:00Z"))
        XCTAssertEqual(KubeAge.short(since: "2026-11-14T10:00:00Z", now: now), "2d")
        XCTAssertEqual(KubeAge.short(since: "2026-11-16T10:55:00.5Z", now: now), "4m")
        XCTAssertEqual(KubeAge.short(since: "", now: now), "")
    }

    func testDeploymentsAndServicesDecode() throws {
        let deployments = try decode(KubeBatch.self, """
        {"kind":"deployments","upserts":[{"name":"api","desired":3,"ready":2,"updated":3,"available":2,"paused":false,"tone":"warning","selector":{"app":"api"}}]}
        """)
        let deployment = try XCTUnwrap(deployments.deployments.first)
        XCTAssertEqual(deployment.readyText, "2/3 ready")
        XCTAssertEqual(deployment.tone, .warning)
        let pods = try decode(KubeBatch.self, """
        {"kind":"pods","upserts":[{"name":"a","labels":{"app":"api","pod-template-hash":"x"}},{"name":"b","labels":{"app":"web"}}]}
        """)
        XCTAssertEqual(pods.pods.filter(deployment.selects).map(\.name), ["a"])
        let services = try decode(KubeBatch.self, """
        {"kind":"services","upserts":[{"name":"api","type":"ClusterIP","clusterIP":"10.0.0.1",
          "ports":[{"name":"http","port":80,"targetPort":"8080","protocol":"TCP"},{"port":53,"targetPort":53,"protocol":"UDP"}],"selector":{"app":"api"}},
          {"name":"kubernetes","type":"ClusterIP","ports":[{"port":443,"targetPort":"6443","protocol":"TCP"}],"selector":{}}]}
        """)
        XCTAssertEqual(services.services[0].portsText, "80→8080, 53/UDP")
        XCTAssertEqual(services.services[0].tcpPorts, [80])
        XCTAssertTrue(services.services[0].canForward)
        XCTAssertFalse(services.services[1].canForward)
    }

    func testRowsMergeRemoveAndSortByName() throws {
        let first = try decode(KubeBatch.self, #"{"kind":"pods","reset":true,"upserts":[{"name":"b","status":"Running"},{"name":"a","status":"Pending"}]}"#)
        var rows = KubeRows.merge([], upserts: first.pods, removals: [], reset: true)
        XCTAssertEqual(rows.map(\.name), ["a", "b"])
        let next = try decode(KubeBatch.self, #"{"kind":"pods","upserts":[{"name":"a","status":"Running"},{"name":"c","status":"Pending"}],"removals":["b"]}"#)
        rows = KubeRows.merge(rows, upserts: next.pods, removals: next.removals, reset: false)
        XCTAssertEqual(rows.map(\.name), ["a", "c"])
        XCTAssertEqual(rows[0].status, "Running")
        XCTAssertEqual(KubeRows.capNote(shown: 500, total: 1234, truncated: true), "Showing 500 of 1,234. Filter to narrow.")
        XCTAssertNil(KubeRows.capNote(shown: 20, total: 20, truncated: false))
    }

    func testErrorStatesAndLogBatches() throws {
        let batch = try decode(KubeBatch.self, """
        {"kind":"pods","state":"error","error":{"kind":"needsSignIn","message":"Your sign-in for “eks” has expired.","plugin":"aws","server":"https://x","signInCommand":["aws","sso","login","--profile","dev"]}}
        """)
        XCTAssertEqual(batch.state, "error")
        XCTAssertEqual(batch.error?.signInCommand, ["aws", "sso", "login", "--profile", "dev"])
        let logs = try decode(KubeLogBatch.self, #"{"stream":4,"lines":[{"text":"hello","stderr":false,"prefix":""}],"dropped":3}"#)
        XCTAssertEqual(logs.lines.map(\.text), ["hello"])
        XCTAssertEqual(logs.dropped, 3)
        XCTAssertFalse(logs.closed)
        let ended = try decode(KubeLogBatch.self, #"{"stream":4,"lines":[],"closed":true,"reason":"error","error":{"kind":"other","message":"previous terminated container \"app\" in pod \"api-1\" not found."}}"#)
        XCTAssertTrue(ended.closed)
        XCTAssertEqual(ended.error?.kind, "other")
        let refused = try decode(KubeActionResult.self, #"{"ok":false,"error":{"kind":"forbidden","message":"Your account can’t delete pods in “api”.","verb":"delete","resource":"pods","namespace":"api"}}"#)
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.error?.namespace, "api")
        XCTAssertTrue(try decode(KubeActionResult.self, #"{"ok":true}"#).ok)
    }

    func testDetailsDecodeContainersConditionsAndEvents() throws {
        let details = try decode(KubeDetails.self, """
        {"context":"dev","namespace":"api","kind":"pods","name":"crash-1","created":"2026-11-16T08:00:00Z","labels":{"app":"crash"},
         "overview":[{"label":"Status","value":"CrashLoopBackOff"},{"label":"Restarts","value":"5"}],
         "containers":[{"name":"app","image":"busybox:1.36","state":"waiting","reason":"CrashLoopBackOff","ready":false,"restarts":5,
           "lastTermination":{"reason":"Error","exitCode":1,"finishedAt":"2026-11-16T08:10:00Z"},"requests":{"cpu":"10m","memory":"16Mi"},"limits":{},"ports":[]}],
         "conditions":[{"type":"Ready","status":"False","reason":"ContainersNotReady"}],
         "events":[{"type":"Warning","reason":"BackOff","message":"Back-off restarting failed container","count":12,"lastSeen":"2026-11-16T08:11:00Z","source":"kubelet"}]}
        """)
        XCTAssertEqual(details.overview.map(\.label), ["Status", "Restarts"])
        XCTAssertEqual(details.containers.first?.lastTermination?.exitCode, 1)
        XCTAssertEqual(KubeContainerDetail.resources(details.containers[0].requests), "cpu 10m, memory 16Mi")
        XCTAssertTrue(details.events[0].isWarning)
        XCTAssertNil(details.error)
        let failed = try decode(KubeDetails.self, #"{"error":{"kind":"notFound","message":"The pod “x” doesn’t exist in “api”."}}"#)
        XCTAssertTrue(failed.error?.isNotFound == true)
    }

    func testManifestSniffingNeedsTopLevelApiVersionAndKind() {
        XCTAssertTrue(KubeManifest.isManifest("# app\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: api\n"))
        XCTAssertTrue(KubeManifest.isManifest("---\nkind: Service\napiVersion: v1\n"))
        XCTAssertFalse(KubeManifest.isManifest("services:\n  api:\n    image: x\n"))
        XCTAssertFalse(KubeManifest.isManifest("spec:\n  apiVersion: v1\n  kind: Thing\n"))
        XCTAssertFalse(KubeManifest.isManifest(String(repeating: "x: y\n", count: 1000) + "apiVersion: v1\nkind: Service\n"))
    }

    func testKubectlDiffSplitsIntoObjects() {
        let output = """
        diff -u -N /tmp/LIVE-1/apps.v1.Deployment.smoke.api /tmp/MERGED-1/apps.v1.Deployment.smoke.api
        --- /tmp/LIVE-1/apps.v1.Deployment.smoke.api\t2026-11-16 10:00:00
        +++ /tmp/MERGED-1/apps.v1.Deployment.smoke.api\t2026-11-16 10:00:00
        @@ -5,7 +5,7 @@
             spec:
        -      image: nginx:1.27
        +      image: nginx:does-not-exist
        diff -u -N /tmp/LIVE-1/v1.Service.smoke.api /tmp/MERGED-1/v1.Service.smoke.api
        --- /tmp/LIVE-1/v1.Service.smoke.api\t2026-11-16 10:00:00
        +++ /tmp/MERGED-1/v1.Service.smoke.api\t2026-11-16 10:00:00
        @@ -0,0 +1,3 @@
        +apiVersion: v1
        +kind: Service
        +metadata: {}
        """
        let objects = KubeDiffObject.split(output)
        XCTAssertEqual(objects.map(\.title), ["Deployment “api”", "Service “api” (New)"])
        XCTAssertEqual(objects.map(\.namespace), ["smoke", "smoke"])
        XCTAssertTrue(objects[0].patch.hasPrefix("--- /tmp/LIVE-1/apps.v1.Deployment.smoke.api"))
        XCTAssertTrue(objects[1].patch.contains("+kind: Service"))
        XCTAssertTrue(KubeDiffObject.split("").isEmpty)
    }

    func testCommandLinesNameContextAndNamespace() {
        XCTAssertEqual(
            KubeCommandLine.exec(kubectl: "kubectl", context: "dev", namespace: "api", pod: "api-1", container: "app"),
            ["kubectl", "--context", "dev", "-n", "api", "exec", "-it", "api-1", "-c", "app", "--", "sh", "-c", "if command -v bash >/dev/null; then exec bash; else exec sh; fi"]
        )
        XCTAssertEqual(
            KubeCommandLine.portForward(kubectl: "/usr/local/bin/kubectl", context: "dev", namespace: "api", target: "svc/api", local: 8081, remote: 80),
            ["/usr/local/bin/kubectl", "--context", "dev", "-n", "api", "port-forward", "svc/api", "8081:80"]
        )
        XCTAssertEqual(KubeCommandLine.forwardTitle(target: "svc/api", local: 8081, remote: 80), "Forward localhost:8081 → svc/api:80")
        let key = KubeCommandLine.forwardKey(context: "dev", namespace: "api", target: "svc/api", local: 8081, remote: 80)
        let parsed = KubeCommandLine.parseForwardKey(key)
        XCTAssertEqual(parsed?.target, "svc/api")
        XCTAssertEqual(parsed?.local, 8081)
        XCTAssertNil(KubeCommandLine.parseForwardKey("docker:compose:x"))
        XCTAssertEqual(KubeCommandLine.diff(kubectl: "kubectl", context: "dev", namespace: "api", file: "/tmp/m.yaml"), ["kubectl", "--context", "dev", "-n", "api", "diff", "-f", "/tmp/m.yaml"])
    }

    func testWatchScopeResetsWhenTheContextOrNamespaceChanges() {
        XCTAssertFalse(KubeWatchScope.needsReset(previousContext: "", previousNamespace: "", context: "dev", namespace: "api"))
        XCTAssertFalse(KubeWatchScope.needsReset(previousContext: "dev", previousNamespace: "api", context: "dev", namespace: "api"))
        XCTAssertTrue(KubeWatchScope.needsReset(previousContext: "dev", previousNamespace: "api", context: "prod", namespace: "api"))
        XCTAssertTrue(KubeWatchScope.needsReset(previousContext: "dev", previousNamespace: "api", context: "dev", namespace: "web"))
    }
}
