package syntaxcheck

import (
	"encoding/json"
	"errors"
	"fmt"
	"go/parser"
	"go/scanner"
	"go/token"
	"path/filepath"
)

const MaxIssues = 20

type Issue struct {
	Path    string `json:"path"`
	Line    int    `json:"line"`
	Column  int    `json:"column"`
	Message string `json:"message"`
}

func (i Issue) String() string {
	return fmt.Sprintf("%s:%d:%d: %s", i.Path, i.Line, i.Column, i.Message)
}

type Result struct {
	Issues    []Issue `json:"issues"`
	Truncated bool    `json:"truncated"`
}

func Check(path string, source []byte) Result {
	display := filepath.ToSlash(path)
	if display == "" {
		display = "source.go"
	}
	fset := token.NewFileSet()
	_, err := parser.ParseFile(fset, display, source, parser.AllErrors|parser.SkipObjectResolution)
	if err == nil {
		return Result{Issues: []Issue{}}
	}
	var list scanner.ErrorList
	if !errors.As(err, &list) {
		return Result{Issues: []Issue{{Path: display, Line: 1, Column: 1, Message: err.Error()}}}
	}
	list.RemoveMultiples()
	result := Result{Issues: make([]Issue, 0, min(len(list), MaxIssues))}
	for _, item := range list {
		if len(result.Issues) == MaxIssues {
			result.Truncated = true
			break
		}
		line, column := item.Pos.Line, item.Pos.Column
		if line < 1 {
			line = 1
		}
		if column < 1 {
			column = 1
		}
		result.Issues = append(result.Issues, Issue{Path: display, Line: line, Column: column, Message: item.Msg})
	}
	return result
}

func CheckJSON(path string, source []byte) string {
	data, err := json.Marshal(Check(path, source))
	if err != nil {
		return `{"issues":[],"truncated":false,"error":"encoding failed"}`
	}
	return string(data)
}
