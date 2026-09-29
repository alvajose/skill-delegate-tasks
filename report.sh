#!/usr/bin/env bash
# Usage (from the repo root): report.sh <request-file> <task> [task...]
# Final report of a run. The facts are collected from files by this script (no LLM, no tokens): per task the run record, the
# brief, the judges' findings and the task's own patch. Then ONE headless call, REPORT_MODEL at REPORT_EFFORT (models.env),
# turns that packet into the report: `claude -p` for a Claude model id (Anthropic subscription), or `opencode run` for a
# provider/model id (any provider OpenCode supports). Its context is only the packet plus a short instruction, never the
# orchestrator's session, so the report costs a few thousand tokens no matter how long the session was.
# Output: <repo>-wt/delegate-report.md (kept: it is the deliverable). Run it BEFORE cleanup.sh, which deletes what it reads.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); source "$here/models.sh"; source "$here/real.sh"
req=${1:?request file: the original request text, any language}; shift
[ $# -gt 0 ] || die "give at least one task id"
root=$(git rev-parse --show-toplevel); packet="$root-wt/delegate-report-packet.md"; out="${REPORT_OUT:-$root-wt/delegate-report.md}"
PATCH_CAP=${REPORT_PATCH_CAP:-16000}   # characters of patch per task

findings() { # findings <judge-file>: one line per finding of the judge's JSON, or why there is none
  [ -s "$1" ] || { echo "  (not run or file removed)"; return; }
  node -e '
const t = require("fs").readFileSync(process.argv[1], "utf8");
for (let k = t.indexOf("\"findings\""); k >= 0; k = t.indexOf("\"findings\"", k + 1)) {
  const i = t.lastIndexOf("{", k); let d = 0, s = false, e = false, j = i;
  for (; j < t.length; j++) { const c = t[j];
    if (s) { if (e) e = false; else if (c === "\\") e = true; else if (c === "\"") s = false; }
    else if (c === "\"") s = true; else if (c === "{") d++; else if (c === "}" && --d === 0) break; }
  try { const r = JSON.parse(t.slice(i, j + 1));
    if (!r.findings.length) { console.log("  clean: no findings"); process.exit(0); }
    for (const f of r.findings) console.log("  - [" + f.severity + "] " + f.location + " (" + f.causal_disposition + "): " + f.claim);
    process.exit(0); } catch (x) {}
}
console.log("  NO VALID RESULT (the judge returned no usable JSON)");' "$1"
}

{
  echo "# Run packet"
  echo; echo "## The request (as the user wrote it; answer in this language)"; echo; cat "$req"
  echo; echo "## Configured judges: 1 = ${JUDGE1_MODEL:-?} (effort ${JUDGE1_EFFORT:-default}), 2 = ${JUDGE2_MODEL:-?} (effort ${JUDGE2_EFFORT:-default})"
  for t in "$@"; do
    wt="$root-wt/$t"; echo; echo "## Task $t"
    if [ -f "$wt.result" ]; then echo '```'; cat "$wt.result"; echo '```'; else echo "(no run record: task finished before records existed, or cleanup already ran)"; fi
    brief=$(sed -n 's/^brief=//p' "$wt.result" 2>/dev/null); [ -f "$brief" ] && { echo; echo "Brief:"; echo '```'; head -60 "$brief"; echo '```'; }
    echo; echo "Judge 1:"; findings "$wt.judge1.txt"; echo "Judge 2:"; findings "$wt.judge2.txt"
    if [ -d "$wt" ]; then
      base=$(wt_base "$wt"); cur=$(wt_tree "$wt")
      merged=no; git branch --merged 2>/dev/null | grep -qx "[* ] *track/$t" && merged=yes
      echo; echo "Branch track/$t merged into the current branch: $merged. Uncommitted changes live in the worktree."
      echo "Files changed by this task:"; echo '```'; git -C "$wt" diff --stat "$base" "$cur"; echo '```'
      echo "Patch (unified, 12 lines of context; it shows the final code of what changed):"; echo '```diff'
      git -C "$wt" diff -U12 "$base" "$cur" | head -c "$PATCH_CAP"; echo; echo '```'
      [ "$(git -C "$wt" diff -U12 "$base" "$cur" | wc -c)" -gt "$PATCH_CAP" ] && echo "(patch cut at $PATCH_CAP characters; say so in the report)"
    else
      echo; echo "(worktree no longer exists: already integrated and cleaned, or discarded)"
    fi
  done
} >"$packet"

SYS="You write the final report of a multi-task engineering run for the person who requested it. Use ONLY the packet you receive: never invent files, behaviour or results; anything the packet does not show, say it was not verified. Write in the language of the request. Structure: 1) Result, at most 3 lines: what was asked, what was done, overall state (done, judged, integrated?). 2) One short section per task: what changed in plain words (files, behaviour before and after), the evidence (done command and its outcome, judge findings with severity; a judge with no valid result is not a pass), open items. 3) How the result looks: the essential final code of the changed parts, quoted from the patch's added and context lines with file names, brief. 4) Not verified and risks. 5) State: worktrees, branches, integration. Be concise, no filler, no praise."

echo "[report] $REPORT_MODEL effort=${REPORT_EFFORT:-default} packet=$(wc -c <"$packet") chars" >&2
if [[ $REPORT_MODEL == */* ]]; then
  # a provider/model id: run it through OpenCode, so any provider or subscription OpenCode supports works. Its context is larger
  # than claude -p's (OpenCode brings its own system prompt and tools); anything that could change a file is denied.
  effort_args "$REPORT_MODEL" "${REPORT_EFFORT:-}"
  OPENCODE_CONFIG_CONTENT='{"permission":{"bash":"deny","edit":"deny","write":"deny","webfetch":"deny"}}' \
    timeout "${REPORT_TIMEOUT:-600}" opencode run "$SYS

$(cat "$packet")" --dir "$root" -m "$REPORT_MODEL" ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} --format json 2>/dev/null \
    | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  const o = [];
  for (const l of s.split("\n")) { try { const j = JSON.parse(l); if (j.type === "text" && j.part && j.part.text) o.push(j.part.text); } catch (e) {} }
  if (!o.length) { console.error("[report] FAILED: no text came back from the model"); process.exit(1); }
  require("fs").writeFileSync(process.argv[1], o.join("\n").trim() + "\n"); console.error("[report] written through opencode"); });' "$out" \
    || die "report generation failed; the packet is at $packet"
else
command -v claude >/dev/null || die "REPORT_MODEL is a Claude model id, so the claude CLI is required; use a provider/model id to go through OpenCode instead"
claude -p --model "$REPORT_MODEL" ${REPORT_EFFORT:+--effort "$REPORT_EFFORT"} --tools "" --strict-mcp-config --disable-slash-commands \
  --no-session-persistence --setting-sources "" --system-prompt "$SYS" --output-format json <"$packet" 2>/dev/null \
  | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  try { const j = JSON.parse(s); require("fs").writeFileSync(process.argv[1], String(j.result).trim() + "\n");
    const u = Object.values(j.modelUsage || {})[0] || {};
    console.error("[report] tokens in=" + ((u.inputTokens || 0) + (u.cacheReadInputTokens || 0) + (u.cacheCreationInputTokens || 0)) + " out=" + (u.outputTokens || 0) + " cost=$" + (j.total_cost_usd || 0).toFixed(4));
  } catch (e) { console.error("[report] FAILED to get a report: " + s.slice(0, 300)); process.exit(1); } });' "$out" || die "report generation failed; the packet is at $packet"
fi
rm -f "$packet"; echo "$out"
