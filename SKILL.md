---
name: delegate-tasks
description: 'Orchestrate a piece of work from whatever model invoked this skill: plan it grounded in the project (its docs plus whatever code-intelligence, memory or documentation tools are available or the user names), delegate each task to a headless OpenCode worker in its own git worktree, loop each worker until an exact done-command passes, run two blind judges per task as it finishes, and get a final report from a cheap model. Invoke as "/delegate-tasks <what to do>".'
---

# Delegate tasks

You are the orchestrator: **the model that was invoked with this skill, in whatever harness and subscription you are running** (Claude Code, OpenCode, Codex, ...). You plan, review, and integrate; you do not need to be a specific model. OpenCode agents implement; two more judge; you plan, review, and integrate. The text after `/delegate-tasks` is the request.

`<skill-dir>` below is the directory this SKILL.md was loaded from.

## Required skills, and the bundled clones

**judgment-day** and **ponytail** are required: this skill is built on them and uses their real text. Install them (see the README).
`vendor/` holds MIT-licensed **clones** of both (their files are named `SKILL.clone.md` on purpose, so no skill loader or installer mistakes them for real skills), only so the skill still works where they are not installed. At the start of **every** run, check for the installed ones first:

- **ponytail:** load it with your harness's skill tool (in Claude Code, `ponytail:ponytail` and `ponytail:ponytail-review`). If it cannot be loaded, read `<skill-dir>/vendor/ponytail/skills/ponytail/SKILL.clone.md` (and `.../ponytail-review/SKILL.clone.md`) and follow it as written.
- **judgment-day:** load it with your skill tool (`judgment-day`). If it cannot be loaded, read `<skill-dir>/vendor/judgment-day/skills/judgment-day/SKILL.clone.md` and its `references/`.
- The scripts do the same on their own for the texts they pass to workers and judges: installed first, clone only as a fallback, with a `WARNING using the BUNDLED CLONE` line in their output.

Whenever a clone is used, **tell the user plainly before launching and again in the report**: "using the bundled clone of <skill>, not the installed one; it may be older than the current version, install it for the real one". A clone is a fallback, never the ideal.

## Models per phase (all configurable)

Only workers and judges need `opencode` installed with providers configured. Every worker/judge model is a variable in `models.env` next to this file (`provider/model`, from `opencode models`). Edit the file to change the default, or override for one run with an environment prefix, e.g. `JUDGE1_MODEL=openai/gpt-5.5 bash delegate.sh ...`. Never hardcode a model in a command.

| Phase | Who | Model variable | Effort variable |
|---|---|---|---|
| 1. Plan | the orchestrator | the model that invoked this skill (change it in your harness, not here) | your harness |
| 2. Implement | OpenCode agent, one per task | `IMPL_MODEL` (empty = OpenCode default) | `IMPL_EFFORT` |
| 3. Judge | two blind OpenCode judges per task | `JUDGE1_MODEL`, `JUDGE2_MODEL` (use two different models) | `JUDGE1_EFFORT`, `JUDGE2_EFFORT` |
| 4. Fix, if the judges confirm severe findings | the real fix actor, OpenCode | `FIX_MODEL` (empty = `IMPL_MODEL`) | `FIX_EFFORT` |
| 5. Integration | the orchestrator | the model that invoked this skill | your harness |
| 6. Final report | one headless call (`report.sh`): `claude -p` for a Claude model id, `opencode run` for a `provider/model` id | `REPORT_MODEL` (default `claude-sonnet-5-5`) | `REPORT_EFFORT` (`medium`) |

Effort is OpenCode's `--variant`. `max` means the highest variant that model offers, and the scripts translate it because the names differ per model (`low/high/max`, `low/medium/xhigh`, `none/thinking`...). Empty means the model's default.

**Models named in the request win over `models.env`.** Any of them can be named, blind judges included, and so can the efforts. Map what the user wrote to the variables:

| The user says | Set |
|---|---|
| implementer, worker | `IMPL_MODEL`, and also `FIX_MODEL` unless the fixer is named separately |
| fixer, fix actor | `FIX_MODEL` |
| judge 1 / judge 2, or "judges: X and Y" (first = 1, second = 2) | `JUDGE1_MODEL`, `JUDGE2_MODEL` |
| report, reporter | `REPORT_MODEL` |
| effort of any of them ("judges at max", "report at low") | the matching `*_EFFORT` |

Use them for this run only, as an environment prefix. **Repeat the prefix on every call of the run** (`delegate.sh`, `judge.sh`, `fix.sh`, `report.sh`): each is a separate process, so a judge or a report launched without it falls back to `models.env`. Write them into `models.env` only when the user says to keep them (if it does not exist yet, copy `models.env.example` first; `models.env` is the user's and is not tracked).

Before launching, tell the user which model and effort each actor will use and where each came from (the request or `models.env`). Check every OpenCode model against `opencode models` (the report's Claude model id is not listed there, that is expected). If one is missing, or two judges end up on the same model, ask the user once.

## Phase 1 - Plan (this is the initial prompt: follow it exactly)

Before writing any plan, ground yourself in the project. Do not plan from the request alone.

1. **Structure:** get the code map, the call flow and who depends on what in the area the request touches, with whatever code-intelligence tool you have (an index like codegraph, an LSP, your harness's search) or the one the user named. If you have none, read the code.
2. **Memory:** if a memory tool is available (engram or another) or the user named one, search it for this project: past decisions, conventions, bugs already fixed, rejected approaches. Do not re-propose what was rejected.
3. **Project intent:** read every `.md` that records business logic, philosophy, vision, and main ideas (`AGENTS.md`, `CLAUDE.md`, `README`, `docs/`, architecture notes). The plan must fit that vision, not fight it.
4. **Libraries:** for any library the plan depends on, use a documentation tool if one is available (context7 or another) or the user named one; otherwise check the installed version's own docs and source. Do not rely on memory for APIs.
5. **Design the plan with the real ponytail skill.** Invoke it (Skill tool, `ponytail:ponytail`) and apply it as written, to every candidate task; drop or shrink tasks accordingly and say what you dropped. Do not work from a summary of it. If it cannot be loaded, use the bundled clone and tell the user (see "Required skills").
6. **Write the plan.** For each task: id, goal in one or two sentences, why it serves the project's vision, allowed files (prefer disjoint sets; two tasks may edit the same file only when they change different regions or functions, and then the plan says so and fixes the integration order), the "done" command that must pass, `depends_on` (ids of the tasks whose result it needs, empty if none), and a risk note. Add a short "dropped by ponytail" list and the order in which branches will be integrated.
7. **Show the plan to the user and wait for approval** before launching anything, unless the request says to skip confirmation.

## Decompose a long plan into a task graph

A detailed plan can be long, with many phases, and still be one objective. Do not hand it to one worker: break it into subtasks and run them as a graph. Each subtask has an id, a goal, allowed files, its own exact done command, and `depends_on`.

- **Split along real seams:** a module, a layer, a result that can be verified on its own. Right-sized means one focused session for a modest model and one command that proves it. If a piece cannot be verified alone, merge it with the piece that lets you verify it.
- **No dependency = parallel.** Every task with no unfinished predecessor is launched at the same time.
- **A dependency exists only when the task needs the other's result** to be written or verified (it calls its code, its done command needs its output, it builds on what it created). Touching the same file in a different region is not a dependency; git merges that (see below).
- **Dependent tasks chain.** When a predecessor's notification says done (exit 0), launch the tasks whose predecessors are now all done, and never earlier. A task that gives up (exit 2) blocks everything downstream: do not launch those, report them as blocked.
- **Show the graph in the plan** (`T3 <- T1, T2`), the waves it produces, and the integration order (dependency order).

## How parallel tasks avoid stepping on each other

The standard git way, no locks: every task gets its own **worktree and branch**, all created from the same `HEAD`, so agents never share a working directory or an index. Overlap in the same file is fine: git's three-way merge combines changes made to different regions, and the orchestrator resolves real conflicts at integration (Phase 5), keeping the intent of both sides, not whichever came last. Disjoint files are still preferred because they make merges trivial.

## Phase 2 - Implement (loops until the task is done)

Write `<scratchpad>/<task>.md` per task from the plan: goal, allowed files, why. The **done command** is a separate argument, not part of the brief: it must be an exact, executable check (tests, typecheck, a script that asserts the behavior) that exits 0 only when the task is truly complete. A vague done command gives a vague result, so make it exact; if you cannot state one, the task is not ready to delegate. The script prepends the standing rules for the agent: the ponytail skill, use the tools it has, no git commits, stay inside the worktree. **Tools the user named** (an MCP server, a skill) go into each brief under "Tools to use". Workers and judges run inside OpenCode, so they only have what OpenCode has configured (`opencode mcp list`): do not promise a worker a tool it cannot reach.

From the repo root, one call per task. Launch now every task that has no unfinished predecessor, in parallel; each time a task finishes, launch the tasks whose predecessors are all done. A chained task also gets `AFTER`: the ids of **all** its ancestors, in dependency order (`AFTER="t1 t2" bash <skill-dir>/delegate.sh ...`). Its worktree then starts from `HEAD` plus their changes, applied uncommitted, and the script records that starting point so the task's own change stays separable (judges review only that):

```bash
bash <skill-dir>/delegate.sh <task> <brief-file> "<done-command>"
```

The script loops on its own: the agent works, the harness runs the done command in the worktree, and while it fails the output goes back to the same session (`FIX_MODEL`) until it passes or `MAX_LOOPS` passes are used. Exit 0 = done; exit 2 = gave up (report it to the user with the last output, do not restart it silently). The worktree is created from `HEAD`: commit or stash anything the agents must see first. Output: worktree `<repo>-wt/<task>` on branch `track/<task>`, log `<repo>-wt/<task>.log`.

**Anything a task creates outside its worktree** (a database, a port, a temp directory) must be private to that task, and its removal command is registered at launch in `DELEGATE_CLEANUP` (one shell command per line; also list `rm -f <brief-file>`), so Phase 7 can always remove it:

```bash
DELEGATE_CLEANUP=$'<command that removes the resource>\nrm -f <brief-file>' \
<ENV_VAR_THE_TESTS_READ>=<value private to this task> \
bash <skill-dir>/delegate.sh <task> <brief-file> "<done-command>"
```

For example, when the project's tests truncate the database they use, give each task its own database: create it under a per-task name, pass its URL through the environment variable the tests read, and register the command that drops it. How to do that is specific to each project, so it is not part of this skill.

**Launching workers:** start `delegate.sh` and `judge.sh` each as its own background task of your harness (in Claude Code: a Bash call with `run_in_background: true`; if your harness has no background tasks, run them in the background of the shell and poll their output) with a name like `OpenCode <task>: <goal in a few words>` (judges: `Judge 1 <task>` and `Judge 2 <task>`, one call each). That makes each worker show up in the harness's background-task list with a readable name, and you are notified when it finishes; do not use a subagent for this. The scripts print one progress line per pass, so the task's output shows what it is doing; read it instead of the JSON log.

## Phase 3 - Judge (as each task finishes)

Judging is the real **judgment-day** skill, not something approximated here: invoke it (Skill tool, `judgment-day`; its bundled clone only if it is not installed) and follow it exactly (both judges confirm = confirmed; one judge = suspect, no auto-fix; its two-round budget; its terminal verdicts `APPROVED | ESCALATED`), with **two deliberate overrides of its human gates**, because this skill runs unattended once the plan is approved:

- **No approval before the correction.** The user's approval of the plan is the authorization and the plan is the criterion: a confirmed severe finding is one that breaks the task's goal, its done command, its allowed files, or a rule in the project's own docs. Fix confirmed severe findings automatically, without asking.
- **Contradictions go to the orchestrator first.** When the judges contradict each other (one reports a severe defect that the other's evidence contradicts, or they disagree on the same location), decide it yourself: read the code at the cited location, check both judges' proofs, run the done command or a focused check. Rule by the plan and the evidence and record the ruling and why in the ledger: a real defect becomes confirmed (fix it), a false one is dropped. Escalate to the user **only** if the evidence does not settle it, stating the question, both positions and what you checked. The scripts only launch the actors with the skill's own texts: `jd-judge-a` / `jd-judge-b` and the skill's judge prompt, verbatim (`real.sh` reads them at run time: the installed ones first, the bundled clone only when one is missing, never a paraphrase).

The moment a task's notification says it is done (exit 0), launch its two judges; **do not wait for the other tasks**. Each judge is its own background call, so each shows up in the background-task list:

```bash
bash <skill-dir>/judge.sh <task> <brief-file> 1     # description: Judge 1 <task>   (jd-judge-a, JUDGE1_MODEL)
bash <skill-dir>/judge.sh <task> <brief-file> 2     # description: Judge 2 <task>   (jd-judge-b, JUDGE2_MODEL)
```

Judges are blind (no shared context). Free-tier models (`opencode/*-free`) are refused as judges because their shell cannot be denied (`ALLOW_FREE_JUDGE=1` overrides that knowingly); `judge.sh` retries a judge once when it returns no valid JSON. Shell, edits and writes are denied to them, as in the real definition, which only lets them read and search; they may use any read-only lookup tool their OpenCode has. Each writes `<repo>-wt/<task>.judge<N>.txt` and the script prints a one-line summary of the judge's JSON (`{"findings":[...],"evidence":[...]}`, severities BLOCKER|CRITICAL|WARNING|SUGGESTION). Exit 4 / "NO RESULT" means the judge returned no valid JSON even after `judge.sh`'s own retry: that is not a clean result; report the task as unresolved. A task that gave up (exit 2) is not judged; report it.

## Phase 4 - Fix and re-judge

Merge the two judge results into the ledger as the judgment-day skill says. Only severe findings confirmed by **both** judges, or ruled real by you on a contradiction, are fixed; do not ask the user first (see Phase 3). Put exactly those rows in a file and run the real fix actor (`jd-fix-agent` definition plus the skill's fix prompt, verbatim):

```bash
bash <skill-dir>/fix.sh <task> <confirmed-findings-file>
```

Then run the task's done command yourself in the worktree. For the scoped re-judgment, append the frozen ledger to the task's brief file and rerun both judges (`judge.sh`): because `fix.sh` left a snapshot, they see only the frozen ledger and the fix delta, as the skill requires. **At most two fix rounds and two re-judgments per task.** Anything still severe after round two is ESCALATED to the user; there is no third round. Apart from the plan approval and integration, this escalation and an unresolvable contradiction are the only points where the run waits for the user.

## Phase 5 - Review and integrate

When every task is judged, for each one read `git -C <worktree> diff` and `git status` and run its done command in its worktree. Integrate only when the user asks; never commit, merge, or push unasked. When asked, follow the dependency order of the graph (predecessors first; a chained task's worktree also contains its ancestors' edits, which git merges without conflict because they are identical to what is already merged). If judging forced a fix in a task that others already build on, apply that fix's delta to their worktrees and rerun their done commands before integrating. In order:

1. Commit the task's branch from its worktree (Conventional Commit message).
2. Merge it into the target branch with `git merge --no-ff track/<task>`, one branch at a time.
3. On a conflict, read both sides, keep the intent of both, and resolve it yourself; never pick a side blindly.
4. After the last merge, rerun the done command of **every** task on the merged result (a clean merge can still break another task), then review the total diff with the real ponytail review skill (Skill tool, `ponytail:ponytail-review`). If it cannot be loaded, use the bundled clone of ponytail-review and tell the user; never improvise a review of your own.

## Phase 6 - Final report (a cheap model, a tiny context)

When integration is decided (done, or the user chose not to integrate yet) and **before** cleanup, produce the report. Write the user's original request to a file and run:

```bash
bash <skill-dir>/report.sh <request-file> <task> [task...]
```

The script collects the facts from files (run record, brief, judge findings, each task's own patch: no LLM involved) and makes **one headless call** with `REPORT_MODEL` at `REPORT_EFFORT` (`claude -p` when it is a Claude model id, `opencode run` when it is a `provider/model` id, so any subscription OpenCode supports works), whose whole context is that packet plus a short instruction. It prints the path of `<repo>-wt/delegate-report.md` and a line with the tokens and cost.

Why not switch the orchestrator's own model for the report, and why not hand it to a subagent that inherits the session: either one makes the cheap model read the whole session, which costs more than the report is worth, while the packet is a few thousand tokens however long the session was. It also works whatever harness the orchestrator runs in.

**Show it to the user without rewriting it**: send the file (in Claude Code, the SendUserFile tool with render; otherwise print it). Do not paraphrase it yourself: writing it again spends the orchestrator's tokens, which is what this phase avoids. Add at most two lines of your own, and only what the report cannot know (for example a decision you need from the user). If the report says something was not verified, that stays in.

The report file is the deliverable and is kept; `report.sh` deletes its packet.

## Phase 7 - Clean up (always, when the whole flow is over)

After the report is written (it reads the logs, verdicts and patches that this phase deletes), for every task, also failed or abandoned ones:

```bash
bash <skill-dir>/cleanup.sh <task>
```

It runs the task's registered cleanup commands (temporary databases, briefs, ...) and deletes its logs, verdicts and patches. It removes the worktree and branch only when the branch is merged and nothing is uncommitted; otherwise it keeps them and exits 3, which you report to the user (for example when they declined integration). Use `--discard` only when the user said to drop that work. A cleanup line that fails stays registered so it can be retried; tell the user.
