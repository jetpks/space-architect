# repo-tender 🌲

[![Gem Version](https://badge.fury.io/rb/repo-tender.svg)](https://badge.fury.io/rb/repo-tender)

> **Keep your local git clones forever fresh!** ヽ(•‿•)ノ✨

`repo-tender` keeps your local git clones **evergreen** — clean, on their
default branch, and recently fetched — so anything that reads them gets a
current, trustworthy copy from your local disk instead of the network! 🪞⚡

## What does "evergreen" mean? 🌿

A clone is **evergreen** when all three of these hold at once:

- 🧼 **Clean** — no modified, staged, untracked, or deleted files
- 🌳 **On the default branch** — whatever the remote calls it (`main`, `trunk`,
  `master`…); repo-tender resolves it from the remote and never assumes!
- 🕰️ **Fresh** — fast-forwarded to the remote within your `refresh_interval`
  (default 6h)

repo-tender's whole job is to keep a tidy local mirror current, so another tool
can clone any of them from `~/src/evergreen/...` **instantly**. 🚀

**Perfect for:**
- 🪞 A local mirror of the repos you clone from constantly
- 🏎️ A downstream "workspace" tool that clones from local disk, not the network
- 🐙 Keeping a whole GitHub org checked out and current
- 🌙 Hands-off, set-and-forget background maintenance

**Why repo-tender rocks:**
- 🔒 **Never destroys your work** — dirty or diverged repos are *reported*,
  never touched. No `reset --hard`, ever.
- ⚡ Concurrent sync sweep powered by [socketry/async] — fibers all the way
  down, one process, no thread soup
- 🤖 A periodic [launchd] job syncs on a schedule while you sleep
- 🐙 Track individual repos **or** whole GitHub orgs (expanded via `gh`)
- 🎛️ Interactive, plain, or JSON output — pretty for you, parseable for scripts
- 💎 Built on [dry-rb] — validated YAML config, `Result`-typed boundaries

[socketry/async]: https://github.com/socketry/async
[launchd]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html
[dry-rb]: https://dry-rb.org/

## Requirements 🌍

repo-tender is **macOS-only** (it schedules via launchd) and **GitHub-only**
(it lists orgs via `gh`) — both sit behind decoupled interfaces, but those are
today's implementations.

| Tool | Version | Why |
|------|---------|-----|
| 🍎 macOS | — | launchd scheduling, `~/Library/LaunchAgents` |
| [mise] | 2026.6+ | pins and provides Ruby |
| 💎 Ruby | 4.0.5 | runtime (pinned in `mise.toml`) |
| git | 2.54+ | the only SCM |
| [gh] | 2.93+ | GitHub org listing (must be authenticated) |

[mise]: https://mise.jdx.dev/
[gh]: https://cli.github.com/

## Installation 📦

We're on RubyGems! 🎉

```bash
gem install repo-tender
repo-tender --help
```

Prefer to hack on it? Install from source instead: 🛠️

```bash
git clone git@github.com:jetpks/repo-tender.git
cd repo-tender
mise install        # installs Ruby 4.0.5 per mise.toml
bundle install
bin/repo-tender --help
```

Make sure `gh` is logged in (otherwise org listing drops to an anonymous
60 req/hour limit):

```bash
gh auth status
```

And you're off! 🎀

## Features ✨

- **The evergreen invariant** — clean · on default branch · fresh, checked per repo
- **Safe by default** — dirty/diverged repos are reported and left byte-for-byte alone
- **Whole-org tracking** — add `socketry` and get every repo it owns
- **Bounded concurrency** — a fast async fan-out that won't melt your machine
- **launchd scheduling** — `install`, `start`, `stop`, `restart`, `status`
- **Default-branch aware** — resolves `trunk`/`master`/`main` from the remote
- **Three output modes** — interactive TUI, plain text, or line-delimited JSON

## Quick Start 🎀

### Track a repo 🐙

Repos are named `host/owner/name`:

```bash
repo-tender repo add github.com/ruby/ruby
# => added: github.com/ruby/ruby

repo-tender repo list
# => github.com/ruby/ruby
```

### Track a whole org 🌐

Orgs expand to their member repos at sync time (archived repos and forks are
excluded by default):

```bash
repo-tender org add socketry              # host defaults to github.com
repo-tender org add github.com/socketry   # equivalent, explicit host
```

Got a few truly enormous repos in an org you never want cloned? Exclude them
with `--ignored-repos` (bare `name` or `owner/name`, comma-separated):

```bash
repo-tender org add bigco --ignored-repos monorepo,huge
# => added: github.com/bigco (… ignored_repos=["monorepo", "huge"])
```

The ignore list is authoritative at expansion time — an ignored repo never
enters a sync sweep. ✋

### Sync everything now ⚡

```bash
repo-tender sync
```

Clones what's missing, fast-forwards what's clean-and-behind, and reports
(never touches!) anything dirty or diverged. Scope it to one repo with
`--repo github.com/ruby/ruby`. 🎯

### Check your repos' health 🩺

```bash
repo-tender status
```

```
REPO                            STATUS  DEFAULT_BRANCH  LAST_SYNCED_AT        LAST_FETCH_AT
github.com/dry-rb/dry-monads    clean   main            2026-06-14T20:01:34Z  2026-06-14T20:01:33Z
github.com/ruby/ruby            dirty   trunk           2026-06-14T20:01:36Z  2026-06-14T20:01:35Z
```

`clean` is the happy path. Anything else is repo-tender telling you a repo needs
*your* attention — it won't touch it for you. 🔒

### Grab an instant copy ⚡🐄

Need a working copy of an evergreen repo? `clone` makes a near-instant
copy-on-write clone (macOS APFS `cp -Rc`) from your local mirror — no network,
barely any disk:

```bash
repo-tender clone ruby                    # resolves the single ruby/ruby mirror
repo-tender clone ruby async --into ~/wip # copy several into a parent dir
```

Name a repo bare (`ruby`), `owner/name`, or `host/owner/name` — bare names that
match more than one mirror error out and list the candidates so you can qualify.
`--into` is the destination **parent** (default `.`); each repo lands at
`<into>/<name>`. And it **never clobbers** — an existing destination is left
byte-for-byte alone. 🔒

### Schedule it & forget it 🤖

Install a per-user launchd agent that runs `sync` every `refresh_interval`:

```bash
repo-tender daemon install
repo-tender daemon status
```

macOS now syncs your repos in the background. Tear it down anytime:

```bash
repo-tender daemon stop
repo-tender daemon uninstall
```

### Tune it 🎛️

Find your config, then edit it (`repo-tender config path`):

```yaml
base_dir: ~/src/evergreen   # where clones live (pick your own!)
refresh_interval: 90m       # "6h", "90m", "45s", "30d", or integer seconds
concurrency: 8              # max parallel git/gh operations per run
```

```bash
repo-tender config show   # see the effective, validated config
```

### Output for robots 🤓

```bash
repo-tender sync --json    # one JSON object per event line (12-factor!)
repo-tender sync --plain   # one plain line per event, no color
repo-tender status --json
```

`--no-color` and `--quiet`/`-q` work everywhere; color auto-disables off a TTY.

## Command Overview 🔍

**Track repos & orgs:**
- `repo add|remove|list REF` — manage individual repos (`host/owner/name`)
- `org add|remove|list NAME` — manage whole orgs (`name` or `host/name`);
  `org add` takes `--include-archived`, `--include-forks`, `--ignored-repos a,b`

**Run & inspect:**
- `sync [--repo REF]` — run one sync pass (optionally scoped to one repo)
- `status` — print the per-repo evergreen status table (reads state, no network)
- `clone NAME... [--into DIR]` — instant COW copy of mirror(s) into a parent dir
- `config path|show` — show the config path, or the effective config

**Schedule (launchd):**
- `daemon install|uninstall` — write/remove the launchd agent
- `daemon start|stop|restart` — enable / disable / run-now
- `daemon status` — loaded? running? last exit?

**Global flags:** `--plain` · `--json` · `--no-color` · `--quiet`/`-q` ·
`--help`/`-h` · `--version`

## How it works 🛠️

The bits worth knowing the *why* of:

- 🔒 **The cardinal rule: never lose your work.** repo-tender only ever
  fast-forwards a *clean* repo that's strictly behind. A dirty tree, local
  commits the remote lacks, a detached HEAD, a non-default branch — all
  *reported* and left untouched. There is no destructive path.
- 🤖 **A periodic launchd job, not a resident daemon.** No socket, no IPC, no
  in-process scheduler. launchd wakes a short-lived `sync` every
  `refresh_interval`; it fans out, writes state, and exits. (`StartInterval` +
  `RunAtLoad`, no `KeepAlive`.)
- 📡 **Local-first, network-last.** Each sync checks on-disk facts first — path
  present? on default branch? clean? `.git/FETCH_HEAD` younger than the
  interval? — and only *then* touches the network. Re-runs are cheap and
  idempotent. ✨
- 🗂️ **Config vs. state.** `config.yaml` is *your* durable intent (hand-edited or
  via the CLI); `state.yaml` is machine-managed (statuses, fetch times,
  org expansions). Splitting them keeps machine rewrites away from the file you
  actually wrote.

## Documentation 📖

- **[Full Reference](docs/reference.md)** 📘 — every command, flag, config key,
  status value, file location, and exit code
- **[Design (PRD)](docs/prd/repo-tender.md)** 🏗️ — the full design & decisions
- **[Builder context](AGENTS.md)** 🤝 — toolchain & conventions

## Development 🧪

Want to hack on it? Yay! 🎉

```bash
bundle install
bundle exec rake test          # full minitest suite
bundle exec standardrb         # lint / format check
bundle exec standardrb --fix   # autofix
```

## Contributing 💝

Bug reports and pull requests are welcome at
[github.com/jetpks/repo-tender](https://github.com/jetpks/repo-tender)! 🌲

## License 📄

Available as open source under the terms of the [MIT License](LICENSE.txt).

---

Made with 💖 and a deep distrust of `reset --hard`, by Eric 🌲
