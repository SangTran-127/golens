package remote

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"golens/core/docker"
	"golens/core/fsutil"
	"golens/core/vmexec"
)

const (
	KindLocal   = "local"
	KindVMArm64 = "vm_arm64"
	KindVMAmd64 = "vm_amd64"
	KindCompose = "compose"
	KindSSH     = "ssh"

	DefaultDebugPort = 2345
	DefaultSSHPort   = 22

	composeBase = "/tmp/golens"
)

type Target struct {
	Kind        string `json:"kind"`
	ComposeFile string `json:"composeFile,omitempty"`
	Service     string `json:"service,omitempty"`
	Host        string `json:"host,omitempty"`
	Port        int    `json:"port,omitempty"`
	WorkDir     string `json:"workDir,omitempty"`
	DebugPort   int    `json:"debugPort,omitempty"`
}

func (t Target) IsRemote() bool {
	return t.Kind == KindCompose || t.Kind == KindSSH
}

func (t Target) IsRosetta() bool {
	return t.Kind == KindVMAmd64
}

func (t Target) debugPort() int {
	if t.DebugPort > 0 && t.DebugPort < 65536 {
		return t.DebugPort
	}
	return DefaultDebugPort
}

func (t Target) sshPort() int {
	if t.Port > 0 && t.Port < 65536 && t.Port != DefaultSSHPort {
		return t.Port
	}
	return 0
}

func (t Target) sshPortArgs(flag string) []string {
	if p := t.sshPort(); p != 0 {
		return []string{flag, strconv.Itoa(p)}
	}
	return nil
}

func (t Target) Label() string {
	switch t.Kind {
	case KindVMAmd64:
		return "Linux AMD64 (Rosetta 2)"
	case KindVMArm64:
		return "Linux ARM64 (Native)"
	case KindCompose:
		return t.Service + " (Compose)"
	case KindSSH:
		if t.sshPort() != 0 {
			return t.Host + ":" + strconv.Itoa(t.sshPort())
		}
		return t.Host
	}
	return "My Mac"
}

var (
	serviceNameRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)
	sshHostRe     = regexp.MustCompile(`^([A-Za-z0-9._-]+@)?[A-Za-z0-9._:\[\]-]+$`)
)

func (t Target) Resolve(root string) (Target, *Issue) {
	switch t.Kind {
	case KindLocal, KindVMArm64, "":
		t.Kind = KindVMArm64
		return t, nil
	case KindVMAmd64:
		t.Kind = KindVMAmd64
		return t, nil
	case KindCompose:
		if strings.TrimSpace(t.Service) == "" {
			return t, issue(CodeConfig, "Choose a Compose Service", "This run configuration runs on Docker Compose but no service is chosen. Pick one in Edit Run Configurations.")
		}
		if !serviceNameRe.MatchString(t.Service) {
			return t, issue(CodeConfig, "Invalid Service Name", fmt.Sprintf("“%s” isn’t a valid Compose service name.", t.Service))
		}
		file := strings.TrimSpace(t.ComposeFile)
		if file == "" {
			file = FindComposeFile(root)
		} else if !filepath.IsAbs(file) {
			file = filepath.Join(root, file)
		}
		if file == "" {
			return t, issue(CodeConfig, "No Compose File", "GoLens couldn’t find compose.yaml or docker-compose.yml in the project. Choose the compose file in Edit Run Configurations.")
		}
		if st, err := os.Stat(file); err != nil || st.IsDir() {
			return t, issue(CodeConfig, "Compose File Not Found", fmt.Sprintf("There’s no compose file at %s. Choose another one in Edit Run Configurations.", file))
		}
		t.ComposeFile = file
	case KindSSH:
		host := strings.TrimSpace(t.Host)
		if host == "" {
			return t, issue(CodeConfig, "Enter an SSH Host", "This run configuration runs over SSH but has no host. Enter user@host in Edit Run Configurations.")
		}
		if strings.HasPrefix(host, "-") || !sshHostRe.MatchString(host) {
			return t, issue(CodeConfig, "Invalid SSH Host", fmt.Sprintf("“%s” isn’t a valid SSH destination. Use user@host or a Host alias from ~/.ssh/config.", host))
		}
		t.Host = host
	default:
		return t, issue(CodeConfig, "Unknown Destination", fmt.Sprintf("“%s” isn’t a destination GoLens knows.", t.Kind))
	}
	return t, nil
}

var composeNames = []string{"compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"}

func FindComposeFile(root string) string {
	for _, n := range composeNames {
		p := filepath.Join(root, n)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

type Transport struct {
	Target          Target
	DockerPath      string
	SSHPath         string
	ControlDir      string
	UsesSecurityKey bool
}

func FindHomebrewSSH() string {
	for _, cand := range []string{"/opt/homebrew/bin/ssh", "/usr/local/bin/ssh"} {
		if fi, err := os.Stat(cand); err == nil && !fi.IsDir() {
			return cand
		}
	}
	return ""
}

func TargetUsesSecurityKey(t Target) bool {
	if t.Kind != KindSSH || strings.TrimSpace(t.Host) == "" {
		return false
	}
	args := []string{"-G"}
	args = append(args, t.sshPortArgs("-p")...)
	args = append(args, extraSSHOptions...)
	args = append(args, t.Host)

	cmd := exec.Command("/usr/bin/ssh", args...)
	if home := vmexec.RealHomeDir(); home != "" {
		cmd.Env = append(os.Environ(), "HOME="+home)
	}
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	return SSHConfigOutputUsesSecurityKey(string(out))
}

func SSHConfigOutputUsesSecurityKey(sshGOutput string) bool {
	for _, line := range strings.Split(sshGOutput, "\n") {
		line = strings.TrimSpace(line)
		lower := strings.ToLower(line)
		if !strings.HasPrefix(lower, "identityfile ") {
			continue
		}
		rawPath := strings.TrimSpace(line[len("identityfile "):])
		expanded := fsutil.ExpandRealHomePath(rawPath)
		if expanded == "" {
			continue
		}
		fi, err := os.Stat(expanded)
		if err != nil || fi.IsDir() {
			continue
		}
		if isSecurityKeyIdentityFile(expanded) {
			return true
		}
	}
	return false
}

func isSecurityKeyIdentityFile(path string) bool {
	if info, err := fsutil.InspectSSHSigningKey(path); err == nil {
		return info.IsSecurityKey
	}
	pubPath := strings.TrimSuffix(path, ".pub") + ".pub"
	if pubBytes, err := os.ReadFile(pubPath); err == nil {
		trimmed := strings.TrimSpace(string(pubBytes))
		if strings.HasPrefix(trimmed, "sk-ssh-ed25519@openssh.com") || strings.HasPrefix(trimmed, "sk-ecdsa-sha2-nistp256@openssh.com") {
			return true
		}
	}
	_, keyType, _, err := fsutil.CheckPrivateKeyHeader(path)
	return err == nil && strings.HasPrefix(keyType, "sk-")
}

func NewTransport(t Target) Transport {
	usesSK := TargetUsesSecurityKey(t)
	sshBin := sshBinary
	if usesSK {
		if hb := FindHomebrewSSH(); hb != "" {
			sshBin = hb
		}
	}
	tr := Transport{
		Target:          t,
		DockerPath:      docker.LookPath("docker"),
		SSHPath:         sshBin,
		ControlDir:      sshControlDir(),
		UsesSecurityKey: usesSK,
	}
	if tr.DockerPath == "" {
		tr.DockerPath = "docker"
	}
	if _, err := os.Stat(tr.SSHPath); err != nil {
		if p := docker.LookPath("ssh"); p != "" {
			tr.SSHPath = p
		} else {
			tr.SSHPath = "ssh"
		}
	}
	return tr
}

var (
	sshBinary       = "/usr/bin/ssh"
	sshControlDir   = controlDir
	extraSSHOptions []string
)

func controlDir() string {
	if dir, err := os.UserCacheDir(); err == nil {
		d := filepath.Join(dir, "GoLens", "ssh")
		if len(d)+42 < 100 {
			return d
		}
	}
	return fmt.Sprintf("/tmp/golens-ssh-%d", os.Getuid())
}

func (tr Transport) ComposeArgs(args ...string) []string {
	file := tr.Target.ComposeFile
	argv := []string{tr.DockerPath, "compose", "-f", file, "--project-directory", filepath.Dir(file)}
	return append(argv, args...)
}

func (tr Transport) isNonAppleSSH() bool {
	return tr.UsesSecurityKey || (tr.SSHPath != "" && tr.SSHPath != "/usr/bin/ssh" && tr.SSHPath != "ssh")
}

func (tr Transport) SSHOptions() []string {
	var opts []string
	if tr.isNonAppleSSH() {
		opts = append(opts, "-o", "IgnoreUnknown=UseKeychain")
	}
	controlName := "%C"
	if tr.isNonAppleSSH() {
		controlName = "hb-%C"
	}
	opts = append(opts,
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ControlMaster=auto",
		"-o", "ControlPath="+filepath.Join(tr.ControlDir, controlName),
		"-o", "ControlPersist=600",
	)
	opts = append(opts, tr.Target.sshPortArgs("-p")...)
	return append(opts, extraSSHOptions...)
}

func (tr Transport) Shell(script string) []string {
	switch tr.Target.Kind {
	case KindCompose:
		return tr.ComposeArgs("exec", "-T", tr.Target.Service, "sh", "-c", script)
	case KindSSH:
		argv := append([]string{tr.SSHPath}, tr.SSHOptions()...)
		return append(argv, "-T", tr.Target.Host, "sh -c "+Quote(script))
	}
	return []string{"/bin/sh", "-c", script}
}

func (tr Transport) SSHControl(op string, extra ...string) []string {
	argv := append([]string{tr.SSHPath}, tr.SSHOptions()...)
	argv = append(argv, "-O", op)
	argv = append(argv, extra...)
	return append(argv, tr.Target.Host)
}

func Quote(s string) string {
	if s == "" {
		return "''"
	}
	safe := true
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("@%+=:,./_-", r)) {
			safe = false
			break
		}
	}
	if safe {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func QuoteArgv(argv []string) string {
	parts := make([]string, len(argv))
	for i, a := range argv {
		parts[i] = Quote(a)
	}
	return strings.Join(parts, " ")
}

func Slug(name string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
		case r == '-' || r == '_' || r == '.' || r == ' ':
			b.WriteByte('-')
		}
	}
	s := strings.Trim(b.String(), "-.")
	if s == "" {
		return "default"
	}
	if len(s) > 40 {
		sum := sha1.Sum([]byte(name))
		s = s[:31] + "-" + hex.EncodeToString(sum[:])[:8]
	}
	return s
}

func GoArch(machine string) (goarch, goarm string, ok bool) {
	switch strings.TrimSpace(machine) {
	case "x86_64", "amd64":
		return "amd64", "", true
	case "aarch64", "arm64", "armv8l", "armv8b":
		return "arm64", "", true
	case "armv7l", "armv7":
		return "arm", "7", true
	case "armv6l":
		return "arm", "6", true
	case "i386", "i486", "i586", "i686":
		return "386", "", true
	case "ppc64le":
		return "ppc64le", "", true
	case "s390x":
		return "s390x", "", true
	case "riscv64":
		return "riscv64", "", true
	case "loongarch64":
		return "loong64", "", true
	}
	return "", "", false
}
