#!/usr/bin/env python3
import hashlib
import json
import shutil
import math
import os
import re
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path


BUNDLE_ID = "dev.golens.test.perf"
CORPUS_CACHE = Path.home() / "Library/Caches/GoLens/perf-corpora"


def load_corpus(spec_path: str) -> dict:
    spec = json.loads(Path(spec_path).read_text())
    if "module" in spec:
        root = CORPUS_CACHE / f"{spec['module'].replace('/', '_')}@{spec['version']}"
        if not root.exists():
            info = json.loads(subprocess.check_output(
                ["go", "mod", "download", "-json", f"{spec['module']}@{spec['version']}"],
                text=True, cwd=str(Path.home()),
            ))
            staging = root.with_name(root.name + ".partial")
            shutil.rmtree(staging, ignore_errors=True)
            shutil.copytree(info["Dir"], staging)
            for dirpath, dirnames, filenames in os.walk(staging):
                os.chmod(dirpath, 0o755)
                for name in filenames:
                    os.chmod(os.path.join(dirpath, name), 0o644)
            subprocess.run(["go", "mod", "download"], cwd=str(staging), check=True)
            staging.rename(root)
    else:
        root = Path(os.path.expanduser(os.environ.get(spec["rootEnv"], spec["root"])))
    spec["root"] = str(root)
    for key in ("target", "largeFile"):
        if key in spec and not (root / spec[key]).is_file():
            raise RuntimeError(f"corpus file missing: {root / spec[key]}")
    return spec


def parse_cputime(raw: str) -> float:
    text = raw.strip()
    if not text:
        return 0.0
    if "-" in text:
        days_s, rest = text.split("-", 1)
        days = int(days_s)
    else:
        days = 0
        rest = text
    parts = rest.split(":")
    if len(parts) == 2:
        mins, secs = int(parts[0]), float(parts[1])
        hours = 0
    elif len(parts) == 3:
        hours, mins, secs = int(parts[0]), int(parts[1]), float(parts[2])
    else:
        return 0.0
    return days * 86400 + hours * 3600 + mins * 60 + secs


def sample_cputime(pid: int) -> float | None:
    p = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], text=True, capture_output=True)
    if p.returncode != 0 or not p.stdout.strip():
        return None
    return parse_cputime(p.stdout)


def find_gopls_pids(root_pid: int) -> list[int]:
    p = subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,comm="], text=True, capture_output=True)
    if p.returncode != 0:
        return []
    children: dict[int, list[tuple[int, str]]] = {}
    all_rows: list[tuple[int, int, str]] = []
    for line in p.stdout.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        pid, ppid, comm = int(parts[0]), int(parts[1]), parts[2]
        children.setdefault(ppid, []).append((pid, comm))
        all_rows.append((pid, ppid, comm))
    queue = [root_pid]
    seen = {root_pid}
    matches: list[int] = []
    while queue:
        cur = queue.pop(0)
        for child_pid, comm in children.get(cur, []):
            if child_pid not in seen:
                seen.add(child_pid)
                queue.append(child_pid)
                if "gopls" in os.path.basename(comm):
                    matches.append(child_pid)
    return sorted(matches)


def run_footprint(pid: int) -> dict:
    p = subprocess.run(["/usr/bin/footprint", "-p", str(pid)], text=True, capture_output=True)
    out = p.stdout + ("\n" + p.stderr if p.stderr else "")
    m = re.search(r"Footprint:\s*([0-9.]+)\s*(B|KB|MB|GB)", out)
    mb = None
    raw_label = None
    if m:
        val = float(m.group(1))
        unit = m.group(2)
        raw_label = f"{val:g} {unit}"
        factors = {"B": 1.0 / (1024 * 1024), "KB": 1.0 / 1024.0, "MB": 1.0, "GB": 1024.0}
        mb = round(val * factors[unit], 2)
    return {
        "pid": pid,
        "returncode": p.returncode,
        "footprint_mb": mb,
        "footprint_raw": raw_label,
        "headline": next((l.strip() for l in out.splitlines() if "Footprint:" in l), ""),
    }


def snapshot_corpus(corpus: dict) -> dict:
    root = Path(corpus["root"])
    workspace = root / corpus["workspace"]
    listing = hashlib.sha256()
    for dirpath, dirnames, filenames in os.walk(workspace):
        dirnames[:] = sorted(d for d in dirnames if d not in (".git", "node_modules"))
        for name in sorted(filenames):
            fp = Path(dirpath) / name
            st = fp.stat()
            listing.update(f"{fp.relative_to(root)}\0{st.st_size}\0{st.st_mtime_ns}\n".encode())
    contents = {
        key: hashlib.sha256((root / corpus[key]).read_bytes()).hexdigest()
        for key in ("target", "largeFile") if key in corpus
    }
    git_status = ""
    if (root / ".git").exists():
        git_status = subprocess.check_output(["git", "-C", str(root), "status", "--porcelain"], text=True)
    return {
        "listing_sha256": listing.hexdigest(),
        "contents_sha256": contents,
        "git_status_sha256": hashlib.sha256(git_status.encode()).hexdigest(),
        "target_size": (root / corpus["target"]).stat().st_size,
        "workspace_dot_golens_exists": (workspace / ".golens").exists(),
    }


def assert_corpus_unchanged(before: dict, after: dict, run_idx: int) -> None:
    if after["workspace_dot_golens_exists"] and not before["workspace_dot_golens_exists"]:
        raise RuntimeError(f"Run {run_idx}: .golens was created inside the read-only corpus")
    for key in ("listing_sha256", "contents_sha256", "git_status_sha256"):
        if before[key] != after[key]:
            raise RuntimeError(f"Run {run_idx}: read-only corpus changed ({key})")


def pct(sorted_vals: list[float], q: float) -> float | None:
    if not sorted_vals:
        return None
    idx = min(len(sorted_vals) - 1, int(len(sorted_vals) * q))
    return round(sorted_vals[idx], 3)


def summarize(values: list[float]) -> dict | None:
    clean = [v for v in values if v is not None]
    if not clean:
        return None
    s = sorted(clean)
    return {
        "n": len(s),
        "min": round(s[0], 3),
        "median": round(statistics.median(s), 3),
        "p95": pct(s, 0.95),
        "p99": pct(s, 0.99),
        "max": round(s[-1], 3),
        "spread": round(s[-1] - s[0], 3),
    }


def build_drive_script(corpus: dict, idle_wait_sec: int) -> str:
    esc = "\u238b"
    bs = "\u232b"
    pause = "\u23f8"

    def comp_probe(expr: str, label: str) -> str:
        typed_len = len(expr.replace(pause, ""))
        return f"code:{expr};panelwait:{label};panel;code:{esc}{bs * typed_len};wait:0.6"

    anchor = "caret:" + corpus["anchor"]

    steps = [
        "wait:6",
        "fakeactive",
        "mark:ready",
        "wait:28",
        "time:warm",
        anchor,
        r"code:\n// ",
        "keylat:200",
        "key:deleteToBeginningOfLine:",
        "key:deleteBackward:",
        "wait:1.0",
        anchor,
        r"code:\n// semedit",
        "wait:1.5",
        "time:semedit-1",
        "code:1",
        "wait:1.2",
        "time:semedit-2",
        f"code:{bs}",
        "wait:1.2",
        "time:semedit-3",
        "code:2",
        "wait:1.2",
        "key:deleteToBeginningOfLine:",
        "key:deleteBackward:",
        "wait:1.0",
        "keystats:reset",
        anchor,
        r"code:\n",
        *[step for line in corpus["burst"] for step in ("codefast:" + line, r"code:\n")][:-1],
        "keystats:burst",
        "key:deleteToBeginningOfLine:",
        "key:deleteBackward:",
        "key:deleteToBeginningOfLine:",
        "key:deleteBackward:",
        "key:deleteToBeginningOfLine:",
        "key:deleteBackward:",
        "wait:6.0",
        anchor,
        r"code:\n",
        *[comp_probe(expr.replace(".", pause + ".", 1), label) for expr, label in corpus["probes"]],
        "key:deleteToBeginningOfLine:",
        "key:deleteBackward:",
        "wait:2.0",
        "caret:" + corpus["packageLine"],
        "mark:idle-ready",
        f"wait:{idle_wait_sec}",
        "mark:done",
        "quit",
    ]
    return ";".join(steps)


def parse_keylat(drive_text: str) -> dict | None:
    match = re.search(
        r"DRIVE keylat n=(\d+) p50=([0-9.]+) p95=([0-9.]+) max=([0-9.]+) over33=(\d+) over50=(\d+)",
        drive_text,
    )
    if not match:
        return None
    return {
        "n": int(match.group(1)),
        "p50_ms": float(match.group(2)),
        "p95_ms": float(match.group(3)),
        "max_ms": float(match.group(4)),
        "over33": int(match.group(5)),
        "over50": int(match.group(6)),
    }


def run_startup_launches(app_exec: str, quiet_dylib: str, corpus: dict, count: int) -> list[float | None]:
    root = Path(corpus["root"])
    env = os.environ.copy()
    env.update({
        "DYLD_INSERT_LIBRARIES": quiet_dylib,
        "GOLENS_MEASURE": "1",
        "GOLENS_EXECUTION_MODE": "host",
        "GOLENS_UNSAVED_RECOVERY": "off",
        "GOPILOT_CREDENTIAL_STORE": "file",
    })
    results: list[float | None] = []
    for _ in range(count):
        subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True)
        proc = subprocess.Popen(
            [app_exec, "-GoLensLastWorkspacePath", str(root / corpus["workspace"]),
             "-GoLensLastFilePath", str(root / corpus["target"]),
             "-GoLensAutoSaveOnFocusLoss", "NO", "-GoLensShowConsole", "<false/>"],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, bufsize=1,
        )
        watchdog = threading.Timer(60, proc.kill)
        watchdog.start()
        first_draw = None
        for line in iter(proc.stderr.readline, ""):
            match = re.search(r"\[measure\] startup first-draw ([0-9.]+) ms since process start", line)
            if match:
                first_draw = float(match.group(1))
                break
        proc.terminate()
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        watchdog.cancel()
        results.append(first_draw)
        time.sleep(2)
    return results


def run_large_file(run_idx: int, app_exec: str, driver_dylib: str, quiet_dylib: str, corpus: dict, out_dir: Path) -> dict:
    root = Path(corpus["root"])
    run_dir = out_dir / f"run-{run_idx}"
    drive_log = run_dir / "large-drive.log"
    before = snapshot_corpus(corpus)
    subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True)
    steps = [
        "wait:6", "fakeactive", "mark:ready", "wait:20",
        "caret:" + corpus["largeAnchor"], r"code:\n// ", "keylat:200",
        "key:deleteToBeginningOfLine:", "key:deleteBackward:", "wait:2", "mark:done", "quit",
    ]
    env = os.environ.copy()
    env.update({
        "DRIVE": ";".join(steps),
        "DRIVE_OUT": str(drive_log),
        "DYLD_INSERT_LIBRARIES": f"{quiet_dylib}:{driver_dylib}",
        "GOLENS_MEASURE": "1",
        "GOLENS_EXECUTION_MODE": "host",
        "GOLENS_UNSAVED_RECOVERY": "off",
        "GOPILOT_CREDENTIAL_STORE": "file",
    })
    t_launch = time.perf_counter()
    first_draw_ms = None
    proc = subprocess.Popen(
        [app_exec, "-GoLensLastWorkspacePath", str(root / corpus["workspace"]),
         "-GoLensLastFilePath", str(root / corpus["largeFile"]),
         "-GoLensAutoSaveOnFocusLoss", "NO", "-GoLensShowConsole", "<false/>"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, bufsize=1,
    )
    watchdog = threading.Timer(180, proc.kill)
    watchdog.start()
    for line in iter(proc.stderr.readline, ""):
        if first_draw_ms is None and "[measure] highlight " in line:
            first_draw_ms = round((time.perf_counter() - t_launch) * 1000.0, 2)
    watchdog.cancel()
    proc.wait(timeout=15)
    assert_corpus_unchanged(before, snapshot_corpus(corpus), run_idx)
    drive_text = drive_log.read_text(errors="replace") if drive_log.exists() else ""
    return {
        "file": corpus["largeFile"],
        "lines": sum(1 for _ in open(root / corpus["largeFile"], "rb")),
        "first_draw_ms": first_draw_ms,
        "keylat": parse_keylat(drive_text),
    }


def run_one(
    run_idx: int,
    app_exec: str,
    driver_dylib: str,
    quiet_dylib: str,
    corpus: dict,
    dwell_seconds: int,
    idle_seconds: int,
    out_dir: Path,
) -> dict:
    workspace_path = str(Path(corpus["root"]) / corpus["workspace"])
    file_path = str(Path(corpus["root"]) / corpus["target"])

    before_snap = snapshot_corpus(corpus)

    subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True)

    run_dir = out_dir / f"run-{run_idx}"
    run_dir.mkdir(parents=True, exist_ok=True)
    drive_log = run_dir / "drive.log"
    app_log = run_dir / "app.log"

    idle_wait_sec = max(idle_seconds + 20, dwell_seconds - 45)
    drive_str = build_drive_script(corpus, idle_wait_sec)

    env = os.environ.copy()
    env.update({
        "DRIVE": drive_str,
        "DRIVE_OUT": str(drive_log),
        "DYLD_INSERT_LIBRARIES": f"{quiet_dylib}:{driver_dylib}",
        "GOLENS_MEASURE": "1",
        "GOLENS_LSP_TRACE": "1",
        "GOLENS_EXECUTION_MODE": "host",
        "GOLENS_UNSAVED_RECOVERY": "off",
        "GOPILOT_CREDENTIAL_STORE": "file",
    })

    cmd = [
        app_exec,
        "-GoLensLastWorkspacePath", workspace_path,
        "-GoLensLastFilePath", file_path,
        "-GoLensAutoSaveOnFocusLoss", "NO",
        "-GoLensShowConsole", "<false/>",
    ]

    load_before = subprocess.check_output(["sysctl", "-n", "vm.loadavg"], text=True).strip()

    first_highlight_ms = None
    first_semantic_ms = None
    launch_ms = None
    highlight_ms: list[float] = []
    completion_ms: list[float] = []
    semantic_events: list[tuple[float, int]] = []
    lsp_error_count = 0
    stderr_lines: list[str] = []

    t_launch = time.perf_counter()
    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def read_stream(stream, is_err: bool):
        nonlocal first_highlight_ms, first_semantic_ms, lsp_error_count, launch_ms
        for line in iter(stream.readline, ""):
            now_epoch = time.time()
            now_ms = (time.perf_counter() - t_launch) * 1000.0
            s = line.rstrip("\n")
            if is_err:
                stderr_lines.append(s)
                first_draw = re.search(r"\[measure\] startup first-draw ([0-9.]+) ms since process start", s)
                if first_draw and launch_ms is None:
                    launch_ms = float(first_draw.group(1))
                elif "[measure] highlight " in s:
                    if first_highlight_ms is None:
                        first_highlight_ms = round(now_ms, 2)
                    m = re.search(r"highlight\s+([0-9.]+)\s+ms", s)
                    if m:
                        highlight_ms.append(float(m.group(1)))
                elif "[measure] semantic-tokens " in s:
                    if first_semantic_ms is None:
                        first_semantic_ms = round(now_ms, 2)
                    bm = re.search(r"\bof\s+(\d+)", s)
                    if bm:
                        semantic_events.append((now_epoch, int(bm.group(1))))
                elif "[measure] completion first-results " in s:
                    m = re.search(r"first-results\s+([0-9.]+)\s+ms", s)
                    if m:
                        completion_ms.append(float(m.group(1)))
                elif "[measure]" in s and "failed:" in s:
                    lsp_error_count += 1
        stream.close()

    t_out = threading.Thread(target=read_stream, args=(proc.stdout, False), daemon=True)
    t_err = threading.Thread(target=read_stream, args=(proc.stderr, True), daemon=True)
    t_out.start()
    t_err.start()

    idle_ready_at = None
    cpu_sample_start = None
    cpu_sample_end = None
    footprint_golens = None
    footprint_gopls = None
    gopls_pids: list[int] = []

    deadline = t_launch + dwell_seconds + 240
    while proc.poll() is None:
        now = time.perf_counter()
        if now > deadline:
            proc.terminate()
            break
        if idle_ready_at is None and drive_log.exists():
            txt = drive_log.read_text(errors="replace")
            if "DRIVE mark idle-ready" in txt:
                idle_ready_at = now
        if idle_ready_at is not None and cpu_sample_start is None:
            sample_start_target = max(t_launch + dwell_seconds - idle_seconds, idle_ready_at + 5.0)
            if now >= sample_start_target:
                gopls_pids = find_gopls_pids(proc.pid)
                cpu_sample_start = {
                    "mono": now,
                    "golens_cpu_s": sample_cputime(proc.pid) or 0.0,
                    "gopls_cpu_s": sum(sample_cputime(p) or 0.0 for p in gopls_pids),
                    "gopls_pids": list(gopls_pids),
                }
        if cpu_sample_start is not None and cpu_sample_end is None:
            if now >= cpu_sample_start["mono"] + idle_seconds and now >= t_launch + dwell_seconds:
                end_gopls_pids = find_gopls_pids(proc.pid) or cpu_sample_start["gopls_pids"]
                cpu_sample_end = {
                    "mono": now,
                    "golens_cpu_s": sample_cputime(proc.pid) or 0.0,
                    "gopls_cpu_s": sum(sample_cputime(p) or 0.0 for p in end_gopls_pids),
                    "gopls_pids": list(end_gopls_pids),
                }
                footprint_golens = run_footprint(proc.pid)
                if end_gopls_pids:
                    fps = [run_footprint(p) for p in end_gopls_pids]
                    total_mb = round(sum(x["footprint_mb"] or 0.0 for x in fps), 2)
                    footprint_gopls = {
                        "pids": end_gopls_pids,
                        "footprint_mb": total_mb,
                        "processes": fps,
                    }
                else:
                    footprint_gopls = {"pids": [], "footprint_mb": None, "processes": []}
        time.sleep(0.5)

    proc.wait(timeout=15)
    t_out.join(timeout=5)
    t_err.join(timeout=5)
    total_wall_s = round(time.perf_counter() - t_launch, 2)

    app_log.write_text("\n".join(stderr_lines) + "\n", encoding="utf-8")
    load_after = subprocess.check_output(["sysctl", "-n", "vm.loadavg"], text=True).strip()

    after_snap = snapshot_corpus(corpus)
    assert_corpus_unchanged(before_snap, after_snap, run_idx)

    if proc.returncode != 0:
        raise RuntimeError(f"Run {run_idx}: GoLensApp exited with non-zero code {proc.returncode}")

    drive_text = drive_log.read_text(errors="replace") if drive_log.exists() else ""
    if "DRIVE unknown step" in drive_text:
        raise RuntimeError(f"Run {run_idx}: driver reported unknown step in {drive_log}")

    final_buffer_bytes = semantic_events[-1][1] if semantic_events else None
    if final_buffer_bytes != before_snap["target_size"]:
        raise RuntimeError(
            f"Run {run_idx}: final in-memory buffer size {final_buffer_bytes} != baseline {before_snap['target_size']}"
        )

    semedit_samples_ms: list[float] = []
    for _, epoch_s in re.findall(r"DRIVE time (semedit-\d+) [0-9.]+ epoch=([0-9.]+)", drive_text):
        edit_epoch = float(epoch_s)
        for sem_epoch, _ in semantic_events:
            if sem_epoch >= edit_epoch and (sem_epoch - edit_epoch) <= 5.0:
                semedit_samples_ms.append(round((sem_epoch - edit_epoch) * 1000.0, 2))
                break

    keylat = parse_keylat(drive_text)

    keystats_match = re.search(
        r"DRIVE keystats burst n=(\d+) p50=([0-9.]+) p95=([0-9.]+) p99=([0-9.]+) max=([0-9.]+) over16=(\d+) over33=(\d+) over50=(\d+) over100=(\d+)",
        drive_text,
    )
    keystats = None
    if keystats_match:
        keystats = {
            "n": int(keystats_match.group(1)),
            "p50_ms": float(keystats_match.group(2)),
            "p95_ms": float(keystats_match.group(3)),
            "p99_ms": float(keystats_match.group(4)),
            "max_ms": float(keystats_match.group(5)),
            "over16": int(keystats_match.group(6)),
            "over33": int(keystats_match.group(7)),
            "over50": int(keystats_match.group(8)),
            "over100": int(keystats_match.group(9)),
        }

    panelwait_ms_all = [
        float(v) for _, v in re.findall(r"DRIVE panelwait (\S+) ([0-9.]+) ms", drive_text)
    ]
    panelwait_timeout_count = len(re.findall(r"DRIVE panelwait \S+ timeout", drive_text))
    panelwait_ms = summarize(panelwait_ms_all)

    panel_visible_count = len(re.findall(r"DRIVE panel visible", drive_text))
    panel_hidden_count = len(re.findall(r"DRIVE panel hidden", drive_text))

    idle_cpu = None
    if cpu_sample_start and cpu_sample_end:
        wall_dt = max(0.1, cpu_sample_end["mono"] - cpu_sample_start["mono"])
        golens_dt = max(0.0, cpu_sample_end["golens_cpu_s"] - cpu_sample_start["golens_cpu_s"])
        gopls_dt = max(0.0, cpu_sample_end["gopls_cpu_s"] - cpu_sample_start["gopls_cpu_s"])
        golens_pct = round((golens_dt / wall_dt) * 100.0, 2)
        gopls_pct = round((gopls_dt / wall_dt) * 100.0, 2)
        idle_cpu = {
            "window_s": round(wall_dt, 2),
            "golens_cpu_s": round(golens_dt, 3),
            "gopls_cpu_s": round(gopls_dt, 3),
            "golens_pct": golens_pct,
            "gopls_pct": gopls_pct,
            "combined_pct": round(golens_pct + gopls_pct, 2),
        }

    comp_first_ms = completion_ms[0] if completion_ms else None
    comp_warm_summary = summarize(completion_ms[1:]) if len(completion_ms) > 1 else summarize(completion_ms)
    recolour_summary = summarize(highlight_ms[1:]) if len(highlight_ms) > 1 else summarize(highlight_ms)
    semedit_summary = summarize(semedit_samples_ms)

    return {
        "run": run_idx,
        "exit_code": proc.returncode,
        "total_wall_s": total_wall_s,
        "load_before": load_before,
        "load_after": load_after,
        "corpus_verified_unchanged": True,
        "final_buffer_bytes": final_buffer_bytes,
        "lsp_error_count": lsp_error_count,
        "cold_launch_first_draw_ms": first_highlight_ms,
        "app_launch_to_first_draw_ms": launch_ms,
        "cold_open_first_semantic_tokens_ms": first_semantic_ms,
        "keylat": keylat,
        "keystats": keystats,
        "treesitter_recolour_ms": recolour_summary,
        "edit_semantic_colours_samples_ms": semedit_samples_ms,
        "edit_semantic_colours_ms": semedit_summary,
        "completion_first_results_all_ms": completion_ms,
        "completion_first_in_package_ms": comp_first_ms,
        "completion_warm_ms": comp_warm_summary,
        "completion_panelwait_all_ms": panelwait_ms_all,
        "completion_panelwait_ms": panelwait_ms,
        "completion_panelwait_timeouts": panelwait_timeout_count,
        "completion_panel_visible_count": panel_visible_count,
        "completion_panel_hidden_count": panel_hidden_count,
        "memory_after_dwell": {
            "golens": footprint_golens,
            "gopls": footprint_gopls,
        },
        "idle_cpu": idle_cpu,
    }


def main():
    app_exec = sys.argv[1]
    driver_dylib = sys.argv[2]
    quiet_dylib = sys.argv[3]
    corpus = load_corpus(sys.argv[4])
    runs = int(sys.argv[5])
    dwell_seconds = int(sys.argv[6])
    idle_seconds = int(sys.argv[7])
    out_dir = Path(sys.argv[8])

    out_dir.mkdir(parents=True, exist_ok=True)
    startup = run_startup_launches(app_exec, quiet_dylib, corpus, 6)
    print(f"=== startup launches without the driver: {startup} ===", flush=True)
    results = []
    for i in range(1, runs + 1):
        print(f"=== perf run {i}/{runs} (dwell={dwell_seconds}s, idle={idle_seconds}s) ===", flush=True)
        res = run_one(i, app_exec, driver_dylib, quiet_dylib, corpus, dwell_seconds, idle_seconds, out_dir)
        if "largeFile" in corpus:
            res["large_file"] = run_large_file(i, app_exec, driver_dylib, quiet_dylib, corpus, out_dir)
        results.append(res)
        print(json.dumps(res, indent=2), flush=True)

    summary = {
        "corpus": corpus["name"],
        "corpus_root": corpus["root"],
        "target_file": corpus["target"],
        "large_file": corpus.get("largeFile"),
        "relaunch_first_draw_all_ms": startup,
        "runs": results,
        "aggregates": {
            "cold_launch_first_draw_ms": summarize([r["cold_launch_first_draw_ms"] for r in results]),
            "app_launch_to_first_draw_ms": summarize([r["app_launch_to_first_draw_ms"] for r in results]),
            "relaunch_first_draw_ms": summarize(startup[1:]),
            "cold_open_first_semantic_tokens_ms": summarize([r["cold_open_first_semantic_tokens_ms"] for r in results]),
            "keylat_p50_ms": summarize([r["keylat"]["p50_ms"] for r in results if r["keylat"]]),
            "keylat_p95_ms": summarize([r["keylat"]["p95_ms"] for r in results if r["keylat"]]),
            "keystats_p50_ms": summarize([r["keystats"]["p50_ms"] for r in results if r["keystats"]]),
            "keystats_p95_ms": summarize([r["keystats"]["p95_ms"] for r in results if r["keystats"]]),
            "keystats_p99_ms": summarize([r["keystats"]["p99_ms"] for r in results if r["keystats"]]),
            "treesitter_recolour_p95_ms": summarize([r["treesitter_recolour_ms"]["p95"] for r in results if r["treesitter_recolour_ms"]]),
            "edit_semantic_colours_p95_ms": summarize([r["edit_semantic_colours_ms"]["p95"] for r in results if r["edit_semantic_colours_ms"]]),
            "completion_first_in_package_ms": summarize([r["completion_first_in_package_ms"] for r in results]),
            "completion_warm_p95_ms": summarize([r["completion_warm_ms"]["p95"] for r in results if r["completion_warm_ms"]]),
            "completion_panelwait_p95_ms": summarize([r["completion_panelwait_ms"]["p95"] for r in results if r["completion_panelwait_ms"]]),
            "lsp_error_count": summarize([float(r["lsp_error_count"]) for r in results]),
            "golens_footprint_mb": summarize([r["memory_after_dwell"]["golens"]["footprint_mb"] for r in results if r["memory_after_dwell"]["golens"]]),
            "gopls_footprint_mb": summarize([r["memory_after_dwell"]["gopls"]["footprint_mb"] for r in results if r["memory_after_dwell"]["gopls"]]),
            "idle_cpu_golens_pct": summarize([r["idle_cpu"]["golens_pct"] for r in results if r["idle_cpu"]]),
            "idle_cpu_gopls_pct": summarize([r["idle_cpu"]["gopls_pct"] for r in results if r["idle_cpu"]]),
            "idle_cpu_combined_pct": summarize([r["idle_cpu"]["combined_pct"] for r in results if r["idle_cpu"]]),
            "large_file_keylat_p95_ms": summarize([r["large_file"]["keylat"]["p95_ms"] for r in results if r.get("large_file", {}).get("keylat")]),
            "large_file_open_first_draw_ms": summarize([r["large_file"]["first_draw_ms"] for r in results if r.get("large_file")]),
        },
    }

    summary_path = out_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("=== AGGREGATE SUMMARY ===", flush=True)
    print(json.dumps(summary["aggregates"], indent=2), flush=True)
    print(f"SUMMARY_FILE={summary_path}", flush=True)


if __name__ == "__main__":
    main()
