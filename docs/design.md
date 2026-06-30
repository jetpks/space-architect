# Space Architect Design

## Why this exists 🏗️

`space-architect` is a CLI for structured agent-assisted development work. It fuses three engines into one gem:

1. **Space management** — task-scoped project workspaces, each with fresh repo clones, notes, prompts, and other ephemera under one obvious filesystem root.
2. **The Architect Loop** — a structured human-AI collaboration protocol for complex multi-iteration build work, with frozen Acceptance Criteria, isolated builder worktrees, and separated judgment from execution.
3. **The evergreen engine** (vendored `repo-tender`) — keeps canonical copies of tracked repos in sync, so new workspaces get fast APFS copy-on-write clones instead of slow network fetches.

The motivating workflow is modern agent-assisted development: several concurrent tasks may touch the same repositories, each task may need fresh clones, notes, logs, and screenshots, and sandboxed tools are more reliable when all task context lives under one obvious filesystem root. The Architect Loop layers a repeatable judgment protocol on top of that foundation.

## Core constraints

- A space is a normal directory structure — inspectable, portable, no database.
- The workspace root location is configurable and may be anywhere on the filesystem.
- App config and state follow the XDG base directory spec.
- Per-space identity lives inside the space in `space.yaml` so the directory is self-describing.
- Space ids are date-prefixed for natural sorting: `20260531-name-of-space`.
- The architect's output lives in `architecture/` inside the space — iteration files, the cross-iteration TOC, and the freeze record.

## The space directory model 📁

A space looks like this:

```text
~/src/spaces/20260531-name-of-space/
  space.yaml          ← visible space metadata (id, title, status, repos, …)
  README.md
  repos/              ← cloned repositories
  notes/
  architecture/       ← architect loop output (not gitignored)
    ARCHITECT.md      ← cross-iteration table of contents
    I01-dry-cli-port.md
    I02-dispatch-engine.md
  build/              ← per-lane worktrees + scratch (gitignored)
    I02-dispatch-engine-lane-a/
      wt/             ← git worktree for this lane
      prompt.md
      report.md
      run.jsonl
```

The default containing directory is `~/src/spaces` (configurable via `architect space config set spaces_dir …`).

### `space.yaml`

Each space stores identity in `space.yaml` at its root:

```yaml
version: 1
id: 20260531-name-of-space
title: Name of Space
status: active
created_at: 2026-05-31T13:48:00-06:00
updated_at: 2026-05-31T13:48:00-06:00
repos: []
notes: []
tickets: []
tags: []
```

Supported statuses: `active`, `paused`, `done`, `archived`.

### `ARCHITECT.md`

`architecture/ARCHITECT.md` is the cross-iteration table of contents scaffolded by `architect init`. It is short (~150 lines) — the next session should be able to grok it in under a minute. It carries:

- A TL;DR block: project goal, last iteration status, next action.
- A repos-in-scope table.
- The verification gate (exact test/build commands per repo).
- An iteration index table: ordinal, name, status, freeze SHA, integration branch, verdict, file path. The index records only scaffolded iterations — ordinals are assigned at spec-time by `architect new`, never pre-assigned to planned work.
- An ordered Backlog for planned (un-numbered) work. Items get their ordinal only when about to be specced; pre-numbering forces renumber churn when priorities reshuffle.
- Open items for the human/architect.
- A decisions log.

**Not in `ARCHITECT.md` = didn't happen.** The iteration index is the canonical record of what was built and what was judged.

### Iteration files

Each iteration lives at `architecture/I<NN>-<name>.md`. The file grows section by section, one commit per section, in this order:

| Section | Purpose | Frozen? |
|---------|---------|---------|
| `## Grounds` | Research distilled: problem, decisions, verified facts with citations. Optional. | Yes (after freeze) |
| `## Specification` | The full, self-contained delegation contract: objective, output format, tool guidance, boundaries, lane plan, effort. | Yes (after freeze) |
| `## Acceptance Criteria` | Prose conditions of correctness (AC1, AC2, …) the architect judges against, plus a fenced ` ```gates ` block of runnable checks. | Yes (after freeze) |
| `## Builder Prompt` | The exact prompt dispatched to each lane, recorded as provenance. | No (appended at dispatch) |
| `## Builder Report` | Raw evidence only — tables, numbers, command output transcribed verbatim from `build/`. | No (appended after dispatch) |
| `## Verdict` | Architect judgment written in a later session: disagreement rulings, AC verdicts, KILL/CONTINUE. | No (final section) |

## The Architect Loop 🔄

### Shape and roles

The Architect Loop separates *judgment* from *execution*:

- **Architect** — Claude Opus 4.8, running interactively. Arbitrates disagreements, judges raw builder evidence against the frozen Acceptance Criteria, decides KILL or CONTINUE. The architect never builds; it evaluates.
- **Builder** — Claude Sonnet 4.6, run headless via `architect dispatch`, one per lane, each in its own git worktree under `build/`. The builder never touches the iteration file or the `architecture/` directory; it writes only inside its assigned worktree and drops its report at `build/<iteration>-<lane>/report.md`.

Multiple lanes can run concurrently because each builder is isolated in its own worktree. Lanes divide the work by non-overlapping file-touch sets so they can run without git conflicts.

### The freeze commit

Before any builder runs, the architect calls `architect freeze ITERATION`. This:

1. Commits the iteration file at its current state (Grounds + Specification + Acceptance Criteria sections must be present).
2. Records the commit SHA as `freeze_sha` in `space.yaml`.

From this point on, any change to the frozen sections (Grounds, Specification, Acceptance Criteria) is an automatic iteration FAIL — `architect verify` reports it, and the architect treats it as a signal of scope drift or builder tampering. The Acceptance Criteria freeze before any builder results exist, which prevents the criteria from being weakened to fit the evidence.

The builder never edits the iteration file — the architect writes every section and transcribes the Builder Report verbatim from the builder's scratch report, keeping the frozen Acceptance Criteria out of the builder's editable blast radius.

### Dispatch and worktrees

`architect dispatch ITERATION LANE` runs the builder headless via `claude -p`, streaming the full conversation to `build/<id>-<lane>/run.jsonl`. The builder receives the lane's prompt from the Specification section. Each builder gets its own git worktree (created with `architect worktree add`) so multiple lanes can write files concurrently without conflict.

### Verdict

The Architect Loop separates dispatch from judgment by design. The dispatching session babysits lane liveness and stops when builders finish — it does not run gates, transcribe evidence, or evaluate results. A fresh judging session opens cold: it runs the MECHANICAL POST-FLIGHT CHECKS (`architect verify`), transcribes each lane's report verbatim into `## Builder Report` (`architect evidence`), runs the frozen gate commands (`architect gate`), and then writes `## Verdict` with per-AC results and a KILL or CONTINUE decision. Fresh-context, cold, all-at-once evaluation is the point — the judging session did not dispatch, so the fresh-session-judgment rule holds.

Passing lanes are integrated into one stable `project/<slug>` branch (slug derived from the space title) that accumulates every iteration — `main` is never touched per-iteration. At project end, `architect land` prints the single `gh pr create --base main --head project/<slug>` command per touched repo; no push or `gh` call is made by the CLI.

## Space identity and resolution 🧭

Space ids are date-prefixed slugs: `20260531-name-of-space`. Duplicate names on the same day get a counter: `20260531-name-of-space-2`.

Commands that take an optional `[SPACE]` resolve in this order:

1. Explicit id or slug on the command line.
2. Nearest parent of `$PWD` containing a `space.yaml`.

Being *inside* a space is what makes it current. `architect space use` records recent state and prints a path, but PWD-based resolution always wins for implicit targeting.

## CLI principles

- The primary executable is `architect`; `space` is a forwarding shim for `architect space …`.
- Output is readable manually and useful in scripts.
- `architect space path [SPACE]` prints only the path.
- `architect space list` / `ls` is compact and human-readable.
- Paths under the user home are displayed as `~/...` in human-oriented output.
- Color defaults to TTY auto-detection and is overrideable with `--color=auto|always|never` (or `--colors`).

## Deferred intentionally

- Jira API integration.
- SQLite or background indexing.
- Shell `cd` integration.
- Notes subcommands beyond establishing the `notes/` directory.
