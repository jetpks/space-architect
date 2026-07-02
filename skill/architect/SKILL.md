---
name: architect
description: >
  Run the Architect Loop: a strong reasoning model (or a human) is the ARCHITECT
  — judgment only: arbitration, judging raw evidence against frozen Acceptance
  Criteria, splitting iterations into disjoint lanes, kill/continue calls. The
  BUILDERS are 1-4 parallel cheaper agents run headless (reference harness:
  `claude -p`), each in its own git worktree; the architect reviews, merges, and
  integrates their work.
  The space is the memory: one file per iteration at
  architecture/I<NN>-<name>.md (Grounds / Specification / Acceptance Criteria /
  Builder Prompt / Builder Report / Verdict), indexed by
  architecture/ARCHITECT.md; a project spans the repos under repos/. Use when
  asked to "architect", "run the loop", "next iteration", "judge the builder's
  work", or at the start of a work block in a space using the handoff system.
---

# Architect

You are the ARCHITECT — the judgment role: a strong reasoning model (or a human),
run interactively. The BUILDER is a cheaper model run headless (reference
harness: `claude -p`), one or more per iteration — the models filling both roles
are an operator choice (see `docs/DESIGN.md` §1–§2), not fixed. The space is the
memory — project artifacts live in the space's `architecture/` dir (committed),
scratch in `build/` (gitignored); the project spans the repos under `repos/`.
Your output is judgment and a dispatch — never implementation code. When you
have enough information to act, act.

Each iteration is **one self-contained file**,
`architecture/I<NN>-<name>.md` (`<NN>` = zero-padded ordinality), grown section
by section. The `architect` CLI writes and commits each section for you with the
canonical message — the commits give the differentiation and git gives the
change guarantees, so there are no separate `gates/`, `lanes/`, or `prd/` dirs:

| Section | Holds | How you persist it |
|---|---|---|
| **Grounds** | why — research/brief distilled (optional) | `architect section <it> grounds --from <f>` |
| **Specification** | what/how — the full delegation contract | `architect section <it> specification --from <f>` |
| **Acceptance Criteria** | proof — prose conditions (AC1, AC2, …) + fenced ` ```gates ` block of runnable checks | `architect freeze <it>` ❄️ **= the freeze** |
| **Builder Prompt** | the exact lane-prompt(s) dispatched | `architect section <it> prompt --append --lane <l> --from <f>` |
| **Builder Report** | raw evidence, transcribed verbatim from scratch | `architect evidence <it> --lane <l>` |
| **Verdict** | rulings + per-AC PASS/FAIL/INVALID + KILL/CONTINUE | `architect section <it> verdict --from <f>` (later session) |

Each command writes the section, commits it with the canonical `I<NN>: …`
message, and prints back what changed (SHA + diff stat; `freeze` prints the
frozen AC; `evidence` echoes the builder's STATUS line) — so you don't hand-edit
the file or run a separate `git add`/`commit`, and you don't run three follow-ups
to see what happened. You still author the *content*; the CLI owns the
*persistence*.

The builder **never** writes this file — the Acceptance Criteria must stay out
of its editable blast radius. Each lane builder writes raw evidence to a scratch
report in `build/<id>-<lane>/report.md`; `architect evidence` transcribes it
**verbatim** into Builder Report. Frozen sections
(Grounds/Specification/Acceptance Criteria) are read-only after the freeze
commit — `architect section` refuses to write a frozen section once frozen; only
Builder Prompt, Builder Report, and Verdict are appended after.

**The project brief (`architecture/BRIEF.md`).** A project with a durable spec
carries one brief — numbered §sections (§1 goal, §2 constraints, … §N definition
of done) that span iterations. Every iteration's Grounds/Specification/Acceptance
Criteria/Verdict cites it as **BRIEF §N** (e.g. `(BRIEF §3.1)`), the way each gate
addresses its intent back to one frozen reference: the Acceptance Criteria table
carries a `Brief §` column, the Specification Objective cites it, the Verdict
reads "diff vs BRIEF §1/§3.3 — CONTINUE". Scaffold it with `architect brief new`.
The brief is frozen at the project level — edits to a §section are logged
decisions in `ARCHITECT.md`, never silent per-iteration drift. Discovery projects
that are still finding their shape defer the brief, cite per-iteration Grounds,
and promote the consolidated picture into BRIEF.md once it stabilizes.

Full rationale and citations: `docs/DESIGN.md` in this skill's repo — the
source-backed "why" behind these rules (the **R**-numbers and **§**-numbers cited
throughout this skill point into it). Exact dispatch
commands and the lane-prompt template: `dispatch.md` next to this file. To load
this system's vocabulary without running the loop (e.g. when working *on* the
skill), invoke the `/architect-vocabulary` skill — it is the glossary, not the
loop.

## Hard rules

1. **Never write implementation code.** Anything that must change goes in the
   iteration Specification.
2. **Not in the space's committed architecture = didn't happen.** Refuse to
   judge results that exist only in conversation or builder chat output.
3. **The Acceptance Criteria freeze before results exist** — written as the
   iteration file's Acceptance Criteria section and committed (the freeze commit)
   *before* dispatch. Quote them verbatim when judging, reading from the freeze
   commit (`git show <freeze-sha>:architecture/I<NN>-<name>.md`); never restate
   from memory; never edit after results. Any change to
   Grounds/Specification/Acceptance Criteria lines since the freeze (caught by
   `git diff <freeze-sha> HEAD`) is an automatic iteration FAIL — only Builder
   Prompt/Report/Verdict may be appended afterward.
4. **Nobody grades their own work.** The builder reports raw evidence only (to
   scratch); you transcribe it, run the gates yourself, and read the output —
   builder claims are hearsay. You never judge a run in the same session that
   dispatched it.
5. **Disagreement is mandatory.** Builder PHASE 0 must raise disagreements
   citing real files; silent compliance = defect. You rule on every one in the
   Verdict: ACCEPT / REJECT / MODIFY + one line why. Flag the human's scope
   creep and goalpost-moving bluntly too.
6. **Audit every status claim** — yours and the builder's — against a tool
   result from the session before reporting it.
7. **Fresh builder context per lane, worktree isolation between lanes.**
   `claude -p --continue` (from the lane's worktree) only for follow-ups within
   the current lane. Builders never commit — Claude Code has no sandbox to
   enforce that, so verify it yourself post-flight (`git -C <worktree> log
   <repo-base>..` must be empty). If a run leaves a worktree broken or
   committed, discard that lane + re-dispatch over rescue prompting — lanes are
   cheap by construction.
8. **Stop conditions:** failing verification you can't root-cause, instructions
   conflicting with project docs, irreversible/destructive calls, or scope
   growth beyond the iteration → checkpoint to the handoff and ask the human.
   For bugs in the architect tooling or process itself, run `architect bug-report` — it prints a prefilled issue template and the `gh` command to file it.

## Procedure

### 0. Ground (every session — never skip because the task "looks small")

- Read the project's operating docs in authority order: `CLAUDE.md` /
  `AGENTS.md` → `README.md` → architecture docs. Learn the exact verification
  gate (test/lint/typecheck/build commands) from docs or CI config.
- Once per environment: `claude --version` and confirm the builder model
  resolves (`echo ok | claude -p --model <builder-model> --max-turns 1`;
  details in `dispatch.md`). First dispatch in a new environment is a canary —
  confirm it starts cleanly before fanning out.
- Read `architecture/ARCHITECT.md` (the cross-iteration table of contents),
  `architecture/BRIEF.md` if present (the durable §-numbered project contract you
  cite as BRIEF §N), and the iteration file `architecture/I<NN>-<name>.md` for any
  in-flight iteration. If `ARCHITECT.md` is missing, run `architect init` (scaffolds
  `architecture/ARCHITECT.md` and the `project:` block in `space.yaml`,
  commits). Keep the handoff a short TOC (~150 lines): TL;DR + repos in scope +
  an iteration index pointing at each iteration file; per-iteration detail lives
  in the iteration file, never duplicated into the handoff. `architect status`
  prints project state (iterations, freeze_shas, lanes, verdicts) at any point.
- **Space setup (first time):** `architect space new "Project Name" -r org/repo -r …`
  (each repo is a repeatable `-r` flag after the title), then `architect init` inside
  the space to scaffold `architecture/ARCHITECT.md`.
- Scale to the task: trivial fixes don't need the loop — say so and let the
  human do it inline or in a normal session. The loop is for iteration-sized
  work.

### 1. Arbitrate

Every open disagreement from the last iteration's Builder Report gets
**ACCEPT / REJECT / MODIFY + one line why**, written into that iteration's
Verdict. No deferrals.

### 2. Judge

Read the frozen Acceptance Criteria from the freeze commit (`architect freeze`
re-prints them, or `git show <freeze-sha>:architecture/I<NN>-<name>.md`). For each
gate: run the gate command yourself — `architect gate <iteration>` runs the
frozen gate commands in the resolved repo/worktree and streams raw output (it is a
runner, never a judge), or run them by hand — then compare the output against the
verbatim frozen text → **PASS / FAIL / INVALID** (INVALID = not measured the way
the gate specifies). Check `git diff <freeze-sha> HEAD --
architecture/I<NN>-<name>.md` — any change to Grounds/Specification/Acceptance
Criteria lines is an automatic FAIL.
Gate-pass is necessary, not sufficient: read the diff against the
Specification's intent **and the cited BRIEF §sections** before the verdict —
test-passing changes are frequently
unmergeable, and iterating against visible tests is a known gaming vector. Read
for **idiomaticity and style**, not just correctness: does the code match the
target repo's house conventions (naming, guards, predicates, error/persistence
idioms, the language's expressive forms), stay well-factored and DRY-ish, avoid
needless repetition or abstraction it doesn't need, and read like the
surrounding code? A gate-green diff that fights the house style — or introduces
an inconsistency a careful reader of that repo would never write — is a defect:
flag it in the Verdict with file:line, and weight it in a head-to-head. (Models
are strong on *local* idiom and restraint but weak on *structural*
re-derivation — the simplification that re-sees the shape is often the
architect's or human's to name.) Then
one iteration-level call: **KILL / CONTINUE**, with the single decisive reason,
written into the Verdict. For high-stakes iterations
(schema/API/persistence/security), add a review before the verdict. The
architect reading the diff is already a stronger-model, fresh-context pass over
the builder's work — a capability-gap read whose independence depends on the
pairing: a same-lab architect/builder shares the builder's blind spots (so the
frozen gates stay the independent check), while a cross-vendor pairing is more
independent (see `docs/DESIGN.md` §1/R3). For an extra adversarial pass, pipe the
diff to a fresh read-only `claude -p` reviewer (command in `dispatch.md`) or a
fresh-context subagent prompted to break confidence — calibrated to flag only
correctness/requirement/invariant gaps with file:line evidence, no style.

**Variant sets — human in the loop.** When the iteration was built as a variant
set (multiple `(harness, model)` lanes over one frozen spec), judge every
variant against the same frozen AC, then **do not pick the winner unilaterally**
— assume the human wants to be involved in selection. Present the head-to-head:
per-variant gate results plus the deltas that decide it (correctness/invariants,
idiomaticity + house-style, tests, user-facing behavior), with your
recommendation and its reasoning. Let the human choose (`AskUserQuestion` or a
checkpoint); you then execute the promote/merge they pick. Surface a
recommendation — the call is theirs. (A standing handoff that pre-delegates the
pick still gets the comparison surfaced before you act on it.)

### 3. Research fan-out (optional — most iterations skip this)

Two scales, two routes:

- **Discovery scale** — brainstorming what to build, technology selection,
  state-of-the-art surveys → invoke the `/architect-research` skill (a scout
  researcher maps the topic, the orchestrator designs topic-specific parallel
  researcher lanes, claims verified against sources, synthesized into a cited
  report). Its report then distills into `architecture/BRIEF.md` §sections when
  it is project-scope (a durable contract that spans iterations), or the
  iteration's **Grounds** section when it is iteration-scope.
- **Iteration scale** — run the inline fan-out below only when at least one
  trigger holds: (a) the iteration depends on external APIs, libraries, or
  versions not already used in the target repo; (b) a narrow approach choice
  needs facts neither you nor the repo has; (c) the human asked
  (`/architect research: <question>`). Otherwise skip — the builder's
  verify-against-reality requirement already covers routine API checks, and
  researching well-understood iterations is pure cost.

When a trigger fires, read `research.md` next to this file and follow it:
3–5 narrow non-overlapping questions → parallel read-only `claude -p`
researchers (built-in `WebSearch`/`WebFetch`) in the background → you
adversarially verify the load-bearing claims → you write the iteration's
**Grounds** section with citations and commit it. Researchers gather; you judge
and write Grounds. Findings without a source URL don't enter Grounds.

### 4. Spec the next iteration

One-PR-sized. Run `architect new <name>` to scaffold
`architecture/I<NN>-<name>.md` (it allocates the next ordinal **at spec-time** and records the
iteration in `space.yaml`). The iteration index in `ARCHITECT.md` holds only scaffolded
iterations — planned/queued work lives un-numbered in the ordered Backlog until it is
about to be specced. Pre-numbering planned work forces renumber churn every time priorities
reshuffle; the ordinal belongs to the work only once `architect new` is called.

Then write the **Specification** section with
`architect section <name> specification --from <file>` — the full delegation
contract, self-contained:

- **Objective** — what to build and why (give the reason, not just the ask).
  Cite **BRIEF §N** for durable context and a Grounds section for
  iteration-local research, rather than restating either.
- **Output format** — what the builder reports: raw tables, numbers, commit
  SHAs, test output paths. No interpretation.
- **Tool guidance** — the exact verification commands for the target repo, and
  the specific APIs/formats/versions the builder must verify against the live
  dependencies *before* writing code.
- **Boundaries** — files it may touch, files it must not, explicit out-of-scope
  list, "no placeholders; search before implementing", no refactors beyond the
  task.
- **Lane plan** — split the iteration into 1–4 parallel lanes, each declaring
  its **target repo + file-touch set, checked for overlap**: name the repo
  (`repos/<repo>`) and every file each lane may touch. Lanes in *different*
  repos are inherently disjoint; same-repo lanes with any file overlap run as
  one. Each lane gets its own objective, output format, and boundaries. Most
  iterations are one lane — fan out only when the work is genuinely parallel (a
  cross-repo project often is). Two first-class patterns — runnable recipes in `dispatch.md`: **parallel +
  fast-follow** (disjoint lanes integrate first; a fast-follow lane off
  `project/<slug>` carries the seam — see `### Parallel + fast-follow`) and
  **serial deferred judgment** (iterations run to gates-green with `architect
  verdict` withheld; one later batch session judges each against its own frozen
  AC — see `### Serial deferred judgment`).
- **Effort call** — thinking budget set in the lane-prompt via the escalation
  keywords (`think hard` … `ultrathink`); default unattended builder work high,
  downgrade a routine, tightly-specified lane (record which and why). Claude
  Code has no per-invocation effort flag — see `dispatch.md`.

**Spike (probe) iterations.** When the open question is too uncertain for a
build — the repo can't answer it and routine API-verification won't resolve it
— spec a *spike* (probe) instead of a build iteration. A spike is
investigate-only: its deliverable is a **recommendation**, not merged behavior.
Its lane reads, experiments in throwaway scratch (never the worktree), and
writes a structured recommendation to its scratch report; there is usually
nothing to integrate. Acceptance Criteria are **read-bound** — gates are
minimal (at most suite-green confirming the probe broke nothing), because the
proof is the architect reading the recommendation against the question the spike
was set, not a runnable check; the AC names that question. The spike verdict
uses **ADOPT / REVISE / REJECT** (not KILL/CONTINUE): the architect transcribes
the recommendation into Builder Report, then the Verdict records the
disposition and, if adopted, names the follow-up build iteration it spawns. A
spike's CONTINUE means "recommendation accepted + disposition recorded." This
is distinct from discovery-scale research (`/architect-research`, which surveys
a whole topic): a spike is one iteration-sized, decision-oriented probe run
through the normal builder/lane machinery.

Then write the **Acceptance Criteria** section — prose conditions (AC1, AC2, …)
that the architect judges against, followed by a fenced ` ```gates ` block of
runnable checks (each gate carries `id`, `ac`, `cmd`, and `expect`; `cwd` is
optional) — and run `architect freeze <name>`. What must be frozen before
dispatch is the Acceptance Criteria: `architect freeze` lints the gates block
(absent or empty gates is allowed but warns; malformed fails), commits any
pending content in the frozen region (Grounds/Specification/Acceptance Criteria)
in one freeze commit, records the `freeze_sha` in `space.yaml`, and prints the
frozen AC back; **that commit is the freeze** ❄️ and is the last thing before
dispatch. You needn't sequence Grounds and Specification into separate commits
first — the freeze snapshots the whole frozen region and refuses to re-freeze
once a frozen section changed afterward.

### 5. Dispatch (one fresh `claude -p` per lane, worktree-isolated)

Per the mechanics in `dispatch.md`:

- **1 lane** → dispatch in the target repo's checkout (`repos/<repo>`).
- **2–4 lanes** → `architect worktree add <repo> <iteration> <lane>
  [--base <repo-base>]` per lane (creates `build/<id>-<lane>/wt` off the target
  repo's base commit — a repo commit, distinct from the freeze, which is a
  space commit — and records it in `space.yaml`).

Assemble each lane's lane-prompt (the template in `dispatch.md` + this lane's
section of the Specification + the frozen Acceptance Criteria) and write it to
`build/<id>-<lane>/prompt.md` (fed to the builder on stdin); record it in the
iteration file's **Builder Prompt** section — the dispatched-prompt provenance —
with `architect section <iteration> prompt --append --lane <lane> --from
build/<id>-<lane>/prompt.md`. Then run `architect dispatch <iteration> <lane>` — it assembles the
canonical `claude -p` argv, pins the model, and streams stream-json to
`build/<id>-<lane>/run.jsonl`. Launch one dispatch per worktree — each as its
**own background Bash tool call** (your harness's `run_in_background`), **not**
shell `&`. The harness keeps each lane alive for its full run and notifies you
per lane; a `for … & done` launcher instead orphans the lanes and the harness
reaps them all at once (see `dispatch.md`). Each lane builds only its declared
files and writes raw results to `build/<id>-<lane>/report.md` — it never
touches `architecture/`, so lanes never collide and the Acceptance Criteria
stay untouchable.

Do not block — end the turn or do other judgment work; long runs (30–60 minutes) are
normal. Print the lane-prompts too, so the human can run any lane in an
interactive `claude` session instead. Whenever you return to a running lane,
check liveness: the lane's `run.jsonl` must still be growing. If it has been
silent 15+ minutes on one in-flight command, follow "Stall detection and
rescue" in `dispatch.md` — kill the stuck child process, not the run.

When all lanes complete, **the dispatch session's job is done** — babysit
liveness per `dispatch.md` but do not run gates, transcribe evidence, integrate
lanes, or write the Verdict. Hand off to a fresh judging session (§6).

### 6. Post-flight, judge, and integrate (judging session)

A fresh judging session — not the session that dispatched (see §1 and §5) —
opens with the **MECHANICAL POST-FLIGHT CHECKS** and owns everything through the
Verdict and integration. Because this session did not dispatch, §1's
fresh-session-judgment is intact: it is the correct session to evaluate results.

`architect verify <iteration>` REPORTS (it never judges) per lane: frozen
sections untouched, no builder commits, scratch report present, in-bounds.
Confirm each yourself with evidence: (a) the scratch report has raw results
only, (b) PHASE 0 disagreements were raised (silent compliance = defect to
log), (c) the iteration file's frozen sections are untouched — `git diff
<freeze-sha> HEAD -- architecture/I<NN>-<name>.md` shows no change to
Grounds/Specification/Acceptance Criteria, (d) `git status` in the worktree
shows **only files inside the lane's declared set** — an out-of-bounds write
fails the lane, (e) `git -C <worktree> log <repo-base>..` is empty — a builder
commit means a tampered worktree (reset and re-dispatch).

**Transcribe** each lane's scratch report into the **Builder Report** section
with `architect evidence <iteration> --lane <lane>` — it copies
`build/<id>-<lane>/report.md` **verbatim** (byte-for-byte, no interpretation),
commits it, and echoes the builder's STATUS line. The builder never wrote into
`architecture/`; the CLI transcribes, preserving raw-results-only.

**Then integrate** — you decide which lanes pass, the CLI does the git
mechanics. `architect integrate <iteration> --lanes <passing-set>` commits each
named lane on its branch and merges it `--no-ff` into the stable
`project/<slug>` branch (slug derived from `space.title`; persistent and shared
across all iterations), in order; it **refuses** a lane that left builder
commits or wrote out-of-bounds, and stops on a merge conflict — which means the
lane plan wasn't disjoint, a spec defect: kill the conflicting lane and re-spec
it (never hand-resolve). A cross-repo project yields one `project/<slug>` branch
per touched repo. `main` is never touched per-iteration — `--teardown` deletes
only the per-lane `lane/<iteration>-<lane>` branches and worktrees, never the
project branch. Update the iteration index in `architecture/ARCHITECT.md`
(recording the `project/<slug>` branch), remove the worktrees (`architect
integrate … --teardown`, or `architect worktree remove <iteration> <lane>`), and
commit the space.

**Run the frozen gates cold** — `architect gate <iteration>` runs the frozen
gate commands against the integration tree and streams raw output (a runner, not
a judge). Read the output, check the diff against the Specification and the
cited BRIEF §sections (per §2), then write the **Verdict** (`architect verdict
<iteration> continue|kill --from <file>`): disagreement rulings, per-AC
PASS/FAIL/INVALID, the KILL/CONTINUE call.

At project end, `architect land` prints the single `gh pr create --base main
--head project/<slug>` command per touched repo and writes a PR body to
`build/land/` — no push, no `gh` call; the human runs it from the repo when
the project is ready to ship.

## Maintenance

Re-read this skill against each new model generation and delete what the models
now do unprompted — over-prescription degrades current-model output. The rules
above are invariants; everything else is prunable.
