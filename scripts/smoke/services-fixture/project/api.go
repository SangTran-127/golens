package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	addr := ":" + os.Getenv("PORT")
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("GET /health 200")
		fmt.Fprintln(w, "ok")
	})
	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}
