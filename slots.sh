# Sourced by delegate.sh, fix.sh and judge.sh. Caps how many OpenCode agents run at once, to bound RAM:
#   MAX_WORKERS  implementers and fix actors at once (default 3)
#   MAX_JUDGES   judges at once (default 2)
#   MAX_AGENTS   all of them together (default 4)
# A script that finds no free slot waits in line (FIFO is not guaranteed, only the caps are). Slots are files in
# <repo>-wt/.slots/, one per running script, named <kind>.<pid>; a slot whose process is gone is reclaimed.
MAX_WORKERS=${MAX_WORKERS:-3}; MAX_JUDGES=${MAX_JUDGES:-2}; MAX_AGENTS=${MAX_AGENTS:-4}

# acquire_slot <worker|judge> <label>: blocks until this process holds a slot; it is released when the process exits.
acquire_slot() {
  local kind=$1 label=$2 dir mutex max waited=0 f pid n_kind n_all
  dir="$(git rev-parse --show-toplevel)-wt/.slots"; mutex="$dir/.lock"; mkdir -p "$dir"
  case $kind in worker) max=$MAX_WORKERS;; judge) max=$MAX_JUDGES;; *) die "unknown slot kind $kind";; esac
  SLOT_FILE="$dir/$kind.$$"
  while :; do
    if mkdir "$mutex" 2>/dev/null; then   # mkdir is atomic: only one script counts and takes a slot at a time
      for f in "$dir"/*.*; do             # reclaim slots of processes that are gone (killed, crashed)
        [ -e "$f" ] || continue; pid=${f##*.}; kill -0 "$pid" 2>/dev/null || rm -f "$f"
      done
      # grep -c exits 1 when it counts 0: without `|| true`, set -e would kill the script while it holds the lock
      n_kind=$(ls "$dir" | grep -c "^$kind\." || true); n_all=$(ls "$dir" | grep -c '\.[0-9]*$' || true)
      if [ "$n_kind" -lt "$max" ] && [ "$n_all" -lt "$MAX_AGENTS" ]; then
        echo "$label" >"$SLOT_FILE"; rmdir "$mutex"
        trap 'rm -f "$SLOT_FILE"' EXIT
        [ "$waited" -gt 0 ] && echo "[$label] slot free after ${waited}s in line, starting"
        return 0
      fi
      rmdir "$mutex"
    else
      # another script is counting right now: retry at once, this is not "no free slot"
      [ -n "$(find "$mutex" -maxdepth 0 -mmin +2 2>/dev/null)" ] && rmdir "$mutex" 2>/dev/null   # left by a killed script
      sleep 0.2; continue
    fi
    [ "$waited" -eq 0 ] && echo "[$label] waiting for a free $kind slot ($max $kind(s), $MAX_AGENTS agents in total)"
    sleep 5; waited=$((waited + 5))
  done
}
