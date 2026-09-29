# Sourced by delegate.sh, judge.sh, fix.sh and report.sh. Reads the judgment-day and ponytail texts at run time, verbatim.
# Nothing here paraphrases them. The INSTALLED skills are always looked for first, on every call; only when one is missing
# is the bundled clone in vendor/ used instead, with a loud warning, because a clone can be older than the real thing.
CLAUDE_HOME=${CLAUDE_HOME:-$HOME/.claude}
VENDOR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vendor
die() { echo "delegate-tasks: $*" >&2; exit 1; }

# pick <label> <installed-path> <clone-path>: prints the path to use. Installed wins; the clone is a warned fallback.
pick() {
  if [ -s "$2" ]; then printf '%s\n' "$2"
  elif [ -s "$3" ]; then
    echo "delegate-tasks: WARNING using the BUNDLED CLONE of $1 ($3), not the installed one: install $1 for the real, current version (see README)" >&2
    printf '%s\n' "$3"
  else die "$1 is missing: neither installed ($2) nor bundled ($3)"; fi
}

# newest installed ponytail plugin file <rel> (e.g. skills/ponytail/SKILL.md), or a path that does not exist
ponytail_installed() { ls -d "$CLAUDE_HOME"/plugins/cache/ponytail/ponytail/*/"$1" 2>/dev/null | sort -V | tail -1 || true; }

# agent_body <name>: the agent definition without its frontmatter (e.g. jd-judge-a, jd-fix-agent)
agent_body() {
  local f; f=$(pick "judgment-day agent $1" "$CLAUDE_HOME/agents/$1.md" "$VENDOR_DIR/judgment-day/agents/$1.md") || exit 1
  tr -d '\r' <"$f" | awk 'c<2 && /^---/ {c++; next} c>=2'
}

# ref_block <heading>: the fenced prompt under that heading of the judgment-day reference
ref_block() {
  local f; f=$(pick "the judgment-day skill" "$CLAUDE_HOME/skills/judgment-day/references/prompts-and-formats.md" \
    "$VENDOR_DIR/judgment-day/skills/judgment-day/references/prompts-and-formats.md") || exit 1
  local out; out=$(tr -d '\r' <"$f" | awk -v h="$1" '$0==h{f=1;next} f&&/^```/{if(!i){i=1;next}else exit} f&&i')
  [ -n "$out" ] || die "heading '$1' not found in $f"; printf '%s\n' "$out"
}

# ponytail_skill: the ponytail SKILL.md (newest installed version, else the clone), frontmatter stripped
ponytail_skill() {
  local f; f=$(pick "the ponytail skill" "$(ponytail_installed skills/ponytail/SKILL.md)" "$VENDOR_DIR/ponytail/skills/ponytail/SKILL.clone.md") || exit 1
  tr -d '\r' <"$f" | awk 'c<2 && /^---/ {c++; next} c>=2'
}

# skill_sources: one line saying which of the two skills are installed and which fall back to the clone (for the report)
skill_sources() {
  local jd=installed pt=installed
  [ -s "$CLAUDE_HOME/skills/judgment-day/references/prompts-and-formats.md" ] && [ -s "$CLAUDE_HOME/agents/jd-judge-a.md" ] \
    && [ -s "$CLAUDE_HOME/agents/jd-judge-b.md" ] && [ -s "$CLAUDE_HOME/agents/jd-fix-agent.md" ] || jd="BUNDLED CLONE"
  [ -s "$(ponytail_installed skills/ponytail/SKILL.md)" ] || pt="BUNDLED CLONE"
  echo "judgment-day: $jd; ponytail: $pt"
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
