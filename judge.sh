#!/usr/bin/env bash
# Usage (from the repo root): judge.sh <task> <brief-file> <1|2>
# One blind judgment-day judge (1 = jd-judge-a with JUDGE1_MODEL, 2 = jd-judge-b with JUDGE2_MODEL), launched as its own
# background task the moment the task finishes. The prompt is the REAL agent definition plus the REAL judge prompt of the
# judgment-day skill, verbatim (see real.sh). The judge can read files and use read-only lookup tools; shell and edits are denied.
# Result: <repo>-wt/<task>.judge<N>.txt containing the judge's JSON ({"findings":[...],"evidence":[...]}).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/models.sh"; source "$here/real.sh"; source "$here/slots.sh"
task=${1:?task}; brief=${2:?brief file}; n=${3:?judge number 1 or 2}
case $n in 1) letter=A; agent=jd-judge-a; model=${JUDGE1_MODEL:?set JUDGE1_MODEL};; 2) letter=B; agent=jd-judge-b; model=${JUDGE2_MODEL:?set JUDGE2_MODEL};; *) die "judge number must be 1 or 2";; esac
root=$(git rev-parse --show-toplevel); wt="$root-wt/$task"; out="$wt.judge$n.txt"
[ -d "$wt" ] || die "no worktree: $wt"
acquire_slot judge "$task judge $n"   # waits in line while MAX_JUDGES / MAX_AGENTS are busy (slots.sh)

# immutable target: the worktree's full change (tracked diff + new files) as a patch inside the worktree, read-only
patch="$wt/.review-patch-$n"; cp "$brief" "$wt/.review-brief-$n.md"
cur=$(wt_tree "$wt")
if [ -f "$wt.prefix.tree" ]; then
  # scoped re-judgment (fix.sh left a snapshot): only the fix delta, plus the frozen ledger the orchestrator put in the brief
  base=$(cat "$wt.prefix.tree"); scope="the fix delta only (scoped re-judgment)"
elif [ -f "$wt.base.tree" ]; then
  base=$(cat "$wt.base.tree"); scope="this task's own change (the changes of the tasks it depends on are already in the files)"
else
  base=$(git -C "$wt" rev-parse 'HEAD^{tree}'); scope="the whole task change"
fi
git -C "$wt" diff "$base" "$cur" >"$patch"
hash=$(sha256sum "$patch" | cut -d' ' -f1)

prompt=$(ref_block "## Judge Prompt")
prompt=${prompt//'{A|B}'/$letter}
prompt=${prompt//'{immutable target identity and exact paths}'/"task $task, sha256 $hash. Task brief: .review-brief-$n.md. Change under review: .review-patch-$n (a patch of $scope; the files it touches are in the current directory). Read only these and the code they touch."}
prompt=${prompt//'{resolved SKILL.md paths}'/"none resolved; project conventions are in AGENTS.md at the repository root"}

echo "[$task] judge $n ($letter): $model reviewing sha256 ${hash:0:12}"
# The real jd-judge definition only lets the judge read and search, so shell, edits and writes are denied by config.
# Free-tier models (opencode/*-free) refuse to run with ANY config override (checked), so their shell cannot be denied:
# they are refused as judges unless the user opts in with ALLOW_FREE_JUDGE=1 (edits are then still auto-rejected: no --auto).
denied='{"permission":{"bash":"deny","edit":"deny","write":"deny","webfetch":"deny"}}'
if [[ $model == opencode/*-free ]]; then
  [ "${ALLOW_FREE_JUDGE:-}" = 1 ] || { rm -f "$wt/.review-brief-$n.md" "$patch"; die "judge $n model $model is free-tier and cannot be sandboxed (its shell stays enabled). Use a paid model in models.env, or set ALLOW_FREE_JUDGE=1 to accept that."; }
  echo "[$task] WARNING judge $n: $model is free-tier; its shell cannot be denied" >&2
  cfg=()
else
  cfg=(env "OPENCODE_CONFIG_CONTENT=$denied")
fi

eff_var="JUDGE${n}_EFFORT"; effort_args "$model" "${!eff_var:-}"
run_judge() {
  "${cfg[@]}" timeout "${JUDGE_TIMEOUT:-900}" opencode run "$(agent_body "$agent")

$prompt" --dir "$wt" -m "$model" ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} >"$out" 2>&1 || echo "judge exited with code $?" >>"$out"
  sed -i 's/\x1b\[[0-9;]*m//g' "$out"
}
# summary of the judge's JSON; exit 4 when there is none
summarize() { node -e '
const t = require("fs").readFileSync(process.argv[1], "utf8");
// models sometimes leave a trailing comma ("},]"): accept that one slip, nothing looser
const parseLoose = (x) => { try { return JSON.parse(x); } catch (e) { return JSON.parse(x.replace(/,(s*[]}])/g, "$1")); } };
// ...or stop right before the final closing brace(s): close only what is still open, never invent content
const closeOpen = (x) => { let d = 0, s = false, e = false; for (const c of x) { if (s) { if (e) e = false; else if (c === "\\") e = true; else if (c === "\"") s = false; } else if (c === "\"") s = true; else if (c === "{") d++; else if (c === "}") d--; } return s || d <= 0 ? x : x + "}".repeat(d); };
for (const m of t.matchAll(/\{\s*"findings"/g)) { const i = m.index;
  let d = 0, s = false, e = false, j = i;
  for (; j < t.length; j++) { const c = t[j];
    if (s) { if (e) e = false; else if (c === "\\") e = true; else if (c === "\"") s = false; }
    else if (c === "\"") s = true; else if (c === "{") d++; else if (c === "}" && --d === 0) break; }
  try { const r = parseLoose(closeOpen(t.slice(i, j + 1))); const by = {};
    for (const f of r.findings) by[f.severity] = (by[f.severity] || 0) + 1;
    console.log(r.findings.length ? "findings: " + JSON.stringify(by) : "clean (no findings)"); process.exit(0); } catch (x) {}
}
process.exit(4);' "$out"; }

run_judge
if ! res=$(summarize); then
  # weak models sometimes invent a path or stop early; the skill says rerun once, so do it here
  echo "[$task] judge $n: no valid result, retrying once"
  cp "$out" "$out.attempt1"; run_judge
  res=$(summarize) || res="NO RESULT after retry (see $out and $out.attempt1)"
fi
rm -f "$wt/.review-brief-$n.md" "$patch"
echo "[$task] judge $n: $res"
case $res in NO\ RESULT*) exit 4;; esac
