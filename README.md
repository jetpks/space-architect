# Space Architect 🚀

[![Gem Version](https://badge.fury.io/rb/space-architect.svg)](https://badge.fury.io/rb/space-architect)

> **The Architect Loop — structured judgment-and-build cycles for humans and their agents!** ✨🛰️

`space-architect` is the gem behind the **Architect Loop**: a structured
judgment-and-build cycle for you and a fleet of headless AI builders, run
inside task-scoped **spaces** — directories that hold repos, notes, and
artifacts under one obvious filesystem root. 🌌

It installs **one executable**, `architect`. The spaces substrate and the
evergreen-checkout engine live in two sibling gems:

| Gem | Dependency | What it provides |
|-----|------------|------------------|
| **space-cadet** | hard | The spaces substrate (`Space::Core`): create, manage & containerize task-scoped workspaces — the `space` binary — plus the copy-on-write evergreen-checkout substrate (`Cloner`, `SCM`) repos provision from |
| **repo-tender** | soft | Evergreen clone tending — the `repo-tender` binary (with the deprecated `src` shim) — and the launchd agent the `architect sessions agent` commands drive. Install with `gem install repo-tender` when you want the session-sync rail — everything else works without it |

Until 8.x this gem was the monolith: it shipped `space`, `architect`, and `src`
binaries (and `architect space …` / `architect src …` forwarders) plus the
vendored `Space::Core` / `Space::Src` subtrees. The 9.0.0 split carved the
tools into their own gems; this gem is the loop only. If you're on 8.x, get
`space` from the **space-cadet** gem and `src` from **repo-tender** now — and
`gem uninstall space-architect` first: the 8.x gem's `space`/`src` executables
collide with the ones the new gems ship.

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

Run an `architect` command from inside a space and it just works — the loop
walks up from `$PWD` until it finds the nearest `space.yaml`. No "current
space" state to get out of sync; where you *are* is the space you mean. 🧭

Create and manage spaces with the **space-cadet** gem:

```sh
space init                                        # create XDG config + state files
space new "Name of Space" -r org/repo -r org/lib  # blast off a new space 🚀
space list                                        # see all your spaces
```

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
gem install repo-tender   # optional: enables the sessions launchd agent
```

The gem installs one executable: `architect`. 🎀

## Quick start 🎀

```sh
# Spaces (space-cadet gem)
space init                                        # create XDG config + state files
space new "Name of Space" -r org/repo -r org/lib  # blast off a new space 🚀
space use 20260531-name-of-space                  # cd into a space by id

# Architect Loop (run from inside a space)
architect install-skills                          # install agent skills (once per machine)
architect init                                    # scaffold ARCHITECT.md + architecture/
architect new my-feature                          # scaffold the next iteration file
architect freeze my-feature                       # lock the Acceptance Criteria ❄️
architect dispatch my-feature lane-a              # send a headless builder to work
```

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
*content* in fresh scratch files; the CLI owns the *persistence* (each command
writes the section, commits it, and prints back what changed). Every committing
command takes `-m`/`--message` and `--message-from <file>` — your first line
completes the subject after a short canonical prefix (`I01 spec: <subject>`),
the rest becomes the body. The space's git log is the loop's durable memory:
write detailed messages.

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
architect brief new --from <f>              # write the durable project BRIEF.md (authored in a scratch file)
architect new <iteration>                   # scaffold architecture/I<NN>-<iteration>.md
architect section <it> <section> --from <f> # write + commit a section (add -m/--message-from for a detailed commit)
architect freeze <iteration>                # freeze the Acceptance Criteria ❄️
architect worktree add <repo> <it> <lane>   # isolated worktree per lane (2–4 lanes)
architect dispatch <it> <lane> --prompt <f> # copy the lane prompt in + dispatch a builder (--detach to survive long runs)
architect verify <iteration>                # post-flight mechanical checks (reports only)
architect evidence <it> --lane <lane>       # transcribe the builder's report verbatim
architect gate <iteration>                  # run the frozen gate commands, stream raw output
architect merge <it> <lane>                 # integrate ONE judged-passing lane (--no-ff)
architect integrate <it> --lanes a,b        # integrate a set of passing lanes, in order
# landing (PR body + push/PR command) is the architect's end-of-project procedure (see skill)
architect status                            # project state (read-only)
architect variant add|compare|promote …     # competing (harness, model) lanes over one frozen spec
architect research dispatch|status|wait …   # parallel read-only research lanes (see below)
```

`architect help` (or bare `architect`, `architect --help`) lists these grouped by
loop phase — **Spec · Build · Judge · Land · Project · Groups**, in canonical
order — and, inside an architect space, ends with a compact loop-status block
(project status + current iteration) so you can see where you are in the loop. 🧭

A typical session:

```sh
architect init                                   # first time
architect new my-feature                         # scaffold I01-my-feature.md
architect section my-feature specification --from spec.md -m "pull-based dispatcher seam"
architect freeze my-feature                      # lock it ❄️
architect dispatch my-feature lane-a --prompt tmp/prompts/I01-lane-a.md --detach   # send a builder; poll the report
architect verify my-feature                      # mechanical post-flight checks
architect evidence my-feature --lane lane-a      # transcribe raw evidence
architect gate my-feature                        # run the frozen gates yourself
# … read the diff against the spec, then write the Verdict …
architect integrate my-feature --lanes lane-a    # merge passing lanes → project/<slug>
# landing (PR body + push/PR command) is the architect's end-of-project procedure (see skill)
```

### Streaming builder output 📡

`architect dispatch` can push the builder's pi JSONL event stream to an ingest
server for
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
**read-only** research lanes — detached `pi -p --mode json` researchers
(read-only by prompt contract; the supervisor-injected guard denies git writes)
that you supervise:

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

### Sessions: the launchd rail 🛰️ (requires repo-tender)

`architect sessions sync` uploads new conversation transcripts (`~/.pi/agent/sessions`
and `~/.claude/projects`) to a space-server; `architect sessions agent
install|uninstall|status` manages the per-user launchd agent that runs the sync
on an interval. These commands drive **repo-tender**'s launchd agent — a *soft*
dependency, deliberately absent from the gemspec: without the gem, the sessions
agent commands print a short error naming the fix (`gem install repo-tender`)
and the rest of `architect` is unaffected.

## Configuration ⚙️

The spaces config the loop reads lives at `~/.config/space-cadet/config.yml`
(XDG-aware, owned by the space-cadet gem) — see `space config show`. The loop
itself has no config of its own: a space's `space.yaml` `project:` block *is*
the loop's state.

## Embedding 📚

Two namespaces, published as two gems:

- **`Space::Core`** (the space-cadet gem) — the substrate: config, state, XDG,
  terminal, git/mise clients, the space store. The `space` CLI runs on this.
- **`Space::Architect`** (this gem) — project state, the builder harness,
  dispatch, and the research supervisor, over the `Space::Core` substrate.

```ruby
require "space_core"       # just spaces (space-cadet gem)
require "space_architect"  # the loop (pulls in the space-cadet gem)
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
