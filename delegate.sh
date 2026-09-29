#!/usr/bin/env bash
# Usage (from the repo root): delegate.sh <task> <brief-file> <done-command>
# Runs OpenCode headless (IMPL_MODEL) in its own worktree <repo>-wt/<task> on branch track/<task>.
# Loops: after each pass the harness runs <done-command> in the worktree; while it fails, the failure
# output goes back to the same session (FIX_MODEL), up to MAX_LOOPS. Judges are NOT run here.
# AFTER="a b" (env): chained task. Its worktree starts from HEAD plus the own changes of tasks a, b (ancestors, in dependency
# order), applied as uncommitted edits; that state is recorded in <wt>.base.tree so the task's own change stays separable.
# Exit 0 = done command passed, 2 = gave up after MAX_LOOPS. Changes stay uncommitted.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/models.sh"; source "$here/real.sh"; source "$here/slots.sh"
task=${1:?task}; brief=${2:?brief file}; donecmd=${3:?done command}
root=$(git rev-parse --show-toplevel); wt="$root-wt/$task"; log="$wt.log"
[ -e "$wt" ] && { echo "worktree already exists: $wt" >&2; exit 1; }
acquire_slot worker "$task"   # waits in line while MAX_WORKERS / MAX_AGENTS are busy (slots.sh)
git worktree add -q -b "track/$task" "$wt" HEAD
# resources this task will create outside the worktree (databases, temp dirs...): cleanup.sh runs these lines at the very end
[ -z "${DELEGATE_CLEANUP:-}" ] || echo "$DELEGATE_CLEANUP" >>"$wt.cleanup"
if [ -n "${AFTER:-}" ]; then
  for p in $AFTER; do
    pwt="$root-wt/$p"; [ -d "$pwt" ] || die "AFTER: no worktree for $p"
    git -C "$pwt" diff "$(wt_base "$pwt")" "$(wt_tree "$pwt")" | git -C "$wt" apply --whitespace=nowarn \
      || die "cannot apply the changes of $p onto $task (overlapping edits?)"
  done
  wt_tree "$wt" >"$wt.base.tree"
fi

run() { # run <model> <prompt> [extra opencode args...]
  local m=$1 p=$2; shift 2; local margs=(); [ -n "$m" ] && margs=(-m "$m")
  # --auto approves permissions: acceptable only because --dir pins the agent to this worktree
  # a hung or looping worker is killed after IMPL_TIMEOUT seconds; the pass then counts as failed and the loop goes on
  timeout "${IMPL_TIMEOUT:-1800}" opencode run "$p" --dir "$wt" --auto --format json ${margs[@]+"${margs[@]}"} "$@" >>"$log" 2>&1 \
    || { rc=$?; echo "opencode exited with code $rc"; [ "$rc" = 124 ] && echo "worker killed after ${IMPL_TIMEOUT:-1800}s (IMPL_TIMEOUT)"; } | tee -a "$log" >&2
}

effort_args "$IMPL_MODEL" "${IMPL_EFFORT:-}"; IMPL_EA=(${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"})
effort_args "$FIX_MODEL" "${FIX_EFFORT:-}"; FIX_EA=(${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"})
# small run record the final report reads (cleanup.sh deletes it)
record() { { echo "task=$task"; echo "status=$1"; echo "passes=$2"; echo "brief=$brief"; echo "done_command=$donecmd"
  echo "impl_model=${IMPL_MODEL:-default}"; echo "impl_effort=${IMPL_EFFORT:-}"; echo "after=${AFTER:-}"; echo "last_done_output:"; echo "${3:-}" | tail -15; } >"$wt.result"; }

: >"$log"
echo "[$task] pass 1: ${IMPL_MODEL:-default model} implementing"
run "$IMPL_MODEL" "$(cat "$here/preamble.md")

# Ponytail skill (verbatim)

$(ponytail_skill)

# Task brief

$(cat "$brief")
Done command (the harness runs it after you finish and sends you back here until it passes): $donecmd" ${IMPL_EA[@]+"${IMPL_EA[@]}"}
sid=$(grep -o 'ses_[A-Za-z0-9]*' "$log" | head -1)
[ -n "$sid" ] || { echo "task $task: no sessionID in $log" >&2; exit 1; }

for ((i=1; ; i++)); do
  if out=$(cd "$wt" && bash -c "$donecmd" 2>&1); then
    record DONE "$i" "$out"
    echo "task: $task | DONE after $i pass(es) | model: ${IMPL_MODEL:-default} | worktree: $wt | log: $log"
    git -C "$wt" status --short; exit 0
  fi
  if [ "$i" -ge "$MAX_LOOPS" ]; then
    record GAVE_UP "$i" "$out"
    echo "task: $task | NOT DONE after $i pass(es); last output:" >&2; echo "$out" | tail -20 >&2; exit 2
  fi
  echo "[$task] pass $i: done command failed, sending the output back to ${FIX_MODEL:-default model}"
  run "$FIX_MODEL" "The done command failed. Keep working until it passes; do not stop to ask. Same rules as before.
Command: $donecmd
Output (last 60 lines):
$(echo "$out" | tail -60)" -s "$sid" ${FIX_EA[@]+"${FIX_EA[@]}"}
done
