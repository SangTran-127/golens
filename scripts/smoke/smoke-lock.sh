LOCK=${LOCK:-/private/tmp/golens-smoke.lock}
SMOKE_LOCK_OWNED=0

smoke_lock_held_by_ancestor() {
  local pid=$PPID cmd
  while [ "${pid:-0}" -gt 1 ]; do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$cmd" in
      *"mkdir $LOCK"*|*with-lock.py*) return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

smoke_lock_acquire() {
  if smoke_lock_held_by_ancestor; then
    echo "smoke lock already held by a parent process; running inside it"
    return 0
  fi
  until mkdir "$LOCK" 2>/dev/null; do sleep 10; done
  SMOKE_LOCK_OWNED=1
}

smoke_lock_release() {
  [ "$SMOKE_LOCK_OWNED" = 1 ] && rmdir "$LOCK" 2>/dev/null
  SMOKE_LOCK_OWNED=0
  return 0
}
