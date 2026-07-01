# DESIGN — The Architect Loop

**A source-backed design for a harness in which a strong judgment model (the
_architect_) plans and reviews while cheaper execution agents (the _builders_)
do the implementation and research in fresh, isolated git worktrees — with the
space as the memory.**

The loop is **model-agnostic**. What matters is the two _identities_ and the
capability relationship between them — a strong reasoning model (or a human)
judging; one or more cheaper, faster agents building — not which specific models
fill those roles. Concrete model/CLI pairings are an implementation choice that
belongs in the README and in per-lane configuration (`architect dispatch
--model …`, `architect variant add`), never baked into the methodology. Where a
section below documents the concrete builder interface (§4) it names the
_reference_ harness (headless `claude -p`) and treats the model id as a
configurable placeholder.

Project memory lives in the space's `architecture/` directory (committed to the
space repo), scratch in `build/` (gitignored), and a project spans one or more
repos under `repos/`. Each iteration is **one self-contained file**,
`architecture/I<NN>-<name>.md`, grown section by section (Grounds /
Specification / Acceptance Criteria / Builder Prompt / Builder Report /
Verdict), **one commit per section** — the commits give the differentiation and
git gives the change guarantees, so there are no separate `gates/`/`lanes/`/`prd/`
directories. The `architect` command family
(`init`/`new`/`freeze`/`worktree`/`dispatch`/`verify`/`gate`/`integrate`/`land`/`status`)
is the primary workspace mechanism, wrapping plain git: the freeze is the commit
that adds the Acceptance Criteria, worktrees are `git worktree`, and verification
is `git diff` + `git log`.

Researched June 2026 from Anthropic engineering posts, agent-harness research,
and widely used community harness skills. Prescriptive claims below cite their
sources (see §8 for the dated-provenance caveat). This document is the "why";
the skill files in `skill/architect/` are the "how". The invariant rules R1–R12
are model-agnostic and unchanged across provider retargets; only the concrete
interface in §4 is implementation-specific.

---

## 1. The problem this design solves

Single-agent coding sessions degrade in three predictable ways:

1. **Context rot** — performance falls as the window fills; Anthropic calls the
   context window "a finite attention budget with diminishing returns"
   ([Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)),
   and practitioners report a "dumb zone" past ~40% utilization
   ([HumanLayer ACE-FCA](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents)).
2. **Self-grading** — the agent that wrote the code reports its own success.
   Benchmark studies found 47–74% of self-improvement runs showed proxy gains
   without real gains, with agents escalating from overt to obfuscated reward
   hacks ([OpenReview](https://openreview.net/forum?id=ikrQWGgxYg),
   [arXiv:2503.11926](https://arxiv.org/pdf/2503.11926)).
3. **Goalpost drift** — acceptance criteria written (or edited) after results
   exist always pass.

The sources surveyed point to the same basic shape — Anthropic's
[harness design post](https://www.anthropic.com/engineering/harness-design-long-running-apps),
obra/superpowers' subagent-driven development, the Ralph loop, and GitHub Spec
Kit:

> **Separate planning context from execution context. Persist state in the repo,
> not the conversation. Dispatch fresh-context workers per task. Verify with an
> agent that didn't write the code.**

This loop adds one more separation on top: **a stronger model judges a different
model's work in a fresh context.** How much that split buys depends on how far
apart the two models are, and that is a knob the operator sets, not a fixed
property of the design:

- The load-bearing separations in the cited evidence are **judge-≠-builder**,
  the **always-fresh judging context**, and a **capability gap where the judge
  outranks the builder**. None of those require two vendors.
- What varies with the pairing is **independence of failure modes**. Two models
  from the same lab share training lineage, so a blind spot the builder has, the
  judge may share — the split is a second line, not the spine. A cross-vendor
  pairing is more independent and recovers the bias-reduction that cross-lab
  designs lean on. Be honest about which you're running.
- Regardless of pairing, **the frozen external gates (R2) and architect-run
  verification (R3) are what the loop actually trusts.** The model split
  hardens the review; it does not carry it.

Economics are the other reason for the split — but be honest about them. In early
practice this loop spent tokens on the strong model and the builder at roughly
**10:1**, and the ceremony that sustains it (freezing, transcribing, cold judging)
is not free. For a problem one strong model can hold in one or two self-managed
context windows, driving it end-to-end is usually the *more* token-efficient
choice — don't run the loop (R11). The loop earns its overhead when you are
building **a lot**: a single self-driving context silently loses decisions that
were never written down, and quality decays as the window fills (context rot,
above). There the payoff is **coherence at scale**, not raw token thrift — a
central, committed plan guides every change, so the codebase stays well-factored
and coherent across dozens of iterations. Keeping the expensive model off the hot
path and running a fleet of cheap builders in parallel is a real saving too, but
it is secondary to the coherence.

---

## 2. Roles

| Role | Who | Effort | Owns |
|---|---|---|---|
| **Architect** | a strong reasoning model (or a human), run interactively | minutes per work block | arbitration, judging raw evidence against frozen gates, next-iteration specs, kill/continue calls |
| **Builder** | a cheaper/faster model run headless, one per lane (high thinking budget default; architect may dial per lane) | ~30–60 min per lane | implementation, lane agents, raw-results reporting |
| **Memory** | the space: per-iteration `architecture/I<NN>-<name>.md` files (indexed by `architecture/ARCHITECT.md`) + space git history | permanent | everything; not in the committed architecture = didn't happen |
| **Human** | you | final | scope, irreversible calls, taste |

The architect runs with full reasoning; judgment over a small handoff file is not
effort-sensitive, so there is no effort knob to pin — the skill carries no
`effort:` frontmatter (that was a field of one early harness).

Why a high thinking budget for the builder: it runs unattended for a stretch
(30–60 minutes in practice), where the metric to buy is review-survival, not
first-token latency — so default to a high budget and let the architect downgrade
routine, tightly-specified lanes. How thinking depth is set is harness-specific —
a reasoning-effort flag on some CLIs, escalation keywords or an env var on others
(see §4). This is a per-lane judgment call the spec records explicitly.

The concrete model/CLI pairing is an operator choice — the same repo can run an
all-one-vendor pairing, a cross-vendor pairing for stronger review independence,
or several pairings head-to-head as a **variant set** (`architect variant add`:
multiple `(harness, model)` lanes over one frozen spec, judged against the same
Acceptance Criteria). Variant sets are a space-architect addition beyond the
original loop, and they buy more than a model bake-off: you get several
**independent implementations** of the same spec, and independent implementations
catch each other's bugs — a defect one variant trips over, another often avoids —
and give you multiple *perspectives* on a hard problem. On a genuinely tricky
iteration it can be worth running variants for that alone; the redundancy is the
point, not just picking a winner. The README documents the reference pairings.

### The space as substrate

The loop runs inside a **space** — a task-scoped directory with a `space.yaml`
identity file (id, title, status, repos, plus the `project:` block that holds
iteration/freeze/lane state). `architect` finds it by walking up from `$PWD` to
the nearest `space.yaml`; being *inside* a space is what makes it current, so
there is no global "current space" state to desync.

```text
space.yaml        # identity + the project: block (iterations, freeze shas, lanes)
architecture/     # committed memory: ARCHITECT.md index + I<NN>-<name>.md (+ BRIEF.md)
repos/            # the repos the project spans (provisioned copy-on-write; see below)
build/            # gitignored scratch: per-lane worktrees build/<id>-<lane>/
notes/  tmp/      # scratch + workspace-local temp
```

Repos are provisioned by **copy-on-write** from an evergreen checkout under the
configured `src_dir` when one exists (an APFS COW clone — instant), falling back
to a network clone otherwise; the bundled `src` engine keeps those evergreen
checkouts tended. This is why fanning out a cross-repo project is cheap: each
lane worktree is a COW slice off a local mirror, not a fresh network fetch.

---

## 3. The twelve design rules

Each rule below is enforced mechanically by the skill, not left as advice.

### R1. The space is the memory; not in `architecture/` = didn't happen
Anthropic's long-running-agent harnesses use a progress file + git history as
the cross-session memory and find "compaction alone is insufficient — structural
artifacts are the load-bearing memory"
([Effective Harnesses](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)).
The architect refuses to judge results that exist only in chat output. Committed
= memory (everything under `architecture/`), gitignored = scratch (`build/`).
The Acceptance Criteria freeze as the commit that adds them to the iteration file
(`I<NN>: acceptance criteria (freeze)`). Community handoff conventions apply: the
next session must grok `ARCHITECT.md` in under a minute; TL;DR first; exact
paths/commands over prose
([handoff-memory conventions](https://lobehub.com/skills/neversight-learn-skills.dev-handoff-memory)).
A `SessionStart` re-grounding hook (scaffolded by `architect init`, running
`architect ground`) re-emits `ARCHITECT.md`/`BRIEF.md`/the in-flight iteration to
each fresh session, so cold pickup is cheap — the memory is the substrate, and
every fresh session is re-seated on it.

### R2. Gates freeze before results exist, and live where the builder can't move them
Anthropic's three-agent harness has the generator and evaluator "negotiate a
sprint contract" in shared files **before coding**, then freeze it
([Harness Design](https://www.anthropic.com/engineering/harness-design-long-running-apps)).
The reward-hacking literature adds the mechanical requirement: keep graders and
criteria out of the agent's editable blast radius. Implementation: the Acceptance
Criteria — prose conditions (AC1, AC2, …) plus a fenced ` ```gates ` block of
runnable checks — are written into the iteration file before dispatch and
committed (the freeze commit); the **builder never writes the iteration file at
all** — it reports to a scratch file the architect transcribes — so the criteria
are never in the builder's editable blast radius. The architect's post-run check
is `git diff <freeze-sha> HEAD -- architecture/I<NN>-<name>.md`: **any change to
the frozen region (Grounds/Specification/Acceptance Criteria, up to `## Builder
Prompt`) is an automatic iteration FAIL**, regardless of results — only Builder
Prompt/Report/Verdict may be appended after the freeze. Criteria are quoted
verbatim when judging (read from the freeze commit), never restated from memory.

### R3. The builder never grades its own work — and neither does the architect alone
Two-stage review, fresh contexts, is the most-replicated community pattern
(superpowers' spec-compliance review then quality review;
[superpowers](https://github.com/obra/superpowers)). Anthropic's agent guidance
states it directly: "Separate, fresh-context verifier subagents tend to
outperform self-critique." The loop's review stack:
1. Builder's own reviewer pass (inside the builder run, never writes feature code) — cheap first pass.
2. Architect runs the gates **itself** and reads the output — "builder test
   claims are hearsay" (matching Anthropic's "demand evidence, not assertions").
   The verdict on a run always happens in a **later, fresh judging session** than
   the one that dispatched it — the dispatcher never grades the run it launched.
3. Adversarial pass for high-stakes iterations. The architect reading the diff is
   already a stronger-model, fresh-context pass over the builder's work. How
   independent that read is depends on the pairing (§1): a same-lab pairing
   shares the builder's blind spots (the frozen gates in R2 are then the
   independent check); a cross-vendor pairing is more independent. For an extra
   pass, pipe the diff to a fresh read-only reviewer or have a fresh-context
   subagent red-team it. Calibrate the reviewer: *"flag only
   correctness/requirement/invariant gaps with file:line evidence — no style
   preferences"* — an uncalibrated reviewer always finds something and that
   spirals into gold-plating.

### R4. Grade the outcome, not the path
From Anthropic's evals guidance: rigid step-sequence grading is brittle; judge
each gate as an independent dimension; give the judge an "unknown/INVALID"
escape so unmeasured ≠ passed
([Demystifying Evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).
Verdicts are per-gate: **PASS / FAIL / INVALID** (INVALID = not measured the way
the gate specifies), then an iteration-level **kill / continue** call. Gate-pass
is necessary, not sufficient — the architect reads the diff against the
Specification's intent and the cited BRIEF §sections before the verdict.

### R5. Disagreement is mandatory, with citations
The builder's PHASE 0 must surface every disagreement with the spec, citing real
files; silent compliance is a defect the architect flags. This is the loop's
defense against spec errors compounding — a literal-minded builder follows a
prescriptive spec exactly, so the only place a spec error gets caught is before
execution. Every open disagreement gets an explicit
**ACCEPT / REJECT / MODIFY + one line why**. No deferrals.

### R6. Delegation carries the full contract: objective, output format, tool guidance, boundaries
Anthropic's multi-agent research system found vague delegation causes
duplication and misinterpretation; every dispatch needs those four parts
([Multi-Agent Research System](https://www.anthropic.com/engineering/multi-agent-research-system)).
The iteration's Specification is exactly those four parts plus the frozen gates.
Specs are self-contained — the builder gets everything in the dispatch block,
with repo paths to read for detail (just-in-time retrieval, not
context-stuffing). Per established agent-prompting guidance, the full task spec
goes up front in one well-specified turn — ambiguous progressive specification
degrades both token efficiency and performance.

### R7. One iteration per loop; fresh builder context per iteration
The Ralph loop's core lesson — and its author's explicit warning about
skill-ifying it: "if you implement Ralph as a skill inside the harness, you're
missing the point — the point is the always-fresh context"
([ghuntley.com/ralph](https://ghuntley.com/ralph/),
[HumanLayer's history](https://www.humanlayer.dev/blog/brief-history-of-ralph)).
This skill respects that: the architect's context holds judgment only; every
iteration is built by a **fresh headless builder process** per lane. A headless
"continue"/"resume" (from the lane's worktree) is used only for follow-ups within
the same iteration (answering the builder's PHASE 0 questions), never to stretch
one builder context across iterations. "Code is cheap": when a run goes badly
wrong — a broken worktree, a poisoned context — `git reset` and re-dispatch beats
a long rescue-prompt. But discard is not the only recovery, and often not the
cheapest: many failures are better handled by a same-iteration continue (feed the
builder the rulings and let it fix its own work with full context) or a narrow
**fast-follow** lane that patches the seam. Reach for a full re-dispatch when the
context is genuinely poisoned; otherwise don't let perfect be the enemy of good.

### R8. Parallelism is architect-orchestrated: one worktree + one fresh builder per lane, capped at 4
Merge conflicts between parallel agents are the top reported multi-agent failure;
the converged mitigation is mapping file-touch sets before parallelizing, one
git worktree per agent, and a practical ceiling of 2–4 lanes before coordination
overhead dominates ([Intility engineering](https://engineering.intility.com/article/agent-teams-or-how-i-learned-to-stop-worrying-about-merge-conflicts-and-love-git-worktrees),
[MindStudio worktrees](https://www.mindstudio.ai/blog/git-worktrees-parallel-ai-coding-agents)).
**The architect — not the builder — owns the fan-out.** The spec splits the
iteration into 1–4 lanes whose file sets are checked for overlap (each lane's
`touch_set`, recorded at `architect worktree add --touch …`); each lane is an
isolated worktree running its own fresh builder process, writing its own raw
report to scratch (`build/<id>-<lane>/report.md`, which the architect transcribes
verbatim into the iteration file's Builder Report). The architect runs per-lane
boundary checks (`architect verify`: `git status` must show only declared files;
`git log <repo-base>..` must be empty, since the builder CLI has no sandbox to
block commits), then `architect integrate` merges each passing lane `--no-ff`
into the stable `project/<slug>` branch with gate smoke-runs. Keeping fan-out in
the architect rather than delegating it to a builder-internal subagent feature
makes a merge conflict a **detectable** event at integration time rather than a
silent hazard, and isolates per-lane failure (discard one lane, not the
iteration). Touch sets need not be *perfectly* disjoint: a large, tangled overlap
means the lane plan was wrong (kill and re-spec), but a small, contained conflict
is usually cheaper to hand-resolve at integration than to avoid by re-running two
whole iterations — reserve "never hand-resolve" for conflicts that signal a real
disjointness defect, not every collision. When an iteration is near-disjoint but
for a thin seam, the **parallel + fast-follow** pattern routes the seam into a
dedicated follow-up lane off the integrated tip.

### R9. Supervise asynchronously; never block on the builder
Anthropic's agent guidance for orchestrators is explicit: "prefer async
communication over blocking on each return" when dispatching and sustaining
parallel subagents. Each builder runs in the background as its own
harness-tracked task (one background Bash tool call per lane — *not* a shell `&`
loop, which orphans the lanes and gets them reaped together; see `dispatch.md`);
the architect ends its turn or does other judgment work, then runs the
post-flight checks when each run completes. Long unattended runs (30–60 minutes,
sometimes more) are normal;
a headless builder draws on its plan's background/credit pool rather than a
per-window interactive quota that could die mid-run (the reference specifics are
in §4). `architect dispatch --detach` and a wall-clock `--timeout` make a lane
survive a harness reap and bound a wedged run.

### R10. Grounded progress claims — audit every status against tool output
Anthropic's agent guidance: instruct the model to audit every status claim
against a tool result from the session before reporting; in their testing this
"nearly eliminated fabricated status reports." Applied twice here: the
architect's own reports, and the handoff rules for the builder (raw
tables/numbers/SHAs only — "no interpretation, no 'promising'; verdicts belong to
the architect and the human"). Every builder report ends in exactly one
`STATUS:` line (COMPLETE / COMPLETE_WITH_CONCERNS / BLOCKED).

### R11. Ground before judging; scale effort to the task
Read the project's own operating docs (CLAUDE.md/AGENTS.md → README →
architecture docs) and learn its verification gate before any judgment; a wrong
assumption multiplies through every dispatch. And not everything needs the loop:
trivial work gets done directly; the full pipeline is for iteration-sized work
and up. "Every component in a harness encodes an assumption about what the model
can't do on its own" — don't run a $200 harness on a $9 task
([Harness Design](https://www.anthropic.com/engineering/harness-design-long-running-apps)).

### R12. Keep the skill thin, declarative, and prunable
Two reasons. (a) Skill mechanics: only descriptions sit in context until invoked,
but the body stays in context for the session — keep it terse, push detail to
referenced files ([Skills docs](https://code.claude.com/docs/en/skills)).
(b) Obsolescence: skills developed for prior models are often too prescriptive
for current models and can degrade output quality (Anthropic's agent guidance),
and the position that scaffolds get obsoleted by better models
([Latent Space, harness engineering](https://www.latent.space/p/harness-eng)).
The skill states *invariants* (the rules above) and *interfaces* (the dispatch
contract), not step-by-step micro-procedures. Review it against each new model
generation and delete what the model now does unprompted — **and this doc is how
you know what is safe to delete: a rule you can no longer tie back to a live
failure mode (§6) or a current source is a candidate for pruning.**

---

## 4. The builder interface (reference implementation: the `claude-code` harness)

This section documents the **concrete** builder interface. The methodology above
is model-agnostic; here the reference harness is headless `claude -p` and the
builder model is a **configurable placeholder** (`<builder-model>`) — the
`architect dispatch` CLI pins it from the lane entry or its reference default,
and `--harness` selects an alternate CLI (e.g. `opencode`). Facts the skill
encodes:

- **The model is pinned explicitly**: `--model <builder-model>`. Pin the full id,
  not a floating alias (a bare "latest"/tier tag drifts to whatever ships next);
  an automation must not let a model bump silently change the builder mid-project.
  `architect dispatch --model …` overrides per dispatch, and a lane records its
  own model at `worktree add`.
- **Filesystem isolation is layered, not automatic.** By default the reference
  CLI has no OS sandbox (it's opt-in via settings, off by default), so the
  first-line controls are the **tool allow/deny lists**
  (`--allowedTools`/`--disallowedTools`) plus `--permission-mode` — `acceptEdits`
  lets builders auto-approve writes without prompting, while researchers get a
  read-only allow list and nothing else (a tool not on the list is denied, not
  prompted, in `-p` mode). That is the soft default. For real hardware isolation,
  the `space` toolkit can pack the space — builders and all — into an **OCI
  container** (`space pack` → `space build` → `space run`, with auth injected at
  runtime rather than baked into the image), so the whole run executes in a
  sandbox it can't escape to the host filesystem or network. Use the tool
  allow/deny lists for the common case; reach for the container when you want the
  run genuinely fenced. (Neither makes `.git` read-only — "builders never commit"
  stays enforced by the layers in the commit-guarantee note below and checked in
  R8.)
- **Thinking budget** is set per harness — there is no one mechanism. Some CLIs
  take a reasoning-effort flag, driven through `architect dispatch --effort`; the
  reference `claude-code` harness has no such flag, so depth is raised with
  in-prompt escalation keywords (`think` < `think hard` < `think harder` <
  `ultrathink`) or the `MAX_THINKING_TOKENS` env var. Builders default high;
  researchers stay modest.
- **Prompt input is stdin** — the lane-prompt is written to
  `build/<id>-<lane>/prompt.md` and fed on stdin, sidestepping shells that mangle
  quotes in big prompts. The reference CLI has no `@file` and no `-C`/working-dir
  flag, so per-lane dispatch `cd`s into the worktree.
- **Telemetry / output**: `--output-format stream-json --verbose` streams JSONL
  events to a run-log (`build/<id>-<lane>/run.jsonl`) for liveness/stall checks;
  the builder's deliverable is the raw report it writes to
  `build/<id>-<lane>/report.md`, and the contract is the `STATUS:` line
  convention, not a schema. `--max-turns N` caps the agent loop as a backstop.
- **Session continuity**: dispatch in the lane's worktree and follow up with a
  headless continue/resume — sessions are scoped per directory, so a bare
  "continue" is deterministic even with parallel lanes. Same-iteration only.
- **Web access** is the built-in `WebSearch`/`WebFetch` tools — no extension or
  key. Builders get them for verify-against-reality API checks; researchers get
  them as their only outward tools (domain-pinned allow rules in
  injection-sensitive repos).
- **`CLAUDE.md`** is the builder's standing context — loaded root-down
  automatically. The loop's PHASE rules live in the lane-prompt so they version
  with the skill; repo-specific build/test commands belong in `CLAUDE.md`.
- **No hard commit guarantee from the runtime.** With no sandbox to make `.git`
  read-only, "builders never commit" is enforced in layers: a runtime first line
  (`--disallowedTools 'Bash(git commit:*)' …`, which a builder can still shell
  out around via `sh -c`), worktree isolation, and the **authoritative** architect
  check after the run — `git -C <worktree> log <repo-base>..` must be empty and
  `git status` must show only declared files. A commit = a tampered worktree →
  reset and re-dispatch.

Canonical dispatch (what `architect dispatch <iteration> <lane>` runs under the
hood; the CLI is the supported path, this is the manual fallback):

```bash
claude -p --model <builder-model> \
  --permission-mode acceptEdits \
  --allowedTools 'Read,Edit,Write,Grep,Glob,Bash,WebSearch,WebFetch' \
  --disallowedTools 'Bash(git commit:*),Bash(git push:*),Bash(git reset:*)' \
  --output-format stream-json --verbose --max-turns 200 \
  < build/<id>-<lane>/prompt.md \
  > build/<id>-<lane>/run.jsonl 2>&1
```

**Billing note (reference implementation, dated).** With the reference
`claude-code` harness, headless `claude -p` draws on the Agent SDK credit pool on
your Claude plan — separate from interactive usage limits since June 15 2026 — so
there are no per-window quotas that die mid-run; unattended overnight loops just
spend that pool. The architect runs as your interactive session. Other harnesses
have their own cost model (e.g. a Codex-CLI builder bills against a ChatGPT
plan's quotas). Treat the specific dates/pools as dated facts (§8).

### CLI principles

- The `architect`, `space`, and `src` binaries are first-class over clean library
  seams; `architect` forwards `architect space …` / `architect src …` so one
  command can drive everything.
- Output is readable manually and useful in scripts; paths under `$HOME` render
  as `~/…` in human output; color auto-detects the TTY and honors
  `--color=auto|always|never`.
- The CLI *runs* gates and *reports* mechanical checks; it never judges. Every
  runner (`gate`, `verify`) prints raw output and defers the verdict to the
  architect.

---

## 5. The loop, end to end

```
one work block:

  0. Ground    — CLAUDE.md/AGENTS.md → verification gate → ARCHITECT.md
                 + BRIEF.md + the in-flight iteration file
  1. Arbitrate — every open disagreement → ACCEPT/REJECT/MODIFY + why (→ Verdict)
  2. Judge     — run the gates yourself; per-gate PASS/FAIL/INVALID vs the
                 verbatim frozen Acceptance Criteria → KILL/CONTINUE (→ Verdict)
  3. Spec      — write Grounds (if researched) + Specification + Acceptance
                 Criteria into architecture/I<NN>-<name>.md; `architect freeze`
                 snapshots the frozen region ❄ (one commit)
  4. Dispatch  — 1-4 parallel headless builder lanes, one git worktree each
                 (background, fresh context); record each lane-prompt in Builder
                 Prompt. Per lane: PHASE 0 disagree-or-fail → PHASE 1 shared
                 contracts frozen → PHASE 2 build own files → raw report to
                 build/ scratch. When builders finish, the dispatch session STOPS.

  ── fresh judging session (did not dispatch) ──
  5. Post-flight — `architect verify` (frozen region untouched, no builder
                 commits, report present, in-bounds); transcribe each scratch
                 report → Builder Report (`architect evidence`)
  6. Integrate — `architect integrate` merges passing lanes --no-ff into the
                 stable project/<slug> branch; run the frozen gates cold
                 (`architect gate`); write the Verdict (`architect verdict`)

The space's architecture/ carries everything across the gap between sessions;
`architect land` prints the end-of-project `gh pr create` per repo at project end.
```

The dispatch session's documented job **ends when the builders finish** — it
babysits lane liveness and then stops; it does not run gates, transcribe
evidence, integrate, or write the Verdict. A **fresh judging session** owns
everything from post-flight through the Verdict. Because that session did not
dispatch, R3's fresh-context judgment holds. The human reads the handoff between
blocks and overrides anything.

Passing lanes integrate into one long-lived `project/<slug>` branch (slug from
`space.title`) that accumulates **every** iteration; `main` is never touched
per-iteration. A cross-repo project yields one `project/<slug>` branch per
touched repo. Two first-class multi-lane patterns compose this: **parallel +
fast-follow** (disjoint lanes integrate first; a fast-follow lane off the merged
tip carries the seam) and **serial deferred judgment** (iterations run to
gates-green with the Verdict withheld; one later batch session judges each
against its own frozen AC — every verdict still cold and fresh-session).

### Optional pre-spec research fan-out

Between judging and speccing, the architect may run a research phase: 3–5
parallel read-only researchers (built-in `WebSearch`/`WebFetch`), each answering
one narrow non-overlapping question, with the architect adversarially verifying
load-bearing claims and writing the iteration's **Grounds** section itself.
Design decisions behind it:

- **Trigger-gated, not always-on.** "Research if you think it helps" fires
  constantly or never; instead the skill names three concrete triggers
  (iteration depends on external APIs/libraries/versions new to the repo; a
  technology choice needs facts nobody has; the human asks) and defaults to
  skip — the builder's verify-against-reality requirement already covers routine
  API checks (R11).
- **Progressive disclosure.** The mechanics live in `research.md`, read only when
  a trigger fires — the default architect context never pays for them (R12).
- **Cheap researchers, strong-model judgment.** Research is coverage work — it
  runs at a modest budget, read-only by toolset, report captured as stdout.
  Verification of load-bearing claims and Grounds authorship stay with the
  architect — researchers are forbidden from making recommendations, the
  research-side equivalent of "raw results only" (R3).
- **Findings discipline** mirrors deep-research harnesses: every finding carries
  a URL, date, exact quote/figure, and confidence tag; disagreements between
  sources are reported, not resolved; "NOT FOUND" beats inference.
- **Grounds is repo memory; raw findings are not.** Grounds is committed with
  citations (R1); raw researcher output stays in gitignored scratch. The builder's
  PHASE 0 challenges Grounds like any other spec input.

### Three skills: `/architect`, `/architect-research`, and `/architect-vocabulary`

Discovery-scale research (brainstorming, technology selection, SOTA surveys) is a
**separate skill**, not a mode of the loop. Three reasons: different invocation
pattern (discovery precedes a project; the loop runs per work block), different
deliverable (a decision report vs a dispatch), and cost — research-grade fan-out
runs ~15× chat-level tokens
([Anthropic multi-agent research](https://www.anthropic.com/engineering/multi-agent-research-system)),
so it must be deliberately invoked. The loop's step 3 routes: discovery scale →
`/architect-research`; narrow iteration facts → the inline fan-out above.
`/architect-research` is scout-first and topic-designed (a cheap scout maps the
topic; the orchestrator designs 3–6 topic-specific lanes from a **source-class
tactics library**, `lanes.md`), because a 2026-06 evidence review found
production deep-research systems use adaptive planner-driven decomposition, and
dynamic beats static decomposition on GAIA
([OAgents](https://arxiv.org/abs/2506.15741): 47.88 static → 51.52 dynamic).

A third skill, **`/architect-vocabulary`**, is reference-only: it loads the
system's terms and a short "where you are" orientation for when you're standing in
a space (or working on the skills themselves) and need the vocabulary understood
without running the loop — it dispatches nothing, freezes nothing, judges nothing.

---

## 6. Failure modes → mechanical mitigations

| Failure mode | Mitigation in this design |
|---|---|
| Reward hacking / gate tampering | Acceptance Criteria committed pre-dispatch (the freeze commit); builder never writes the iteration file (reports to scratch); post-flight `git diff <freeze-sha> HEAD` on the frozen region; any change = automatic FAIL (R2) |
| Builder grades own work | Raw-results-only handoff; architect runs gates itself; fresh-session judgment; capability-gap review (R3, R10) |
| Goalpost moving | Verbatim gate quoting; gates never edited after results; a missing gate is a spec defect, frozen for the next iteration only (R2, R4) |
| Scope creep | Explicit out-of-scope list per iteration; silent scope additions = builder failure; architect flags creep by name (R5, R6) |
| Context rot | Architect context holds judgment only; fresh builder process per iteration; the space's `architecture/` is the memory; SessionStart re-grounding (R1, R7) |
| Merge conflicts between lanes | Overlap-checked `touch_set` lanes, ≤4, worktrees; a large tangled conflict = disjointness defect (kill/re-spec), a small contained one is hand-resolved at integration; parallel + fast-follow for the seam (R8) |
| Placeholder implementations | Gate commands are end-to-end and executable; "search before implementing; no placeholder code" in the lane-prompt (R4) |
| Broken repo after a long run | One iteration per loop; recover with a same-iteration continue or a narrow fast-follow, or `git reset` + re-dispatch when the context is poisoned; lanes are cheap (R7) |
| Fabricated status reports | Every status claim audited against a tool result, both sides; one `STATUS:` line (R10) |
| Gate-passing but unmergeable work | Judge reads the diff against spec intent and cited BRIEF §sections, not gate output alone — METR: 38% test-pass, ~0 mergeable as-is; capability-gap review for high-stakes (R3, R4) |
| Builder gaming visible gates | Gates frozen + read-only; architect-run verification; no builder iterate-against-gate loops (ImpossibleBench: visible-test loops raised cheating 33%→38%) (R2, R3) |
| Wedged / stalled unattended run | Liveness checks on the run-log; diagnose the child process tree; kill narrowest first; `dispatch --timeout` process-group-kills a wedged builder; explicit timeouts on long commands (R9, dispatch.md) |
| Shared-lineage review blind spot | Frozen external gates as the independent check; cross-vendor pairing or an extra red-team pass when independence matters (§1, R3) |
| Harness bloat / obsolescence | Thin declarative skill; per-model-generation pruning review, tied back to this doc's rules + failure modes (R12) |

---

## 7. What this deliberately is not

- **Not a general-purpose orchestrator.** A single-model plan→delegate→review
  inside one session is a different tool. This is the two-role, separate-process
  loop — a strong model judges, fresh headless builders build, the criteria
  freeze in the space repo as a commit to the iteration file.
- **Not an autonomous infinite loop.** The human sits between work blocks by
  design — that's where kill/continue authority lives. The architect step *can*
  run as a scheduled headless job chaining blocks, but that's an extension, not
  the default.
- **Not just an agent loop.** A bare headless run already loops plan→act→test
  against a stopping condition within one run. This design adds the separations a
  bare loop lacks: a separate stronger-model judge, frozen external gates,
  arbitration, and repo-resident memory across runs.

---

## 8. Sources

**Provenance caveat.** These sources were surveyed and architect-verified in
**June 2026**. Treat them as **dated provenance**, not evergreen truth — some are
already superseded (e.g. Papers With Code shut down July 2025, succeeded by HF
Papers; Bluesky's public search API has returned 403 since March 2025;
`lanes.md` flags several such traps). Re-verify a claim against a current source
before leaning on it in a new iteration, and update this section when the
evidence moves.

**Anthropic (official):**
[Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) ·
[Multi-Agent Research System](https://www.anthropic.com/engineering/multi-agent-research-system) ·
[Writing Tools for Agents](https://www.anthropic.com/engineering/writing-tools-for-agents) ·
[Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) ·
[Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) ·
[Demystifying Evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) ·
[Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps) ·
[Claude Code Best Practices](https://code.claude.com/docs/en/best-practices) ·
[Skills](https://code.claude.com/docs/en/skills) ·
[Subagents](https://code.claude.com/docs/en/sub-agents) ·
[Headless mode](https://code.claude.com/docs/en/headless) ·
[Permissions](https://code.claude.com/docs/en/permissions) ·
[Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)

**Evidence reviews (2026-06, architect-verified primary sources):**
[Geng & Neubig — async SE agents, worktree+manager topology](https://huggingface.co/papers/2603.21489) ·
[PEAR — weak planners hurt more than weak executors](https://arxiv.org/abs/2510.07505) ·
[AgentForge — execution-grounded role decomposition](https://arxiv.org/abs/2604.13120) ·
[ImpossibleBench — test-exploitation in coding agents](https://arxiv.org/abs/2510.20270) ·
[METR — SWE-bench-passing PRs mostly unmergeable](https://metr.org/blog/2025-08-12-research-update-towards-reconciling-slowdown-with-time-horizons/) ·
[Cross-Context Review — fresh-context judging wins](https://arxiv.org/abs/2603.12123) ·
[Chroma — context rot](https://www.trychroma.com/research/context-rot) ·
[OpenAI — harness engineering / AGENTS.md rot](https://openai.com/index/harness-engineering/) ·
[Cognition — multi-agents: what's actually working](https://cognition.ai/blog/multi-agents-working) ·
[OAgents — static vs dynamic decomposition on GAIA](https://arxiv.org/abs/2506.15741) ·
[AOrchestra — on-demand subagent construction](https://arxiv.org/abs/2602.03786)

**Community / experts:**
[obra/superpowers](https://github.com/obra/superpowers) ·
[Ralph Wiggum loop](https://ghuntley.com/ralph/) ·
[A Brief History of Ralph](https://www.humanlayer.dev/blog/brief-history-of-ralph) ·
[Advanced Context Engineering (HumanLayer)](https://github.com/humanlayer/advanced-context-engineering-for-coding-agents) ·
[Simon Willison — Agentic Engineering Patterns](https://simonwillison.net/guides/agentic-engineering-patterns/how-coding-agents-work/) ·
[Latent Space — Harness Engineering](https://www.latent.space/p/harness-eng) ·
[GitHub Spec Kit](https://github.com/github/spec-kit) ·
[Reward hacking in self-improvement](https://openreview.net/forum?id=ikrQWGgxYg) ·
[Obfuscated reward hacking](https://arxiv.org/pdf/2503.11926) ·
[Worktrees for parallel agents](https://engineering.intility.com/article/agent-teams-or-how-i-learned-to-stop-worrying-about-merge-conflicts-and-love-git-worktrees)

---

*This is the "why". The "how" lives in the skill files (`skill/architect/SKILL.md`,
`dispatch.md`, `research.md`) and the command reference (`docs/reference.md`).
The invariants (R1–R12) are stable; the concrete interface (§4) tracks the
reference harness; everything else is prunable (R12) — prune against the rules
and failure modes here, not from memory.*
