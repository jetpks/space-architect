# Space and project state 🗄️

Where the loop keeps state: the `space.yaml` project block, the
`architecture/` files, and the XDG paths the tooling reads and writes. All of
this is read from the code, not recalled.

## The space and its identity file

A space is a directory with a `space.yaml` identity file (id, title, status,
repos, notes, tags) plus conventional subdirectories:

```text
~/architect/spaces/<yyyymmdd>-<slug>/
  space.yaml        # identity + the project: block (the loop's state)
  README.md
  repos/            # cloned (or copy-on-write provisioned) repositories
  notes/            # scratch, prompts, logs
  architecture/     # committed memory: ARCHITECT.md + BRIEF.md + I<NN>-<name>.md
  build/            # gitignored scratch: lane worktrees, run logs, reports
  tmp/              # workspace-local temp — use this instead of /tmp
```

`architect` resolves the current space by walking up from `$PWD` to the
nearest `space.yaml` — there is no "current space" state to desync.

## The `project:` block in `space.yaml`

`architect init` adds it; every state-changing command updates it. Fields as
the code writes them:

| Field | Written by | Holds |
|-------|------------|-------|
| `status` | `init` | project status (`active`, …) |
| `current_iteration` | `new` | the in-flight iteration's name |
| `iterations[]` | `new` | one entry per iteration: `name`, `ordinal`, `file`, `verdict` (default `pending`) |
| `iterations[].freeze_sha` | `freeze` | SHA of the freeze commit — the frozen region's tamper seal |
| `iterations[].lanes[]` | `freeze` | each lane's `name`, `repo`, `touch_set` (from the frozen ```lanes block) |
| `iterations[].lanes[].base_sha` | `worktree add` / `provision` | the base ref the lane branched from |
| `iterations[].integration_branch` / `integrate_sha` | `integrate` / `merge` | where the lanes merged and at which SHA |
| `project.model` / `project.harness` | `worktree add --model/--harness` | project-level dispatch defaults |
| `project.commit_mode` | — | `strict` (default) or `conductor`; overridable per run on `verify`/`merge`/`integrate` |

Read it with `architect status` (human view) or by reading `space.yaml`
directly — it is plain YAML.

## `architecture/` — the committed memory

**`ARCHITECT.md`** (`architect init`, from the bundled template) — the
cross-iteration index: TL;DR, repos in scope, the per-repo verification gate
commands, the iteration index table (status values: speccing → frozen →
dispatched → in-flight → awaiting-verdict → done), backlog, open items, and a
Decisions log. Keep it short (~150 lines): the next session must grok it in
under a minute.

**`BRIEF.md`** (`architect brief new`, optional) — the durable project
contract: numbered §sections (§1 goal & non-goals, §2 constraints/frozen
stack, …) that every iteration cites as **BRIEF §N**. Edits to a §section are
project-scope decisions — log them in ARCHITECT.md's Decisions log.

**`I<NN>-<name>.md`** (`architect new`, from the bundled template) — one
self-contained file per iteration, grown section by section, one commit per
section:

| Section | Holds | Persisted by |
|---------|-------|--------------|
| `## Grounds` | why — research/brief distilled, with citations (optional) | `architect section <it> grounds --from <f>` |
| `## Specification` | what/how — the full delegation contract + the ```lanes block | `architect section <it> specification --from <f>` |
| `## Acceptance Criteria` | proof — prose ACs + the ```gates block | `architect section <it> acceptance-criteria --from <f>` |
| `## Builder Prompt` | the exact lane prompt(s) dispatched | `architect section <it> prompt --append --lane <l> --from <f>` |
| `## Builder Report` | raw evidence, transcribed verbatim | `architect evidence <it> --lane <l>` |
| `## Verdict` | rulings, per-AC table, KILL/CONTINUE | `architect section <it> verdict --from <f>` / `architect verdict <it> <decision>` |

The frozen region is Grounds + Specification + Acceptance Criteria (everything
up to `## Builder Prompt`); after `freeze`, only the last three sections may be
appended.

## `build/` — the gitignored scratch

```text
build/
  <id>-<lane>/          # one per dispatched lane
    wt/                 # the lane's git worktree (branch lane/<id>-<lane>)
    prompt.md           # the lane prompt, copied byte-for-byte at dispatch
    run.jsonl           # streamed builder JSONL event log
    report.md           # the builder's raw report (transcribed by `evidence`)
  rehearse/             # rehearsal transcripts (one file per non-EMPTY run)
  research/<id>/        # research lanes' sessions + logs
  land/                 # PR-body drafts at landing time
```

## XDG paths

| Path | Owner | Holds |
|------|-------|-------|
| `~/.config/space-cadet/config.yml` | space-cadet | the spaces config (`base_dir`, `src_dir`, protocol, …) — see `space config show`; the loop has no config of its own |
| `$XDG_STATE_HOME/space-cadet/state.yml` | space-cadet | substrate state (recent spaces, current space) |
| `$XDG_STATE_HOME/space-architect/session-sync.yaml` | space-architect | the session-sync upload cursor (`architect sessions sync --state-file` overrides) |

All are XDG-aware: `XDG_CONFIG_HOME` and `XDG_STATE_HOME` are honored; the
defaults under `$HOME` otherwise.
