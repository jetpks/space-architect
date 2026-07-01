# Builder dispatch reference

Verified against the `claude` CLI (Claude Code) headless mode — the reference
harness — June 2026. The builder is `claude -p` (`--print`, the non-interactive
headless mode) pinned to the configured builder model (`<builder-model>`) — a
cheaper model run headless via the same harness the architect uses. Key facts the
skill encodes: lane-prompts go in on **stdin** (Claude Code has no `@file`, and a
big quoted lane-prompt as a shell argument gets mangled); the model is pinned with
`--model <builder-model>` (a floating alias drifts to whatever ships next — pin
the full id); there is **no `-C`/working-dir flag**, so
per-lane dispatch `cd`s into the worktree; permissions are the **tool
allow/deny lists** (`--allowedTools`/`--disallowedTools`) plus
`--permission-mode`, not a sandbox; web access is the built-in
`WebSearch`/`WebFetch` tools (no extension to install).

**The one load-bearing difference from the Codex design:** Codex's
`--sandbox workspace-write` made `.git` physically read-only. Claude Code has
**no automatic filesystem sandbox** in headless mode (the sandbox is opt-in via
settings, off by default), so `.git` is not hardware-protected. "Builders never
commit" (hard rule 7) is now enforced in three layers, weakest to strongest:
(1) a runtime first line — deny the git-write tools with
`--disallowedTools 'Bash(git commit:*)' …`; (2) worktree isolation between
lanes; (3) the authoritative check — an architect post-flight
`git -C <worktree> log <repo-base>..` that must be empty. The deny rules are
not airtight (a builder can shell out — `sh -c 'git commit …'` — past the
pattern match), so the post-flight `git log` is what the loop actually trusts.
If a lane committed, treat the worktree as tampered: reset and re-dispatch.

**Preflight (once per environment):** run `claude --version`, and confirm the
builder model resolves with a one-shot canary
(`echo ok | claude -p --model <builder-model> --max-turns 1`). No API key —
the builder runs on your Claude plan — but note headless `claude -p` draws on
the Agent SDK credit pool (separate from interactive usage since June 15 2026;
see `docs/DESIGN.md` §4). On the first real dispatch in a new environment, launch
ONE canary lane and confirm it starts cleanly before fanning anything out.

## Canonical dispatch — `architect dispatch <iteration> <lane>`

The canonical path is `architect dispatch <iteration> <lane>`. The tool
assembles the canonical `claude -p` argv, pins the builder model (the lane's
configured model or the CLI's reference default; see `docs/DESIGN.md` §4),
reads the lane prompt from `build/<id>-<lane>/prompt.md` on stdin, and streams
`--output-format stream-json --verbose` output to
`build/<id>-<lane>/run.jsonl`. Run each lane as its own **background Bash tool
call** (`run_in_background`) so your turn doesn't block for the full run (30–60
minutes is typical).

Write the lane's prompt to `build/<id>-<lane>/prompt.md` first (never pass a
big prompt as a shell argument — shells mangle quotes), then:

```bash
# single-lane iteration — run from the space root
architect dispatch <iteration> <lane>
```

For multi-lane iterations, create worktrees first (one per lane), then dispatch
each lane from its worktree:

```bash
# per lane:
architect worktree add <repo> <iteration> <lane> [--base <repo-base>]
architect dispatch <iteration> <lane>
```

`architect worktree add` creates `build/<id>-<lane>/wt` off the target repo's
base commit (a repo commit — distinct from the freeze, which is a space
commit), adds it with a `lane/<iteration>-<lane>` branch, and records it in
`space.yaml`.

Issue each dispatch as its **own background Bash tool call** — one call per
lane. Never use a shell `&` loop. A `for … & done` launcher is a *launcher*
process: it returns the instant it has spawned the lane children, the harness
reaps those now-orphaned `claude` processes, and every lane dies at once with no
`result` — partial diffs, no reports (this exact failure has happened: three
lanes killed at the same second, zero output). One blocking dispatch per
background Bash tool keeps each lane attached to a harness-tracked task that
survives the full run and reports completion per lane.

### What the tool runs under the hood

`architect dispatch` is equivalent to this — documented here for transparency
and as the manual fallback:

```bash
# write prompt to build/<id>-<lane>/prompt.md first, then:
( cd build/<id>-<lane>/wt && \
  claude -p --model <builder-model> \
    --permission-mode acceptEdits \
    --allowedTools 'Read,Edit,Write,Grep,Glob,Bash,WebSearch,WebFetch' \
    --disallowedTools 'Bash(git commit:*),Bash(git push:*),Bash(git reset:*),Bash(git merge:*),Bash(git rebase:*),Bash(git checkout:*),Bash(git branch:*)' \
    --output-format stream-json --verbose \
    --max-turns 200 \
    < <space>/build/<id>-<lane>/prompt.md \
    > <space>/build/<id>-<lane>/run.jsonl 2>&1 )
```

`acceptEdits` auto-approves file writes; listing `Bash` in `--allowedTools`
auto-approves shell commands so the run never blocks on a prompt; any tool *not*
on the allow list is denied rather than prompted in `-p` mode (so the builder
can't wander outside its toolset), and the `--disallowedTools` deny rules win
over the allow list (deny always takes precedence) as the runtime first line
against commits. Redirect stderr (`2>&1`) into the run-log so a dispatch error
lands somewhere instead of vanishing.

### Integration (judging session — after per-lane post-flight passes)

This block runs in the judging session, not the dispatch session — the dispatch
session's job ends when builders finish (see SKILL.md §5–6). You decide which
lanes pass; the CLI does the git mechanics. Canonical path:

```bash
architect integrate <iteration> --lanes <passing-set>   # e.g. --lanes lane-a,lane-b
architect gate <iteration>                              # integration smoke (raw output; verdict stays yours)
architect integrate <iteration> --lanes <passing-set> --teardown   # or remove worktrees + lane branches after
architect land                                          # end of project: prints gh pr create --base main --head project/<slug>
```

`architect integrate` commits each named lane on its branch and merges it
`--no-ff` into the repo's stable `project/<slug>` branch (slug of `space.title`,
persistent across all iterations), in order. It **refuses** a lane that left
builder commits or wrote out-of-bounds (the mechanical post-flight checks), and
aborts on a merge conflict. A merge conflict = the lane plan wasn't disjoint = a
spec defect: kill the conflicting lane and re-spec; don't hand-resolve builder
conflicts. It runs **no gates and makes no verdict** — `architect gate` streams
the raw gate output for you to judge. `--teardown` deletes only the per-lane
`lane/<iteration>-<lane>` branches and worktrees; it never deletes the
`project/<slug>` branch.

Under the hood / manual fallback (one lane shown):

```bash
# check out or create the project integration branch:
git -C repos/<repo> checkout project/<slug> 2>/dev/null || \
  git -C repos/<repo> checkout -b project/<slug> <repo-base>
git -C build/<id>-<lane>/wt add -A
git -C build/<id>-<lane>/wt commit -m "lane <lane>: <what>"
git -C repos/<repo> merge --no-ff lane/<iteration>-<lane>
<run the gate commands>          # integration smoke after every merge
architect worktree remove <iteration> <lane>
git -C repos/<repo> branch -d lane/<iteration>-<lane>
# at project end:
architect land                   # prints gh pr create --base main --head project/<slug>
```

### Parallel + fast-follow

Use when an iteration is near-disjoint — all but a thin shared seam (a
registration line, an index entry, a shared require). Route the seam into a
dedicated fast-follow lane; the parallel lanes stay genuinely disjoint and
integrate without conflict.

**Recipe:**

1. **Spec the seam out of the parallel lanes.** Assign the seam file(s) to the
   fast-follow lane's `--touch` set and exclude them from every parallel lane's
   touch-set — so the parallel set is disjoint by construction.

2. **Create worktrees and dispatch the parallel lanes** (off the repo base):
   ```bash
   architect worktree add <repo> <iteration> lane-a
   architect worktree add <repo> <iteration> lane-b
   architect dispatch <iteration> lane-a   # own background Bash call each
   architect dispatch <iteration> lane-b
   ```

3. **Judging session — integrate the parallel set.** `project/<slug>` advances
   to their merged tip:
   ```bash
   architect integrate <iteration> --lanes lane-a,lane-b
   architect gate <iteration>
   ```

4. **Create the fast-follow lane off the integrated tip.** `--base` accepts any
   git ref — passing `project/<slug>` roots the new worktree at the merged tip
   (the keystone move):
   ```bash
   architect worktree add <repo> <iteration> ff --base project/<slug>
   architect dispatch <iteration> ff
   ```

5. **Judging session — integrate the fast-follow lane.** Because it descends
   directly from `project/<slug>`, the `--no-ff` merge appends cleanly with no
   conflicts:
   ```bash
   architect integrate <iteration> --lanes ff
   architect gate <iteration>
   ```

**Invariant:** the parallel lanes must stay disjoint — a conflict among them is
still a disjointness defect (kill and re-spec; never hand-resolve). The
fast-follow lane is the sanctioned home for the seam and never conflicts because
it is a descendant of the integrated tip.

### Serial deferred judgment

Use when several iterations (or serial same-file lanes within one iteration)
should run to gates-green without a judging session between each — batching cold
AC judgment into one later session.

**Recipe:**

Per iteration, freeze and dispatch as normal. In a fresh judging session, run
post-flight, integrate, and gate — but **withhold `architect verdict`**:

```bash
# judging session (per iteration) — stop before verdict:
architect integrate <iteration> --lanes <passing-set>
architect gate <iteration>
# do NOT run: architect verdict <iteration> continue|kill
```

Each integrated-but-unjudged iteration surfaces as `awaiting-verdict` in
`architect status`:

```bash
architect status
# II   Iteration          …  Verdict
# 03   some-feature       …  awaiting-verdict
# 04   another-feature    …  awaiting-verdict
```

One later batch judging session evaluates all `awaiting-verdict` iterations,
oldest-first. For each: read its own frozen AC from its freeze commit, run its
gates cold, and record the verdict:

```bash
architect gate <iteration>               # run the frozen gates cold
architect verdict <iteration> continue   # or: kill
```

**§1 preserved:** each verdict is cold and fresh-session — the batch judging
session did not dispatch any of these iterations, so the §1
fresh-session-judgment rule holds for every verdict in the batch.

**Deliberate risk:** iteration N+1 integrated on top of N's not-yet-judged work
rests on a foundation that a later KILL at N would revert. Accept this coupling
only consciously, and always judge oldest-first so a KILL stops you before you
compound it.

## Operating guidance

- Background each lane as its own harness task and let the **per-lane
  completion notification** bring you back (long runs — 30–60 minutes — are normal); read
  `build/<id>-<lane>/run.jsonl` and the repo state afterwards. Do not write a
  blocking `while pgrep …; sleep` wait loop as a Bash command — that is itself
  a launcher that ties up a turn. When you return to a lane, check liveness via
  run-log growth (the stall rules below still apply unchanged).
- Pin the model explicitly. The tool does this automatically (`--model
  <builder-model>`). A floating alias (a bare "latest"/tier tag) drifts to
  whatever ships next — fine interactively, but automations pin the full id so a
  model bump can't silently change builder behavior mid-project.
- Effort = thinking budget. Claude Code has no per-invocation effort flag the
  way Codex exposed `model_reasoning_effort`; the builder sets thinking depth
  **in the block** via the escalation keywords (`think` < `think hard` <
  `think harder` < `ultrathink`), or you floor it with the `MAX_THINKING_TOKENS`
  env var on the dispatch. Default unattended builder work to a high budget
  (open the block with "Think harder…"); downgrade a routine,
  tightly-specified lane to "think hard" (record which and why in the spec).
- **Builders never commit, and the architect verifies it.** Claude Code has no
  sandbox to make `.git` read-only, so this is enforced by the deny rules at
  dispatch *and* checked after the run: before integrating a lane, confirm
  `git -C build/<id>-<lane>/wt log <repo-base>..` is empty and
  `git -C build/<id>-<lane>/wt status` shows only files inside the lane's
  declared set. A commit or an out-of-bounds write fails the lane — reset and
  re-dispatch (lanes are cheap, hard rule 7).
- Same-iteration follow-up (e.g. answering PHASE 0 disagreements after the
  human rules): from the lane's worktree, `claude -p --continue "<rulings +
  proceed>"` resumes that worktree's most recent session with full context —
  sessions are scoped per directory, so `--continue` (`-c`) is deterministic
  even with parallel lanes. (Alternatively pin `--session-id <uuid>` at
  dispatch and resume with `--resume <uuid>`.) Resume the **same way you
  dispatch** — one background Bash tool call per lane, each a single blocking
  `claude -p --continue …`, never a `&` loop (a `&` launcher orphans the
  resumed lanes exactly as it does fresh ones). Never resume across iterations —
  every iteration gets a fresh context.
- Capability-gap review gate (high-stakes iterations): the architect outranks the
  builder, so the architect reading the diff is already a stronger-model,
  fresh-context pass over it. How independent that read is depends on the pairing
  — a same-lab architect/builder shares the builder's blind spots (the frozen
  gates stay the independent check), a cross-vendor pairing is more independent
  (see `docs/DESIGN.md` §1/R3). For an extra adversarial pass, pipe the
  instruction + diff to a fresh read-only reviewer:
  ```bash
  { echo "Review this diff against the spec. Flag ONLY correctness/requirement/invariant gaps with file:line evidence. No style."; \
    git -C <repo-root> diff <base>...HEAD; } \
  | claude -p --model <builder-model> --allowedTools 'Read,Grep,Glob'
  ```
- `build/` is already gitignored by the space, so no extra `.gitignore` entry
  is needed. Scratch never reaches the space repo; only `architecture/` is
  committed.

## Stall detection and rescue

A dispatched run is STALLED when its `run.jsonl`
(`build/<id>-<lane>/run.jsonl`) has not grown for 15+ minutes AND the last
event is an in-flight `Bash` tool call (a `tool_use` for `Bash` with no
matching `tool_result` yet). Silent gaps between events are normal model
thinking; a shell command that should take seconds sitting in flight for 15+
minutes is not.

Diagnose before killing: find the command's child under the `claude` PID
(claude → shell → child). Hot-spinning (high CPU) or blocked (zero CPU and none
of its expected side effects on disk) — hung either way.

Kill the NARROWEST thing: the stuck child process, not the `claude` run. The
command returns a failure to the builder, which adapts with its full context
intact. Kill the whole run only when the builder re-enters the same hang or the
worktree is broken; then discard the lane and re-dispatch (hard rule 7).

Claude Code runs the `Bash` tool directly with no sandbox, so the Codex-era
sandbox-specific hang sources don't apply — but long-running and interactive
commands still hang an unattended run. Spec consequence: give every potentially
long command an explicit timeout in the lane-prompt (the `Bash` tool also takes
a per-call timeout), cap the run with `--max-turns` as a loop backstop, steer
builders toward the repo's existing test fixtures over hand-rolled long-running
harnesses, and when a gate needs a runtime that can't run unattended
(interactive prompts, servers without a timeout), have the builder record the
exact failure as a disagreement/blocker and verify what it can — gate verdicts
are architect-run anyway (hard rule 4). Write the gate file anticipating this.

## Manual alternative (human-driven)

Paste the lane-prompt into an interactive `claude` session (no `-p`). Claude
Code's agent loop runs plan→act→test against the block's stopping condition
while you watch and steer — approve tools as they come, or set `/permissions`
first. Use when the human wants to babysit a run.

## Lane-prompt template

```
Execute the architect spec below. Operating rules:

PHASE 0 — Before any code: reply with your plan and EVERY disagreement you have
with this spec, with reasons, citing real files in this repo. Silent compliance
is a failure. Silent scope additions are a failure. If you have no
disagreements, state what you checked before concluding the spec is sound.
Verify the named APIs/formats/versions against the live dependencies before
planning around them.

PHASE 1 — Treat the shared contracts (schemas/interfaces) named in the spec,
and the repo's existing public interfaces, as FROZEN: do not change them —
other lanes depend on them. You have no access to the space's architecture/
directory; the architect owns it. The ACCEPTANCE CRITERIA below are frozen —
verify your work against them; never weaken or work around them.

PHASE 2 — Build YOUR LANE ONLY: exactly the files listed in BOUNDARIES. You
are one of several parallel lane agents working in isolated worktrees; files
outside your lane belong to other agents — touching them fails your lane.
No placeholder implementations — search the codebase before implementing;
full implementations only. Write IDIOMATIC, house-consistent code: read the
neighbouring code and match its conventions (naming, guards, predicates,
error/persistence idioms, the language's expressive collection/enumerable
forms); well-factored and DRY-ish; terse but clear; pragmatic, not clever — the
smallest change that does the job, no abstraction it doesn't need. Consistency
with the surrounding code is part of correctness here: a change that works but
fights the house style (or introduces an inconsistency a careful reader of this
repo would never write) is not done. Tests stay simple and terse, exercising
public behavior, no mock/stub of the class under test. Verify your work by
running the acceptance criteria's gate commands and record the verbatim output. Do NOT commit and do NOT run any
git write command (commit/add/branch/reset/checkout) — the architect commits
and merges after verification, and verifies you made no commits. Do NOT delete
lock files or escalate privileges if a command fails; record the exact error
and continue. Give every potentially long command an explicit timeout; if a
runtime will not start unattended (interactive prompt, server with no timeout),
record the exact failure in your report and route around it — never busy-wait
or retry in a loop. When done, write your report to the scratch file given to
you, build/<id>-<lane>/report.md (an absolute path outside your worktree),
with RAW results only — tables, numbers, command output — no interpretation, no
"promising". Every status claim must be backed by a command result from this
run. Keep the report compact — tables and numbers, not prose. End it with
exactly one status line: STATUS: COMPLETE | COMPLETE_WITH_CONCERNS (list them)
| BLOCKED (exact blocker + what you tried). Verdicts belong to the architect
and the human. Persist until your lane is fully handled end-to-end; do not stop
at analysis or partial fixes.

=== OBJECTIVE (and why) ===
...

=== OUTPUT FORMAT ===
...

=== TOOL GUIDANCE (verification commands; verify-against-reality list) ===
...

=== BOUNDARIES (may touch / must not touch / out of scope) ===
...

=== DISAGREEMENT RULINGS (from last session) ===
...

=== ACCEPTANCE CRITERIA (frozen — the architect re-runs these to judge; verify
against them, do not edit or work around) ===
...
```

## Builder-side standing setup (one time per machine/repo)

- The builder is the same `claude` binary as the architect (reference harness),
  running a cheaper model — nothing extra to install. `architect dispatch` pins
  the model per dispatch (`--model <builder-model>`); a `~/.claude/settings.json`
  `"model"` default is fine interactively, but automations pin it explicitly so a
  default can't silently swap the builder.
- Repo `CLAUDE.md` is the builder's standing context — Claude Code loads it
  root-down automatically. Put exact build/test commands and repo gotchas there;
  the loop's PHASE rules stay in the dispatch block so they version with the
  skill. (Claude Code does **not** auto-read `AGENTS.md`; if the repo keeps its
  build/test docs there, add `@AGENTS.md` to `CLAUDE.md` to pull it in.)
- The builder is a bare `claude -p` over the block — it is not invoking the
  `/architect` skills, the block is its entire instruction set. (`--bare` would
  give a leaner builder context but also drops `CLAUDE.md`/skills/hooks — keep
  `CLAUDE.md`, so skip `--bare` unless the repo has no standing build/test doc.)
- Billing: headless `claude -p` draws on the Agent SDK credit pool on your
  Claude plan (separate from interactive usage limits since June 15 2026).
  There's no per-window quota that dies mid-run the way a chat session can, but
  a long parallel fan-out does spend that pool. The architect runs as your
  interactive Claude Code session.
