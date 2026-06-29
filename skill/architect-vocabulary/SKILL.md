---
name: architect-vocabulary
description: >
  Load the Architect system's vocabulary and a short "where you are"
  orientation — space, project, iteration, lane, brief, builder, architect,
  gate, freeze, verdict, research, variant set — for when you're standing in a
  space-architect workspace (or working on the skill itself) and need the terms
  understood in conversation but do NOT want to run the loop. Reference only:
  it does not dispatch builders, freeze, judge, or write iteration files.
  Invoke as /architect-vocabulary.
---

# Architect Vocabulary

This skill loads **terminology and orientation only**. It is the glossary, not
the loop.

## What this skill is — and isn't

- **Is:** the shared vocabulary of `space-architect` plus a quick orientation to
  where things live, so these terms are understood for the rest of the session.
- **Isn't:** the build loop. Do **not** run `architect new` / `freeze` /
  `dispatch` / `integrate`, do **not** write or edit anything under
  `architecture/`, and do **not** render verdicts on builder work. That is the
  separate **`/architect`** skill — invoke it deliberately when you actually
  want to run the loop. Read-only `architect` commands (`status`, `show`) are
  fine here.

## Vocabulary

**Roles**

- **architect** — the judgment role (a human, or Claude Opus 4.8 in judgment
  mode): arbitrates disagreements, writes and freezes iteration files, calls
  kill/continue, merges builder output. Never writes implementation code.
- **builder** — the implementation role: Claude Sonnet 4.6 run headless via
  `architect dispatch` (`claude -p`), one per lane in its own worktree. Reports
  raw evidence; never grades its own work; never edits `architecture/`.

**The workspace**

- **space** — a task-scoped workspace directory holding repos, notes, and
  artifacts under one root. `architect` finds it by walking up from `$PWD` to the
  nearest `space.yaml`.
- **space.yaml** — the space's identity file: id, title, status, repos, notes,
  tags, plus the `architect:` block (project state — iterations, freeze shas,
  lanes).
- **project** — an Architect Loop instance living inside a space; spans the
  repos under `repos/`.

**The unit of work**

- **iteration** — one PR-sized unit of work, captured as a single self-contained
  file `architecture/I<NN>-<name>.md`, grown section by section. Its sections:
  - **Grounds** — *why*: research/brief distilled (optional).
  - **Specification** — *what/how*: the full delegation contract.
  - **Acceptance Criteria** — *proof*: exact gate commands + thresholds; this is
    what gets frozen.
  - **Builder Prompt** — the exact lane-prompt(s) dispatched.
  - **Builder Report** — raw evidence, transcribed verbatim from build scratch.
  - **Verdict** — rulings + per-AC PASS/FAIL/INVALID + KILL/CONTINUE.
- **lane** — a parallel slice of an iteration (1–4 per iteration), each
  declaring a disjoint target repo + file-touch set. Lanes in different repos are
  inherently disjoint; same-repo lanes that overlap files run as one. Each runs
  in its own worktree under `build/<id>-<lane>/`.
- **worktree** — the isolated git worktree a lane builds in, off the target
  repo's base commit, so lanes never collide.
- **dispatch** — launching a fresh headless builder for a lane (`architect
  dispatch <iteration> <lane>`), streaming output to `build/<id>-<lane>/run.jsonl`.

**Contracts and checkpoints**

- **brief** (`architecture/BRIEF.md`) — the durable, §-numbered project contract
  that spans iterations; frozen at the project level and cited as **BRIEF §N**.
- **ARCHITECT.md** (`architecture/ARCHITECT.md`) — the cross-iteration index /
  table of contents and project-wide state.
- **freeze** ❄️ — committing the frozen region (Grounds / Specification /
  Acceptance Criteria) *before* dispatch (`architect freeze`). Records the
  **freeze_sha** in `space.yaml`; any later change to those sections is an
  automatic iteration FAIL.
- **gate** — a frozen verification command + threshold (test/lint/typecheck/
  build). `architect gate` runs them and streams raw output — it is a runner,
  never a judge.

**Outcomes**

- **verdict** — the architect's ruling on an iteration, written after evidence:
  - per-criterion: **PASS** / **FAIL** / **INVALID** (INVALID = not measured the
    way the gate specifies).
  - iteration-level: **KILL** / **CONTINUE**.
- **variant set** — an iteration built as multiple `(harness, model)` lanes over
  one frozen spec, judged head-to-head against the same Acceptance Criteria; the
  winner is selected with the human in the loop, not unilaterally.

**Research**

- **research** — two scales:
  - **discovery scale** (brainstorming, technology selection, state-of-the-art)
    → the **`/architect-research`** skill: a scout maps the topic, the
    orchestrator designs parallel researcher **lanes**, claims are verified
    against sources, and the synthesis distills into a brief §section or an
    iteration's Grounds.
  - **iteration scale** → an inline fan-out run only when an iteration needs
    facts the repo doesn't already have.

**Repos**

- **evergreen** / copy-on-write / **`src` engine** — repo provisioning: when an
  up-to-date local copy exists under `evergreen_dir`, `architect` copies it into
  the space (copy-on-write on APFS) instead of cloning over the network. The
  vendored `src` engine keeps those evergreen checkouts tended.

## Where you are

A space's directory layout:

```text
space.yaml        # identity + project state (the architect: block)
README.md
repos/            # the repos the project spans
notes/            # scratch, prompts, logs
architecture/     # ARCHITECT.md index + I<NN>-<name>.md iteration files (+ BRIEF.md)
build/            # lane worktrees + scratch: build/<id>-<lane>/
tmp/              # workspace-local temp — use instead of /tmp
```

Safe **read-only** commands to orient yourself (these don't run the loop):

```sh
architect status            # project state: iterations, freeze shas, lanes, verdicts
architect space show        # the space you're standing in
architect space list        # all your spaces
```

## Maintenance

This glossary is a **self-contained copy** of terms defined canonically in the
`architect` skill (`SKILL.md`) and the project `README.md`. It is installed as an
isolated skill, so it can't reference those at runtime — when the vocabulary
changes there, re-read this file against them and update it to keep the two from
drifting.
