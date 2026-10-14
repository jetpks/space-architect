# Project commands 🧭

Project-level commands: scaffolding, grounding, state, repo sync, skill
installation, bug reporting, and read-only loop cost accounting. Usage lines
are the shipped binary's own.

## `architect init [SPACE]`

Scaffold (or top up) the architect project in the current space: creates
`architecture/ARCHITECT.md`, adds the `project:` block to `space.yaml`, and
writes a `.claude/settings.json` `SessionStart` hook (startup / clear / resume)
that re-grounds fresh sessions via `architect ground`. Idempotent — it writes
only the pieces that are missing and never overwrites existing files.

```sh
architect init
architect init 20260531-name-of-space
```

Takes the shared [commit-message options](spec.md#commit-messages) for the
initialization commit.

## `architect ground [SPACE]`

Print the grounding reads for a fresh session to stdout, under per-file
delimiters — `architecture/ARCHITECT.md`, `architecture/BRIEF.md` (if
present), and the in-flight iteration file (the `current_iteration` entry's
file if it exists, else the highest-ordinal `I<NN>-*.md`). This is what the
`SessionStart` hook scaffolded by `architect init` runs.

Also warns when a tracked repo's local branch is behind its remote — run
`architect sync <name>` in that case.

Emits nothing (exit 0) when invoked from inside a lane worktree under
`build/`, so builders are never grounded.

```sh
architect ground
```

## `architect status [SPACE]`

Show the architect project state — current iteration, the iteration index
(ordinal, freeze SHA, lanes, verdict), and iteration files. Read-only.

```sh
architect status
```

## `architect sync [REPO] [SPACE]`

Sync tracked repo clones with their remotes — fast-forward only, no
rebase/reset.

```sh
architect sync               # all tracked repos
architect sync my-app        # one repo
```

## `architect install-skills`

Install the bundled skills (`architect`, `architect-research`,
`architect-vocabulary`) for a harness. Run once per machine after installing
the gem, or after upgrading to pick up skill changes.

| Option | Default | Description |
|--------|---------|-------------|
| `--provider=VALUE` | `claude` | Skill install target (validated by the installer). |
| `--[no-]project` | `false` | Install to the current working directory instead of globally. |
| `--[no-]force` | `false` | Overwrite existing skills that differ. |
| `--[no-]dry-run` | `false` | Print what would happen without writing files. |

```sh
architect install-skills                       # claude (default)
architect install-skills --provider pi         # or codex | opencode
architect install-skills --project --dry-run   # show what would change
```

## `architect bug-report`

Generate a prefilled GitHub issue template for filing bugs against
space-architect.

| Option | Default | Description |
|--------|---------|-------------|
| `--title=VALUE` | — | Issue title, written into the title and the body's leading H1 (omit and `gh` will prompt for one interactively — the body file does not set it). |

```sh
architect bug-report --title "dispatch --detach exits 1 on first poll"
```

## `architect cost`

Account the loop's spend and speed from the pi session artifacts already on
disk: run metas (`*_meta.json`, at any depth) plus the interactive and
runner session files (any other `.jsonl` whose first line is a
`type: "session"` header) under the space's session dir —
`~/.pi/agent/sessions/--<slug>--`, where `<slug>` is the space path with
every `/` replaced by `-`. Read-only: nothing is written, stdout only.

Three views, one per invocation:

- default — agent × model cost table (input/output tokens, cache
  read/write, $, turns, cache hit ratio) with a totals row
- `--by-iteration` — the same table split into per-iteration windows
  (`[freeze_i, freeze_{i+1})` by each artifact's start time; artifacts
  before the first boundary land in `unattributed`) with a grand total
- `--latency` — per model: assistant-round count, mean round wall seconds,
  turn throughput (output tokens ÷ round wall — tool and child-wait time
  included, so tool-heavy runs deflate it), generation speed (output ÷ Σ
  assistant `durationMs` — what the model actually emits per generating
  second), and wait share (Σ tool time ÷ wall; a round is one user message
  through the last assistant message before the next)

Token counts print at 3 significant figures (`1.83B`, `999K`) by default;
  `--precise` prints exact integers with thousands separators. Colors
  (bold header/TOTAL rows, yellow $ column) follow the standard
  `--color`/`--colors` flags. `--json` is never rounded or colored.

| Option | Default | Description |
|--------|---------|-------------|
| `--json` | `false` | Emit the machine-readable JSON contract instead of tables. |
| `--space=VALUE` | nearest ancestor with `space.yaml` | Space path or id to account. |
| `--sessions-root=VALUE` | `~/.pi/agent/sessions` | pi sessions root to scan. |
| `--since=VALUE` | — | Only artifacts starting at/after this ISO-8601 timestamp or `YYYY-MM-DD` date. |
| `--by-iteration` | `false` | Split the cost table into per-iteration windows. |
| `--latency` | `false` | Per-model round latency instead of the cost table. |
| `--precise` | `false` | Exact token counts with thousands separators (default: 3 significant figures). |

```sh
architect cost
architect cost --space 20261009-pi-port --by-iteration
architect cost --latency --json
architect cost --precise
```
