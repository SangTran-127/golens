package docker

import (
	"encoding/json"
	"fmt"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

const (
	BaseDistrolessStatic = "distroless-static"
	BaseDistrolessBase   = "distroless-base"
	BaseAlpine           = "alpine"
	BaseScratch          = "scratch"

	alpineRuntimeTag = "alpine:3.22"
	binDir           = "/usr/local/bin/"
)

type GenerateOptions struct {
	Package string `json:"package"`
	Base    string `json:"base"`
	Port    *int   `json:"port"`
}

type GenerateResult struct {
	Dir           string         `json:"dir"`
	Dockerfile    string         `json:"dockerfile"`
	Dockerignore  string         `json:"dockerignore"`
	MainPackages  []string       `json:"mainPackages"`
	GoVersion     string         `json:"goVersion"`
	UsesCgo       bool           `json:"usesCgo"`
	CgoReason     string         `json:"cgoReason"`
	DetectedPorts []DetectedPort `json:"detectedPorts"`
	Warnings      []string       `json:"warnings"`
	Package       string         `json:"package"`
	Base          string         `json:"base"`
	Port          int            `json:"port"`
	Error         string         `json:"error,omitempty"`
}

func GenerateJSON(contextDir, optionsJSON string) (out string) {
	defer func() {
		if r := recover(); r != nil {
			out = fmt.Sprintf(`{"error":%q}`, fmt.Sprint("couldn’t generate a Dockerfile: ", r))
		}
	}()
	var opts GenerateOptions
	if strings.TrimSpace(optionsJSON) != "" {
		if err := json.Unmarshal([]byte(optionsJSON), &opts); err != nil {
			return fmt.Sprintf(`{"error":%q}`, "invalid options: "+err.Error())
		}
	}
	b, err := json.Marshal(Generate(contextDir, opts))
	if err != nil {
		return fmt.Sprintf(`{"error":%q}`, err.Error())
	}
	return string(b)
}

func Generate(contextDir string, opts GenerateOptions) GenerateResult {
	res := GenerateResult{MainPackages: []string{}, DetectedPorts: []DetectedPort{}, Warnings: []string{}, Dockerignore: defaultIgnore}
	if !filepath.IsAbs(contextDir) {
		res.Error = "The project folder must be an absolute path."
		return res
	}
	mod := findModule(filepath.Clean(contextDir))
	if mod == nil {
		res.Error = "No go.mod found in this folder or its parents, so there’s no Go module to build."
		return res
	}
	res.Dir = mod.root
	scan := scanGoFiles(mod.root)
	for m := range scan.mains {
		res.MainPackages = append(res.MainPackages, m)
	}
	sort.Slice(res.MainPackages, func(i, j int) bool {
		a, b := res.MainPackages[i], res.MainPackages[j]
		return a == "." || (b != "." && a < b)
	})
	res.DetectedPorts = detectPorts(mod.root)

	if v, _ := mod.required(); v != "" {
		res.GoVersion = v
	}
	switch {
	case mod.sqlite:
		res.CgoReason = "go.mod requires github.com/mattn/go-sqlite3"
	case scan.cgoFile != "":
		res.CgoReason = fmt.Sprintf(`%s imports "C"`, scan.cgoFile)
	}
	res.UsesCgo = res.CgoReason != ""

	if !scan.complete {
		res.Warnings = append(res.Warnings, "The module is too large to scan completely, so some main packages or ports may be missing.")
	}
	if res.GoVersion == "" {
		res.Warnings = append(res.Warnings, "go.mod has no go directive, so the builder uses the newest Go 1 image.")
	}
	if !mod.hasGoSum && mod.requires {
		res.Warnings = append(res.Warnings, "go.sum is missing, so the build will fail. Run go mod tidy first.")
	}
	if len(res.MainPackages) == 0 {
		res.Error = "The module has no main package, so there’s no program to put in the image."
		return res
	}

	res.Package = strings.TrimPrefix(path.Clean(filepath.ToSlash(opts.Package)), "./")
	if opts.Package == "" {
		res.Package = res.MainPackages[0]
	} else if !scan.mains[res.Package] {
		res.Error = fmt.Sprintf("%s isn’t a main package in this module.", opts.Package)
		return res
	}

	res.Base = opts.Base
	switch res.Base {
	case "":
		res.Base = BaseDistrolessStatic
		if res.UsesCgo {
			res.Base = BaseDistrolessBase
		}
	case BaseDistrolessStatic, BaseDistrolessBase, BaseAlpine, BaseScratch:
	default:
		res.Error = fmt.Sprintf("Unknown runtime image %q.", opts.Base)
		return res
	}
	if res.UsesCgo && (res.Base == BaseDistrolessStatic || res.Base == BaseScratch) {
		res.Warnings = append(res.Warnings, fmt.Sprintf("This module uses cgo (%s), so the binary needs a C library that %s doesn’t have.", res.CgoReason, res.Base))
	}

	if opts.Port != nil {
		res.Port = *opts.Port
	} else {
		res.Port = defaultPort(res.DetectedPorts, res.Package)
	}
	if res.Port < 0 || res.Port > 65535 {
		res.Error = fmt.Sprintf("Port %d is outside 1–65535.", res.Port)
		return res
	}

	res.Dockerfile = renderDockerfile(res, mod.hasGoSum)
	return res
}

func defaultPort(ports []DetectedPort, pkg string) int {
	for _, p := range ports {
		if p.Package == pkg {
			return p.Port
		}
	}
	if len(ports) > 0 {
		return ports[0].Port
	}
	return 0
}

func binaryName(pkg, moduleRoot string) string {
	name := path.Base(pkg)
	if pkg == "." {
		name = filepath.Base(moduleRoot)
	}
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-', r == '_', r == '.':
			b.WriteRune(r)
		default:
			b.WriteRune('-')
		}
	}
	if s := strings.Trim(b.String(), "-._"); s != "" {
		return s
	}
	return "app"
}

func renderDockerfile(res GenerateResult, hasGoSum bool) string {
	goTag := "1"
	if parts := strings.Split(versionPrefixRe.FindString(res.GoVersion), "."); len(parts) >= 2 {
		goTag = parts[0] + "." + parts[1]
	} else if len(parts) == 1 && parts[0] != "" {
		goTag = parts[0]
	}
	cgo := res.UsesCgo && res.Base != BaseDistrolessStatic && res.Base != BaseScratch
	builder := "golang:" + goTag + "-alpine"
	if cgo && res.Base == BaseDistrolessBase {
		builder = "golang:" + goTag + "-bookworm"
	}
	bin := binaryName(res.Package, res.Dir)
	target := "."
	if res.Package != "." {
		target = "./" + res.Package
	}
	mods := "go.mod go.sum"
	if !hasGoSum {
		mods = "go.mod"
	}

	var b strings.Builder
	w := func(format string, a ...any) { fmt.Fprintf(&b, format+"\n", a...) }
	w("# syntax=docker/dockerfile:1")
	w("")
	w("FROM %s AS builder", builder)
	if cgo && res.Base == BaseAlpine {
		w("RUN apk add --no-cache gcc musl-dev")
	}
	w("WORKDIR /src")
	if cgo {
		w("ENV CGO_ENABLED=1")
	} else {
		w("ENV CGO_ENABLED=0")
	}
	w("COPY %s ./", mods)
	w("RUN %s \\\n    go mod download", cacheMounts)
	w("COPY . .")
	w("RUN %s \\\n    go build -trimpath -ldflags=\"-s -w\" -o /out/%s %s", cacheMounts, bin, target)
	w("")

	switch res.Base {
	case BaseDistrolessStatic:
		w("FROM gcr.io/distroless/static-debian12:nonroot")
	case BaseDistrolessBase:
		w("FROM gcr.io/distroless/base-debian12:nonroot")
	case BaseAlpine:
		w("FROM %s", alpineRuntimeTag)
		w("RUN apk add --no-cache ca-certificates tzdata")
	case BaseScratch:
		w("FROM scratch")
		w("COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/")
	}
	w("COPY --from=builder /out/%s %s%s", bin, binDir, bin)
	if res.Base == BaseDistrolessStatic || res.Base == BaseDistrolessBase {
		w("USER nonroot:nonroot")
	} else {
		w("USER 65532:65532")
	}
	if res.Port > 0 {
		w("EXPOSE %d", res.Port)
	}
	w("ENTRYPOINT [\"%s%s\"]", binDir, bin)
	return b.String()
}
