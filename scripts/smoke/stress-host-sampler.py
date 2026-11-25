import subprocess
import sys
import time

app = sys.argv[1]


def cpu_seconds(text):
    parts = text.split(":")
    secs = float(parts[-1])
    if len(parts) > 1:
        secs += 60 * int(parts[-2].split("-")[-1])
    if len(parts) > 2:
        secs += 3600 * int(parts[-3].split("-")[-1])
    return secs


last = {}
while True:
    rows = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,time=,comm="], capture_output=True, text=True).stdout.splitlines()
    procs = {}
    for row in rows:
        f = row.split(None, 4)
        if len(f) == 5:
            procs[f[0]] = f
    if app not in procs:
        break
    tracked = {app: "app"}
    for pid, f in procs.items():
        if f[1] == app and "gopls" in f[4]:
            tracked[pid] = "gopls"
        elif "Virtualization.VirtualMachine" in f[4]:
            tracked[pid] = "vm"
    now = time.time()
    out = []
    for pid, role in tracked.items():
        f = procs[pid]
        cpu = cpu_seconds(f[3])
        prev = last.get(pid)
        pct = 100 * (cpu - prev[1]) / (now - prev[0]) if prev else 0.0
        last[pid] = (now, cpu)
        out.append(f"{role}:{pid}:cpu={pct:.0f}:rssMB={int(f[2]) // 1024}")
    print(f"epoch={now:.3f} " + " ".join(out), flush=True)
    time.sleep(1)
