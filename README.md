# delegate-tasks

An agent skill that lets any model act as an **orchestrator**: it plans a piece of work, splits it into a graph of subtasks, delegates each one to a headless [OpenCode](https://opencode.ai) worker in its own git worktree, and has two blind judges review every result. The final report is written by a cheap model in a tiny fresh context.

The orchestrator is whichever model invoked the skill (Claude Code, OpenCode, Codex...). Workers, judges and the reporter are configured in `models.env`.

---

**Grosso Modo**: You select your best model in you favorite AI subscription, call the skill with the prompt telling what you need, and your orchestator will create a plan that, when approved, it will delegate it in all the tasks needed, calling one Opencode (just opencode shell for now) agente per task.
All the OpenCode agents loop until their respective tasks are marked as done. As each task finishes, the orchestrator launches two blind judges for it, using the **judgment-day** skill, so every task gets a double check before anything is integrated. Then the orchestrator will wait for your command to integrate the changes and call a reporter model to produce the final report.

All models, including the blind judges, can be mentioned explicitly in the prompt or configured in `models.env`.

---

## How it works

| Phase        | What happens                                                                                                                                                                                                                                                           |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Plan      | The orchestrator grounds itself in the project (its docs, plus whatever code-intelligence, memory or documentation tools are available or you name), designs the plan with the ponytail skill, splits it into subtasks with `depends_on`, and waits for your approval. |
| 2. Implement | One worktree and branch per task. Independent tasks run in parallel; a dependent task starts when its predecessors finish, on top of their changes. A worker loops until the task's _done command_ passes.                                                             |
| 3. Judge     | As each task finishes, two blind judges (the real judgment-day agents) review its own change. Each judge is its own background task.                                                                                                                                   |
| 4. Fix       | Only severe findings confirmed by both judges are fixed, by the real fix actor, at most two rounds.                                                                                                                                                                    |
| 5. Integrate | Only when you ask: commit each branch and merge one at a time, in dependency order.                                                                                                                                                                                    |
| 6. Report    | `report.sh` builds a fact packet from files and one headless call turns it into the report.                                                                                                                                                                            |
| 7. Clean up  | Temporary databases, logs and merged worktrees are removed. Unmerged work is kept.                                                                                                                                                                                     |

Nothing is committed, merged or pushed unless you ask for it.

## Requirements

- `bash` (Git Bash on Windows), `git`, `node`.
- [`opencode`](https://opencode.ai) with the providers of the models you configure. Workers and judges run through `opencode run`.
- `report.sh` needs either the `claude` CLI (a Claude model id, the default) or any `provider/model` that OpenCode can run.
- The real texts of these skills and agents, read at run time and never paraphrased (the scripts stop if one is missing):
  - the **judgment-day** skill and the agents `jd-judge-a`, `jd-judge-b`, `jd-fix-agent`, from [gentle-ai](https://github.com/Gentleman-Programming/gentle-ai). They are read from `~/.claude/agents/` and `~/.claude/skills/judgment-day/`.
  - the **ponytail** plugin ([DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail)), read from `~/.claude/plugins/cache/ponytail/`.
  - If they live elsewhere, set `CLAUDE_HOME`.

### Installing the two required skills

**ponytail** ([repository](https://github.com/DietrichGebert/ponytail)). In Claude Code, as two separate prompts:

```text
/plugin marketplace add DietrichGebert/ponytail
/plugin install ponytail@ponytail
```

This is the install the scripts read from (`~/.claude/plugins/cache/ponytail/`). OpenCode can load it too, with `{ "plugin": ["@dietrichgebert/ponytail"] }` in `opencode.json`, but that does not replace the Claude Code install.

**judgment-day** ([repository](https://github.com/Gentleman-Programming/gentle-ai), MIT). It ships inside gentle-ai. Either:

- **Only the pieces this skill needs** (the skill and its three agents). The agent files in the repo are templates, so the model and effort placeholders are filled on the way:

  ```bash
  base=https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/internal/assets
  dest=${CLAUDE_HOME:-$HOME/.claude}
  mkdir -p "$dest/skills/judgment-day/references" "$dest/agents"
  curl -fsSL "$base/skills/judgment-day/SKILL.md" -o "$dest/skills/judgment-day/SKILL.md"
  curl -fsSL "$base/skills/judgment-day/references/prompts-and-formats.md" -o "$dest/skills/judgment-day/references/prompts-and-formats.md"
  for a in jd-judge-a jd-judge-b jd-fix-agent; do
    curl -fsSL "$base/claude/agents/$a.md" | sed -e 's/{{CLAUDE_MODEL}}/sonnet/' -e '/{{CLAUDE_EFFORT_FRONTMATTER}}/d' > "$dest/agents/$a.md"
  done
  ```

- **The whole gentle-ai framework** with its own installer, which also adds memory, workflows and many more skills and agents, then run `gentle-ai install` and pick Claude Code:

  ```bash
  brew install gentleman-programming/tap/gentle-ai                                                       # macOS
  curl -fsSL https://raw.githubusercontent.com/Gentleman-Programming/gentle-ai/main/scripts/install.sh | bash  # macOS / Linux
  go install github.com/gentleman-programming/gentle-ai/v4/cmd/gentle-ai@latest                           # Windows (needs Go)
  ```

## What works with what

| Piece                                 | Works with                                                                                      | Notes                                                                                                                                                                       |
| ------------------------------------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Orchestrator                          | any model in any harness that can load a skill and run bash                                     | tested only in Claude Code with an Anthropic subscription; some steps name Claude Code tools (Skill tool, background bash, file sending), use your harness's equivalent     |
| Workers, judges, fix actor            | any model `opencode run` can reach: API keys, subscriptions and gateways that OpenCode supports | free-tier models cannot be judges (see safety notes)                                                                                                                        |
| Final report                          | `claude -p` for a Claude model id, or `opencode run` for a `provider/model` id                  | the OpenCode route carries OpenCode's own system prompt, so it costs more tokens than `claude -p`                                                                           |
| Code intelligence, memory, docs tools | none required                                                                                   | codegraph, engram, context7 and the like are only suggestions: the orchestrator uses what is available or what you name, and workers use what their OpenCode has configured |
| Skills                                | **judgment-day** and **ponytail** are required                                                  | the judges and the implementers use their real text on purpose, with no built-in substitute                                                                                 |

## Install

Put this folder where your harness reads skills, for example:

```bash
git clone <this repo> ~/.claude/skills/delegate-tasks     # Claude Code, and OpenCode reads it too
```

Optionally make your own copy of the settings (it works without: the scripts fall back to the example):

```bash
cp models.env.example models.env     # models.env is git-ignored, so your choices stay yours
```

Then invoke it: `/delegate-tasks <what you want done>`.

## Configuration: `models.env`

Every model and effort is a variable. `models.env.example` holds the defaults; copy it to `models.env` (git-ignored) for your own choices, or prefix one run: `JUDGE1_MODEL=provider/model bash judge.sh ...`.

| Variable                        | Used by                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------- |
| `IMPL_MODEL`, `IMPL_EFFORT`     | the implementer of each task                                                    |
| `FIX_MODEL`, `FIX_EFFORT`       | retries inside the implement loop and the fix actor (empty = the implementer's) |
| `JUDGE1_MODEL`, `JUDGE1_EFFORT` | judge 1 (`jd-judge-a`)                                                          |
| `JUDGE2_MODEL`, `JUDGE2_EFFORT` | judge 2 (`jd-judge-b`); use a different model family than judge 1               |
| `REPORT_MODEL`, `REPORT_EFFORT` | the final report (default `claude-sonnet-5-5`, `medium`)                        |
| `MAX_LOOPS`                     | maximum implement passes per task                                               |

Models are `provider/model` ids from `opencode models`. Effort is OpenCode's `--variant`: `max` means the highest variant the model offers, and the scripts translate it because the names differ per model (`low/high/max`, `low/medium/xhigh`, `none/thinking`...).

## Scripts

| Script                                  | Purpose                                                                                                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `delegate.sh <task> <brief> <done-cmd>` | worktree, worker loop until the done command passes. `AFTER="a b"` chains it after other tasks; `DELEGATE_CLEANUP` registers what to remove at the end. |
| `judge.sh <task> <brief> <1\|2>`        | one blind judge, using the real judgment-day agent and prompt.                                                                                          |
| `fix.sh <task> <findings>`              | the real fix actor applies only the confirmed findings.                                                                                                 |
| `report.sh <request> <task>...`         | the final report.                                                                                                                                       |
| `cleanup.sh <task> [--discard]`         | remove temporary resources; the worktree and branch only if merged.                                                                                     |

## Safety notes

- Workers run with OpenCode's `--auto` (it approves permissions) and are pinned to their worktree with `--dir`. That confines where they start, it is **not a sandbox**.
- Judges get shell, edit and write permissions denied by config. Free-tier models (`opencode/*-free`) refuse any config override, so their shell cannot be denied and `judge.sh` refuses them unless `ALLOW_FREE_JUDGE=1`.
- Higher effort and judges that read many files cost tokens. Check the price of the models you choose with `opencode models <provider> --verbose`.

## Status

Developed and used on Windows 11 with Git Bash and `opencode-go` models. Tested end to end on a real project with two independent tasks (implement loop, four judges, report). Chained tasks, fix rounds and the cleanup of temporary databases were checked with a fake `opencode` and small scenarios, not on a long real plan. Linux and macOS are untested.

## Future improvements

- Other shells. The scripts are bash only (Git Bash on Windows); PowerShell, cmd and fish are not supported yet.
- Orchestrators other than Claude Code, which are untested.

## License

None yet.
