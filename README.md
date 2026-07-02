# Space Architect 🚀

[![Gem Version](https://badge.fury.io/rb/space-architect.svg)](https://badge.fury.io/rb/space-architect)

> **Task-scoped workspaces that double as Architect Loop projects — for humans and their agents!** ✨🛰️

`space-architect` is a Ruby toolkit for **spaces** — task-scoped project
workspaces that hold repos, notes, and artifacts under one obvious filesystem
root — fused with the **Architect Loop**: a structured judgment-and-build cycle
for you and a fleet of headless AI builders. 🌌

The gem ships **three composable binaries** over clean library seams:

| Binary | What it does | Library |
|--------|--------------|---------|
| **`space`** 🪐 | Create, manage & containerize task-scoped workspaces | `Space::Core` |
| **`architect`** 🏗️ | Run the Architect Loop — judgment + headless builders | `Space::Architect` |
| **`src`** 🌲 | Tend evergreen repo checkouts for copy-on-write provisioning | `Space::Src` |

Each is a first-class executable. `architect` also forwards `architect space …`
and `architect src …` to the other two, so a project can drive everything from
one command when that's handier. 🎀

## What's a space? 🪐

A space is just a regular directory with a tiny YAML identity file and room for
everything a task needs:

```text
~/architect/spaces/20260531-name-of-space/
  space.yaml        # identity: id, title, status, repos, notes, tags
  README.md
  repos/            # cloned (or copy-on-write'd) repositories
  notes/            # scratch, prompts, logs
  architecture/     # iteration files: I<NN>-<name>.md + ARCHITECT.md index + BRIEF.md
  build/            # lane worktrees + scratch (build/<id>-<lane>/)
  tmp/              # workspace-local temp — use this instead of /tmp
```

Run a command from anywhere inside a space and it just works — `space` and
`architect` walk up from `$PWD` until they find the nearest `space.yaml`. No
"current space" state to get out of sync; where you *are* is the space you
mean. 🧭

## Installation 📦

Add it to your `Gemfile`:

```ruby
gem "space-architect"
```

```bash
bundle install
```

Or grab it yourself:

```bash
gem install space-architect
```

The gem is `space-architect`; it installs three executables — `space`,
`architect`, and `src`. 🎀

## Quick start 🎀

```sh
# Spaces
space init                                        # create XDG config + state files
space new "Name of Space"                         # blast off a new space 🚀
space new "Name of Space" -r org/repo -r org/lib  # …with repos cloned in (repeat -r)
space list                                        # see all your spaces
space show                                        # show the space you're standing in

# Evergreen checkouts (copy-on-write sources for fast provisioning)
src repo add github.com/example-org/example-app     # tend it 🌲
src sync                                            # one sync pass
src status                                          # per-repo evergreen status

# Architect Loop (run from inside a space)
architect install-skills                          # install agent skills (once per machine)
architect init                                    # scaffold ARCHITECT.md + architecture/
architect new my-feature                          # scaffold the next iteration file
architect freeze my-feature                       # lock the Acceptance Criteria ❄️
architect dispatch my-feature lane-a              # send a headless builder to work

# Containers (run from inside a space) — a portable, reproducible-by-SHA image of the space
space pack                                         # render build/oci/ (Dockerfile + entrypoint)
space build                                        # pack + build & tag <space-id>:<git-sha>
space run                                          # run it — login shell, auth from your env
```

## `space` — task-scoped workspaces 🌌

```sh
space init
space new "Name of Space"
space new "Name of Space" -r org/repo -r example-tools/alpha -r example-tools/beta
space list                                   # alias: space ls
space show 20260531-name-of-space
space path 20260531-name-of-space
space current                                # based on $PWD
space show                                   # based on $PWD
space status done                            # based on $PWD
space status 20260531-name-of-space done
space config set default_provider github.com
space config set default_organization example-org
space repo add example-app                   # github.com/example-org/example-app
space repo add example-tools/alpha example-tools/beta
space repo add gitlab.com/example-org/api
space repo resolve example-app example-tools/async
space repo ls                                # alias: space repos ls
space use 20260531-name-of-space             # records recent state, prints the path
space ls --color=always                      # auto | always | never (--colors also accepted)
```

Repos are passed with a repeatable `-r` flag (`-r org/repo -r org/lib`); the
comma form (`-r a,b`) works too. Space ids are date-prefixed
(`20260531-name-of-space`) so they sort naturally, and duplicate names on the
same day get a counter (`…-name-of-space-2`). 📅

Everything `space` does is also reachable as `architect space …` from within a
project.

## Containerize a space: `pack` · `build` · `run` 📦

A space is self-describing enough to become a container. `space pack` renders a
portable OCI build context from the space; `space build` packs and builds it into
a **reproducible-by-SHA** image; `space run` runs that image with your auth
injected at runtime and stateful paths bind-mounted back to the host. 🐳

```sh
space pack                    # render build/oci/ (Dockerfile + entrypoint + ignore file)
space pack -o /tmp/ctx        # …to a different output directory
space build                   # pack, then build & tag <space-id>:<git-sha> and :latest
space run                     # run <space-id>:latest — login shell, auth from your env
space run architect status    # …or run a one-off command instead of the login shell
space run --tty               # force an interactive TTY (default: auto-detect)
```

**What lands in the image.** The context copies the whole space tree (filtered by
a generated `Dockerfile.dockerignore`) onto a `ruby:4.0.5` base with `git`, the
Claude Code CLI, and the `space-architect` gem — installed from the in-space
`repos/space-architect` checkout when present (a pinned build), else from
RubyGems. Secrets never enter the layers: `.env`, `*.key`, `*.pem`, ssh keys,
`build/`, and `tmp/` are all excluded by the generated ignore file. 🔒

**Reproducible by SHA.** `space build` tags the image `<space-id>:<sha>`, where
`<sha>` is the space repo's 12-char `HEAD` (suffixed `-dirty` when the tree has
uncommitted changes), plus a moving `:latest`. Same commit → same tag → same
image. It drives the `container` CLI, but the output is an ordinary OCI/Docker
build context, so `docker build -f build/oci/Dockerfile .` (from the space root)
works just as well.

**Auth stays out of the layers.** `space run` injects only the auth environment
variables that are actually set — `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`,
`ANTHROPIC_BASE_URL` — with `-e` at run time, so credentials live in your shell,
never in the image. 🗝️

**Forwarding payload credentials.** Beyond the always-on auth trio, a space can declare
`run.env:` in `space.yaml` — a list of host env var names forwarded into the container at
run time. You can also pass `space run --env VAR` (repeatable) for ad hoc additions. All
forwarding is bare `-e VAR` passthrough: values never appear in argv, `ps`, or the image.
A requested-but-unset var warns on stderr instead of silently failing inside the guest.

```yaml
run:
  env:                         # run-time: host var names, forwarded as bare -e VAR
    - FIREWORKS_API_KEY
    - OPENAI_API_KEY
```

**Declaring provisioning & persistence** — two optional keys in `space.yaml`:

```yaml
pack:
  provision:                 # build-time: relative scripts, baked in by `space build`
    - scripts/setup-toolchain.sh
  persist:                   # run-time: absolute guest paths, bind-mounted per run
    - /root/.claude
    - /root/.local/state
```

`provision` scripts must live under the space root and be executable. Each script is
copied into the image individually (`COPY <script> /space/<script>`) and then invoked
(`RUN /space/<script>`) **before** the full space tree lands and **before** the gem is
installed. This ordering is the cache-hygiene guarantee: editing any other space file
leaves the provision and gem-install layers cached, so a rebuild completes in seconds
instead of minutes. Scripts must therefore be self-contained — they run with only the
base system layers and any earlier provision scripts' outputs; they cannot read other
space files or call `architect`/`space`. Scripts must have the executable bit set; COPY
preserves the mode from the build context.

`persist` paths must be absolute; `space run` bind-mounts each one from
`<space>/.state<path>` on the host (created on first run) so a container's mutable state
survives across runs. Both are validated at pack time.

Like everything else, these are reachable as `architect space pack|build|run`
from inside a project.

## `src` — the evergreen engine 🌲

`src` keeps local clones under `<src_dir>/<host>/<owner>/<repo>` (default
`~/architect/src/…`) clean, on their default branch, and freshly fetched — so
spaces can provision repos by **copy-on-write** instead of cloning over the
network.

```sh
src repo add github.com/example-org/example-app     # track + tend a repo
src org add github.com/example-org                  # track a whole org
src sync                                            # run one sync pass (--repo to scope)
src status                                          # per-repo evergreen status table
src clone example-app                               # APFS copy-on-write into $PWD
src daemon install                                  # per-user launchd agent for background sync
```

When `space repo add` finds a matching evergreen checkout, it copy-on-writes
from it instead of hitting the network — instant provisioning. ⚡ The two
surfaces share one layout by design, so they line up with zero configuration:

```sh
src repo add github.com/example-org/example-app   # tend it: keep it evergreen 🌲
space repo add example-app                          # copies it instantly ⚡
```

`src` has its own `--plain` / `--json` output modes for scripting, and its own
fish integration (`src shell fish install`).

## `architect` — the Architect Loop 🏗️

The **Architect Loop** is a structured build cycle for you and headless AI
builders. Each loop lives inside a space as a *project*.

**Roles:**

- **Architect** — the judgment role: a strong reasoning model (or you), run
  interactively. Arbitrates disagreements, writes and freezes iteration files,
  calls kill/continue, merges builder output. Never writes implementation code.
- **Builder** — the execution role: a cheaper model run headless via `architect
  dispatch`, one per lane in its own git worktree. Reads the iteration's Builder
  Prompt, does the work, writes raw evidence to `build/<id>-<lane>/report.md`.
  Never grades its own work; never edits `architecture/`.

The loop is **model-agnostic** — which models fill the two roles is your choice
(e.g. a strong Claude model judging a cheaper one on the same plan, or a
cross-vendor pairing for more independent review). Set it per dispatch with
`architect dispatch --model …`, or run several pairings head-to-head as a
**variant set** (`architect variant add`). See
[docs/DESIGN.md](docs/DESIGN.md) §1–§2 for the reasoning.

**Filesystem layout:**

```text
architecture/
  ARCHITECT.md              # cross-iteration index; project-wide state
  BRIEF.md                  # durable §-numbered project contract (optional)
  I01-<iteration>.md        # one self-contained file per iteration
build/
  I01-<iteration>-<lane>/   # lane worktree + scratch per dispatch
    run.jsonl               # streamed builder output
    report.md               # builder report (transcribed into the iteration file verbatim)
```

**Iteration file anatomy** — one file, grown section by section. You author the
*content*; the CLI owns the *persistence* (each command writes the section,
commits it with the canonical message, and prints back what changed):

| Section | Holds | How you persist it |
|---------|-------|--------------------|
| `## Grounds` | why — research / brief distilled (optional) | `architect section <it> grounds --from <f>` |
| `## Specification` | what/how — the full delegation contract | `architect section <it> specification --from <f>` |
| `## Acceptance Criteria` | proof — exact gate commands + thresholds | `architect freeze <it>` ❄️ |
| `## Builder Prompt` | the exact lane-prompt(s) dispatched | `architect section <it> prompt --append --lane <l> --from <f>` |
| `## Builder Report` | raw evidence, transcribed verbatim | `architect evidence <it> --lane <l>` |
| `## Verdict` | rulings + per-AC PASS/FAIL + KILL/CONTINUE | `architect section <it> verdict --from <f>` |

**The freeze ❄️** — `architect freeze <iteration>` commits the frozen region
(Grounds / Specification / Acceptance Criteria), records the `freeze_sha`, and
prints the frozen Acceptance Criteria back. Any change to those sections
afterward is an automatic iteration FAIL. The builder never edits the iteration
file.

**Re-grounding 🧭** — `architect init` also scaffolds a `SessionStart` hook that
runs `architect ground` (emitting `ARCHITECT.md`, `BRIEF.md`, and the in-flight
iteration) so every fresh session starts oriented — the loop leans on
fresh-session judgment, and this is what makes picking up cold cheap. Builders
inside a lane worktree are never grounded.

**Command surface:**

```sh
architect init                              # scaffold ARCHITECT.md + the space.yaml project: block + SessionStart hook
architect brief new                         # scaffold the durable project BRIEF.md
architect new <iteration>                   # scaffold architecture/I<NN>-<iteration>.md
architect section <it> <section> --from <f> # write + commit a section
architect freeze <iteration>                # freeze the Acceptance Criteria ❄️
architect worktree add <repo> <it> <lane>   # isolated worktree per lane (2–4 lanes)
architect dispatch <it> <lane>              # dispatch a builder (add --detach to survive long runs)
architect verify <iteration>                # post-flight mechanical checks (reports only)
architect evidence <it> --lane <lane>       # transcribe the builder's report verbatim
architect gate <iteration>                  # run the frozen gate commands, stream raw output
architect merge <it> <lane>                 # integrate ONE judged-passing lane (--no-ff)
architect integrate <it> --lanes a,b        # integrate a set of passing lanes, in order
architect land                              # end-of-project PR command (no push, no gh)
architect status                            # project state (read-only)
architect variant add|compare|promote …     # competing (harness, model) lanes over one frozen spec
architect research dispatch|status|wait …   # parallel read-only research lanes (see below)
```

A typical session:

```sh
architect init                                   # first time
architect new my-feature                         # scaffold I01-my-feature.md
architect section my-feature specification --from spec.md
architect freeze my-feature                      # lock it ❄️
architect dispatch my-feature lane-a --detach    # send a builder; poll the report
architect verify my-feature                      # mechanical post-flight checks
architect evidence my-feature --lane lane-a      # transcribe raw evidence
architect gate my-feature                        # run the frozen gates yourself
# … read the diff against the spec, then write the Verdict …
architect integrate my-feature --lanes lane-a    # merge passing lanes → project/<slug>
architect land                                   # print gh pr create at project end
```

### Streaming builder output 📡

`architect dispatch` can push the builder's stream-json to an ingest server for
live viewing:

```sh
# Push to an already-created run (you supply the full ingest URL):
architect dispatch my-feature lane-a \
  --push-url   $HOST/runs/<id>/ingest \
  --push-token $INGEST_TOKEN

# Create a run and push in one step (requires --push-token = server's INGEST_TOKEN):
architect dispatch my-feature lane-a \
  --push-host  $HOST \
  --push-token $INGEST_TOKEN
```

`--push-host` POSTs to `<HOST>/runs`, parses the new run id from the `201`
response, derives `<HOST>/runs/<id>/ingest`, and streams there; the created run
id and ingest URL are printed after dispatch starts. `--push-url` and
`--push-host` are mutually exclusive, both require `--push-token`, and neither
can be combined with `--detach` (the push tees the live pipe in-process).

### Research lanes 🔭

When an iteration needs facts the repo doesn't already have, fan out parallel
**read-only** research lanes — detached `claude -p` researchers (no
Edit/Write/Bash) that you supervise:

```sh
architect research dispatch 01-official-api.prompt.md 02-changelog.prompt.md
architect research wait        # tails each lane's run.jsonl; --level 1-4, --quiet, --thinking
architect research status      # status of dispatched runs
```

Researchers gather; the architect verifies the load-bearing claims against
sources and writes the iteration's **Grounds** section.

### Skills 🧠

`architect install-skills` installs the bundled `architect`,
`architect-research`, and `architect-vocabulary` skills for your harness:

```sh
architect install-skills                         # default: claude (~/.claude/skills/)
architect install-skills --provider opencode     # or codex | pi
architect install-skills --project               # into ./… instead of globally
architect install-skills --dry-run               # show what would change
```

`architect-vocabulary` loads the system's terms and a short orientation when
you're in a space but don't want to run the loop.

## Fish shell integration 🐟

Shells can't let a child process change *their* working directory, so `space`
and `src` each ship a small fish wrapper function plus completions (commands,
subcommands, spaces, statuses, config keys, repo refs). Install into fish's
autoloaded directories:

```fish
space shell fish install
src shell fish install
exec fish
```

After restarting fish (or `exec fish`), `space new "…"` and
`space use <id>` will `cd` into the selected space once the command succeeds;
every other command keeps normal CLI behavior. 🚪 The functions and completions
are written under `~/.config/fish/`, so there's no need to edit `config.fish`.
For one-off testing without installing:

```fish
space shell init fish | source
```

## Configuration ⚙️

Config lives at `~/.config/space-architect/config.yml` (XDG-aware) and defaults to:

```yaml
version: 1
base_dir: ~/architect            # spaces_dir + src_dir hang off this by default
default_provider: github.com
default_organization:
git_clone_protocol: ssh          # ssh | https
```

Derived defaults: `spaces_dir` → `<base_dir>/spaces`, `src_dir` (evergreen
checkout root) → `<base_dir>/src`. Override either explicitly. View values with
`space config show`; set one with `space config set KEY VALUE`. Editable keys:
`base_dir`, `spaces_dir`, `src_dir`, `default_provider`, `default_organization`,
`git_clone_protocol`.

## Repos: evergreen, copy-on-write, concurrent ⚡

Repos are added to the current space under `repos/` and tracked in `space.yaml`.
When an up-to-date evergreen checkout exists at
`<src_dir>/<host>/<owner>/<name>` (e.g.
`~/architect/src/github.com/example-org/example-app`), `space` copies it into the
space instead of cloning over the network — a copy-on-write clone on APFS. ⚡
Set `src_dir` empty to always clone:

```sh
space config set src_dir ""
```

Clone URLs default to SSH (`git@github.com:example-org/example-app.git`); switch
with `space config set git_clone_protocol https`. Multiple repos passed to
`space repo add` are fetched **concurrently**, up to five at a time, on fibers —
no threads, all cooperative. 🧵 After each repo lands, `space` runs `mise trust`
in it. Each space also gets a workspace-local `tmp/` — use it instead of `/tmp`.

## Embedding 📚

The library is split into three namespaces you can require independently:

- **`Space::Core`** — the foundation: config, state, XDG, terminal, git/mise
  clients, the space store. The `space` CLI runs on this alone.
- **`Space::Architect`** — project state, the builder harness, dispatch, and the
  research supervisor.
- **`Space::Src`** — the evergreen engine (tracking, sync, copy-on-write clone).

```ruby
require "space_core"       # just spaces
require "space_architect"  # the full loop (pulls in core + src)
require "space_src"        # just the evergreen engine
```

## Documentation 📖

- **[Command Reference](docs/reference.md)** — every command, flag, and behavior
- **[Design](docs/DESIGN.md)** — the source-backed rationale: the twelve invariant rules (R1–R12), the failure-mode → mitigation table, and why the loop is shaped this way
- **[Changelog](CHANGELOG.md)** — release history

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
