#!/usr/bin/env bash
# Usage (from the repo root): fix.sh <task> <confirmed-findings-file>
# The real judgment-day fix actor (jd-fix-agent definition + the skill's Fix Actor Prompt, verbatim) applies ONLY the
# findings the orchestrator confirmed, using FIX_MODEL. It first snapshots the tree (<repo>-wt/<task>.prefix.tree) so that the
# scoped re-judgment sees only the fix delta, as the skill requires. Then the orchestrator reruns the done command and both judges.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/models.sh"; source "$here/real.sh"; source "$here/slots.sh"
task=${1:?task}; findings=${2:?confirmed findings file}
root=$(git rev-parse --show-toplevel); wt="$root-wt/$task"; [ -d "$wt" ] || die "no worktree: $wt"
acquire_slot worker "$task fix"

prompt=$(ref_block "## Fix Actor Prompt")
prompt=${prompt//'{table}'/"$(cat "$findings")"}
prompt=${prompt//'{resolved SKILL.md paths}'/"none resolved; project conventions are in AGENTS.md at the repository root"}
margs=(); [ -n "$FIX_MODEL" ] && margs=(-m "$FIX_MODEL")
effort_args "$FIX_MODEL" "${FIX_EFFORT:-}"
wt_tree "$wt" >"$wt.prefix.tree"
echo "[$task] fix actor: ${FIX_MODEL:-default model}"
# --auto approves permissions: acceptable only because --dir pins the agent to this worktree
timeout "${IMPL_TIMEOUT:-1800}" opencode run "$(agent_body jd-fix-agent)

$prompt" --dir "$wt" --auto --format json ${margs[@]+"${margs[@]}"} ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} >>"$wt.fix.log" 2>&1 || echo "fix actor exited with code $?" >>"$wt.fix.log"
git -C "$wt" status --short
