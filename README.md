# Space Cadet 🚀

[![Gem Version](https://badge.fury.io/rb/space-cadet.svg)](https://badge.fury.io/rb/space-cadet)

> **Task-scoped project workspaces for humans and their agents!** ✨🛰️

`space-cadet` is a Ruby CLI for creating and managing **spaces** — task-scoped
project workspaces that hold repos, notes, and artifacts under one obvious
filesystem root. Think of a space as a launchpad for a single mission: a ticket,
an investigation, or an agentic work session. 🌌

## What's a space? 🪐

A space is just a regular directory with a tiny YAML identity file and room for
everything a task needs:

```text
~/src/spaces/20260531-name-of-space/
  .space.yml        # identity: id, title, status, repos, notes, tags
  README.md
  repos/            # cloned (or copy-on-write'd) repositories
  notes/            # scratch, prompts, logs
  artifacts/        # screenshots, outputs, ephemera
  tmp/              # workspace-local temp — use this instead of /tmp
```

Run a command from anywhere inside a space and it just works — `space` walks up
from `$PWD` until it finds the nearest `.space.yml`. No "current space" state to
get out of sync; where you *are* is the space you mean. 🧭

## Installation 📦

Add it to your `Gemfile`:

```ruby
gem "space-cadet"
```

Then:

```bash
bundle install
```

Or grab it yourself:

```bash
gem install space-cadet
```

The executable is `space`. The gem is `space-cadet`. 🎀

## Quick Start 🎀

```sh
space init                       # create XDG config + state files
space new "Name of Space"        # blast off a new space 🚀
space list                       # see all your spaces
space show                       # show the space you're standing in
space status done                # mark the current mission complete
```

## Usage 🛰️

```sh
space init
space new "Name of Space"
space new "Name of Space" -r example-tools/alpha -r example-tools/beta
space list
space show 20260531-name-of-space
space path 20260531-name-of-space
space current                 # based on $PWD
space show                    # based on $PWD
space status done             # based on $PWD
space status 20260531-name-of-space done
space config set default_provider github.com
space config set default_organization example-org
space repo add example-app     # github.com/example-org/example-app
space repo add example-tools/alpha example-tools/beta
space repo add gitlab.com/example-org/api
space repo resolve example-app example-tools/async
space repo ls
space use 20260531-name-of-space # records recent state and prints the path
space ls --color=always       # auto, always, or never; --colors is also accepted
```

Space ids are date-prefixed (`20260531-name-of-space`) so they sort naturally,
and duplicate names on the same day get a counter (`...-name-of-space-2`). 📅

## Fish shell integration 🐟

Shells can't let a child process change *their* working directory, so `space`
ships a small fish wrapper function. It also installs fish completions for
commands, subcommands, spaces, statuses, config keys, and common config values.
Install both into fish's autoloaded directories:

```fish
space shell fish install
exec fish
```

Restarting fish (or `exec fish`) lets the current terminal pick up the new
autoloaded wrapper function. After that, `space new "Name of Space"` and
`space use 20260531-name-of-space` will `cd` into the selected space once the
CLI command succeeds. Every other command keeps the normal CLI behavior. 🚪

The function is written to `~/.config/fish/functions/space.fish` and completions
to `~/.config/fish/completions/space.fish`, so there's no need to edit
`config.fish`. For one-off testing without installing:

```fish
space shell init fish | source
```

## Configuration ⚙️

Configuration follows the XDG base directory spec and defaults to
`~/.config/space-cadet/config.yml`:

```yaml
version: 1
spaces_dir: ~/src/spaces
evergreen_dir: ~/src/evergreen
default_provider: github.com
default_organization:
git_clone_protocol: ssh
```

## Repos: evergreen, copy-on-write, concurrent 🌲

Repos are added to the current space under `repos/` and tracked in `.space.yml`.
When an up-to-date local copy exists under `evergreen_dir` at
`<evergreen_dir>/<provider>/<owner>/<name>` (e.g.
`~/src/evergreen/github.com/example-org/example-app`), `space` copies it into the
space instead of cloning over the network — much faster, and a copy-on-write
clone on APFS. ⚡ Set `evergreen_dir` to empty to always clone:

```sh
space config set evergreen_dir ""
```

When no evergreen copy is found, the repo is cloned over the network. Clone URLs
default to SSH (`git@github.com:example-org/example-app.git`). Prefer HTTPS?

```sh
space config set git_clone_protocol https
```

When stdout/stderr are attached to a TTY, long-running repo operations show an
interactive spinner. Multiple repos passed to `space repo add` are fetched
**concurrently**, up to five at a time, on fibers — no threads, all cooperative.
🧵 After each repo is in place, `space` runs `mise trust` in it so local mise
config is ready to go.

Each space also gets a workspace-local `tmp/`. Use it instead of `/tmp` or
`/var/tmp`; when using `mktemp`, point it at `tmp/`. 🗑️

## Documentation 📖

- **[Command Reference](docs/reference.md)** — every command, flag, and behavior
- **[Design](docs/design.md)** — why spaces exist and how they're shaped

## Development 🛠️

```sh
bundle install
bundle exec rake test       # the full minitest suite
bundle exec rake build      # build the gem into pkg/
bundle exec rake install    # build + install into your user gem home
```

## Contributing 💝

Bug reports and pull requests are welcome on GitHub at
[https://github.com/jetpks/space-cadet](https://github.com/jetpks/space-cadet)!

## License 📄

Available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).

---

Made with 💖 and fibers 🧵 by Eric
