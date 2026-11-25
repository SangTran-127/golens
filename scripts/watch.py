import os
import sys
import time
import subprocess
import signal

# Folders to watch
WATCH_DIRS = ["desktop", "core"]
EXTENSIONS = [".swift", ".go", ".h", ".c"]

def get_mtimes():
    mtimes = {}
    for d in WATCH_DIRS:
        if not os.path.exists(d):
            continue
        for root, dirs, files in os.walk(d):
            # Skip build/hidden directories
            if ".build" in root or ".git" in root:
                continue
            for f in files:
                if any(f.endswith(ext) for ext in EXTENSIONS):
                    path = os.path.join(root, f)
                    try:
                        mtimes[path] = os.path.getmtime(path)
                    except OSError:
                        pass
    return mtimes

def main():
    print("GoLens Hot-Restart Watcher Started.")
    print(f"Watching directories: {WATCH_DIRS} for changes...")
    
    mtimes = get_mtimes()
    app_process = None
    
    def start_app():
        nonlocal app_process
        if app_process:
            print("[Watcher] File change detected! Stopping application...")
            try:
                # Terminate the entire process group cleanly
                os.killpg(os.getpgid(app_process.pid), signal.SIGTERM)
                app_process.wait(timeout=2)
            except Exception:
                try:
                    app_process.terminate()
                except Exception:
                    pass
        
        print("[Watcher] Rebuilding project...")
        # Run make build
        build_res = subprocess.run(["make", "build"])
        if build_res.returncode == 0:
            print("[Watcher] Build successful! Launching application...")
            # Run make run using preexec_fn=os.setsid so we can kill all child processes cleanly
            app_process = subprocess.Popen(["make", "run"], preexec_fn=os.setsid)
        else:
            print("[Watcher] Build failed. Fix compiler errors to restart.")

    # Initial start
    start_app()
    
    try:
        while True:
            time.sleep(1)
            current_mtimes = get_mtimes()
            
            # Check for additions, deletions, or modifications
            changed = False
            if len(current_mtimes) != len(mtimes):
                changed = True
            else:
                for path, mtime in current_mtimes.items():
                    if path not in mtimes or mtimes[path] != mtime:
                        changed = True
                        break
            
            if changed:
                mtimes = current_mtimes
                start_app()
                
    except KeyboardInterrupt:
        print("\nStopping Hot-Restart Watcher...")
        if app_process:
            try:
                os.killpg(os.getpgid(app_process.pid), signal.SIGTERM)
            except Exception:
                pass

if __name__ == "__main__":
    main()
