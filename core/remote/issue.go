package remote

import (
	"fmt"
	"strconv"
	"strings"
)

const (
	CodeConfig            = "config"
	CodeDockerMissing     = "dockerMissing"
	CodeEngineDown        = "engineDown"
	CodeServiceNotRunning = "serviceNotRunning"
	CodeUnknownService    = "unknownService"
	CodeNoShell           = "noShell"
	CodeNoTar             = "noTar"
	CodeAuthFailed        = "authFailed"
	CodeHostKeyUnknown    = "hostKeyUnknown"
	CodeHostKeyChanged    = "hostKeyChanged"
	CodeHostNotFound      = "hostNotFound"
	CodeUnreachable       = "unreachable"
	CodeGoMissing         = "goMissing"
	CodeDlvMissing        = "dlvMissing"
	CodeArchUnknown       = "archUnknown"
	CodePtrace            = "ptrace"
	CodeDebugger          = "debugger"
	CodeFailed            = "failed"

	FixStartService = "startService"
	FixInstallDelve = "installDelve"
	FixOpenTerminal = "openTerminal"
	FixEditTarget   = "editDestination"
	FixRetry        = "retry"
)

type Issue struct {
	Code     string `json:"code"`
	Title    string `json:"title"`
	Message  string `json:"message"`
	Fix      string `json:"fix,omitempty"`
	FixTitle string `json:"fixTitle,omitempty"`
	Command  string `json:"command,omitempty"`
	Detail   string `json:"detail,omitempty"`
	Target   Target `json:"target"`
}

func (i *Issue) Error() string {
	return i.Title
}

func issue(code, title, message string) *Issue {
	i := &Issue{Code: code, Title: title, Message: message}
	if code == CodeConfig || code == CodeUnknownService {
		i.Fix, i.FixTitle = FixEditTarget, "Edit Destination…"
	}
	return i
}

func (i *Issue) with(t Target) *Issue {
	i.Target = t
	return i
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	for j := len(lines) - 1; j >= 0; j-- {
		if l := strings.TrimSpace(lines[j]); l != "" {
			return l
		}
	}
	return ""
}

func classifyCompose(t Target, stderr string) *Issue {
	low := strings.ToLower(stderr)
	var i *Issue
	switch {
	case strings.Contains(low, "cannot connect to the docker daemon"),
		strings.Contains(low, "failed to connect to the docker api"),
		strings.Contains(low, "is the docker daemon running"),
		strings.Contains(low, "error during connect"):
		i = issue(CodeEngineDown, "Docker Engine Isn’t Running", "GoLens runs this configuration in "+t.Label()+", but the Docker engine isn’t reachable. Start OrbStack, Docker Desktop or Colima, then try again.")
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	case strings.Contains(low, "no such service"):
		i = issue(CodeUnknownService, "Service Not in Compose File", fmt.Sprintf("The compose file has no service named “%s”. Choose another service in Edit Run Configurations.", t.Service))
	case strings.Contains(low, "is not running"), strings.Contains(low, "no container found"), strings.Contains(low, "is restarting"):
		i = issue(CodeServiceNotRunning, "Service Isn’t Running", fmt.Sprintf("GoLens runs your program inside the running “%s” container, and it isn’t up. Start it, then run again.", t.Service))
		i.Fix, i.FixTitle = FixStartService, "Start Service"
	case strings.Contains(low, "executable file not found"), strings.Contains(low, "oci runtime exec failed"), strings.Contains(low, "no such file or directory") && strings.Contains(low, "sh"):
		i = issue(CodeNoShell, "Service Has No Shell", fmt.Sprintf("“%s” has no /bin/sh, so GoLens can’t copy, start or stop programs in it. Use an image with a shell (alpine, debian or golang) for this service.", t.Service))
	default:
		msg := lastLine(stderr)
		if msg == "" {
			msg = "docker compose failed without an error message."
		}
		i = issue(CodeFailed, "Couldn’t Reach "+t.Label(), msg)
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	}
	i.Detail = strings.TrimSpace(stderr)
	return i.with(t)
}

func classifySSH(t Target, stderr string) *Issue {
	low := strings.ToLower(stderr)
	connect := strings.Join(append(append([]string{"ssh"}, t.sshPortArgs("-p")...), Quote(t.Host)), " ")
	var i *Issue
	switch {
	case strings.Contains(low, "remote host identification has changed"):
		i = issue(CodeHostKeyChanged, "Host Key Changed", t.Host+" presented a different host key than the one in known_hosts. This can mean the server was reinstalled, or that someone is intercepting the connection. Confirm the new key with the server’s owner, remove the old entry with ssh-keygen -R, then connect again.")
		i.Fix, i.FixTitle, i.Command = FixOpenTerminal, "Open in Terminal", "ssh-keygen -F "+Quote(hostOnly(t.Host))
	case strings.Contains(low, "host key verification failed"), strings.Contains(low, "no matching host key"), strings.Contains(low, "host key is known for") && strings.Contains(low, "not"):
		i = issue(CodeHostKeyUnknown, "Unknown Host Key", t.Host+" isn’t in your known_hosts yet, and GoLens won’t trust a new host on its own. Connect once in Terminal, check the fingerprint and answer yes, then run again.")
		i.Fix, i.FixTitle, i.Command = FixOpenTerminal, "Connect in Terminal", connect+" exit"
	case strings.Contains(low, "device not found"), strings.Contains(low, "sk_sign failed"):
		i = issue(CodeAuthFailed, "Security Key Not Detected", "Connecting to "+t.Host+" requires your hardware security key. Plug in your security key, then try again and touch the key when it flashes.")
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	case strings.Contains(low, "pin required"), strings.Contains(low, "verify-required"):
		i = issue(CodeAuthFailed, "Security Key PIN Required", "The security key for "+t.Host+" requires a FIDO2 PIN (verify-required). Unlock it in Terminal or use a touch-only security key.")
		i.Fix, i.FixTitle, i.Command = FixOpenTerminal, "Connect in Terminal", connect
	case strings.Contains(low, "permission denied"), strings.Contains(low, "too many authentication failures"):
		i = issue(CodeAuthFailed, "SSH Sign-In Failed", t.Host+" didn’t accept your SSH keys, and GoLens can’t type a password for you. Add your public key to the host (ssh-copy-id) or load it into ssh-agent, then run again.")
		i.Fix, i.FixTitle, i.Command = FixOpenTerminal, "Set Up Key in Terminal", strings.Join(append(append([]string{"ssh-copy-id"}, t.sshPortArgs("-p")...), Quote(t.Host)), " ")
	case strings.Contains(low, "could not resolve hostname"), strings.Contains(low, "nodename nor servname"), strings.Contains(low, "name or service not known"):
		i = issue(CodeHostNotFound, "Host Not Found", "No host named “"+hostOnly(t.Host)+"” could be found. Check the host name in Edit Run Configurations.")
		i.Fix, i.FixTitle = FixEditTarget, "Edit Destination…"
	case strings.Contains(low, "connection refused"), strings.Contains(low, "timed out"), strings.Contains(low, "no route to host"), strings.Contains(low, "network is unreachable"), strings.Contains(low, "connection closed"), strings.Contains(low, "connection reset"):
		i = issue(CodeUnreachable, "Can’t Connect to "+t.Label(), "The host didn’t answer on "+sshPortPhrase(t)+". Check that it’s running, that sshd listens on that port and that you’re on the right network, then try again.")
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	default:
		msg := lastLine(stderr)
		if msg == "" {
			msg = "ssh failed without an error message."
		}
		i = issue(CodeFailed, "Couldn’t Reach "+t.Label(), msg)
		i.Fix, i.FixTitle = FixRetry, "Try Again"
	}
	i.Detail = strings.TrimSpace(stderr)
	return i.with(t)
}

func hostOnly(h string) string {
	if at := strings.LastIndexByte(h, '@'); at >= 0 {
		return h[at+1:]
	}
	return h
}

func dlvMissingIssue(t Target) *Issue {
	i := issue(CodeDlvMissing, "Delve Isn’t Installed on "+t.Label(), "Debugging runs the Delve debugger next to your program, and "+t.Label()+" doesn’t have it. GoLens can build Delve for this machine and copy it there.")
	i.Fix, i.FixTitle = FixInstallDelve, "Install Delve"
	return i.with(t)
}

func goMissingIssue(t Target) *Issue {
	where := t.Label()
	i := issue(CodeGoMissing, "Go Isn’t Installed on "+where, "CGO_ENABLED=1 needs a C toolchain for Linux, so GoLens builds inside "+where+", and it has no go command. Use an image or host with Go (for example golang:1-bookworm), or set CGO_ENABLED=0 in the configuration’s environment.")
	i.Fix, i.FixTitle = FixEditTarget, "Edit Configuration…"
	return i.with(t)
}

func archIssue(t Target, machine string) *Issue {
	return issue(CodeArchUnknown, "Unsupported Architecture", fmt.Sprintf("%s reports machine type “%s”, which Go can’t build for.", t.Label(), machine)).with(t)
}

func noTarIssue(t Target) *Issue {
	return issue(CodeNoTar, "tar Isn’t Available on "+t.Label(), "GoLens copies programs to the destination with tar, and "+t.Label()+" doesn’t have it. Install tar there (apk add tar, apt-get install tar), then run again.").with(t)
}

func ptraceIssue(t Target) *Issue {
	msg := "Delve couldn’t trace the program because the kernel refused ptrace."
	if t.Kind == KindCompose {
		msg += " Add cap_add: [SYS_PTRACE] and security_opt: [\"seccomp:unconfined\"] to the “" + t.Service + "” service, recreate it, then debug again."
	} else {
		msg += " Allow it on the host (sysctl kernel.yama.ptrace_scope=0), then debug again."
	}
	return issue(CodePtrace, "Debugging Isn’t Allowed", msg).with(t)
}

func sshPortPhrase(t Target) string {
	if p := t.sshPort(); p != 0 {
		return "port " + strconv.Itoa(p)
	}
	return "its SSH port (22 unless ~/.ssh/config sets another)"
}
