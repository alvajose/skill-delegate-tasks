# Sourced by delegate.sh, judge.sh and fix.sh. Reads the REAL skill and agent texts at run time, verbatim.
# Nothing here paraphrases them, and there is no fallback: if a source is missing the script stops.
CLAUDE_HOME=${CLAUDE_HOME:-$HOME/.claude}
die() { echo "delegate-tasks: $*" >&2; exit 1; }

# agent_body <name>: the agent definition without its frontmatter (e.g. jd-judge-a, jd-fix-agent)
agent_body() {
  local f="$CLAUDE_HOME/agents/$1.md"; [ -s "$f" ] || die "missing real agent definition: $f"
  tr -d '\r' <"$f" | awk 'c<2 && /^---/ {c++; next} c>=2'
}

# ref_block <heading>: the fenced prompt under that heading of the real judgment-day reference
ref_block() {
  local f="$CLAUDE_HOME/skills/judgment-day/references/prompts-and-formats.md"
  [ -s "$f" ] || die "missing real judgment-day reference: $f"
  local out; out=$(tr -d '\r' <"$f" | awk -v h="$1" '$0==h{f=1;next} f&&/^```/{if(!i){i=1;next}else exit} f&&i')
  [ -n "$out" ] || die "heading '$1' not found in $f"; printf '%s\n' "$out"
}

# ponytail_skill: the real ponytail SKILL.md (newest installed version), frontmatter stripped
ponytail_skill() {
  local f; f=$(ls -d "$CLAUDE_HOME"/plugins/cache/ponytail/ponytail/*/skills/ponytail/SKILL.md 2>/dev/null | sort -V | tail -1)
  [ -n "$f" ] || die "the ponytail skill is not installed under $CLAUDE_HOME/plugins/cache/ponytail"
  tr -d '\r' <"$f" | awk 'c<2 && /^---/ {c++; next} c>=2'
}

# wt_tree <worktree>: tree object of the worktree's current content (tracked + new files, .gitignore respected, review
# scratch excluded). Built in a temporary index: no branch, HEAD or real index is touched, nothing is committed.
wt_tree() {
  local idx; idx=$(mktemp -u)
  GIT_INDEX_FILE=$idx git -C "$1" add -A -- . ':!.review-*' >/dev/null 2>&1
  GIT_INDEX_FILE=$idx git -C "$1" write-tree; rm -f "$idx"
}
# wt_base <worktree>: the tree a task started from: HEAD, or HEAD + its predecessors for a chained task (<wt>.base.tree)
wt_base() { if [ -f "$1.base.tree" ]; then cat "$1.base.tree"; else git -C "$1" rev-parse 'HEAD^{tree}'; fi; }
