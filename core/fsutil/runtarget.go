package fsutil

import (
	"fmt"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
)

func RunDir(root, workingDirectory, activeFile string) (dir, note string) {
	if workingDirectory != "" {
		if !filepath.IsAbs(workingDirectory) {
			workingDirectory = filepath.Join(root, workingDirectory)
		}
		return filepath.Clean(workingDirectory), ""
	}
	if !strings.HasSuffix(activeFile, ".go") {
		return root, ""
	}
	dir = filepath.Dir(activeFile)
	if strings.HasSuffix(activeFile, "_test.go") {
		return dir, ""
	}
	f, err := parser.ParseFile(token.NewFileSet(), activeFile, nil, parser.PackageClauseOnly)
	if err != nil || f.Name.Name == "main" {
		return dir, ""
	}
	return root, fmt.Sprintf("%s is in package %s, not main, so the project root runs instead.", filepath.Base(activeFile), f.Name.Name)
}
