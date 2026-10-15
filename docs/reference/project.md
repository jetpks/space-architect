# Project commands 🧭

Project-level commands: scaffolding, grounding, state, repo sync, skill and
extension installation, bug reporting, read-only loop cost accounting, and the
run/loop log viewers. Usage lines are the shipped binary's own.

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

## `architect install-extensions`

Install the architect-loop pi extension package through pi's own mechanics:
runs `pi install <source>` then `pi update --extension <source>`, in order,
aborting on the first failure. The gem owns the standing declaration (the
package source, `git:git@github.com:jetpks/pi-extensions.git`); pi owns
`settings.json` and the update mechanics. Idempotent by pi's semantics — safe
to re-run. `--extension` (singular) on purpose: the gem reconciles exactly the
package it declares, not the operator's other packages.

| Option | Default | Description |
|--------|---------|-------------|
| — | — | No options beyond the shared `--color`/`--colors` flags. |

A missing `pi` binary or a failing step is a loud error naming the exact
command and its captured output.

```sh
architect install-extensions
```

## `architect runlog [FILE]`

Pretty-print a pi agent run.jsonl as it streams: thinking dim, assistant text
plain, tool calls and their results one-lined, and a final `✓ done` / `✗ failed`
line with usage summed across the whole exchange (output, cache read, cost,
elapsed). System/user/toolResult message echoes and non-JSON noise on the
stream are dropped. Reads FILE, or stdin — the intended use is a live tail:

```sh
tail -f build/I08-…/run.jsonl | architect runlog
architect runlog build/I08-…/run.jsonl
```

| Env var | Default | Description |
|---------|---------|-------------|
| `RUNLOG_LIMIT` | `2000` | Character limit for one-lined tool inputs/outputs (clipped with a literal `…`). |
| `NO_COLOR` | — | Set to disable color (color is also off when stdout is not a tty). |

## `architect looplog [SPACE]`

Follow every active pi-subagents run in a space, live. Watches the pi
subagents' artifact transcripts from two roots — pi's default sessions dir for
the space slug (`~/.pi/agent/sessions/--<slug>--/`) and the space's `build/`
tree — and streams them with runlog's display discipline, each line prefixed
with a colored per-run tag and the record's own timestamp. Lane worktrees
(`wt/` directories) are pruned from discovery.

| Option | Default | Description |
|--------|---------|-------------|
| `--list` | `false` | Inventory only — one line per run (active ●/·, agent tag, last-activity HH:MM, age, size, run id, task), newest first; no follow. |
| `--replay` | `false` | Print existing history on adoption, then follow. |
| `--all` | `false` | Adopt every transcript, however stale. |

Blocks until ctrl+c (quiet exit). `SPACE` defaults to the nearest ancestor with
`space.yaml`.

| Env var | Default | Description |
|---------|---------|-------------|
| `LOOPLOG_WINDOW` | `900` | Seconds: transcripts mtime-older than this are stale (not adopted) unless `--all`. |
| `RUNLOG_LIMIT` | `2000` | Character limit for one-lined tool inputs/outputs. |
| `RUNLOG_THINK` | — | When set (an integer), clamp thinking text to that many characters (otherwise unclipped). |
| `PI_SESSIONS_DIR` | `~/.pi/agent/sessions` | pi sessions root to scan. |
| `NO_COLOR` | — | Set to disable color (color is also off when stdout is not a tty). |

```sh
architect looplog                      # follow active runs from $PWD's space
architect looplog --list               # inventory only
architect looplog --replay --all       # full history, however stale, then follow
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
