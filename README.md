# Space Architect 🚀

[![Gem Version](https://badge.fury.io/rb/space-architect.svg)](https://badge.fury.io/rb/space-architect)

> **The Architect Loop — structured judgment-and-build cycles for humans and their agents!** ✨🛰️

`space-architect` is the gem behind the **Architect Loop**: a structured
judgment-and-build cycle in which a strong reasoning model (the *architect*)
plans, freezes acceptance criteria, and judges the work of a fleet of headless
AI *builders* — one per lane, each in its own git worktree. The loop runs inside
task-scoped **spaces**: directories that hold repos, notes, and artifacts under
one obvious filesystem root. Nothing lives only in a chat window — every
decision, spec, and verdict is committed to the space repo.

It installs **one executable**, `architect`. The spaces substrate and the
evergreen-checkout engine are two sibling gems:

| Gem | Dependency | What it provides |
|-----|------------|------------------|
| **space-cadet** | hard | The spaces substrate (`Space::Core`): create, manage & containerize task-scoped workspaces — the `space` binary — plus the copy-on-write evergreen-checkout substrate repos provision from |
| **repo-tender** | soft | Evergreen clone tending — the `repo-tender` binary (with the deprecated `src` shim) — and the launchd agent the `architect sessions agent` commands drive. Install with `gem install repo-tender` when you want the session-sync rail — everything else works without it |

## Installation 📦

```bash
gem install space-architect
gem install repo-tender   # optional: enables the sessions launchd agent
```

The gem installs one executable: `architect`. 🎀 (Or add
`gem "space-architect"` to your Gemfile and `bundle install`.)

Upgrading from the 8.x monolith? Uninstall `space-architect` 8.x **first** —
its `space`/`src` executables collide with the ones the new gems ship — see
[the upgrade guide](docs/how-to/upgrade-from-the-8x-monolith.md).

## 60-second start 🎀

Run one full loop iteration in a scratch space — the
[tutorial](docs/tutorials/one-loop-iteration.md) walks it end to end:

```sh
space init                          # create the XDG config + state files (space-cadet gem)
space new "Docsmith Tutorial"       # blast off a new space 🚀
cd ~/architect/spaces/<id>-docsmith-tutorial
architect init                      # scaffold ARCHITECT.md + the space.yaml project: block
```

From there the loop is: `architect new` → `architect section …` → `architect
freeze` → `architect dispatch` → `architect gate` → `architect integrate`. The
tutorial runs every step on a scratch repo.

## The four quadrants 🧭

| Quadrant | Read it when you… | Start here |
|----------|-------------------|------------|
| **Tutorials** — learning-oriented | are new and want a guided journey | [docs/tutorials](docs/tutorials/) |
| **How-to guides** — goal-oriented | have a specific task to do | [docs/how-to](docs/how-to/) |
| **Reference** — information-oriented | need a fact about a command, flag, or file | [docs/reference](docs/reference/) |
| **Explanation** — understanding-oriented | want the why behind the design | [docs/explanation](docs/explanation/) |

## Development 🛠️

```sh
bundle install
bundle exec rake test       # the full minitest suite
bundle exec rake build      # build the gem into pkg/
bundle exec rake install    # build + install into your user gem home
```

Bug reports and pull requests are welcome on GitHub at
[https://github.com/jetpks/space-architect](https://github.com/jetpks/space-architect).
Available as open source under the [MIT License](LICENSE.txt).

---

Made with 💖 and fibers 🧵 by Eric
