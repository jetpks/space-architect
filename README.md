# Space Architect 🚀

[![Gem Version](https://badge.fury.io/rb/space-architect.svg)](https://badge.fury.io/rb/space-architect)

> **Task-scoped workspaces that double as Architect Loop missions — for humans and their agents!** ✨🛰️

`space-architect` is a Ruby CLI for creating and managing **spaces** — task-scoped
project workspaces that hold repos, notes, and artifacts under one obvious
filesystem root — fused with the **Architect Loop**: a structured judgment-and-build
cycle for you and a fleet of headless AI builders. 🌌

## What's a space? 🪐

A space is just a regular directory with a tiny YAML identity file and room for
everything a task needs:

```text
~/src/spaces/20260531-name-of-space/
  space.yaml        # identity: id, title, status, repos, notes, tags
  README.md
  repos/            # cloned (or copy-on-write'd) repositories
  notes/            # scratch, prompts, logs
  architecture/     # iteration files: I<NN>-<name>.md + ARCHITECT.md index
  build/            # lane worktrees + scratch (build/<id>-<lane>/)
  tmp/              # workspace-local temp — use this instead of /tmp
```

Run a command from anywhere inside a space and it just works — `architect` walks
up from `$PWD` until it finds the nearest `space.yaml`. No "current space" state to
get out of sync; where you *are* is the space you mean. 🧭

## Installation 📦

Add it to your `Gemfile`:

```ruby
gem "space-architect"
```

Then:

```bash
bundle install
```

Or grab it yourself:

```bash
gem install space-architect
```

The primary executable is `architect`. The gem is `space-architect`. 🎀
A `space` shim is also installed and forwards all arguments to `architect space …`
for convenience.

## Quick Start 🎀

**Space management:**

```sh
architect space init                              # create XDG config + state files
architect space new "Name of Space"              # blast off a new space 🚀
architect space new "Name of Space" org/repo …  # with repos cloned in (variadic)
architect space list                             # see all your spaces
architect space show                             # show the space you're standing in
architect space status done                      # mark the current mission complete
```

**Architect Loop (run from inside a space):**

```sh
architect install-skills                          # install skills for your harness (once per machine)
architect init                                   # scaffold ARCHITECT.md + architecture/
architect new <iteration>                        # scaffold next iteration file
architect dispatch <iteration> <lane>            # dispatch a builder for a lane
architect status                                 # show mission state (read-only)
architect freeze <iteration>                     # freeze Acceptance Criteria
architect verify <iteration>                     # post-flight mechanical checks
```

`architect install-skills` installs the bundled `architect`, `architect-research`,
and `architect-vocabulary` skills for a harness. (`architect-vocabulary` loads the
system's terms and a short orientation when you're in a space but don't want to run
the loop — see [The Architect Loop](#the-architect-loop-).) Default is `claude`
(`~/.claude/skills/`); use `--provider
opencode|codex|pi` for other harnesses, and `--project` to install into the current
directory instead of globally. See the [command reference](docs/reference.md) for details.

## Usage 🛰️

```sh
architect space init
architect space new "Name of Space"
architect space new "Name of Space" org/repo example-tools/alpha example-tools/beta
architect space list
architect space show 20260531-name-of-space
architect space path 20260531-name-of-space
architect space current                      # based on $PWD
architect space show                         # based on $PWD
architect space status done                  # based on $PWD
architect space status 20260531-name-of-space done
architect space config set default_provider github.com
architect space config set default_organization example-org
architect space repo add example-app         # github.com/example-org/example-app
architect space repo add example-tools/alpha example-tools/beta
architect space repo add gitlab.com/example-org/api
architect space repo resolve example-app example-tools/async
architect space repo ls
architect space use 20260531-name-of-space   # records recent state and prints the path
architect space ls --color=always            # auto, always, or never; --colors is also accepted
```

Space ids are date-prefixed (`20260531-name-of-space`) so they sort naturally,
and duplicate names on the same day get a counter (`...-name-of-space-2`). 📅

## The Architect Loop 🏗️

Space Architect ships a structured build cycle for you and headless AI builders
called the **Architect Loop**. Each loop lives inside a space as a *mission*.

**Roles:**

- **Architect** — you (or Claude Opus 4.8 in judgment mode): arbitrates disagreements,
  writes and freezes iteration files, calls kill/continue, merges builder output.
- **Builder** — Claude Sonnet 4.6 run headless via `architect dispatch`; reads the
  iteration's Builder Prompt from `architecture/`, does the work, writes its report
  to `build/<id>-<lane>/`.

**Filesystem layout:**

```text
architecture/
  ARCHITECT.md              # cross-iteration index; mission-wide state
  I01-<iteration>.md        # one file per iteration
  I02-<iteration>.md
build/
  I01-<iteration>-<lane>/   # lane worktree + scratch per dispatch
    run.jsonl               # streamed builder output
    report.md               # builder report (transcribed to iteration file verbatim)
```

**Iteration file anatomy** (in `architecture/I<NN>-<name>.md`):

| Section | Who writes it | When |
|---------|--------------|------|
| `## Grounds` | Architect | Before dispatch — research, PRD, decisions |
| `## Specification` | Architect | Before dispatch — full delegation contract |
| `## Acceptance Criteria` | Architect | Before `architect freeze` — frozen, read-only after |
| `## Builder Prompt` | Architect | Records the exact prompt dispatched |
| `## Builder Report` | Architect | Transcribed verbatim from `build/…/report.md` |
| `## Verdict` | Architect | After reviewing evidence — KILL / CONTINUE |

**Acceptance Criteria freeze before results** — `architect freeze <iteration>` commits
the frozen sections and records `freeze_sha`; any change to Grounds, Specification,
or Acceptance Criteria after that point is an automatic iteration FAIL. The builder
never edits the iteration file.

**Typical loop session:**

```sh
# From inside your space:
architect init                                   # first time: scaffold ARCHITECT.md
architect new my-feature                         # scaffold architecture/I01-my-feature.md
# … write Grounds + Specification + Acceptance Criteria …
architect freeze my-feature                      # lock it
architect dispatch my-feature lane-A             # send builder to work
# … builder runs, writes build/I01-my-feature-lane-A/report.md …
architect verify my-feature                      # mechanical post-flight checks
architect status                                 # review mission state
# … architect reads evidence and writes Verdict …
```

## Fish shell integration 🐟

Shells can't let a child process change *their* working directory, so `architect`
ships a small fish wrapper function. It also installs fish completions for commands,
subcommands, spaces, statuses, config keys, and common config values. Install both
into fish's autoloaded directories:

```fish
architect space shell fish install
exec fish
```

Restarting fish (or `exec fish`) lets the current terminal pick up the new autoloaded
wrapper function. After that, `architect space new "Name of Space"` and
`architect space use 20260531-name-of-space` will `cd` into the selected space once the
CLI command succeeds. Every other command keeps normal CLI behavior. 🚪

The function is written to `~/.config/fish/functions/space.fish` and completions to
`~/.config/fish/completions/space.fish`, so there's no need to edit `config.fish`.
For one-off testing without installing:

```fish
architect space shell init fish | source
```

## Configuration ⚙️

Configuration follows the XDG base directory spec:

```yaml
version: 1
spaces_dir: ~/src/spaces
evergreen_dir: ~/src/evergreen
default_provider: github.com
default_organization:
git_clone_protocol: ssh
```

View current values: `architect space config show`. Set a value: `architect space config set KEY VALUE`.

## Repos: evergreen, copy-on-write, concurrent 🌲

Repos are added to the current space under `repos/` and tracked in `space.yaml`.
When an up-to-date local copy exists under `evergreen_dir` at
`<evergreen_dir>/<provider>/<owner>/<name>` (e.g.
`~/src/evergreen/github.com/example-org/example-app`), `architect` copies it into the
space instead of cloning over the network — much faster, and a copy-on-write clone
on APFS. ⚡ Set `evergreen_dir` to empty to always clone:

```sh
architect space config set evergreen_dir ""
```

When no evergreen copy is found, the repo is cloned over the network. Clone URLs
default to SSH (`git@github.com:example-org/example-app.git`). Prefer HTTPS?

```sh
architect space config set git_clone_protocol https
```

When stdout/stderr are attached to a TTY, long-running repo operations show an
interactive spinner. Multiple repos passed to `architect space repo add` are fetched
**concurrently**, up to five at a time, on fibers — no threads, all cooperative. 🧵
After each repo is in place, `architect` runs `mise trust` in it so local mise config
is ready to go.

Each space also gets a workspace-local `tmp/`. Use it instead of `/tmp` or
`/var/tmp`; when using `mktemp`, point it at `tmp/`. 🗑️

## The `src` engine: evergreen checkouts 🌿

`architect src …` exposes the **vendored** evergreen engine (from
[repo-tender](https://github.com/jetpks/repo-tender)) directly — no separate
installation needed. It keeps local clones under
`~/src/evergreen/<host>/<owner>/<repo>` clean, on their default branch, and freshly
fetched.

```sh
architect src repo add github.com/example-org/example-app   # tend it 🌲
architect src sync                                           # run one sync pass
architect src status                                         # per-repo evergreen status
```

When `architect space repo add` sees a matching evergreen copy, it copy-on-writes
from it instead of hitting the network — instant provisioning. ⚡

The vendored engine and space management share the same layout by design — both use
`<evergreen_dir>/<host>/<owner>/<repo>` — so they line up with zero configuration:

```sh
architect src repo add github.com/example-org/example-app   # tend it: keep it evergreen 🌲
architect space repo add example-app                         # copies it instantly ⚡
```

## Documentation 📖

- **[Command Reference](docs/reference.md)** — every command, flag, and behavior
- **[Design](docs/design.md)** — why spaces and the Architect Loop exist and how they're shaped

## Development 🛠️

```sh
bundle install
bundle exec rake test       # the full minitest suite
bundle exec rake build      # build the gem into pkg/
bundle exec rake install    # build + install into your user gem home
```

## Contributing 💝

Bug reports and pull requests are welcome on GitHub at
[https://github.com/jetpks/space-architect](https://github.com/jetpks/space-architect)!

## License 📄

Available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

---

Made with 💖 and fibers 🧵 by Eric
