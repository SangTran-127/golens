#!/usr/bin/env python3
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "gopilot" / "fixtures"
GO_RUN_DIRS = {
    "http-storage": ".",
    "cli": ".",
    "library": ".",
    "di-ambiguous": ".",
    "multi-module": ".",
    "concurrency": ".",
    "perf-cpu": ".",
    "perf-heap": ".",
    "perf-contention": ".",
    "benchmark-lab": ".",
}
GO_TEST_ARGS = {
    "multi-module": ["./app/...", "./lib/..."],
}


def declared(source: str, name: str) -> bool:
    patterns = [
        rf"^func\s+(\([^)]*\)\s+)?{re.escape(name)}\b",
        rf"^type\s+{re.escape(name)}\b",
        rf"^(const|var)\s+{re.escape(name)}\b",
        rf"^\s+{re.escape(name)}\s*\(",
    ]
    return any(re.search(p, source, re.M) for p in patterns)


def check_ground_truth(fixture_dir: Path) -> list[str]:
    errors = []
    truth = json.loads((fixture_dir / "ground-truth.json").read_text())
    refs = []
    if truth.get("entry"):
        refs.append(truth["entry"])
    flow = truth["representativeFlow"]
    refs.extend(flow["steps"])
    if flow.get("output"):
        refs.append(flow["output"])
    for fact in truth.get("expectedFacts", []):
        refs.extend(fact.get("refs", []))
    for ref in refs:
        path = fixture_dir / ref["file"]
        if not path.is_file():
            errors.append(f"{fixture_dir.name}: missing file {ref['file']}")
            continue
        symbol = ref["symbol"].split(".")[-1]
        if not declared(path.read_text(), symbol):
            errors.append(f"{fixture_dir.name}: symbol {ref['symbol']} not declared in {ref['file']}")
    test_sources = "\n".join(p.read_text() for p in fixture_dir.rglob("*_test.go"))
    for name in truth.get("tests", []):
        if not re.search(rf"^func\s+{re.escape(name)}\(", test_sources, re.M):
            errors.append(f"{fixture_dir.name}: test {name} not found")
    return errors


PROFILE_ROW = re.compile(r"^\s*\S+\s+\S+%\s+\S+%\s+\S+\s+\S+%\s+(.*?)(?: \(inline\))?$")


def pprof_rows(profile: Path, sample_index: str) -> list[str]:
    cmd = ["go", "tool", "pprof", "-top", "-nodecount=60"]
    if sample_index != "cpu":
        cmd.append(f"-sample_index={sample_index}")
    result = subprocess.run([*cmd, str(profile)], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr)
    rows = []
    for line in result.stdout.splitlines():
        match = PROFILE_ROW.match(line)
        if match:
            rows.append(match.group(1))
    return rows


def check_profiles(fixture_dir: Path) -> list[str]:
    errors = []
    truth = json.loads((fixture_dir / "ground-truth.json").read_text())
    spec = truth.get("profiles")
    if not spec:
        return errors
    script = fixture_dir / spec["prepare"]
    if not script.is_file() or not script.stat().st_mode & 0o111:
        return [f"{fixture_dir.name}: {spec['prepare']} missing or not executable"]
    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / fixture_dir.name
        shutil.copytree(fixture_dir, copy)
        for kind, expect in spec["kinds"].items():
            out = Path(tmp) / f"{kind}.pprof"
            result = subprocess.run([str(script), str(copy), str(out), kind], capture_output=True, text=True)
            if result.returncode != 0 or not out.is_file() or out.stat().st_size == 0:
                errors.append(f"{fixture_dir.name}: prepare.sh {kind} failed\n{result.stderr}")
                continue
            try:
                rows = pprof_rows(out, expect["sampleIndex"])
            except RuntimeError as exc:
                errors.append(f"{fixture_dir.name}: pprof {kind} failed: {exc}")
                continue
            if not rows or rows[0] != expect["topFlat"]:
                errors.append(f"{fixture_dir.name}: {kind} top flat frame is {rows[:1]}, expected {expect['topFlat']}")
            for name in expect.get("mustContain", []):
                if name not in rows:
                    errors.append(f"{fixture_dir.name}: {kind} profile lacks frame {name}")
        extra = subprocess.run([str(script), str(copy), str(Path(tmp) / "bad.pprof"), "bogus"], capture_output=True, text=True)
        if extra.returncode == 0:
            errors.append(f"{fixture_dir.name}: prepare.sh accepted an unsupported kind")
    return errors


def run(cmd: list[str], cwd: Path) -> bool:
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(f"FAIL {' '.join(cmd)} in {cwd}\n{result.stdout}{result.stderr}\n")
        return False
    return True


def main() -> int:
    with_profiles = "--profiles" in sys.argv[1:]
    failed = False
    for name in sorted(GO_RUN_DIRS):
        fixture_dir = FIXTURES / name
        if not fixture_dir.is_dir():
            print(f"missing fixture {name}")
            failed = True
            continue
        errors = check_ground_truth(fixture_dir)
        if with_profiles:
            errors += check_profiles(fixture_dir)
        for error in errors:
            print(error)
        ok = not errors
        targets = GO_TEST_ARGS.get(name, ["./..."])
        ok = run(["go", "vet", *targets], fixture_dir) and ok
        ok = run(["go", "test", *targets], fixture_dir) and ok
        unformatted = subprocess.run(["gofmt", "-l", "."], cwd=fixture_dir, capture_output=True, text=True).stdout.strip()
        if unformatted:
            print(f"{name}: gofmt differences:\n{unformatted}")
            ok = False
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
        failed = failed or not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
