package goast

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"golens/core/bridge"
	"golens/core/vmexec"
)

type DisasmInstruction struct {
	Address  string `json:"address"`
	Mnemonic string `json:"mnemonic"`
	Operands string `json:"operands"`
	Source   string `json:"source"`
	Line     int    `json:"line"`
}

type DisasmResult struct {
	Function     string              `json:"function"`
	TargetArch   string              `json:"targetArch"`
	Instructions []DisasmInstruction `json:"instructions"`
	Error        string              `json:"error,omitempty"`
}

var disasmCounter uint64

func DisassembleFunction(pkgDir, funcName, arch string) (*DisasmResult, error) {
	arch = strings.ToLower(strings.TrimSpace(arch))
	if arch != "arm64" && arch != "amd64" {
		return nil, fmt.Errorf("unsupported target architecture: %s (supported: arm64, amd64)", arch)
	}

	targetDir := strings.TrimSpace(pkgDir)
	if info, err := os.Stat(targetDir); err == nil && !info.IsDir() {
		targetDir = filepath.Dir(targetDir)
	}

	workDir := targetDir
	modRoot := findGoModRoot(targetDir, targetDir)
	if modRoot != "" {
		workDir = modRoot
	} else {
		modRoot = workDir
	}

	relPkg := "."
	if targetDir != "" && targetDir != workDir {
		if rel, err := filepath.Rel(workDir, targetDir); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
			relPkg = "./" + filepath.ToSlash(rel)
		}
	}

	nonce := atomic.AddUint64(&disasmCounter, 1)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	var dumpOut []byte
	var err error

	guestWorkDir := vmexec.HostToGuestPath(modRoot, workDir)
	guestTmpBin := fmt.Sprintf("/tmp/golens_disasm_%d_%d_%s", time.Now().UnixNano(), nonce, arch)

	vmBuildCmd := vmexec.CommandContext(ctx, "go", "build", "-p", "2", "-o", guestTmpBin, relPkg)
	vmBuildCmd.Dir = guestWorkDir
	vmBuildCmd.Rosetta = (arch == "amd64")
	vmBuildCmd.Env = vmexec.DefaultVMEnv(arch, map[string]string{"GOMEMLIMIT": "512MiB", "GOGC": "50"})

	vmOut, vmErr := vmBuildCmd.CombinedOutput()
	if vmErr == nil {
		defer func() {
			_ = vmexec.CommandContext(context.Background(), "rm", "-f", guestTmpBin).Run()
		}()

		var objdumpArgs []string
		if funcName != "" {
			objdumpArgs = []string{"tool", "objdump", "-s", symPatternFor(funcName), guestTmpBin}
		} else {
			objdumpArgs = []string{"tool", "objdump", guestTmpBin}
		}
		vmDumpCmd := vmexec.CommandContext(ctx, "go", objdumpArgs...)
		vmDumpCmd.Dir = guestWorkDir
		vmDumpCmd.Rosetta = (arch == "amd64")
		vmDumpCmd.Env = vmexec.DefaultVMEnv(arch, nil)

		dumpOut, err = vmDumpCmd.CombinedOutput()
		if err != nil {
			return nil, fmt.Errorf("objdump failed: %v\n%s", err, string(dumpOut))
		}
	} else if bridge.CanFallbackToHost(vmErr) {
		hostTmpBin := filepath.Join(os.TempDir(), fmt.Sprintf("golens_disasm_%d_%d_%s", time.Now().UnixNano(), nonce, arch))
		defer func() { _ = os.Remove(hostTmpBin) }()

		hostBuildCmd := exec.CommandContext(ctx, "go", "build", "-p", "2", "-o", hostTmpBin, relPkg)
		hostBuildCmd.Dir = workDir
		hostBuildCmd.Env = append(os.Environ(), "GOARCH="+arch, "GOMEMLIMIT=512MiB", "GOGC=50")
		hostBuildOut, hostBuildErr := hostBuildCmd.CombinedOutput()
		if hostBuildErr != nil {
			return nil, fmt.Errorf("build failed for %s: %v\n%s", arch, hostBuildErr, string(hostBuildOut))
		}

		var objdumpArgs []string
		if funcName != "" {
			objdumpArgs = []string{"tool", "objdump", "-s", symPatternFor(funcName), hostTmpBin}
		} else {
			objdumpArgs = []string{"tool", "objdump", hostTmpBin}
		}
		hostDumpCmd := exec.CommandContext(ctx, "go", objdumpArgs...)
		hostDumpCmd.Dir = workDir
		hostDumpCmd.Env = append(os.Environ(), "GOARCH="+arch)
		dumpOut, err = hostDumpCmd.CombinedOutput()
		if err != nil {
			return nil, fmt.Errorf("objdump failed: %v\n%s", err, string(dumpOut))
		}
	} else {
		return nil, fmt.Errorf("build failed for %s: %v\n%s", arch, vmErr, string(vmOut))
	}

	return parseObjdumpOutput(string(dumpOut), funcName, arch, modRoot)
}

func symPatternFor(funcName string) string {
	if strings.Contains(funcName, ")") || strings.Contains(funcName, "(") || strings.HasPrefix(funcName, "*") {
		normalized := funcName
		if strings.HasPrefix(funcName, "*") && !strings.HasPrefix(funcName, "(*") {
			if dot := strings.Index(funcName, "."); dot > 0 {
				normalized = "(" + funcName[:dot] + ")" + funcName[dot:]
			}
		}
		return `(?:^|\.)` + regexp.QuoteMeta(normalized) + `$`
	} else if strings.Contains(funcName, ".") {
		return `(?:^|\.)` + regexp.QuoteMeta(funcName) + `$`
	}
	return `(?:^|[^)])\.` + regexp.QuoteMeta(funcName) + `$|^` + regexp.QuoteMeta(funcName) + `$`
}

func isTargetSymbol(sym, funcName string) bool {
	funcName = strings.TrimSpace(funcName)
	if funcName == "" {
		return true
	}

	if sym == funcName {
		return true
	}

	if (!strings.HasPrefix(funcName, "runtime.") && !strings.HasPrefix(funcName, "internal/")) &&
		(strings.HasPrefix(sym, "runtime.") || strings.HasPrefix(sym, "runtime/") || strings.HasPrefix(sym, "internal/")) {
		return false
	}

	if strings.Contains(funcName, ")") || strings.Contains(funcName, "(") || strings.HasPrefix(funcName, "*") {
		normalized := funcName
		if strings.HasPrefix(funcName, "*") && !strings.HasPrefix(funcName, "(*") {
			if dot := strings.Index(funcName, "."); dot > 0 {
				normalized = "(" + funcName[:dot] + ")" + funcName[dot:]
			}
		}
		return sym == normalized || strings.HasSuffix(sym, "."+normalized) || strings.HasSuffix(sym, "/"+normalized)
	}

	if strings.Contains(funcName, ".") {
		if strings.Contains(sym, ")") || strings.Contains(sym, "(") {
			return false
		}
		return sym == funcName || strings.HasSuffix(sym, "."+funcName) || strings.HasSuffix(sym, "/"+funcName)
	}

	if strings.Contains(sym, ")") || strings.Contains(sym, "(") {
		return false
	}

	if !strings.HasSuffix(sym, "."+funcName) {
		return false
	}

	prefix := strings.TrimSuffix(sym, "."+funcName)
	pkgPart := prefix
	if lastSlash := strings.LastIndex(prefix, "/"); lastSlash >= 0 {
		pkgPart = prefix[lastSlash+1:]
	}
	if strings.Contains(pkgPart, ".") {
		return false
	}

	return true
}

func parseObjdumpOutput(raw, funcName, arch string, modRoots ...string) (*DisasmResult, error) {
	var modRoot string
	if len(modRoots) > 0 {
		modRoot = modRoots[0]
	}
	res := &DisasmResult{
		Function:     funcName,
		TargetArch:   arch,
		Instructions: make([]DisasmInstruction, 0),
	}

	lines := strings.Split(raw, "\n")
	asmRegex := regexp.MustCompile(`^\s*([a-zA-Z0-9_\-./\\]+\.go):(\d+)\s+(0x[0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+(\S+)\s*(.*)$`)

	inTargetFunction := (funcName == "")
	for _, l := range lines {
		trimmed := strings.TrimSpace(l)
		if strings.HasPrefix(trimmed, "TEXT ") {
			parts := strings.Fields(trimmed)
			if len(parts) >= 2 {
				sym := strings.TrimSuffix(parts[1], "(SB)")
				if idx := strings.Index(sym, "<"); idx >= 0 {
					sym = sym[:idx]
				}
				inTargetFunction = isTargetSymbol(sym, funcName)
			}
			continue
		}

		if !inTargetFunction {
			continue
		}

		m := asmRegex.FindStringSubmatch(l)
		if m != nil {
			srcLine, _ := strconv.Atoi(m[2])
			if srcLine > 0 {
				sourcePath := m[1]
				if modRoot != "" && strings.HasPrefix(sourcePath, "/workspaces/") {
					sourcePath = vmexec.GuestToHostPath(modRoot, sourcePath)
				}
				res.Instructions = append(res.Instructions, DisasmInstruction{
					Source:   sourcePath,
					Line:     srcLine,
					Address:  m[3],
					Mnemonic: m[5],
					Operands: strings.TrimSpace(m[6]),
				})
			}
		}
	}

	return res, nil
}
