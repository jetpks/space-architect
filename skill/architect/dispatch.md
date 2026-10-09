# Builder dispatch reference

Verified against `pi` 1.1.0 (badlogic/pi-mono) headless print mode — the reference
harness. The builder is `pi -p` (`--print`, the non-interactive mode) pinned to
the configured builder model (`<builder-model>`) — a cheaper model run headless
via the same harness the architect uses. Key facts the skill encodes: lane-prompts
go in on **stdin** (piped stdin is prepended to the message, and a big quoted
lane-prompt as a shell argument gets mangled); the model is pinned with
`--model <builder-model>` (a floating alias drifts to whatever ships next — pin
the full id); there is **no working-dir flag**, so per-lane dispatch `cd`s into
the worktree; there is **no tool allow/deny flag surface and no turn cap** — tool
control is the injected **builder guard** extension (`-e`), hermeticity comes from
`--no-approve` (project-trust pinned to untrusted: the lane's `.pi/` project
resources never load; `AGENTS.md`/`CLAUDE.md` context files still load; explicit
`-e` paths still load), and the run's bound is the dispatch wall-clock timeout
(TERM → grace → KILL); web access comes from the web tools loaded by the pi
extensions configured in `~/.pi/agent` (no per-dispatch setup).

**The one load-bearing difference from the Codex design:** Codex's
`--sandbox workspace-write` made `.git` physically read-only. pi has
**no filesystem sandbox**, so `.git` is not hardware-protected. "Builders never
commit" (hard rule 7) is enforced in three layers, weakest to strongest:
(1) a runtime first line — the **builder guard** extension denies git-write
commands (and `bash`-unparseable commands) before evaluation (see `### The
builder guard` below); (2) worktree isolation between
lanes; (3) the authoritative check — an architect post-flight
`git -C <worktree> log <repo-base>..` that must be empty. The guard's deny is
not airtight (a builder can shell out — `sh -c 'git commit …'` — past the
parse), so the post-flight `git log` is what the loop actually trusts.
If a lane committed, treat the worktree as tampered: reset and re-dispatch.

**Preflight (once per environment):** run `pi --version`, and confirm the
builder model resolves with a one-message probe
(`echo ok | pi -p --model <builder-model>`). No API-key/env ceremony — provider
config (e.g. the Fireworks key) resolves from `~/.pi/agent`; pi needs no
`ANTHROPIC_*` env. Past that one-time check, no dispatch needs a manual
start-check: every foreground dispatch self-verifies. Shortly after launch it
prints a liveness line to stderr naming the streamed model and confirming the
run log is growing — or a WARN line instead when the streamed model disagrees
with the pinned `<builder-model>` or the log isn't growing. (Liveness source:
the run log is pi's JSONL event stream — ~20 event types, `session` →
`agent_start`/`turn_start` → `message_*`/`tool_execution_*` →
`turn_end`/`agent_end`/`agent_settled`; the line is parsed from the first
assistant-role event carrying a `model` field.)

## Canonical dispatch — `architect dispatch <iteration> <lane>`

The canonical path is `architect dispatch <iteration> <lane> --prompt <file>`.
The tool copies your prompt file to `build/<id>-<lane>/prompt.md` (the CLI owns
that canonical path — you never write it directly), copies the vendored
builder-guard to `build/<id>-<lane>/builder-guard.ts`, assembles the canonical
`pi -p` argv, pins the builder model (the lane's
configured model or the CLI's reference default; see `docs/DESIGN.md` §4),
feeds the copied lane prompt to the builder on stdin, and streams
pi's `--mode json` event stream to
`build/<id>-<lane>/run.jsonl`. Run each lane as its own **background Bash tool
call** (`run_in_background`) so your turn doesn't block for the full run (30–60
minutes is typical).

Author the lane's prompt in a **fresh timestamped scratch file**
(`tmp/prompts/<id>-<lane>-<hhmmss>.md` — never a pre-existing canonical path,
which trips your harness's read-before-write guard; never a shell argument —
shells mangle quotes), then hand it to dispatch:

```bash
# single-lane iteration — run from the space root; dispatch copies the prompt to
# build/<id>-<lane>/prompt.md and runs in the lane's provisioned worktree
# (materialized on demand from the frozen declaration)
architect dispatch <iteration> <lane> --prompt tmp/prompts/<id>-<lane>-<hhmmss>.md
```

For multi-lane iterations, materialize every declared lane in one shot with
`architect provision`, then dispatch each lane from its worktree:

```bash
architect provision <iteration>          # all declared lanes: worktree + lane/<id>-<lane> branch
architect dispatch <iteration> lane-a --prompt <lane-a scratch file>   # own background Bash call each
architect dispatch <iteration> lane-b --prompt <lane-b scratch file>
```

`architect provision` reads the frozen lane declarations from `space.yaml` and,
per lane, creates `build/<id>-<lane>/wt` off the resolved base (`--base`
override, else `project/<slug>` when it exists, else the repo's default branch —
a repo commit, distinct from the freeze, which is a space commit), adds it with a
`lane/<iteration>-<lane>` branch, and records it in `space.yaml`. It is
idempotent (`--lane <name>` provisions a single lane), and wraps the
`architect worktree add` primitive — still registered for edge cases, not a step
in the flow. `dispatch`, `integrate`, and `gate` also lazily materialize a lane
whose worktree is missing from its frozen declaration, so the flow can't
dead-end on a missing worktree.

Issue each dispatch as its **own background Bash tool call** — one call per
lane. Never use a shell `&` loop. A `for … & done` launcher is a *launcher*
process: it returns the instant it has spawned the lane children, the harness
reaps those now-orphaned `pi` processes, and every lane dies at once with no
`result` — partial diffs, no reports (this exact failure has happened: three
lanes killed at the same second, zero output). One blocking dispatch per
background Bash tool keeps each lane attached to a harness-tracked task that
survives the full run and reports completion per lane.

### What the tool runs under the hood

`architect dispatch` is equivalent to this — documented here for transparency
and as the manual fallback:

```bash
# dispatch --prompt copies the scratch prompt to build/<id>-<lane>/prompt.md and
# the vendored guard to build/<id>-<lane>/builder-guard.ts; the manual equivalent
# is those copies followed by:
( cd build/<id>-<lane>/wt && \
  pi -p --mode json \
    --model <builder-model> \
    --session-dir <space>/build/<id>-<lane> \
    --no-approve \
    -e <space>/build/<id>-<lane>/builder-guard.ts \
    [--thinking <level>] \
    < <space>/build/<id>-<lane>/prompt.md \
    > <space>/build/<id>-<lane>/run.jsonl 2>&1 )
```

`--no-approve` pins project-trust to untrusted for the run — a **hermetic
builder**: the lane's `.pi/` project resources (settings, extensions, skills,
prompts, themes, SYSTEM.md) never load, while `AGENTS.md`/`CLAUDE.md` context
files still load root-down and the explicit `-e` guard always loads — the guard
cannot be shrunk by project-local config. `--session-dir` points pi's session
storage and lookup at the lane's build dir, which is what makes `--continue`
follow-ups (below) deterministic per lane. Redirect stderr (`2>&1`) into the
run-log so a dispatch error lands somewhere instead of vanishing.

### The builder guard — what a builder sees on a deny

The guard is a pi extension (`lib/space_architect/pi/builder-guard.ts` in the
space-architect repo, copied into the lane's build dir and injected via `-e`).
Its `tool_call` handler intercepts every `bash` call **before evaluation** and
blocks two classes, returning the deny reason as the bash tool result text —
that reason is the builder's only feedback, so it says what to do instead:

- **Git write operations** — `commit`, `push`, `pull`, `reset`, `merge`,
  `rebase`, `checkout`, `switch`, `branch`, `tag`, and the rest of git's write
  verbs — denied because the architect CLI owns all commits (hard rule 7). The
  deny text surfaces as `architect builder guard: …` in the tool result. The
  parse walks each command segment past git's flags (`git -C <path> commit` is
  still a deny), and reads like `git log --grep=commit` pass — the guard
  classifies the subcommand, it never substring-matches the raw command.
- **`bash`-unparseable commands** — the guard runs `bash -n` and blocks on a
  parse error (unterminated quote, missing `;` before `then`), with bash's
  stderr in the reason. The parse-check is parse-level only: an unclosed `[`
  (`[ -f /etc/hosts` with no `]`) is a *runtime* `test` failure, syntactically
  valid — not the guard's domain.

The guard is a first line, not a sandbox — the post-flight `git log` check
(Operating guidance below) stays the authoritative no-commits proof.

### Integration (judging session — after per-lane post-flight passes)

This block runs in the judging session, not the dispatch session — the dispatch
session's job ends when builders finish (see SKILL.md §5–6). You decide which
lanes pass; the CLI does the git mechanics. Canonical path:

```bash
architect integrate <iteration> --lanes <passing-set>   # e.g. --lanes lane-a,lane-b
architect gate <iteration>                              # integration smoke (raw output; verdict stays yours)
architect integrate <iteration> --lanes <passing-set> --teardown   # or remove worktrees + lane branches after
# end of project: landing is the architect's, not a CLI command — write the PR
# body to a fresh build/land/<repo>-pr-body-<yyyymmdd-hhmm>.md yourself, then
# present the paste-and-run block (cd, git push -u origin project/<slug>,
# gh pr create) — see SKILL.md §6
```

`architect integrate` commits each named lane on its branch and merges it
`--no-ff` into the repo's stable `project/<slug>` branch (slug of `space.title`,
persistent across all iterations), in order. Pass `-m`/`--message-from` — the
lane commit lands in the repo's PR history, so say what the lane did and why,
not just that it integrated. It **refuses** a lane that left
builder commits or wrote out-of-bounds (the mechanical post-flight checks), and
aborts on a merge conflict. A merge conflict = the lane plan wasn't disjoint = a
spec defect: kill the conflicting lane and re-spec; don't hand-resolve builder
conflicts. It runs **no gates and makes no verdict** — `architect gate` streams
the raw gate output for you to judge. `--teardown` deletes only the per-lane
`lane/<iteration>-<lane>` branches and worktrees; it never deletes the
`project/<slug>` branch. Every destructive lane operation — `worktree remove`,
`integrate --teardown`, and the re-point path of `provision --base` — refuses
per lane when that lane's worktree still holds uncommitted work, untracked
files included, because that's what a dispatched lane always holds; `--force`
overrides and discards it. The `--lanes <passing-set>` integration path itself
is unaffected — `integrate` commits each lane's work before tearing it down.

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
# at project end there is no CLI step: the architect writes a fresh
# build/land/<repo>-pr-body-<yyyymmdd-hhmm>.md and presents the push +
# gh pr create block
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

2. **Provision and dispatch the parallel lanes** (off the repo base). Provision
   only the parallel lanes by name — leave the fast-follow lane unmaterialized
   until step 4, so it can root at the integrated tip:
   ```bash
   architect provision <iteration> --lane lane-a
   architect provision <iteration> --lane lane-b
   architect dispatch <iteration> lane-a   # own background Bash call each
   architect dispatch <iteration> lane-b
   ```

3. **Judging session — integrate the parallel set.** `project/<slug>` advances
   to their merged tip:
   ```bash
   architect integrate <iteration> --lanes lane-a,lane-b
   architect gate <iteration>
   ```

4. **Provision the fast-follow lane off the integrated tip.** `--base` accepts
   any git ref — passing `project/<slug>` roots the new worktree at the merged
   tip (the keystone move); `--lane ff` provisions just that lane:
   ```bash
   architect provision <iteration> --lane ff --base project/<slug>
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

Per iteration, rehearse, freeze, and dispatch as normal. In a fresh judging session, run
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

### Long-running sweep (detached, two-phase)

Use when a lane's own work *is* a long-running detached process — a 30–70
minute sweep, migration, or batch run the lane must launch, let run
unattended, and then audit once it exits. A metered builder session paying
tokens to sit in a poll loop is the wrong instrument for that wait: split the
lane across two builder sessions instead, one before the process runs and one
after.

**Recipe:**

1. **Phase A — launch, prove liveness, stop deliberately.** The lane-prompt's
   PHASE 2 tells the builder to launch the process detached (backgrounded and
   redirected to a log file, survives the builder's own process exit), capture
   its pid, prove it's alive with one command result (e.g. `ps -p <pid>` plus a
   growing log tail — not an assertion), pre-structure the report with the
   sections phase B will fill in, and end the session there — not mid-poll —
   at:
   ```
   STATUS: SWEEP_RUNNING (pid <pid>, run dir <path>)
   ```
   `SWEEP_RUNNING` is the fixed token spec authors and architects grep for;
   the pid and run dir ride in the same line because nothing else in the loop
   captures them.

2. **The wait belongs to the architect's harness, not the builder session.**
   Between phase A and B, a process-exit monitor on the architect's side —
   notification-driven, not a poll loop — watches for the pid to exit. A
   builder session spends tokens to sit idle in a wait; the harness doesn't.
   Do not dispatch a phase-B session, or resume one, until the process has
   actually exited.

3. **Phase B — resume and audit.** Once the process has exited, resume the
   same lane worktree with `--continue` — the one sanctioned use of
   `--continue` beyond same-lane follow-ups (see `## Operating guidance`
   below) — and hand it the post-run audit as the new instruction:
   ```bash
   ( cd build/<id>-<lane>/wt && \
     echo "The sweep at <run dir> (pid <pid>) has exited. Audit its output
   against the spec's acceptance criteria, finish the report you
   pre-structured in phase A, and end at STATUS: COMPLETE." \
     | pi -p --continue --session-dir <space>/build/<id>-<lane> \
       --mode json --model <builder-model> \
       --no-approve \
       -e <space>/build/<id>-<lane>/builder-guard.ts \
       > build/<id>-<lane>/run-b.jsonl 2>&1 )
   ```
   (`--mode json` because the audit run gets its own run log — `run-b.jsonl`
   stays a pi JSONL event stream like the first. Piped stdin is prepended to
   the resumed message, same as a fresh dispatch.)
   Phase B runs the post-run audits the spec asked for, then finishes the
   report at `STATUS: COMPLETE` (or `COMPLETE_WITH_CONCERNS`/`BLOCKED`, per the
   template) exactly as any other lane would.

**Invariant:** phase A never ends mid-poll or at a pending status of its own
invention — it ends at `SWEEP_RUNNING` with the pid and run dir recorded, or
it's indistinguishable from a lane that gave up. Spec authors: an in-lane
"poll until it finishes" / "never end the session while it runs" instruction
loses to the template's no-busy-wait clause below every time a builder holds
both — write this two-phase shape into the lane spec instead of a poll
instruction.

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
- Effort = thinking budget. Set it per dispatch: `architect dispatch --effort
  <level>` (aliases `--thinking`/`--reasoning`) accepts
  `off`/`minimal`/`low`/`medium`/`high`/`xhigh`/`max`, normalizes to that
  canonical set, and pi accepts the full set unchanged (`--thinking <level>`) —
  no harness-side clamping; each model's `thinkingLevelMap` in
  `~/.pi/agent/models.json` clamps further per model (e.g. a model whose map
  sends `off`/`minimal` to a higher floor). The escalation keywords (`think` <
  `think hard` < `think harder` < `ultrathink`) still raise depth from inside
  the block. Default unattended builder work to a high budget; downgrade
  a routine, tightly-specified lane (record which and why in the spec).
- **Builders never commit, and the architect verifies it.** pi has no sandbox
  to make `.git` read-only, so the injected guard denies git-write commands at
  dispatch (see `### The builder guard` above) *and* it is checked after the
  run: before integrating a lane, confirm
  `git -C build/<id>-<lane>/wt log <repo-base>..` is empty and
  `git -C build/<id>-<lane>/wt status` shows only files inside the lane's
  declared set. A commit or an out-of-bounds write fails the lane — reset and
  re-dispatch (lanes are cheap, hard rule 7).
- Same-iteration follow-up (e.g. answering PHASE 0 disagreements after the
  human rules): from the lane's worktree, `pi -p --continue --session-dir
  <space>/build/<id>-<lane> "<rulings + proceed>"` resumes the lane's most
  recent session in that session dir with full context — `-c` continues that
  most recent session, so follow-ups are deterministic even with parallel
  lanes. Resume the **same way you dispatch** — one background Bash tool call
  per lane, each a single blocking `pi -p --continue …`, never a `&` loop (a
  `&` launcher orphans the resumed lanes exactly as it does fresh ones). Add
  `--mode json` and redirect when you want the resumed run logged like a fresh
  dispatch. Never resume across iterations — every iteration gets a fresh
  context.
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
  | pi -p --model <builder-model> --tools read,grep,find,ls
  ```
- `build/` is already gitignored by the space, so no extra `.gitignore` entry
  is needed. Scratch never reaches the space repo; only `architecture/` is
  committed.

## Stall detection and rescue

A dispatched run is STALLED when its `run.jsonl`
(`build/<id>-<lane>/run.jsonl`) has not grown for 15+ minutes AND the last
event is an in-flight `bash` tool call (a `tool_execution_start` for `bash`
with no matching `tool_execution_end` yet). Silent gaps between events are
normal model thinking; a shell command that should take seconds sitting in
flight for 15+ minutes is not.

Diagnose before killing: find the command's child under the `pi` PID
(pi → shell → child). Hot-spinning (high CPU) or blocked (zero CPU and none
of its expected side effects on disk) — hung either way.

Kill the NARROWEST thing: the stuck child process, not the `pi` run. The
command returns a failure to the builder, which adapts with its full context
intact. Kill the whole run only when the builder re-enters the same hang or the
worktree is broken; then discard the lane and re-dispatch (hard rule 7).

pi runs the `bash` tool directly with no sandbox, so the Codex-era
sandbox-specific hang sources don't apply — but long-running and interactive
commands still hang an unattended run, and pi has no turn cap (there is no
`--max-turns` flag), so the dispatch's wall-clock timeout (TERM → grace →
KILL) is the run's bound, not a turn budget. Spec consequence: give every
potentially long command an explicit timeout in the lane-prompt, steer
builders toward the repo's existing test fixtures over hand-rolled long-running
harnesses, and when a gate needs a runtime that can't run unattended
(interactive prompts, servers without a timeout), have the builder record the
exact failure as a disagreement/blocker and verify what it can — gate verdicts
are architect-run anyway (hard rule 4). Write the gate file anticipating this —
`architect rehearse` runs the drafted gates pre-freeze, so an unattended-hostile
gate surfaces as **BROKEN** while still editable (advisory: a correct RED can
look broken).

## Manual alternative (human-driven)

Paste the lane-prompt into an interactive `pi` session (no `-p`). pi's agent
loop runs plan→act→test against the block's stopping condition while you watch
and steer. Use when the human wants to babysit a run.

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
verify your work against them; never weaken or work around them. If an AC's
letter can only be satisfied by making the artifact worse than the property the
AC asserts, build the right thing and raise the conflict in your report — name
the AC, the conflict, and the evidence. This is not permission to skip work or
weaken a criterion: the conflict is reported, never silently resolved.

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
and continue. Do NOT use `run_in_background` (or shell `&`) for your own work —
this process terminates when you end your turn and reaps its own children, so
backgrounded work is SIGTERMed and its output lost while the run still exits
0; run long commands serially in the foreground instead. Give every
potentially long command an explicit timeout; if a
runtime will not start unattended (interactive prompt, server with no timeout),
record the exact failure in your report and route around it — never busy-wait
or retry in a loop. The one sanctioned exception is a deliberate wait on a
detached process this lane itself launched: end that phase at
`STATUS: SWEEP_RUNNING` (pid + run dir) per `### Long-running sweep` in
dispatch.md, instead of polling for it to finish — this clause still forbids
retry loops and sitting on an unattended runtime with no timeout. When done, write your report to the scratch file given to
you, build/<id>-<lane>/report.md (an absolute path outside your worktree),
with RAW results only — tables, numbers, command output — no interpretation, no
"promising". Every status claim must be backed by a command result from this
run. Keep the report compact — tables and numbers, not prose. Do not title the
report — the architect's tooling supplies the `### <lane>` heading when it
transcribes; keep any headings inside the report at `###` or deeper. End it with
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

- The builder is the same `pi` binary as the architect (reference harness),
  running a cheaper model — nothing extra to install. `architect dispatch` pins
  the model per dispatch (`--model <builder-model>`); a default model in
  `~/.pi/agent` config is fine interactively, but automations pin it explicitly
  so a default can't silently swap the builder.
- Repo `AGENTS.md`/`CLAUDE.md` are the builder's standing context — pi loads
  them root-down automatically (`--no-approve` does not gate them). Put exact
  build/test commands and repo gotchas there; the loop's PHASE rules stay in
  the dispatch block so they version with the skill.
- The builder is a bare `pi -p` over the block — it is not invoking the
  `/architect` skills, the block is its entire instruction set.
- Billing: the builder draws on the provider account configured in
  `~/.pi/agent` (per-token API usage — e.g. the Fireworks key). There's no
  per-window quota that dies mid-run the way a chat session can, but a long
  parallel fan-out does spend that account. The architect runs as your
  interactive session.
