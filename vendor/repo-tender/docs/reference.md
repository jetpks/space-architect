# Reference 📘

Everything `repo-tender` can do, in detail — commands, configuration, state,
files, and exit codes. The [README](../README.md) is the friendly tour 🌲; this
is the lookup table. 🔎

Version: 0.1.0.

## Synopsis

```
repo-tender <command> [subcommand] [arguments] [options]
```

| Command | Purpose |
|---------|---------|
| [`repo`](#repo) | Add / remove / list individually tracked repos |
| [`org`](#org) | Add / remove / list tracked GitHub orgs |
| [`sync`](#sync) | Run one sync pass |
| [`status`](#status) | Print the per-repo evergreen status table |
| [`clone`](#clone) | Copy-on-write copy of mirror(s) into a working dir |
| [`config`](#config) | Show the config path or effective config |
| [`daemon`](#daemon) | Manage the launchd scheduled job |

Top-level forms that print and exit 0: `repo-tender`, `--help`, `-h`, `help`
(usage); `version`, `--version` (the version string).

## Global options

Accepted by every command — they select the output mode.

| Option | Effect |
|--------|--------|
| `--plain` | Plain text: one line per event, no color. |
| `--json` | JSON: one object per event line (12-factor friendly). |
| `--no-color` | Disable ANSI color (text stays human-formatted). |
| `--quiet`, `-q` | Suppress non-essential output. |
| `--help`, `-h` | Print command help and exit 0. |

See [Output modes](#output-modes) for resolution rules.

## Commands

### `repo`

Manage individually tracked repos. Backed by `config.yaml` (the source of
truth). A repo is identified by the triple `(host, owner, name)`; its clone URL
and on-disk path are *derived*, never stored.

| Subcommand | Argument | Description |
|------------|----------|-------------|
| `repo add REF` | `REF` = `host/owner/name` | Add a tracked repo. Idempotent on the triple. |
| `repo remove REF` | `REF` = `host/owner/name` | Remove a tracked repo. |
| `repo list` | — | List tracked repos, one `host/owner/name` per line. |

**`REF` format.** Exactly three slash-separated parts: `github.com/ruby/ruby`.
A ref with any other number of parts, or an empty part, is rejected:

```
invalid repo reference: "socketry/async" (expected host/owner/name)
```

**Behaviour notes.**

- `add` of an already-tracked repo prints `already tracked: <ref>` and exits 0
  (no duplicate written).
- `remove` of an untracked repo prints `not tracked: <ref>` and exits 1; the
  config is left unchanged.
- The config is validated before every write.

### `org`

Manage tracked GitHub orgs. An org is expanded into its member repos at sync
time via `gh`. An org is identified by `(host, name)`.

| Subcommand | Argument | Description |
|------------|----------|-------------|
| `org add NAME` | `NAME` = `name` or `host/name` | Add a tracked org. Idempotent on `(host, name)`. |
| `org remove NAME` | `NAME` = `name` or `host/name` | Remove a tracked org. |
| `org list` | — | List tracked orgs. |

**`NAME` format.** Either a bare name (`socketry`, host defaults to
`github.com`) or `host/name` (`github.com/socketry`). Three-or-more parts are
rejected:

```
invalid org reference: "a/b/c" (expected "<name>" or "<host>/<name>")
```

**`org add` options.**

| Option | Description |
|--------|-------------|
| `--include-archived` | Include archived repos when expanding the org (default `false`). |
| `--include-forks` | Include forks when expanding the org (default `false`). |
| `--ignored-repos=a,b` | Repos to exclude from expansion — bare `name` or `owner/name`, comma-separated. |

All three persist onto the org entry in `config.yaml` and can equally be set by
hand-editing it. The `ignored_repos` filter is **authoritative** at expansion
time: a listed repo is dropped before it ever reaches a sync sweep, matched by
either its bare `name` or its full `owner/name`.

**Repeated vs. comma form.** Use the comma form (`--ignored-repos a,b`) for
multiple values. The repeated form (`--ignored-repos a --ignored-repos b`) does
**not** accumulate — the underlying CLI parser keeps the last value only (a
`dry-cli` array-option behavior, not specific to this flag).

**Changing an existing org.** `org add` is idempotent on `(host, name)` and does
not mutate an already-tracked org's options — to change flags or the ignore
list, `org remove` then `org add` with the new options.

### `sync`

Run one sync pass over every tracked repo (explicit + org-expanded).

| Option | Description |
|--------|-------------|
| `--repo=VALUE` | Scope the pass to a single tracked repo (`host/owner/name`). |
| *(global options)* | `--plain`, `--json`, `--no-color`, `--quiet`/`-q`. |

**What a pass does, per repo** (local-first; see the README's
[How it works](../README.md)):

- **Missing** path → `git clone` into `$BASE_DIR/host/owner/name`.
- **Clean + behind** → `git fetch` then `git merge --ff-only`.
- **Fresh** (FETCH_HEAD younger than `refresh_interval`) → skipped, no network.
- **Dirty / diverged / detached / wrong branch** → recorded, left untouched.

Work fans out concurrently up to `concurrency`. One repo's failure does not
abort the run; it's recorded in state. Results are written to `state.yaml`.

### `status`

Print the per-repo evergreen status table from `state.yaml`. Reads state only —
**no network, no git invocation.** If state is empty:

```
(no repos in state — run `repo-tender sync` to populate)
```

Otherwise a tab-separated table, rows sorted by repo key:

| Column | Meaning |
|--------|---------|
| `REPO` | `host/owner/name` |
| `STATUS` | One of the [status values](#status-values) (colorized) |
| `DEFAULT_BRANCH` | Default branch resolved from the remote |
| `LAST_SYNCED_AT` | ISO-8601 timestamp of last sync, or empty |
| `LAST_FETCH_AT` | ISO-8601 timestamp of last fetch, or empty |

### `clone`

Make a copy-on-write copy of one or more evergreen mirrors into a working
directory, using macOS APFS clonefile (`cp -Rc`) — near-instant, near-zero disk.

```
repo-tender clone NAME... [--into DIR]
```

| Argument / Option | Description |
|-------------------|-------------|
| `NAME...` | One or more repo names to copy (variadic). |
| `--into=DIR` | Destination **parent** directory (default `.`). Each repo lands at `<DIR>/<name>`. |

**`NAME` resolution** (against `config.base_dir`, layout `$BASE/host/owner/name`):

- bare `name` → the single `$BASE/*/*/name` match; **ambiguous** (more than one
  owner) → `Failure` listing the candidates, nothing copied.
- `owner/name` → `$BASE/*/owner/name`.
- `host/owner/name` → exact path.
- no match → `Failure` ("not found under base_dir …"), nothing copied.

**Behaviour notes.**

- **No-clobber (no-data-loss):** if `<into>/<name>` already exists, the copy is
  refused with a `Failure` and the existing directory is left byte-for-byte
  untouched. `clone` never overwrites.
- Each name resolves and copies independently; one bad name is reported on
  `stderr` and does not abort the others.
- Exit code is `1` if **any** name failed, else `0`.
- macOS-only (APFS clonefile); consistent with the project's platform scope.

### `config`

| Subcommand | Description |
|------------|-------------|
| `config path` | Print the resolved `config.yaml` path (honors `$XDG_CONFIG_HOME`). |
| `config show` | Print the effective (validated, defaults-applied) config as YAML. |

`config show` reflects defaults and normalization — e.g. `refresh_interval: 6h`
appears as `21600`.

### `daemon`

Manage the per-user launchd agent (label `io.github.jetpks.repo-tender.sync`).
The plist is written to `~/Library/LaunchAgents/<label>.plist`.

| Subcommand | launchctl mapping |
|------------|-------------------|
| `daemon install` | Write the plist + `bootstrap gui/$UID <plist>`. |
| `daemon uninstall` | `bootout gui/$UID/<label>` + remove the plist (idempotent). |
| `daemon start` | `bootstrap` + enable. |
| `daemon stop` | `bootout` / disable. |
| `daemon restart` | `kickstart -k` (run now). |
| `daemon status` | Parse `launchctl print`/`list` (loaded? running? last exit) + show last-run state. |

See [launchd plist](#launchd-plist) for the generated job's shape.

## Configuration

### `config.yaml`

Durable user intent. Location: `$XDG_CONFIG_HOME/repo-tender/config.yaml`
(default `~/.config/repo-tender/config.yaml`). Hand-editable; also rewritten by
`repo`/`org` CRUD. Validated on every load and before every write.

```yaml
base_dir: ~/src/evergreen          # default if absent
refresh_interval: 6h               # see below; default 6h
concurrency: 8                     # max parallel git/gh ops per run; default 8
repos:
  - owner: ruby                    # host omitted ⇒ github.com
    name: ruby
orgs:
  - name: socketry                 # host omitted ⇒ github.com
    include_forks: true            # only non-default flags are written
    ignored_repos:                 # excluded from expansion (bare name or owner/name)
      - async
```

The writer emits **clean YAML**: string keys (no `:symbol:` prefixes), and it
**omits anything at its default** — a `host` of `github.com`, an
`include_archived`/`include_forks` of `false`, and an empty `ignored_repos`.
Dropping defaults on write is lossless: `load` re-applies them, so the round
trip reproduces an equal config. You may still write any field explicitly by
hand.

| Key | Type | Default | Notes |
|-----|------|---------|-------|
| `base_dir` | path | `~/src/evergreen` | Root of the on-disk clone tree. |
| `refresh_interval` | duration | `6h` (`21600`) | Freshness window; see [Duration format](#duration-format). |
| `concurrency` | integer > 0 | `8` | Max concurrent git/gh operations per run. |
| `repos[]` | list | `[]` | Each: `host` (default `github.com`), `owner`, `name`. |
| `orgs[]` | list | `[]` | Each: `host` (default `github.com`), `name`, `include_archived` (default `false`), `include_forks` (default `false`), `ignored_repos` (default `[]`; array of `name` or `owner/name` to exclude from expansion). |

Validation rejects missing required fields, a non-positive/unparseable
`refresh_interval`, a non-integer `concurrency`, and malformed repo/org entries —
each with a field-level message. Comments and unknown keys are **not preserved**
across a machine rewrite (the reason config and [state](#stateyaml) are split).

#### Duration format

`refresh_interval` accepts an integer (seconds) or a `<n><unit>` string, where
unit is one of:

| Unit | Meaning | Example | Seconds |
|------|---------|---------|---------|
| *(none)* | seconds | `21600` | 21600 |
| `s` | seconds | `45s` | 45 |
| `m` | minutes | `90m` | 5400 |
| `h` | hours | `6h` | 21600 |
| `d` | days | `30d` | 2592000 |

Must be strictly positive. The human form is normalized to integer seconds on
load and emitted as seconds on write-back.

### `state.yaml`

Machine-managed; **never hand-edit.** Location:
`$XDG_STATE_HOME/repo-tender/state.yaml` (default
`~/.local/state/repo-tender/state.yaml`). Rewritten by every sync.

```yaml
repos:
  github.com/ruby/ruby:
    default_branch: trunk
    last_fetch_at: 2026-06-12T20:01:33Z
    last_synced_at: 2026-06-12T20:01:34Z
    status: clean
    last_error: null
orgs:
  github.com/socketry:
    last_listed_at: 2026-06-12T20:00:10Z
    repo_count: 41
```

Org-discovered repos are recorded here (state), not in `config.yaml`, so the
user's config stays stable.

### Status values

The `status` field per repo (and the `STATUS` column):

| Value | Meaning | Action taken |
|-------|---------|--------------|
| `clean` | On default branch, no local changes, fresh. | None needed. |
| `dirty` | Uncommitted changes present. | **Reported, never touched.** |
| `diverged` | Local commits the remote lacks. | **Reported, never reset.** |
| `detached` | HEAD is detached. | Reported. |
| `wrong_branch` | On a non-default branch. | Reported; a *clean* tree may be switched back, a dirty tree is left. |
| `missing` | Path not present on disk. | Cloned. |
| `error` | An operation failed (see `last_error`). | Recorded; run continues. |

## Files & locations

| Path | What |
|------|------|
| `$XDG_CONFIG_HOME/repo-tender/config.yaml` | Config (default `~/.config/...`). |
| `$XDG_STATE_HOME/repo-tender/state.yaml` | State (default `~/.local/state/...`). |
| `$XDG_STATE_HOME/repo-tender/logs/` | Sync logs (rotated by the process itself). |
| `$BASE_DIR/host/owner/name/` | An evergreen clone (e.g. `~/src/evergreen/github.com/ruby/ruby`). |
| `~/Library/LaunchAgents/io.github.jetpks.repo-tender.sync.plist` | The scheduled job. |

XDG overrides (`$XDG_CONFIG_HOME`, `$XDG_STATE_HOME`) are honored when set.

## launchd plist

`daemon install` generates a fixed-shape plist:

| Key | Value |
|-----|-------|
| `Label` | `io.github.jetpks.repo-tender.sync` |
| `ProgramArguments` | `[<mise>, exec, --, <ruby>, <abs bin/repo-tender>, sync]` |
| `WorkingDirectory` | Absolute repo root (so mise finds `mise.toml`). |
| `EnvironmentVariables` | `MISE_CONFIG_FILE = <abs mise.toml>` |
| `StartInterval` | `refresh_interval` in seconds. |
| `RunAtLoad` | `true` |
| `ProcessType` | `Background` |
| `StandardOutPath` / `StandardErrorPath` | Absolute logs under the log dir. |

No `KeepAlive` — this is a periodic job, not a resident daemon. All paths are
absolute (`~`/`$HOME` resolved). Ruby runs via `mise exec` (not `mise activate`,
which is broken non-interactively). The plist validates under `plutil -lint`.

## Output modes

The active mode is resolved per command from flags, environment, and whether
stdout is a TTY:

- **Interactive** (default on a TTY): live status line + colorized summary.
- **Plain** (`--plain`, or non-TTY): one line per event, no color.
- **JSON** (`--json`): one JSON object per event line.
- `--no-color` forces color off; color is also off automatically when stdout is
  not a TTY.
- `--quiet`/`-q` suppresses non-essential output.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success. |
| `1` | A `Failure` occurred (message on stderr). |
| `130` | Interrupted by `SIGINT` (`^C`); prints `interrupted` on stderr. |

## See also

- [README](../README.md) 🌲 — the friendly tour
- [`AGENTS.md`](../AGENTS.md) 🤝 — build conventions and toolchain
- [`docs/prd/repo-tender.md`](prd/repo-tender.md) 🏗️ — full design (PRD)
- [`docs/research/repo-tender.md`](research/repo-tender.md) 🔬 — evidence ledger
