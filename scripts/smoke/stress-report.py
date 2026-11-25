import collections
import datetime
import glob
import os
import re
import sys

out, mode = sys.argv[1], sys.argv[2]


def read(name):
    try:
        with open(os.path.join(out, name), errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def pct(values, q):
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(len(s) * q))]


drive = read(f"stress-{mode}.log")
marks = []
phase_of_line = []
current = "start"
for line in drive:
    m = re.match(r"DRIVE time (\S+) \S+ epoch=(\S+)", line)
    if m:
        current = m.group(1)
        marks.append((float(m.group(2)), current))
    phase_of_line.append(current)


def phase_at(epoch):
    name = "start"
    for t, n in marks:
        if epoch >= t:
            name = n
        else:
            break
    return name


order = []
for _, n in marks:
    if n not in order:
        order.append(n)

print("== keystrokes (due to painted, ms) ==")
for line in drive:
    if line.startswith("DRIVE keystats") and " reset " not in line:
        print("  " + line[6:])
print("== main-thread stalls (hangmon, ms) ==")
for line in drive:
    if line.startswith("DRIVE hangmon report"):
        print("  " + line[6:])
for line in drive:
    if line.startswith("DRIVE keylat"):
        print("  " + line[6:])
stalls = [l for l in drive if l.startswith("DRIVE stall ")]
if stalls:
    print("== main-thread stall stacks (>=50 ms, GoLens and UI frames, innermost first) ==")
    for l in stalls:
        head, _, frames = l[12:].partition(": ")
        keep = [f.split("`", 1)[1] for f in frames.split(" <- ") if f.startswith(("GoLensApp`", "SwiftUI`", "SwiftUICore`", "AppKit`", "libgoagent"))]
        at = re.search(r"epoch=(\S+)", head)
        print(f"  {phase_at(float(at.group(1))) if at else '?'} {head}")
        print("      " + " <- ".join(keep[:14])[:900])

panels = collections.Counter()
slow = collections.defaultdict(list)
for line, ph in zip(drive, phase_of_line):
    if line.startswith("DRIVE panel visible"):
        panels[(ph, "visible")] += 1
    elif line.startswith("DRIVE panel hidden"):
        panels[(ph, "hidden")] += 1
    m = re.match(r"DRIVE slowkey (\S+) ms", line)
    if m:
        slow[ph].append(float(m.group(1)))
print("== completion panel and slow keys (>50 ms) per phase ==")
for ph in order:
    v, h = panels[(ph, "visible")], panels[(ph, "hidden")]
    s = slow.get(ph, [])
    if v or h or s:
        print(f"  {ph:18s} panel {v}/{v + h}  slowkeys n={len(s)} max={max(s) if s else 0:.0f}")
for line in drive:
    if line.startswith("DRIVE head") or "not found" in line:
        print("  " + line[6:])

req = collections.defaultdict(list)
outcomes = collections.defaultdict(collections.Counter)
inflight = collections.defaultdict(int)
diags = collections.defaultdict(list)
changes = collections.Counter()
for line in read(f"core-{mode}.log"):
    ts = line[:23]
    try:
        epoch = datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S.%f").timestamp()
    except ValueError:
        continue
    ph = phase_at(epoch)
    m = re.search(r"\[lspreq\] done (\S+) id=\d+ ms=(\S+) outcome=(\S+) bytes=\d+ inflight=(\d+)", line)
    if m:
        req[(ph, m.group(1))].append(float(m.group(2)))
        outcomes[(ph, m.group(1))][m.group(3)] += 1
        inflight[ph] = max(inflight[ph], int(m.group(4)))
        continue
    m = re.search(r"\[lspreq\] diagnostics (\S+) v=\S+ n=(\d+) sinceChange=(\S+)", line)
    if m:
        diags[ph].append((m.group(1), int(m.group(2))))
        continue
    if "[lspreq] didChange" in line:
        changes[ph] += 1
print("== LSP requests per phase (ms from send to response) ==")
for ph in order:
    methods = sorted(k[1] for k in req if k[0] == ph)
    if not methods and not diags.get(ph):
        continue
    d = diags.get(ph, [])
    print(f"  [{ph}] didChange={changes[ph]} publishDiagnostics={len(d)} files={len(set(p for p, _ in d))} diags={sum(n for _, n in d)} max-inflight={inflight[ph]}")
    for meth in methods:
        v = req[(ph, meth)]
        oc = " ".join(f"{k}={n}" for k, n in sorted(outcomes[(ph, meth)].items()))
        print(f"    {meth:38s} n={len(v):3d} p50={pct(v, .5):7.0f} p90={pct(v, .9):7.0f} max={max(v):7.0f}  {oc}")

host = collections.defaultdict(lambda: collections.defaultdict(list))
for line in read(f"host-{mode}.log"):
    m = re.match(r"epoch=(\S+) (.*)", line)
    if not m:
        continue
    ph = phase_at(float(m.group(1)))
    for item in m.group(2).split():
        role, _, cpu, rss = item.split(":")
        host[ph][role + " cpu"].append(float(cpu.split("=")[1]))
        host[ph][role + " rssMB"].append(float(rss.split("=")[1]))
print("== host CPU (% of one core) and RSS per phase: mean / max ==")
for ph in order:
    if ph in host:
        print(f"  {ph:18s} " + "  ".join(f"{k}={sum(v) / len(v):.0f}/{max(v):.0f}" for k, v in sorted(host[ph].items())))

guest = read("stress-guest.log")
if guest:
    print("== guest per phase: cgroup memory.current MB max, MemAvailable MB min, swap MB max, gopls RSS MB max, gopls CPU %, memory.high events, oom kills ==")
    rows = []
    for line in guest:
        m = re.match(r"ep=(\d+) up=(\S+) cur=(\d*) avail=(\d*) swap=(\d*) zram=\[.*?\] events=\[(.*?)\] oom_kill (\d+) procs=\[(.*)\]", line)
        if not m:
            continue
        ev = dict(re.findall(r"(\w+) (\d+)", m.group(6)))
        gp = re.search(r"gopls:\d+:rss=(\d*):ticks=(\d*)", m.group(8))
        tb = re.search(r"total=(\d+) balloon=(\d+)", line)
        hi = re.search(r"high=(\d+)", line)
        rows.append((int(m.group(1)), float(m.group(2)), int(m.group(3) or 0), int(m.group(4) or 0), int(m.group(5) or 0), int(ev.get("high", 0)), int(m.group(7)),
                     int(gp.group(1) or 0) if gp else 0, int(gp.group(2) or 0) if gp else 0,
                     (int(tb.group(1)) - 4 * int(tb.group(2))) >> 10 if tb else 0, int(hi.group(1)) >> 20 if hi else 0))
    per = collections.defaultdict(list)
    for r in rows:
        per[phase_at(r[0])].append(r)
    for ph in order:
        rs = per.get(ph)
        if not rs:
            continue
        span = max(rs[-1][1] - rs[0][1], 1)
        cpu = 100 * (rs[-1][8] - rs[0][8]) / 100 / span
        guest = f" guestMB={min(r[9] for r in rs)}-{max(r[9] for r in rs)} highMB={min(r[10] for r in rs)}-{max(r[10] for r in rs)}" if any(r[9] for r in rs) else ""
        print(f"  {ph:18s} cur={max(r[2] for r in rs) >> 20} avail={min(r[3] for r in rs) >> 10} swap={max(r[4] for r in rs) >> 10} goplsRSS={max(r[7] for r in rs) >> 10} goplsCPU={cpu:.0f} high+={rs[-1][5] - rs[0][5]} oom={rs[-1][6]}{guest}")

app = read(f"app-{mode}.log")
fr = [float(m.group(1)) for m in (re.search(r"completion first-results (\S+) ms", l) for l in app) if m]
if fr:
    print(f"== completion first-results ms: n={len(fr)} p50={pct(fr, .5):.0f} p90={pct(fr, .9):.0f} max={max(fr):.0f}")
fails = [l for l in app if "failed" in l and "[measure]" in l]
print(f"== measure failures logged: {len(fails)}")
for l in collections.Counter(re.sub(r"\d+(\.\d+)?", "N", l) for l in fails).most_common(8):
    print(f"  {l[1]}x {l[0][:160]}")
print("== stack samples: " + " ".join(os.path.basename(p) for p in sorted(glob.glob(os.path.join(out, "sample-*.txt")))))
