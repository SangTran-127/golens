package fsutil

import (
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"

	"golens/core/bridge"
)

func sanitizeGoPackageName(name string) string {
	var sb strings.Builder
	for i, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_' {
			sb.WriteRune(r)
		} else if r >= '0' && r <= '9' {
			if i > 0 {
				sb.WriteRune(r)
			}
		}
	}
	return strings.ToLower(sb.String())
}

func inferGoPackageName(path string) string {
	dir := filepath.Dir(path)
	base := filepath.Base(path)
	if entries, err := os.ReadDir(dir); err == nil {
		fset := token.NewFileSet()
		var testPkg string
		for _, entry := range entries {
			name := entry.Name()
			if entry.IsDir() || name == base || !strings.HasSuffix(strings.ToLower(name), ".go") {
				continue
			}
			f, err := parser.ParseFile(fset, filepath.Join(dir, name), nil, parser.PackageClauseOnly)
			if err != nil || f == nil || f.Name == nil || f.Name.Name == "" || f.Name.Name == "_" {
				continue
			}
			if !strings.HasSuffix(strings.ToLower(name), "_test.go") {
				return f.Name.Name
			}
			if testPkg == "" {
				testPkg = strings.TrimSuffix(f.Name.Name, "_test")
			}
		}
		if testPkg != "" {
			return testPkg
		}
	}
	if strings.EqualFold(base, "main.go") {
		return "main"
	}
	if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
		return "main"
	}
	if strings.EqualFold(filepath.Base(filepath.Dir(dir)), "cmd") {
		return "main"
	}
	pkgName := filepath.Base(dir)
	if pkgName == "." || pkgName == "/" || pkgName == "" {
		return "main"
	}
	pkgName = sanitizeGoPackageName(pkgName)
	if pkgName == "" {
		return "main"
	}
	return pkgName
}

func CreateFileOrFolderWithError(path string, isFolder bool) error {
	if strings.TrimSpace(path) == "" {
		return os.ErrInvalid
	}
	var err error
	if isFolder {
		cleanPath := filepath.Clean(path)
		err = os.MkdirAll(filepath.Dir(cleanPath), 0o755)
		if err == nil {
			err = os.Mkdir(cleanPath, 0o755)
		}
	} else {
		dir := filepath.Dir(path)
		err = os.MkdirAll(dir, 0o755)
		if err == nil {
			var f *os.File
			f, err = os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
			if err == nil {
				if strings.HasSuffix(strings.ToLower(path), ".go") {
					pkgName := inferGoPackageName(path)
					_, _ = f.WriteString(fmt.Sprintf("package %s\n\n", pkgName))
				}
				_ = f.Close()
			}
		}
	}
	if err != nil {
		bridge.Log(fmt.Sprintf("Couldn’t create %s: %v", filepath.Base(path), err))
		return err
	}
	bridge.Debug(fmt.Sprintf("Created %s", path))
	return nil
}

func CreateFileOrFolder(path string, isFolder bool) bool {
	return CreateFileOrFolderWithError(path, isFolder) == nil
}

func SplitArgs(input string) []string {
	var args []string
	var cur strings.Builder
	inToken := false
	var quote rune
	escaped := false

	for _, r := range input {
		if escaped {
			cur.WriteRune(r)
			inToken = true
			escaped = false
			continue
		}
		if r == '\\' && quote != '\'' {
			escaped = true
			inToken = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				cur.WriteRune(r)
			}
			inToken = true
			continue
		}
		if r == '"' || r == '\'' {
			quote = r
			inToken = true
			continue
		}
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			if inToken {
				args = append(args, cur.String())
				cur.Reset()
				inToken = false
			}
			continue
		}
		cur.WriteRune(r)
		inToken = true
	}
	if inToken {
		args = append(args, cur.String())
	}
	return args
}
