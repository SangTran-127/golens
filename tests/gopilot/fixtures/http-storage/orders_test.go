package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCreateOrderPersists(t *testing.T) {
	exec := newMemoryExecer()
	svc := NewService(NewSQLRepository(exec), NewInventory(map[string]int{"sku-1": 3}))
	mux := http.NewServeMux()
	NewHandler(svc).Routes(mux)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("POST", "/orders", strings.NewReader(`{"sku":"sku-1","qty":2}`)))

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d", rec.Code)
	}
	if len(exec.rows) != 1 {
		t.Fatalf("rows = %d", len(exec.rows))
	}
}

func TestCreateOrderOutOfStock(t *testing.T) {
	svc := NewService(NewSQLRepository(newMemoryExecer()), NewInventory(map[string]int{"sku-1": 1}))
	mux := http.NewServeMux()
	NewHandler(svc).Routes(mux)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest("POST", "/orders", strings.NewReader(`{"sku":"sku-1","qty":5}`)))

	if rec.Code != http.StatusConflict {
		t.Fatalf("status = %d", rec.Code)
	}
}
