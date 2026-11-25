//go:build ignore

// Loopback stub provider for AI Suggestions smoke runs.
// go run scripts/smoke/completion-stub.go -port 47231 -log /tmp/stub.log [-delay 150ms]
// Serves /v1/chat/completions (chat hole-fill), /v1/completions (fill-in-the-middle) and /v1/models.
// Each request is appended to the log as one line: method path model stream suffix=<bool> case=<name>.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type request struct {
	Model    string    `json:"model"`
	Messages []message `json:"messages"`
	Prompt   string    `json:"prompt"`
	Suffix   *string   `json:"suffix"`
	Stream   *bool     `json:"stream"`
	Stop     []string  `json:"stop"`
}

var (
	logMu   sync.Mutex
	logFile *os.File
	delay   time.Duration
)

func record(line string) {
	logMu.Lock()
	defer logMu.Unlock()
	fmt.Fprintln(logFile, time.Now().Format("15:04:05.000"), line)
}

func answer(before, after string) (string, string) {
	if len(before) > 160 {
		before = before[len(before)-160:]
	}
	header := strings.TrimRight(before, " \t\n")
	switch {
	case strings.HasSuffix(header, "func add(a, b int) int {"):
		return "single", "return a + b"
	case strings.Contains(before, "func add(a, b int) int {") && strings.HasSuffix(before, "return "):
		return "probe", "a + b"
	case strings.HasSuffix(header, "func (s *Store) Lookup(k string) (string, error) {"):
		return "multi", "s.mu.RLock()\n\tdefer s.mu.RUnlock()\n\tv, ok := s.data[k]\n\tif !ok {\n\t\treturn \"\", ErrNotFound\n\t}\n\treturn v, nil\n}"
	case strings.Contains(before, "func sub(a, b int) int {") && strings.HasSuffix(before, "return a"):
		return "through", " - b"
	case strings.HasSuffix(before, "fmt.Println(") && strings.HasPrefix(after, ")"):
		return "closers", "\"ready\", s.Len())"
	default:
		return "none", ""
	}
}

func chunks(text string) []string {
	if text == "" {
		return nil
	}
	var out []string
	for len(text) > 0 {
		n := 7
		if n > len(text) {
			n = len(text)
		}
		out = append(out, text[:n])
		text = text[n:]
	}
	return out
}

func handle(fim bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":{"message":"bad json"}}`, http.StatusBadRequest)
			return
		}
		before, after := req.Prompt, ""
		if req.Suffix != nil {
			after = *req.Suffix
		}
		if strings.HasPrefix(before, "<|fim_prefix|>") {
			body := strings.TrimSuffix(strings.TrimPrefix(before, "<|fim_prefix|>"), "<|fim_middle|>")
			parts := strings.SplitN(body, "<|fim_suffix|>", 2)
			before = parts[0]
			if len(parts) == 2 {
				after = parts[1]
			}
		}
		if !fim {
			for _, m := range req.Messages {
				if m.Role == "user" {
					parts := strings.SplitN(m.Content, "<CURSOR>", 2)
					before = parts[0]
					if len(parts) == 2 {
						after = parts[1]
					}
				}
			}
		}
		name, text := answer(before, after)
		stream := req.Stream != nil && *req.Stream
		record(fmt.Sprintf("%s %s model=%s stream=%v suffix=%v case=%s ua=%q", r.Method, r.URL.Path, req.Model, stream, req.Suffix != nil, name, r.UserAgent()))
		if delay > 0 {
			select {
			case <-time.After(delay):
			case <-r.Context().Done():
				return
			}
		}
		promptTokens := (len(before) + len(after)) / 4
		if fim && req.Suffix != nil {
			promptTokens = (len(before) + len(*req.Suffix)) / 4
		}
		if !stream {
			choice := map[string]any{"index": 0, "finish_reason": "stop"}
			if fim {
				choice["text"] = text
			} else {
				choice["message"] = map[string]any{"role": "assistant", "content": text}
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]any{"id": "stub", "choices": []any{choice}, "usage": map[string]any{"prompt_tokens": promptTokens, "completion_tokens": len(text) / 4}})
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		for _, piece := range chunks(text) {
			var choice map[string]any
			if fim {
				choice = map[string]any{"index": 0, "text": piece}
			} else {
				choice = map[string]any{"index": 0, "delta": map[string]any{"content": piece}}
			}
			data, _ := json.Marshal(map[string]any{"choices": []any{choice}})
			fmt.Fprintf(w, "data: %s\n\n", data)
			if flusher != nil {
				flusher.Flush()
			}
			select {
			case <-time.After(15 * time.Millisecond):
			case <-r.Context().Done():
				record("cancelled " + r.URL.Path)
				return
			}
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
	}
}

func main() {
	port := flag.Int("port", 47231, "loopback port")
	logPath := flag.String("log", "completion-stub.log", "request log file")
	flag.DurationVar(&delay, "delay", 150*time.Millisecond, "delay before the first byte")
	flag.Parse()
	f, err := os.OpenFile(*logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		log.Fatal(err)
	}
	logFile = f
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", handle(false))
	mux.HandleFunc("/v1/completions", handle(true))
	mux.HandleFunc("/v1/models", func(w http.ResponseWriter, r *http.Request) {
		record("GET /v1/models")
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"data":[{"id":"mistralai/codestral-2508"},{"id":"text-completion-codestral/codestral-latest"}]}`)
	})
	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	fmt.Println("completion stub listening on", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
