#!/usr/bin/env bash
# Usage (from the repo root): cleanup.sh <task> [--discard]
# Run when the WHOLE flow is over (final review and integration included), for every task, also failed ones.
# Always: runs the task's registered cleanup commands (<repo>-wt/<task>.cleanup, one shell command per line,
# e.g. dropping a temporary database) and deletes the task's run files (logs, verdicts, briefs listed there).
# Worktree and branch: removed only if the branch is merged into the current branch and the worktree has no
# uncommitted work. Otherwise they are KEPT and reported. --discard removes them anyway (only when the user said so).
set -uo pipefail
task=${1:?task}; discard=${2:-}
root=$(git rev-parse --show-toplevel); wt="$root-wt/$task"; reg="$wt.cleanup"; failed=0

if [ -f "$reg" ]; then
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    if (cd "$root" && bash -c "$cmd") >/dev/null 2>&1; then echo "[$task] cleaned: $cmd"
    else echo "[$task] CLEANUP FAILED (kept in $reg): $cmd" >&2; failed=1; fi
  done <"$reg"
fi
rm -f "$wt".log "$wt".fix.log "$wt".prefix.tree "$wt".base.tree "$wt".result "$wt".judge*.txt "$wt".judge*.txt.attempt1
[ "$failed" = 0 ] && rm -f "$reg"

branch="track/$task"
if [ -d "$wt" ]; then
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -n "$discard" ] || { git branch --merged | grep -qx "[* ] *$branch" && [ -z "$dirty" ]; }; then
    git worktree remove --force "$wt" && git branch -D "$branch" -q 2>/dev/null
    echo "[$task] removed worktree and branch"
  else
    echo "[$task] KEPT worktree and branch: not merged or has uncommitted work (use --discard only if the user said to drop it)" >&2
    exit 3
  fi
fi
exit $failed
