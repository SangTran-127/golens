package main

import (
	"log"
	"net/http"
	"os"
)

func main() {
	repo := NewSQLRepository(newMemoryExecer())
	svc := NewService(repo, NewInventory(map[string]int{"sku-1": 10}))
	mux := http.NewServeMux()
	NewHandler(svc).Routes(mux)
	addr := os.Getenv("ORDERS_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	log.Fatal(http.ListenAndServe(addr, mux))
}
