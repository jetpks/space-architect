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

## Exit codes 🚦

`space` exits non-zero on failure (unknown space, ambiguous id, refusing to
overwrite an existing file without `--force`, and so on) with a clear message on
stderr.
