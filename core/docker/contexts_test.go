package docker

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

func (h resolverHome) contextWithDescription(name, host, description string) {
	h.write(filepath.Join(".docker", "contexts", "meta", contextDirName(name), "meta.json"),
		`{"Name":"`+name+`","Metadata":{"Description":"`+description+`"},"Endpoints":{"docker":{"Host":"`+host+`","SkipTLSVerify":false}}}`)
}

func (h resolverHome) tls(name, file, content string) {
	h.write(filepath.Join(".docker", "contexts", "tls", contextDirName(name), "docker", file), content)
}

func forgetChosenContext(t *testing.T) {
	t.Cleanup(func() {
		chosenContext.Lock()
		chosenContext.name = ""
		chosenContext.Unlock()
		clientCache.Lock()
		clientCache.c = nil
		clientCache.Unlock()
	})
}

func TestContextsListsTransportsAndCurrent(t *testing.T) {
	h := newResolverHome(t)
	forgetChosenContext(t)
	h.write(".docker/config.json", `{"currentContext":"dev"}`)
	h.contextWithDescription("dev", "ssh://deploy@dev.example:2222", "Dev box")
	h.contextWithDescription("secure", "tcp://10.0.0.5:2376", "")
	h.tls("secure", "ca.pem", "ca")
	h.tls("secure", "cert.pem", "cert")
	h.tls("secure", "key.pem", "key")
	h.contextWithDescription("plain", "tcp://10.0.0.6:2375", "")
	h.contextWithDescription("local", "unix:///tmp/local.sock", "")
	h.write(".docker/contexts/meta/broken/meta.json", `{"Name":"broken"`)
	orb := h.write(".orbstack/run/docker.sock", "")

	list := Contexts()
	want := []ContextInfo{
		{Name: "default", Description: "Current DOCKER_HOST based configuration", Endpoint: "unix://" + orb, Transport: "unix"},
		{Name: "dev", Description: "Dev box", Endpoint: "ssh://deploy@dev.example:2222", Transport: "ssh", Current: true},
		{Name: "local", Endpoint: "unix:///tmp/local.sock", Transport: "unix"},
		{Name: "plain", Endpoint: "tcp://10.0.0.6:2375", Transport: "tcp"},
		{Name: "secure", Endpoint: "tcp://10.0.0.5:2376", Transport: "tls"},
	}
	if list.Current != "dev" || list.Error != "" || !reflect.DeepEqual(list.Contexts, want) {
		t.Fatalf("contexts = %+v", list)
	}

	if res := UseContext("secure"); !res.OK {
		t.Fatalf("use secure = %+v", res)
	}
	ep := resolve(t)
	dir := filepath.Join(h.home, ".docker", "contexts", "tls", contextDirName("secure"), "docker")
	if ep.Context != "secure" || ep.Source != "golens" || !ep.TLS || ep.CAFile != filepath.Join(dir, "ca.pem") ||
		ep.CertFile != filepath.Join(dir, "cert.pem") || ep.KeyFile != filepath.Join(dir, "key.pem") {
		t.Fatalf("secure endpoint = %+v", ep)
	}
	if list := Contexts(); list.Current != "secure" || !list.Contexts[4].Current || list.Contexts[1].Current {
		t.Fatalf("after UseContext = %+v", list)
	}
	if data, _ := json.Marshal(ep); strings.Contains(string(data), "pem") {
		t.Fatalf("TLS paths must stay out of JSON: %s", data)
	}

	if res := UseContext("missing"); res.OK || res.Error != "There’s no Docker context named “missing”." {
		t.Fatalf("missing context = %+v", res)
	}
	if res := UseContext(" "); res.OK {
		t.Fatalf("empty name = %+v", res)
	}
	if CurrentContext() != "secure" {
		t.Fatal("a refused switch must keep the current context")
	}
}

func TestChosenContextWinsOverEnvironmentAndReachesCLISessions(t *testing.T) {
	h := newResolverHome(t)
	forgetChosenContext(t)
	h.contextWithDescription("local", "unix:///tmp/local.sock", "")
	t.Setenv("DOCKER_HOST", "unix:///env/host.sock")
	t.Setenv("DOCKER_CONTEXT", "other")
	if CurrentContext() != "default" || CLIContextArgs() != nil {
		t.Fatal("without a choice GoLens follows DOCKER_HOST like the CLI")
	}
	if env := Env(); !slices.Contains(env, "DOCKER_HOST=unix:///env/host.sock") || !slices.Contains(env, "DOCKER_CONTEXT=other") {
		t.Fatal("without a choice the environment passes through unchanged")
	}
	if res := UseContext("local"); !res.OK {
		t.Fatal(res.Error)
	}
	if ep := resolve(t); ep.Socket != "/tmp/local.sock" || ep.Context != "local" {
		t.Fatalf("chosen context = %+v", ep)
	}
	env := Env()
	if !slices.Contains(env, "DOCKER_CONTEXT=local") || slices.Contains(env, "DOCKER_CONTEXT=other") || slices.ContainsFunc(env, func(kv string) bool { return strings.HasPrefix(kv, "DOCKER_HOST=") }) {
		t.Fatalf("CLI env = %v", env)
	}
	if got := CLIContextArgs(); !reflect.DeepEqual(got, []string{"--context", "local"}) {
		t.Fatalf("CLI args = %v", got)
	}
	if res := UseContext("default"); !res.OK {
		t.Fatal(res.Error)
	}
	if ep := resolve(t); ep.Socket != "/env/host.sock" || ep.Context != "default" {
		t.Fatalf("default keeps DOCKER_HOST = %+v", ep)
	}
	if env := Env(); !slices.Contains(env, "DOCKER_CONTEXT=default") || !slices.Contains(env, "DOCKER_HOST=unix:///env/host.sock") {
		t.Fatalf("default CLI env = %v", env)
	}
}

func writePEM(t *testing.T, h resolverHome, name, file, kind string, der []byte) {
	h.tls(name, file, string(pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: der})))
}

func TestTLSContextConnectsWithItsCertificates(t *testing.T) {
	h := newResolverHome(t)
	forgetChosenContext(t)
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "golens-client"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	clientDER, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	clientCert, _ := x509.ParseCertificate(clientDER)
	pool := x509.NewCertPool()
	pool.AddCert(clientCert)
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(r.TLS.PeerCertificates) == 0 {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/_ping":
			w.Header().Set("API-Version", "1.47")
			w.Write([]byte("OK"))
		case "/v1.47/version":
			writeJSON(w, map[string]any{"Version": "28.0.0", "ApiVersion": "1.47"})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	srv.TLS = &tls.Config{ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: pool}
	srv.StartTLS()
	t.Cleanup(srv.Close)
	keyDER, _ := x509.MarshalECPrivateKey(key)
	writePEM(t, h, "secure", "ca.pem", "CERTIFICATE", srv.Certificate().Raw)
	writePEM(t, h, "secure", "cert.pem", "CERTIFICATE", clientDER)
	writePEM(t, h, "secure", "key.pem", "EC PRIVATE KEY", keyDER)
	h.contextWithDescription("secure", "tcp://"+srv.Listener.Addr().String(), "")
	if res := UseContext("secure"); !res.OK {
		t.Fatal(res.Error)
	}
	c, err := engineClient(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if v, err := c.Version(context.Background()); err != nil || v.Version != "28.0.0" || c.scheme != "https" {
		t.Fatalf("version over TLS = %+v, %v", v, err)
	}

	h.contextWithDescription("nocert", "tcp://"+srv.Listener.Addr().String(), "")
	writePEM(t, h, "nocert", "ca.pem", "CERTIFICATE", srv.Certificate().Raw)
	if res := UseContext("nocert"); !res.OK {
		t.Fatal(res.Error)
	}
	if _, err := engineClient(context.Background()); err == nil {
		t.Fatal("a server that wants a client certificate must refuse a context without one")
	}
}

func TestSSHEndpointUsesTheInjectedDialerAndCarriesItsIssue(t *testing.T) {
	f := newFakeEngine(t, nil)
	h := newResolverHome(t)
	forgetChosenContext(t)
	h.contextWithDescription("vps", "ssh://deploy@vps.example", "")
	old := SSHDialer
	t.Cleanup(func() { SSHDialer = old })
	var hosts []string
	SSHDialer = func(ctx context.Context, host string) (net.Conn, error) {
		hosts = append(hosts, host)
		var d net.Dialer
		return d.DialContext(ctx, "unix", f.Socket)
	}
	if res := UseContext("vps"); !res.OK {
		t.Fatal(res.Error)
	}
	snap := TakeSnapshot(Scope{})
	if snap.Engine.State != "running" || snap.Engine.Context != "vps" || snap.Engine.Endpoint != "ssh://deploy@vps.example" || snap.Engine.Issue != nil {
		t.Fatalf("snapshot over ssh = %+v", snap.Engine)
	}
	if len(hosts) == 0 || hosts[0] != "ssh://deploy@vps.example" {
		t.Fatalf("dialed %v", hosts)
	}

	closeEngineConnections()
	issue := Issue{Code: "hostKeyUnknown", Title: "Unknown Host Key", Message: "vps.example isn’t in your known_hosts yet.", Fix: "openTerminal",
		FixTitle: "Connect in Terminal", Command: "ssh deploy@vps.example exit"}
	SSHDialer = func(ctx context.Context, host string) (net.Conn, error) { return nil, &IssueError{Issue: issue} }
	snap = TakeSnapshot(Scope{})
	if snap.Engine.State != "down" || snap.Engine.Reason != ReasonDown || snap.Engine.Issue == nil || *snap.Engine.Issue != issue ||
		snap.Engine.Error != issue.Message || snap.Engine.Context != "vps" {
		t.Fatalf("snapshot with an ssh issue = %+v", snap.Engine)
	}
	data, _ := json.Marshal(snap.Engine)
	if !strings.Contains(string(data), `"issue":{"code":"hostKeyUnknown","title":"Unknown Host Key"`) || !strings.Contains(string(data), `"command":"ssh deploy@vps.example exit"`) {
		t.Fatalf("engine JSON = %s", data)
	}
}

func contextEngine(t *testing.T, h resolverHome, name string) *svcEngine {
	s := newSvcEngine(t)
	h.contextWithDescription(name, "unix://"+s.Socket, "")
	return s
}

func TestUseContextClosesWatchLogsAndStats(t *testing.T) {
	h := newResolverHome(t)
	forgetChosenContext(t)
	a := contextEngine(t, h, "a")
	b := contextEngine(t, h, "b")
	t.Setenv("DOCKER_HOST", "")
	a.add(&svcContainer{ID: hexID("a1"), Name: "api", Image: "api", Labels: map[string]string{}, Logs: []fakeLogLine{{Text: "hello"}}})
	b.add(&svcContainer{ID: hexID("b1"), Name: "worker", Image: "worker", Labels: map[string]string{}})
	statsEnded := make(chan struct{}, 1)
	a.Handle("GET /v1.47/containers/{id}/stats", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{"memory_stats": map[string]any{"usage": 10, "limit": 100}})
		w.(http.Flusher).Flush()
		<-r.Context().Done()
		statsEnded <- struct{}{}
	})
	rec := recordStatus(t)
	if res := UseContext("a"); !res.OK {
		t.Fatal(res.Error)
	}
	watch := WatchStart([]string{"containers"})
	if bs := rec.batches(t, 1); !bs[0].Reset || bs[0].Engine.Context != "a" || len(bs[0].Upserts) != 1 || bs[0].Upserts[0].Name != "api" {
		t.Fatalf("first batch = %+v", bs[0])
	}
	logs := LogsOpen([]string{hexID("a1")}, 10)
	rec.waitFor(t, LogsTopic, 1)
	stats := StatsStart(hexID("a1"))
	rec.waitFor(t, StatsTopic, 1)

	if res := UseContext("b"); !res.OK {
		t.Fatal(res.Error)
	}
	select {
	case <-statsEnded:
	case <-time.After(time.Second):
		t.Fatal("the stats request on the old engine stayed open")
	}
	if openLogStreams() != 0 || openStatsStreams() != 0 {
		t.Fatal("streams still open after the switch")
	}
	var logClosed LogsEvent
	for _, p := range rec.waitFor(t, LogsTopic, 2) {
		var ev LogsEvent
		json.Unmarshal([]byte(p), &ev)
		if ev.Closed {
			logClosed = ev
		}
	}
	if logClosed.Stream != logs || logClosed.Error != "" {
		t.Fatalf("logs closed event = %+v", logClosed)
	}
	var statsClosed StatsEvent
	json.Unmarshal([]byte(rec.waitFor(t, StatsTopic, 2)[1]), &statsClosed)
	if !statsClosed.Closed || statsClosed.Stream != stats || statsClosed.Error != "" {
		t.Fatalf("stats closed event = %+v", statsClosed)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		bs := rec.batches(t, 1)
		last := bs[len(bs)-1]
		if last.Reset && last.Engine.Context == "b" {
			if len(last.Upserts) != 1 || last.Upserts[0].Name != "worker" {
				t.Fatalf("batch after the switch = %+v", last)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the watch never reconnected to b: %+v", last)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, _, _, conns := b.snapshot(); conns != 1 {
		t.Fatalf("events connections on b = %d", conns)
	}
	WatchStop(watch)
}
