package httpfile

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	PublicEnvFile  = "http-client.env.json"
	PrivateEnvFile = "http-client.private.env.json"
	sharedEnvName  = "$shared"
)

type EnvironmentIssue struct {
	File    string `json:"file"`
	Message string `json:"message"`
}

type Environments struct {
	Names       []string                     `json:"names"`
	PublicFile  string                       `json:"publicFile,omitempty"`
	PrivateFile string                       `json:"privateFile,omitempty"`
	Issues      []EnvironmentIssue           `json:"issues"`
	values      map[string]map[string]string
}

func withinEnvRoot(path, root string) bool {
	if root == string(filepath.Separator) {
		return strings.HasPrefix(path, root)
	}
	return path == root || strings.HasPrefix(path, root+string(filepath.Separator))
}

func findUpwards(dir, root, name string) string {
	dir = filepath.Clean(dir)
	root = filepath.Clean(root)
	bounded := root != "" && root != "." && withinEnvRoot(dir, root)
	for {
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
		if !bounded || dir == root {
			return ""
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

func LoadEnvironments(httpPath, root string) Environments {
	envs := Environments{Names: []string{}, Issues: []EnvironmentIssue{}, values: map[string]map[string]string{}}
	dir := filepath.Dir(httpPath)
	envs.PublicFile = findUpwards(dir, root, PublicEnvFile)
	envs.PrivateFile = findUpwards(dir, root, PrivateEnvFile)
	for _, path := range []string{envs.PublicFile, envs.PrivateFile} {
		if path == "" {
			continue
		}
		parsed, err := readEnvFile(path)
		if err != nil {
			envs.Issues = append(envs.Issues, EnvironmentIssue{File: path, Message: err.Error()})
			continue
		}
		for env, vars := range parsed {
			if envs.values[env] == nil {
				envs.values[env] = map[string]string{}
			}
			for k, v := range vars {
				envs.values[env][k] = v
			}
		}
	}
	for name := range envs.values {
		if name != sharedEnvName {
			envs.Names = append(envs.Names, name)
		}
	}
	sort.Strings(envs.Names)
	return envs
}

func (e Environments) Variables(name string) map[string]string {
	out := map[string]string{}
	for k, v := range e.values[sharedEnvName] {
		out[k] = v
	}
	for k, v := range e.values[name] {
		out[k] = v
	}
	return out
}

func (e Environments) Has(name string) bool {
	_, ok := e.values[name]
	return ok && name != sharedEnvName
}

func readEnvFile(path string) (map[string]map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("could not be read: %v", err)
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return map[string]map[string]string{}, nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, describeJSONError(data, err)
	}
	out := map[string]map[string]string{}
	for env, body := range raw {
		var vars map[string]json.RawMessage
		if err := json.Unmarshal(body, &vars); err != nil {
			return nil, fmt.Errorf("environment %q must be an object of variable names and values", env)
		}
		values := map[string]string{}
		for k, v := range vars {
			values[k] = rawToString(v)
		}
		out[env] = values
	}
	return out, nil
}

func rawToString(v json.RawMessage) string {
	var s string
	if err := json.Unmarshal(v, &s); err == nil {
		return s
	}
	return string(bytes.TrimSpace(v))
}

func describeJSONError(data []byte, err error) error {
	if syn, ok := err.(*json.SyntaxError); ok {
		line := 1 + bytes.Count(data[:min(int(syn.Offset), len(data))], []byte("\n"))
		return fmt.Errorf("has a JSON syntax error on line %d: %v", line, syn)
	}
	return fmt.Errorf("is not a JSON object of environments: %v", err)
}

func EnvironmentTemplate(names []string) string {
	if len(names) == 0 {
		names = []string{"dev"}
	}
	var b strings.Builder
	b.WriteString("{\n")
	for i, n := range names {
		b.WriteString("  " + strconv.Quote(n) + ": {\n    \"host\": \"http://localhost:8080\"\n  }")
		if i < len(names)-1 {
			b.WriteString(",")
		}
		b.WriteString("\n")
	}
	b.WriteString("}\n")
	return b.String()
}
