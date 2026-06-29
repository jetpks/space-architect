# Command Reference 📖

Every Space Architect (`space-architect`) command, flag, and behavior. The primary executable is `architect`; `space` is a forwarding shim — `space foo` routes to `architect space foo`. 🚀

## Global options 🎨

These work on any command:

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `--color` | `auto` `always` `never` | `auto` | Color output. `--colors` is accepted too. |

Color defaults to auto-detection: colorized when stdout is a TTY, plain otherwise. Paths under your home directory are displayed as `~/...` in human-oriented output.

## Space resolution 🧭

Commands that take an optional `[SPACE]` resolve it in this order:

1. An explicit id or slug passed on the command line.
2. Otherwise, the nearest parent directory of `$PWD` containing a `space.yaml`.

Being *inside* a space is what makes it current — `architect space use` records recent state and prints a path, but it never overrides `$PWD`-based resolution.

## Architect Loop commands 🔄

These root-level commands manage the Architect Loop within a space.

### `architect init [SPACE]`

Scaffold architect project memory in the current space: creates `architecture/ARCHITECT.md` and adds the `architect:` block to `space.yaml`. Idempotent guard: refuses if `ARCHITECT.md` already exists.

```sh
architect init
architect init 20260531-name-of-space
```

### `architect install-skills [--provider=PROVIDER] [--project] [--force]`

Install the bundled skills (`architect`, `architect-research`, and `architect-vocabulary`) for a harness. Run this once per machine after installing the gem, or after upgrading to pick up skill changes.

```sh
architect install-skills                              # claude (default) → ~/.claude/skills/
architect install-skills --provider opencode           # → ~/.config/opencode/skills/
architect install-skills --provider codex              # → ~/.agents/skills/
architect install-skills --provider pi                 # → ~/.pi/agent/skills/
architect install-skills --project                     # install to ./.claude/skills/ instead of global
architect install-skills --force                       # overwrite existing skills that differ
architect install-skills --dry-run                      # print what would happen without writing
```

| Option | Default | Description |
|--------|---------|-------------|
| `--provider=VALUE` | `claude` | Harness: `claude`, `codex`, `opencode`, `pi`. |
| `--project` | `false` | Install to the current working directory instead of global. |
| `--force` | `false` | Overwrite existing skills that differ from the bundled source. |
| `--dry-run` | `false` | Print what would happen without writing any files. |

Provider destination paths:

| Provider | Global | `--project` |
|----------|--------|-------------|
| `claude` | `~/.claude/skills/` | `./.claude/skills/` |
| `codex` | `~/.agents/skills/` | `./.agents/skills/` |
| `opencode` | `~/.config/opencode/skills/` | `./.opencode/skills/` |
| `pi` | `~/.pi/agent/skills/` (or `$PI_CODING_AGENT_DIR/skills/`) | `./.pi/skills/` |

### `architect new ITERATION [SPACE]`

Scaffold the next iteration file at `architecture/I<NN>-<ITERATION>.md` from the iteration template. Allocates the next ordinal and records the iteration in `space.yaml`.

```sh
architect new dry-cli-port
architect new dispatch-engine 20260531-name-of-space
```

### `architect status [SPACE]`

Show the Architect Loop project state: current iteration, the iteration index table (ordinal, freeze SHA, lanes, verdict), and iteration files. Read-only.

```sh
architect status
architect status 20260531-name-of-space
```

### `architect freeze ITERATION [SPACE]`

Commit the iteration file (Grounds + Specification + Acceptance Criteria must be present) and record its SHA as `freeze_sha` in `space.yaml`. Refuses to re-freeze once the frozen sections have changed.

```sh
architect freeze dry-cli-port
architect freeze dry-cli-port 20260531-name-of-space
```

### `architect verify ITERATION [SPACE]`

Post-flight mechanical checks for an iteration — reports only, no judgment. Per lane: (a) frozen sections untouched since freeze, (b) builder made no commits in the worktree, (c) the builder's scratch report `build/<id>-<lane>/report.md` exists, (d) builder stayed in-bounds per the lane's declared touch set.

```sh
architect verify dry-cli-port
architect verify dry-cli-port 20260531-name-of-space
```

### `architect dispatch ITERATION LANE [SPACE]`

Dispatch a builder for a lane: runs `claude -p` headless and streams the full conversation to `build/<id>-<lane>/run.jsonl`.

```sh
architect dispatch dry-cli-port lane-a
architect dispatch dispatch-engine lane-b 20260531-name-of-space --model claude-opus-4-8
architect dispatch dry-cli-port lane-a --max-turns 100
```

| Option | Default | Description |
|--------|---------|-------------|
| `--model=VALUE` | `claude-sonnet-4-6` | Model for the builder. |
| `--max-turns=VALUE` | `200` | Max conversation turns. |

### `architect worktree [SUBCOMMAND]`

Manage per-lane git worktrees under `build/`.

```sh
architect worktree add my-app dry-cli-port lane-a
architect worktree add my-app dry-cli-port lane-a --base main
architect worktree list
architect worktree remove dry-cli-port lane-a
```

| Command | Description |
|---------|-------------|
| `worktree add REPO ITERATION LANE [--base REF]` | Create a worktree at `build/<id>-<lane>/wt` off the repo's base commit (default: `HEAD`). |
| `worktree list` | List active architect worktree directories. |
| `worktree remove ITERATION LANE` | Remove the lane worktree. |

## Space management: `architect space …` 🗂️

Manage project spaces. These commands are also accessible via the `space` shim (e.g., `space new "Title"` → `architect space new "Title"`).

### `architect space init`

Create the default XDG config and state files.

```sh
architect space init
```

### `architect space new TITLE [REPOS]`

Create a new space. The id is date-prefixed and slugged from the title (`"Name of Space"` → `20260531-name-of-space`); duplicate names on the same day get a counter (`...-name-of-space-2`). Optionally clone repos into the new space immediately.

```sh
architect space new "Name of Space"
architect space new "Name of Space" example-tools/alpha example-tools/beta
architect space new "Name of Space" --no-git   # skip git init
```

| Option | Description |
|--------|-------------|
| `--[no-]git` | Initialize the space as a Git repository (default: `--git`). |

### `architect space list` (alias `architect space ls`)

List all spaces, compact and human-readable.

```sh
architect space list
architect space ls --color=always
```

### `architect space show [IDENTIFIER]`

Show metadata for a space, or the current space when no id is given.

```sh
architect space show
architect space show 20260531-name-of-space
```

### `architect space path [IDENTIFIER]`

Print *only* the path for a space (handy for scripting).

```sh
architect space path
architect space path 20260531-name-of-space
```

### `architect space use IDENTIFIER`

Record a space in recent state and print its path.

```sh
architect space use 20260531-name-of-space
```

### `architect space current`

Show the current space, resolved from `$PWD`.

```sh
architect space current
```

### `architect space status [SPACE] STATUS`

Set a space's status. Supported statuses: `active`, `paused`, `done`, `archived`.

```sh
architect space status done                              # current space
architect space status 20260531-name-of-space archived
```

### `architect space config [SUBCOMMAND]`

Show or update configuration.

```sh
architect space config show
architect space config path
architect space config set default_provider github.com
architect space config set default_organization example-org
architect space config set git_clone_protocol https
architect space config set evergreen_dir ""              # disable evergreen copies
```

Config lives at `~/.config/space-architect/config.yml` (XDG-aware):

```yaml
version: 1
spaces_dir: ~/src/spaces
evergreen_dir: ~/src/evergreen
default_provider: github.com
default_organization:
git_clone_protocol: ssh
```

### `architect space repo [SUBCOMMAND]` (alias `architect space repos`)

Manage repos in the current space.

```sh
architect space repo add example-app
architect space repo add example-tools/alpha example-tools/beta
architect space repo add gitlab.com/example-org/api
architect space repo list            # alias: ls
architect space repo resolve example-app example-tools/async
```

- **add** — clone (or copy-on-write from `evergreen_dir`) repos into `repos/`, concurrently up to five at a time.
- **list** / **ls** — list repos tracked in the current space.
- **resolve** — print the resolved full name and clone URL without cloning.

### `architect space shell [SUBCOMMAND]`

Manage shell integration. Only `fish` is supported today.

```sh
architect space shell init fish              # print the fish function to stdout
architect space shell fish install           # install function + completions
architect space shell fish install --force   # overwrite existing files
architect space shell fish uninstall
architect space shell fish path              # print install paths
architect space shell complete spaces        # print completion candidates
```

## Evergreen engine: `architect src …` 🌲

The evergreen engine (`space-src`, exposed as `src`) keeps canonical copies of tracked repos in sync so spaces can clone via fast APFS copy-on-write. Run `architect src --help` to list available subcommands.

> **Note:** these commands appear under `architect src <verb>` but are not listed in root `architect --help`. Discover them via `architect src --help`.

### `architect src clone NAMES`

Clone evergreen repo(s) into a working directory via APFS COW copy.

```sh
architect src clone example-app
architect src clone example-tools/alpha example-tools/beta
architect src clone github.com/example-org/api --into ~/work
```

| Option | Description |
|--------|-------------|
| `--into=DIR` | Destination parent directory (default: `$PWD`). |
| `--json` | JSON output (one object per event line). |
| `--plain` | Plain text output, no color. |
| `--quiet, -q` | Suppress non-essential output. |

### `architect src sync`

Run one sync pass — fetch + fast-forward all tracked repos.

```sh
architect src sync
architect src sync --repo github.com/example-org/api   # scope to one repo
```

### `architect src status`

Show the per-repo evergreen status table (source: `$XDG_STATE_HOME/space-src/state.yaml`).

```sh
architect src status
```

### `architect src repo [SUBCOMMAND]`

Manage tracked repos in the evergreen store.

```sh
architect src repo add example-org/api
architect src repo list
architect src repo remove example-org/api
```

### `architect src org [SUBCOMMAND]`

Manage tracked orgs (all repos under an org are synced automatically).

```sh
architect src org add github.com/example-org
architect src org list
architect src org remove github.com/example-org
```

### `architect src config [SUBCOMMAND]`

Show or locate the evergreen engine config (separate from space config).

```sh
architect src config show
architect src config path
```

### `architect src daemon [SUBCOMMAND]`

Manage the per-user launchd sync agent (macOS).

```sh
architect src daemon install
architect src daemon start
architect src daemon stop
architect src daemon restart
architect src daemon status
architect src daemon uninstall
```

## Exit codes 🚦

`architect` exits non-zero on failure — unknown space, ambiguous id, refusing to overwrite an existing file without `--force`, and so on — with a clear message on stderr.
