package remote

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"golens/core/docker"
)

type ComposeServices struct {
	File     string   `json:"file"`
	Services []string `json:"services"`
	Error    string   `json:"error,omitempty"`
}

func ListComposeServices(root, file string) ComposeServices {
	if file == "" {
		file = FindComposeFile(root)
	} else if !filepath.IsAbs(file) {
		file = filepath.Join(root, file)
	}
	res := ComposeServices{File: file, Services: []string{}}
	if file == "" {
		res.Error = "No compose.yaml or docker-compose.yml in the project."
		return res
	}
	data, err := os.ReadFile(file)
	if err != nil {
		res.Error = "Couldn’t read " + filepath.Base(file) + "."
		return res
	}
	text := string(data)
	if parsed := ParseComposeServices(text); len(parsed) > 0 && !composeNeedsCLI(text) {
		res.Services = parsed
		return res
	}
	if cli := docker.LookPath("docker"); cli != "" {
		tr := Transport{Target: Target{Kind: KindCompose, ComposeFile: file}, DockerPath: cli}
		r := runArgv(20*time.Second, tr.ComposeArgs("config", "--services"), "")
		if r.err == nil {
			for _, s := range strings.Fields(r.stdout) {
				res.Services = append(res.Services, s)
			}
			sort.Strings(res.Services)
			return res
		}
	}
	res.Services = ParseComposeServices(text)
	return res
}

func composeNeedsCLI(text string) bool {
	for _, raw := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
		t := strings.TrimSpace(raw)
		if strings.HasPrefix(t, "#") {
			continue
		}
		if strings.HasPrefix(raw, "include:") || strings.HasPrefix(t, "extends:") {
			return true
		}
	}
	return false
}

func ComposeServicesJSON(root, file string) string {
	b, _ := json.Marshal(ListComposeServices(root, file))
	return string(b)
}

func ParseComposeServices(text string) []string {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	out := []string{}
	in := false
	childIndent := -1
	for _, raw := range lines {
		t := strings.TrimSpace(raw)
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		indent := len(raw) - len(strings.TrimLeft(raw, " "))
		if indent == 0 {
			in = strings.HasPrefix(t, "services:")
			childIndent = -1
			continue
		}
		if !in {
			continue
		}
		if childIndent < 0 {
			childIndent = indent
		}
		if indent != childIndent {
			continue
		}
		k, _, ok := strings.Cut(t, ":")
		if !ok {
			continue
		}
		k = strings.Trim(strings.TrimSpace(k), `"'`)
		if k != "" && serviceNameRe.MatchString(k) {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}
