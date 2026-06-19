# Command Reference 📖

Every `space-cadet` command, flag, and behavior. The executable is `space`. 🚀

## Global options 🎨

These work on any command:

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `--color` | `auto` `always` `never` | `auto` | Color output. `--colors` is accepted too. |

Color defaults to auto-detection: colorized when stdout is a TTY, plain
otherwise. Paths under your home directory are displayed as `~/...` in
human-oriented output.

## Space resolution 🧭

Commands that take an optional `[SPACE]` resolve it in this order:

1. An explicit id passed on the command line (`space show 20260531-name-of-space`).
2. Otherwise, the nearest parent directory of `$PWD` containing a `.space.yml`.

Being *inside* a space is what makes it current — `space use` records recent
state and prints a path, but it never overrides `$PWD`-based resolution.

## Commands 🛰️

### `space init`

Create the default XDG config and state files.

```sh
space init
space init --force      # overwrite existing config and state files
```

### `space new TITLE`

Create a new space. The id is date-prefixed and slugged from the title
(`"Name of Space"` → `20260531-name-of-space`); duplicate names on the same day
get a counter (`...-name-of-space-2`).

```sh
space new "Name of Space"
space new "Name of Space" -r example-tools/alpha -r example-tools/beta
```

| Option | Description |
|--------|-------------|
| `-r`, `--repo` | Clone a repo into the new space. Repeatable. |

With fish integration installed, `space new` also `cd`s you into the new space.

### `space list` (alias `space ls`)

List all spaces, compact and human-readable.

```sh
space list
space ls --color=always
```

### `space show [SPACE]`

Show metadata for a space, or the current space when no id is given.

```sh
space show
space show 20260531-name-of-space
```

### `space path [SPACE]`

Print *only* the path for a space (handy for scripting and `cd`).

```sh
space path
space path 20260531-name-of-space
cd (space path 20260531-name-of-space)   # fish
```

### `space use SPACE`

Record a space in recent state and print its path. With fish integration, also
`cd`s into it.

```sh
space use 20260531-name-of-space
```

### `space current`

Show the current space, resolved from `$PWD`.

```sh
space current
```

### `space status [SPACE] STATUS`

Set a space's status. Supported statuses: `active`, `paused`, `done`,
`archived`.

```sh
space status done                            # current space
space status 20260531-name-of-space archived
```

### `space config [SUBCOMMAND]`

Show or update configuration.

```sh
space config show
space config path
space config set default_provider github.com
space config set default_organization example-org
space config set git_clone_protocol https
space config set evergreen_dir ""            # disable evergreen copies
```

Config lives at `~/.config/space-cadet/config.yml` (XDG-aware):

```yaml
version: 1
spaces_dir: ~/src/spaces
evergreen_dir: ~/src/evergreen
default_provider: github.com
default_organization:
git_clone_protocol: ssh
```

### `space repo SUBCOMMAND` (alias `space repos`)

Manage repos in the current space.

```sh
space repo add example-app                       # github.com/<default_org>/example-app
space repo add example-tools/alpha example-tools/beta
space repo add gitlab.com/example-org/api
space repo list                                  # alias: ls
space repo resolve example-app example-tools/async
```

- **add** — clone (or copy-on-write from `evergreen_dir`) repos into `repos/`,
  concurrently, up to five at a time, then run `mise trust`.
- **list** / **ls** — list repos tracked in the current space.
- **resolve** — print the resolved full name and clone URL without cloning.

### `space shell SUBCOMMAND`

Manage shell integration. Only `fish` is supported today.

```sh
space shell init fish              # print the fish function to stdout
space shell fish install           # install function + completions
space shell fish install --force   # overwrite existing files
space shell fish uninstall
space shell fish path              # print install paths
space shell complete spaces        # print completion candidates
```

The fish function installs to `~/.config/fish/functions/space.fish` and
completions to `~/.config/fish/completions/space.fish`. Restart fish (or
`exec fish`) to pick them up.

### `space architect SUBCOMMAND`

Manage an Architect Loop mission inside the current space. The mission memory is
one self-contained file per slice at `artifacts/<NN>-<slice>.md` (sections:
Grounds / Contract / Rubric / Builder Prompt / Builder Report / Verdict), indexed
by `artifacts/HANDOFF.md`. Mission state (slices, freeze SHAs, lanes, verdicts)
lives in an `architect:` block in `.space.yml`. Scratch (worktrees, lane-prompts,
builder reports) lives under `tmp/architect/` (gitignored).

```sh
space architect init                         # scaffold artifacts/HANDOFF.md + .space.yml block; commits
space architect new dry-cli-port             # scaffold artifacts/01-dry-cli-port.md (next ordinal)
space architect status                       # read-only mission state
space architect freeze dry-cli-port          # commit the slice file; record freeze_sha
space architect worktree add my-app s1 lane-a --base HEAD
space architect worktree list
space architect worktree remove s1 lane-a
space architect verify dry-cli-port          # per-lane mechanical checks (reports only)
```

| Command | Description |
|---------|-------------|
| `architect init [SPACE]` | Scaffold `artifacts/HANDOFF.md` and add the `architect:` block to `.space.yml`; commits. Idempotent guard: refuses if `HANDOFF.md` exists. |
| `architect new SLICE [SPACE]` | Allocate the next ordinal and scaffold `artifacts/<NN>-<SLICE>.md` from the slice template; record the slice; commits. |
| `architect status [SPACE]` | Print mission status, current slice, the slice table (NN, freeze SHA, lanes, verdict), and slice files. Read-only. |
| `architect freeze SLICE [SPACE]` | Commit the slice file (which must carry a `## Rubric` section) and record its SHA as `freeze_sha`. Refuses to re-freeze once a **frozen section** (anything above `## Builder Prompt`) has changed. |
| `architect worktree add REPO SLICE LANE [--base REF]` | Create a worktree at `tmp/architect/wt/<SLICE>-<LANE>` off the repo's base commit (default `HEAD`); record the lane in `.space.yml`. |
| `architect worktree remove SLICE LANE` | Remove the lane worktree and drop it from `.space.yml`. |
| `architect worktree list` | List active lane worktree directories. |
| `architect verify SLICE [SPACE]` | Report per lane (PASS/FAIL/N/A, no judgment): (a) frozen sections untouched since freeze, (b) no builder commits in the worktree, (c) the builder's scratch report `tmp/architect/<SLICE>-<LANE>.report.md` exists, (d) in-bounds vs the lane's touch set. |

The `architect:` block survives unrelated `space` commands that rewrite
`.space.yml`. The builder never writes under `artifacts/` — it writes a scratch
report which the architect transcribes into the slice's Builder Report section,
keeping the frozen Rubric out of the builder's editable blast radius.

## Exit codes 🚦

`space` exits non-zero on failure (unknown space, ambiguous id, refusing to
overwrite an existing file without `--force`, and so on) with a clear message on
stderr.
