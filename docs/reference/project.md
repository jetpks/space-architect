# Project commands 🧭

Project-level commands: scaffolding, grounding, state, repo sync, skill
installation, and bug reporting. Usage lines are the shipped binary's own.

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
