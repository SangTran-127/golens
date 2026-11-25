package main

import (
	"encoding/json"
	"log"
	"net"
	"net/http"
	"os"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/reflection"
)

func main() {
	httpAddr := os.Getenv("HTTP_ADDR")
	grpcAddr := os.Getenv("GRPC_ADDR")
	go func() {
		ln, err := net.Listen("tcp", grpcAddr)
		if err != nil {
			log.Fatal(err)
		}
		s := grpc.NewServer()
		hs := health.NewServer()
		hs.SetServingStatus("orders", healthpb.HealthCheckResponse_SERVING)
		healthpb.RegisterHealthServer(s, hs)
		reflection.Register(s)
		log.Fatal(s.Serve(ln))
	}()
	mux := http.NewServeMux()
	mux.HandleFunc("POST /login", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ User, Password string }
		_ = json.NewDecoder(r.Body).Decode(&in)
		w.Header().Set("Content-Type", "application/json")
		if in.Password != "secret" {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"wrong password"}`))
			return
		}
		_, _ = w.Write([]byte(`{"token":"tok-` + in.User + `","expiresIn":3600}`))
	})
	mux.HandleFunc("GET /users", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer tok-") {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"missing token"}`))
			return
		}
		_, _ = w.Write([]byte(`{"users":[{"id":1,"name":"Ana","email":"ana@example.com","roles":["admin","dev"]},{"id":2,"name":"Bao","email":"bao@example.com","roles":["dev"]},{"id":3,"name":"Chi","email":"chi@example.com","roles":[]}],"total":3}`))
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) })
	log.Fatal(http.ListenAndServe(httpAddr, mux))
}
