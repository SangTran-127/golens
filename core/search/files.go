package search

import (
	"context"
	"path/filepath"
)

func Files(root string) []string {
	out := make(chan string, 256)
	go listFiles(context.Background(), root, out)
	var files []string
	for p := range out {
		if filepath.Base(p) == ".DS_Store" {
			continue
		}
		if rel, err := filepath.Rel(root, p); err == nil {
			files = append(files, rel)
		}
	}
	return files
}
