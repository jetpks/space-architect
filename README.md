# repo-tender

> Keep your local git clones **evergreen** — clean, on their default branch, and
> recently fetched — so another tool can clone them from your local disk
> instantly instead of over the network.

`repo-tender` is a small Ruby CLI plus a periodic [launchd] job. You tell it
which repos and GitHub orgs you care about; on a schedule it fetches and
fast-forwards the ones it safely can, clones the ones that are missing, and
**reports — never touches —** anything dirty or diverged. macOS-only,
GitHub-only (both behind decoupled interfaces).

[launchd]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html

---

## How this documentation is organized

This README follows the [Diátaxis framework](https://diataxis.fr/) — four
distinct kinds of documentation, kept separate on purpose:

- **[Tutorial](#tutorial-get-your-first-repo-evergreen)** — a guided lesson to
  go from nothing to a synced clone. Start here if you're new.
- **[How-to guides](#how-to-guides)** — short recipes for specific goals
  ("track a whole org", "schedule automatic syncs").
- **[Reference](docs/reference.md)** — the dry, complete catalogue of every
  command, flag, config key, and status value.
- **[Explanation](#explanation)** — the *why* behind the design: the evergreen
  invariant, the no-data-loss rule, why a launchd job instead of a daemon.

---

## Requirements

| Tool | Version | Why |
|------|---------|-----|
| macOS | — | launchd scheduling, `~/Library/LaunchAgents` |
| [mise] | 2026.6+ | pins and provides Ruby |
| Ruby | 4.0.5 | runtime (pinned in `mise.toml`) |
| git | 2.54+ | the only SCM |
| [gh] | 2.93+ | GitHub org listing (must be authenticated) |

[mise]: https://mise.jdx.dev/
[gh]: https://cli.github.com/

## Installation

Not published to RubyGems — install from source:

```bash
git clone git@github.com:jetpks/repo-tender.git
cd repo-tender
mise install        # installs Ruby 4.0.5 per mise.toml
bundle install
bin/repo-tender --help
```

Confirm `gh` is authenticated (org listing falls back to an anonymous 60
req/hour limit otherwise):

```bash
gh auth status
```

For convenience you can put `bin/repo-tender` on your `PATH`, or alias it.
Every example below uses `bin/repo-tender`; substitute `repo-tender` if you've
aliased it.

---

## Tutorial: get your first repo evergreen

This walks you from a fresh checkout to a fully synced local clone. It takes a
couple of minutes. Follow it in order — every step builds on the last.

### 1. Decide where your evergreen clones should live

repo-tender keeps every clone under one `base_dir`, laid out as
`base_dir/host/owner/name`. Pick wherever *you* want that tree to live. e.g. `~/code`, `~/src`, or `~/Documents/repos`. If unspecified, `repo-tender` will store repos in `~/src/evergreen`

Find your config file:

```bash
bin/repo-tender config path
# → /Users/you/.config/repo-tender/config.yaml
```

Create that file (the directory may not exist yet — `mkdir -p` its parent) with
your chosen base:

```yaml
base_dir: ~/code/evergreen   # ← your choice
```

The rest of this tutorial assumes `~/code/evergreen`; substitute your own path
throughout.

### 2. Track a small repo

We'll track [`dry-rb/dry-monads`](https://github.com/dry-rb/dry-monads) — small
and quick to clone. Repos are named `host/owner/name`:

```bash
bin/repo-tender repo add github.com/dry-rb/dry-monads
# → added: github.com/dry-rb/dry-monads
```

Confirm it's tracked:

```bash
bin/repo-tender repo list
# → github.com/dry-rb/dry-monads
```

### 3. Run your first sync

```bash
bin/repo-tender sync
```

repo-tender sees the repo is missing on disk and clones it to
`~/code/evergreen/github.com/dry-rb/dry-monads` (under whatever `base_dir` you
chose). You'll watch the live status line, then an end-of-run summary.

### 4. Check the status

```bash
bin/repo-tender status
```

```
REPO                            STATUS  DEFAULT_BRANCH  LAST_SYNCED_AT        LAST_FETCH_AT
github.com/dry-rb/dry-monads    clean   main            2026-06-14T20:01:34Z  2026-06-14T20:01:33Z
```

`clean` means the clone is exactly as it should be: on the default branch, no
local changes, freshly fetched.

### 5. Run sync again

```bash
bin/repo-tender sync
```

This time nothing happens over the network — the clone was fetched moments ago,
well within the 6-hour `refresh_interval`, so repo-tender skips it entirely.
Syncs are cheap and idempotent by design.

**You've now got an evergreen clone** in the location you chose. From here, the
[how-to guides](#how-to-guides) show you how to track whole orgs and put syncing
on a schedule.

---

## How-to guides

Task-focused recipes. Each is independent — jump to the one you need.

### Track a single repo

```bash
bin/repo-tender repo add github.com/ruby/ruby
bin/repo-tender repo list
bin/repo-tender repo remove github.com/ruby/ruby
```

Repos are always `host/owner/name`. Re-adding the same repo is idempotent (it
won't duplicate). See [`repo`](docs/reference.md#repo).

### Track a whole GitHub org

Orgs are expanded to their member repos at sync time via `gh`:

```bash
bin/repo-tender org add socketry              # host defaults to github.com
bin/repo-tender org add github.com/socketry   # equivalent, explicit host
bin/repo-tender org list
```

By default archived repos and forks are excluded. To change that, edit the org
entry in `config.yaml` and set `include_archived: true` / `include_forks: true`.
See [`org`](docs/reference.md#org) and [the config schema](docs/reference.md#configyaml).

### Sync everything now

```bash
bin/repo-tender sync
```

Clones missing repos, fast-forwards clean-and-behind ones, and reports
dirty/diverged ones without touching them.

### Sync just one repo

```bash
bin/repo-tender sync --repo github.com/ruby/ruby
```

### Check the status of every tracked repo

```bash
bin/repo-tender status
```

Reads the last-known state (it does **not** hit the network). The `STATUS`
column tells you which repos need your attention — see
[status values](docs/reference.md#status-values).

### Change the refresh interval, base directory, or concurrency

Edit `config.yaml` (find it with `bin/repo-tender config path`):

```yaml
base_dir: ~/src/evergreen   # where clones live
refresh_interval: 90m       # "6h", "90m", "45s", "30d", or integer seconds
concurrency: 8              # max parallel git/gh operations per run
```

Validate the result and see the effective, defaults-applied config:

```bash
bin/repo-tender config show
```

### Schedule automatic syncs

Install a per-user launchd agent that runs `sync` every `refresh_interval`:

```bash
bin/repo-tender daemon install
bin/repo-tender daemon status
```

`install` writes a plist to `~/Library/LaunchAgents/` and bootstraps it. From
then on macOS runs your syncs in the background. To stop and remove it:

```bash
bin/repo-tender daemon stop
bin/repo-tender daemon uninstall
```

See [`daemon`](docs/reference.md#daemon) for `start`, `restart`, and what each
verb maps to in `launchctl`.

### Get machine-readable output

For scripts, pipelines, or 12-factor logging:

```bash
bin/repo-tender sync --json      # one JSON object per event line
bin/repo-tender sync --plain     # one plain line per event, no color
bin/repo-tender status --json
```

`--no-color` and `--quiet`/`-q` are also available on every command. When output
isn't a TTY, color is disabled automatically. See
[output modes](docs/reference.md#output-modes).

---

## Explanation

Background and design rationale. Read this to understand *why* repo-tender
behaves the way it does — none of it is needed to use the tool.

### What "evergreen" means

A repo is **evergreen** when all three hold:

- **Clean** — no modified, staged, untracked, or deleted files.
- **On the default branch** — HEAD is the remote's default branch, *whatever
  it's named*. repo-tender resolves this from the remote (e.g. `trunk`,
  `master`, `main`); it never assumes `main`.
- **Fresh** — the default branch is up to date with the remote, fetched within
  `refresh_interval` (default 6 hours).

The point is that some *other* tool — e.g. a tool that makes ephemeral
workspaces — can then clone any of these from your local filesystem instantly
instead of pulling them over the network. repo-tender's whole job is to keep
that local mirror current and trustworthy.

### The cardinal rule: never lose your work

repo-tender will **never** mutate a dirty or diverged repo. If a clone has local
changes, local commits the remote doesn't have, a detached HEAD, or a checked-out
non-default branch, repo-tender records the situation in its status and *leaves
the working tree byte-for-byte untouched*. There is no `reset --hard`, no
stashing, no force-switching a dirty tree. It only ever fast-forwards a clean
repo that is strictly behind its remote.

This is the invariant the entire design protects. A periodic background job that
could silently destroy uncommitted work would be worse than useless.

### Config versus state — why two files

- **`config.yaml`** is *your* durable intent: the repos and orgs you chose, your
  base dir and intervals. You edit it (directly or via the CLI). It changes only
  when you change it.
- **`state.yaml`** is *machine-managed*: per-repo status, last-fetch times,
  default branches resolved from remotes, org-expansion results. repo-tender
  rewrites it constantly; you never hand-edit it.

Keeping them separate means machine rewrites never churn or clobber your
hand-authored config (YAML comment loss on rewrite is real — so the file that
gets rewritten holds nothing you wrote). It's also why org-discovered repos live
in state, not config: expanding `socketry` into 40 repos shouldn't bloat your
config file.

### Why a launchd job, not a resident daemon

repo-tender has **no** long-running process, no UNIX socket, no IPC, no
in-process scheduler. launchd owns the cadence and lifecycle: every
`refresh_interval` it wakes a short-lived `repo-tender sync`, which fans out its
work concurrently (via [socketry/async] with a bounded semaphore), writes
results to state, and exits.

A periodic job is the right shape for "bring things up to date every few hours."
A resident daemon would mean re-implementing supervision, restart-on-crash, and
signal handling that launchd already does correctly — and `KeepAlive` is for
processes meant to run forever, which this is not. The plist uses
`StartInterval` + `RunAtLoad` and is classified `Background`.

[socketry/async]: https://github.com/socketry/async

### Local-first evaluation

Each sync minimizes network use. Before touching the network, repo-tender checks
on-disk facts: is the path present? is HEAD on the default branch? is the tree
clean? is `.git/FETCH_HEAD` younger than `refresh_interval`? Only a clean,
on-default, *stale* repo triggers a `git fetch`, and only a clean repo that's
strictly behind gets a `git merge --ff-only`. A repo fetched within the interval
is skipped without any network call — which is what makes a manual re-run cheap
and the whole thing idempotent.

### Why macOS-only and GitHub-only

Scheduling is via launchd, which is macOS-specific. Org listing is via `gh`,
which is GitHub-specific. Both sit behind decoupled interfaces (`SCM::Client`,
`Forge::Client`) so other platforms or forges *could* be added — but today only
the git + GitHub + launchd implementations exist. No push, no write to remotes,
no web UI.

---

## Reference

The complete, exhaustive catalogue — every command, option, config key, status
value, file location, and exit code — lives in **[docs/reference.md](docs/reference.md)**.

## Development

```bash
bundle exec rake test          # full minitest suite
bundle exec standardrb         # lint / format check
bundle exec standardrb --fix   # autofix
```

Architecture, build conventions, and the slice-by-slice design history live in
[`AGENTS.md`](AGENTS.md) and [`docs/prd/repo-tender.md`](docs/prd/repo-tender.md).

## License

MIT.
