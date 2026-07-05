# Command Reference 📖

Every Space Architect (`space-architect`) command, flag, and behavior. The gem installs three first-class binaries — `architect`, `space`, and `src` — over clean `Space::Architect` / `Space::Core` / `Space::Src` seams. `architect` also forwards `architect space …` and `architect src …` to the other two, so a project can drive everything from one command; this reference documents commands under those forwarded prefixes, but each works identically as a bare `space …` / `src …` invocation. 🚀

## Global options 🎨

These work on any command:

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `--color` | `auto` `always` `never` | `auto` | Color output. `--colors` is accepted too. |

Color defaults to auto-detection: colorized when stdout is a TTY, plain otherwise. Paths under your home directory are displayed as `~/...` in human-oriented output.

## Space resolution 🧭

Commands that take an optional `[SPACE]` resolve it in this order:

1. An explicit id or slug passed on the command line.
2. Otherwise, the nearest parent directory of `$PWD` containing a `space.yaml`.

Being *inside* a space is what makes it current — `architect space use` records recent state and prints a path, but it never overrides `$PWD`-based resolution.

## Architect Loop commands 🔄

These root-level commands manage the Architect Loop within a space. `architect help` (or bare `architect`, `architect --help`) lists them grouped by loop phase — Spec, Build, Judge, Land, Project, Groups — in canonical order; inside an architect space the listing ends with a compact loop-status block (project status + current iteration).

### `architect init [SPACE]`

Scaffold (or top up) the architect project in the current space: creates `architecture/ARCHITECT.md`, adds the `project:` block to `space.yaml`, and writes a `.claude/settings.json` `SessionStart` hook that re-grounds fresh sessions (see `architect ground`). Idempotent — it writes only the pieces that are missing and never overwrites existing files, so it is safe to re-run (e.g. to add the hook to a project created before it existed).

```sh
architect init
architect init 20260531-name-of-space
```

### `architect ground [SPACE]`

Print the grounding reads for a fresh session to stdout — `architecture/ARCHITECT.md`, `architecture/BRIEF.md` (if present), and the in-flight iteration file — under per-file delimiters. This is what the `SessionStart` hook scaffolded by `architect init` runs, so a resumed or newly-cleared session starts oriented without re-reading by hand. Emits nothing (exit 0) when invoked from inside a lane worktree under `build/`, so builders are never grounded. `CLAUDE.md` is never re-emitted.

```sh
architect ground
```

### `architect install-skills [--provider=PROVIDER] [--project] [--force]`

Install the bundled skills (`architect`, `architect-research`, and `architect-vocabulary`) for a harness. Run this once per machine after installing the gem, or after upgrading to pick up skill changes.

```sh
architect install-skills                              # claude (default) → ~/.claude/skills/
architect install-skills --provider opencode           # → ~/.config/opencode/skills/
architect install-skills --provider codex              # → ~/.agents/skills/
architect install-skills --provider pi                 # → ~/.pi/agent/skills/
architect install-skills --project                     # install to ./.claude/skills/ instead of global
architect install-skills --force                       # overwrite existing skills that differ
architect install-skills --dry-run                      # print what would happen without writing
```

| Option | Default | Description |
|--------|---------|-------------|
| `--provider=VALUE` | `claude` | Harness: `claude`, `codex`, `opencode`, `pi`. |
| `--project` | `false` | Install to the current working directory instead of global. |
| `--force` | `false` | Overwrite existing skills that differ from the bundled source. |
| `--dry-run` | `false` | Print what would happen without writing any files. |

Provider destination paths:

| Provider | Global | `--project` |
|----------|--------|-------------|
| `claude` | `~/.claude/skills/` | `./.claude/skills/` |
| `codex` | `~/.agents/skills/` | `./.agents/skills/` |
| `opencode` | `~/.config/opencode/skills/` | `./.opencode/skills/` |
| `pi` | `~/.pi/agent/skills/` (or `$PI_CODING_AGENT_DIR/skills/`) | `./.pi/skills/` |

### `architect new ITERATION [SPACE]`

Scaffold the next iteration file at `architecture/I<NN>-<ITERATION>.md` from the iteration template. Allocates the next ordinal and records the iteration in `space.yaml`.

```sh
architect new dry-cli-port
architect new dispatch-engine 20260531-name-of-space
```

### `architect status [SPACE]`

Show the Architect Loop project state: current iteration, the iteration index table (ordinal, freeze SHA, lanes, verdict), and iteration files. Read-only.

```sh
architect status
architect status 20260531-name-of-space
```

### `architect freeze ITERATION [SPACE]`

Commit the iteration file (Grounds + Specification + Acceptance Criteria must be present) and record its SHA as `freeze_sha` in `space.yaml`. Refuses to re-freeze once the frozen sections have changed.

```sh
architect freeze dry-cli-port
architect freeze dry-cli-port 20260531-name-of-space
```

### `architect verify ITERATION [SPACE]`

Post-flight mechanical checks for an iteration — reports only, no judgment. Per lane: (a) frozen sections untouched since freeze, (b) builder made no commits in the worktree, (c) the builder's scratch report `build/<id>-<lane>/report.md` exists, (d) builder stayed in-bounds per the lane's declared touch set.

```sh
architect verify dry-cli-port
architect verify dry-cli-port 20260531-name-of-space
```

### `architect dispatch ITERATION LANE [SPACE]`

Dispatch a builder for a lane: runs the harness (`claude -p` by default) headless in the lane's worktree, reads the lane's `build/<id>-<lane>/prompt.md`, and streams the full conversation to `build/<id>-<lane>/run.jsonl`, with the builder's report at `build/<id>-<lane>/report.md`. Refuses to dispatch a missing, empty, or still-stubbed prompt.

```sh
architect dispatch dry-cli-port lane-a
architect dispatch dispatch-engine lane-b 20260531-name-of-space --model claude-opus-4-8
architect dispatch dry-cli-port lane-a --max-turns 100
architect dispatch dry-cli-port lane-a --detach          # returns a PID; poll report.md
```

| Option | Default | Description |
|--------|---------|-------------|
| `--model=VALUE` | lane entry, else the reference default `claude-sonnet-4-6` | Builder model to pin — any provider/tier; pin a full id, not a floating alias. |
| `--max-turns=VALUE` | `200` | Max conversation turns. |
| `--harness=VALUE` | lane entry, else `claude-code` | Harness override (`claude-code`, `opencode`). |
| `--effort=VALUE` | — | Reasoning effort (opencode only; sets `reasoningEffort` in the model config). |
| `--detach` | `false` | Detach the builder process — returns immediately with a PID; poll `report.md` for completion. Cannot combine with `--push-url`/`--push-host`. |
| `--timeout=SECONDS` | `14400` (4h) | Wall-clock timeout; the wedged builder's process group is killed. `0` disables. Foreground only. |
| `--push-url=URL` | — | Stream the builder's stream-json to an already-created run's ingest URL (requires `--push-token`). |
| `--push-host=URL` | — | Create a run via `POST <host>/runs` and stream to the derived ingest URL (requires `--push-token`; mutually exclusive with `--push-url`). |
| `--push-token=TOKEN` | — | Bearer token for the ingest endpoint. |

### `architect worktree [SUBCOMMAND]`

Manage per-lane git worktrees under `build/`.

```sh
architect worktree add my-app dry-cli-port lane-a
architect worktree add my-app dry-cli-port lane-a --base main
architect worktree list
architect worktree remove dry-cli-port lane-a
```

| Command | Description |
|---------|-------------|
| `worktree add REPO ITERATION LANE` | Create a worktree at `build/<id>-<lane>/wt` and record the lane in `space.yaml`. Idempotent — re-adding a lane reuses the existing worktree/branch and merges the new options in place. |
| `worktree list` | List active architect worktree directories. |
| `worktree remove ITERATION LANE` | Remove the lane worktree. |

`worktree add` options:

| Option | Default | Description |
|--------|---------|-------------|
| `--base=REF` | repo `HEAD` | Base ref for the worktree. Accepts any git ref, including the `project/<slug>` integration branch — see `### Parallel + fast-follow` in `dispatch.md`. |
| `--harness=VALUE` | `claude-code` | Harness for the lane (`claude-code`, `opencode`). |
| `--model=VALUE` | — | Model for the lane (required for `opencode`). |
| `--effort=VALUE` | — | Reasoning effort (opencode only; sets `reasoningEffort` in the model config). |
| `--touch=GLOBS` | — | Comma-separated file globs the lane may touch. Recorded as the lane's `touch_set` and enforced by the in-bounds check (`architect verify`) and by `merge`. |

### `architect section ITERATION SECTION [SPACE]`

Write a section of the current iteration file and commit it in one step. `SECTION` must be one of: `grounds`, `specification`, `prompt`, `verdict`. Provide the body via `--from <file>` (recommended for multi-line content), `--body <text>` (inline), or `--stdin`. Pass `--append --lane <name>` to stack a `### <lane>` subsection instead of replacing the section body — used to record per-lane Builder Prompts. Refuses to write a frozen section (Grounds/Specification) once the iteration is frozen.

```sh
architect section my-feature specification --from spec.md
architect section my-feature grounds --from grounds.md
architect section my-feature prompt --append --lane lane-a --from build/I01-my-feature-lane-a/prompt.md
architect section my-feature verdict --from verdict.md
```

| Option | Default | Description |
|--------|---------|-------------|
| `--from=FILE` | — | Read the section body from a file. |
| `--body=TEXT` | — | Inline section body (one-liners). |
| `--stdin` | `false` | Read the section body from stdin. |
| `--append` | `false` | Append a `### <lane>` subsection instead of replacing. |
| `--lane=NAME` | — | Lane name for an appended subsection. |

### `architect brief new [SPACE]`

Scaffold the durable project brief at `architecture/BRIEF.md` and commit it. The brief holds numbered §sections (§1 goal, §2 constraints, … §N definition of done) that span all iterations; each iteration's Specification and Verdict cites it as **BRIEF §N**. Idempotent guard: refuses if `BRIEF.md` already exists unless `--force` is passed.

```sh
architect brief new
architect brief new --force   # overwrite an existing BRIEF.md
```

| Option | Default | Description |
|--------|---------|-------------|
| `--force` | `false` | Overwrite an existing `BRIEF.md`. |

### `architect evidence ITERATION [SPACE]`

Transcribe a lane's scratch report at `build/<id>-<lane>/report.md` **verbatim** (byte-for-byte, no interpretation) into the `## Builder Report` section of the iteration file and commit. Echoes the builder's STATUS line on completion. Pass `--lane` for a per-lane subsection; omit for a single-lane iteration.

```sh
architect evidence my-feature
architect evidence my-feature --lane lane-a
```

| Option | Default | Description |
|--------|---------|-------------|
| `--lane=NAME` | — | Lane name (appends a `### <lane>` subsection; omit for single-lane iterations). |

### `architect merge ITERATION LANE [SPACE]`

Integrate a single architect-judged-passing lane: commits the builder's working-tree changes on the per-lane `lane/<id>-<lane>` branch, then merges `--no-ff` into the repo's stable `project/<slug>` branch. Runs no gates and makes no verdict — those are the architect's. Refuses a lane that left builder commits or wrote outside its declared touch set. Aborts cleanly on a merge conflict (a lane-plan disjointness defect — kill the conflicting lane and re-spec; do not hand-resolve).

```sh
architect merge my-feature lane-a
architect merge my-feature lane-a --message "lane lane-a: integrate"
```

| Option | Default | Description |
|--------|---------|-------------|
| `--message=TEXT` | `"lane <lane>: integrate"` | Commit message for the lane's working-tree changes. |

### `architect integrate ITERATION [SPACE]`

Integrate the architect-supplied set of passing lanes in order, running `merge` for each and stopping on the first conflict. The target is the stable `project/<slug>` branch (slug derived from `space.title`) shared across all iterations — `main` is never touched per-iteration. Calling `integrate` again with a new `--lanes` set appends to the same `project/<slug>` branch (used by the parallel + fast-follow pattern to stack a fast-follow lane onto the integrated tip). Pass `--teardown` to remove lane worktrees and delete per-lane `lane/<id>-<lane>` branches after merging; it never deletes the `project/<slug>` branch.

```sh
architect integrate my-feature --lanes lane-a,lane-b
architect integrate my-feature --lanes lane-a,lane-b --teardown
```

| Option | Default | Description |
|--------|---------|-------------|
| `--lanes=NAMES` | (required) | Comma-separated list of passing lane names (the architect decides the set). |
| `--teardown` | `false` | Remove worktrees and delete per-lane branches after merge. |

### `architect gate ITERATION [LANE] [SPACE]`

Run the iteration's frozen Acceptance Criteria gate commands and stream raw output per gate, reporting PASS or FAIL for each. Gate commands are always read from the freeze commit — never the working copy — so the criteria stay immutable. Without a lane argument, runs in `repos/<repo>` against the currently-checked-out branch (typically `project/<slug>` after `architect integrate`). With a lane name, runs in that lane's worktree. The mechanical results are runner output; the AC verdict is always the architect's.

```sh
architect gate my-feature
architect gate my-feature lane-a   # run in the lane worktree
```

### `architect verdict ITERATION DECISION [SPACE]`

Record the architect's verdict for an iteration: writes the `## Verdict` prose to the iteration file and records the decision (`continue` or `kill`) in `space.yaml`, committed in one step. The verdict covers disagreement rulings (ACCEPT/REJECT/MODIFY + one line each), per-AC PASS/FAIL/INVALID results, and the KILL/CONTINUE call with the single decisive reason. Provide the body via `--from <file>`, `--body <text>`, or `--stdin`.

```sh
architect verdict my-feature continue --from verdict.md
architect verdict my-feature kill --body "AC2 gate failed: 0 tests found"
```

| Option | Default | Description |
|--------|---------|-------------|
| `--from=FILE` | — | Read the verdict body from a file. |
| `--body=TEXT` | — | Inline verdict body. |
| `--stdin` | `false` | Read the verdict body from stdin. |

> **Note:** landing is not a CLI command. At project end the architect writes the PR body and presents the push + `gh pr create` block — see the architect skill's procedure.

### `architect variant [SUBCOMMAND]`

Manage competing-lane variant sets — multiple `(harness, model)` lanes over one byte-identical frozen spec, used to compare builder strategies or model tiers head-to-head. Judge every variant against the same frozen AC before promoting a winner.

```sh
architect variant add my-app my-feature --pairs "claude-code,opencode:fireworks-ai/accounts/fireworks/models/glm-5p2"
architect variant compare my-feature
architect variant promote my-feature v02
```

| Command | Description |
|---------|-------------|
| `variant add REPO ITERATION --pairs PAIRS [--base REF] [--prompt FILE]` | Create a variant set: one worktree per `harness[:model]` pair. |
| `variant compare ITERATION` | Side-by-side view of all variants (winner, harness, model, integration branch, status). |
| `variant promote ITERATION WINNER` | Promote one variant as the winner; marks others discarded. |

### `architect research [SUBCOMMAND]`

Fan out parallel, **read-only** research lanes — detached `claude -p` researchers with no Edit/Write/Bash — when an iteration needs facts the repo doesn't already have. A socketry/async fiber mux tails each lane's `run.jsonl`; the architect verifies the load-bearing claims against sources and writes the iteration's `## Grounds`.

```sh
architect research dispatch 01-official-api.prompt.md 02-changelog.prompt.md
architect research wait          # tails every lane until all complete
architect research status        # snapshot of dispatched runs
```

| Command | Description |
|---------|-------------|
| `research dispatch PROMPTS...` | Dispatch one detached researcher per prompt file (space-separated paths). |
| `research status [SPACE]` | Show the state of dispatched research runs (id, pid, state, model, last line). |
| `research wait [SPACE]` | Wait for all dispatched runs to complete, streaming their output. |

`research dispatch` options:

| Option | Default | Description |
|--------|---------|-------------|
| `--model=VALUE` | reference default `claude-sonnet-4-6` | Researcher model override (any provider/tier). |
| `--max-turns=VALUE` | `40` | Max turns per researcher. |

`research wait` options:

| Option | Default | Description |
|--------|---------|-------------|
| `--level=N` | `1` | Verbosity: `1`=lifecycle, `2`=+text, `3`=+tools, `4`=+io. |
| `--quiet` | `false` | Suppress all output; exit status only (L0). |
| `--thinking` | `false` | Show assistant thinking blocks. |
| `--jsonl` | `false` | Emit raw lane-tagged JSONL (mutually exclusive with `--level`/`--quiet`). |

## Space management: `architect space …` 🗂️

Manage project spaces. These commands are also accessible via the `space` shim (e.g., `space new "Title"` → `architect space new "Title"`).

### `architect space init`

Create the default XDG config and state files.

```sh
architect space init
```

### `architect space new TITLE [-r REPO]...`

Create a new space. The id is date-prefixed and slugged from the title (`"Name of Space"` → `20260531-name-of-space`); duplicate names on the same day get a counter (`...-name-of-space-2`). Repos are passed with a repeatable `-r` flag (the comma form `-r a,b` works too) and are cloned into the new space immediately.

```sh
architect space new "Name of Space"
architect space new "Name of Space" -r example-tools/alpha -r example-tools/beta
architect space new "Name of Space" --no-git   # skip git init
```

| Option | Description |
|--------|-------------|
| `-r, --repo=REPO` | Repo ref to clone; repeat once per repo (comma form also accepted). |
| `--[no-]git` | Initialize the space as a Git repository (default: `--git`). |

### `architect space list` (alias `architect space ls`)

List all spaces, compact and human-readable.

```sh
architect space list
architect space ls --color=always
```

### `architect space show [IDENTIFIER]`

Show metadata for a space, or the current space when no id is given.

```sh
architect space show
architect space show 20260531-name-of-space
```

### `architect space path [IDENTIFIER]`

Print *only* the path for a space (handy for scripting).

```sh
architect space path
architect space path 20260531-name-of-space
```

### `architect space use IDENTIFIER`

Record a space in recent state and print its path.

```sh
architect space use 20260531-name-of-space
```

### `architect space current`

Show the current space, resolved from `$PWD`.

```sh
architect space current
```

### `architect space status [SPACE] [STATUS]`

**Report or set.** With no status keyword — bare, or with just a space id — it *reports* the space: its metadata (ID, Title, Status, Path, Created, Updated) followed by a compact loop-status block (project status, current iteration, derived state) when the space runs an Architect project, quietly omitted for a non-architect space. Pass a status keyword to *set* it instead; supported statuses: `active`, `paused`, `done`, `archived`.

```sh
architect space status                                   # report the current space
architect space status 20260531-name-of-space            # report another space
architect space status done                              # set the current space's status
architect space status 20260531-name-of-space archived   # set another space's status
```

### `architect space config [SUBCOMMAND]`

Show or update configuration.

```sh
architect space config show
architect space config path
architect space config set default_provider github.com
architect space config set default_organization example-org
architect space config set git_clone_protocol https
architect space config set src_dir ""                    # disable evergreen copy-on-write (always clone)
```

Config lives at `~/.config/space-architect/config.yml` (XDG-aware):

```yaml
version: 1
base_dir: ~/architect            # spaces_dir + src_dir hang off this by default
default_provider: github.com
default_organization:
git_clone_protocol: ssh          # ssh | https
```

`spaces_dir` defaults to `<base_dir>/spaces` and `src_dir` (the evergreen checkout root) to `<base_dir>/src`; set either explicitly to override. Editable keys: `base_dir`, `spaces_dir`, `src_dir`, `default_provider`, `default_organization`, `git_clone_protocol`.

### `architect space repo [SUBCOMMAND]` (alias `architect space repos`)

Manage repos in the current space.

```sh
architect space repo add example-app
architect space repo add example-tools/alpha example-tools/beta
architect space repo add gitlab.com/example-org/api
architect space repo list            # alias: ls
architect space repo resolve example-app example-tools/async
```

- **add** — add repos into `repos/` (copy-on-write from an evergreen checkout under `src_dir` when available, else clone), concurrently up to five at a time.
- **list** / **ls** — list repos tracked in the current space.
- **resolve** — print the resolved full name and clone URL without cloning.

### `architect space shell [SUBCOMMAND]`

Manage shell integration. Only `fish` is supported today.

```sh
architect space shell init fish              # print the fish function to stdout
architect space shell fish install           # install function + completions
architect space shell fish install --force   # overwrite existing files
architect space shell fish uninstall
architect space shell fish path              # print install paths
architect space shell complete spaces        # print completion candidates
```

### `architect space pack`

Render a portable OCI build context for the current space into `build/oci/` (override with `-o`): a `Dockerfile`, an executable `entrypoint.sh`, and a `Dockerfile.dockerignore`. The Dockerfile is rendered in cache-hygiene layer order: stable system layers first, then each `pack.provision` script copied and run individually, then the gem install, then the full space tree. This means a space-content edit after a cold build leaves the provision and gem-install layers cached — only `COPY . /space` and later re-run, so the rebuild completes in seconds. The gem is installed from the in-space `repos/space-architect` checkout when present (determined at render time), else from RubyGems; the generated ignore file keeps secrets and scratch (`.env`, `*.key`, `*.pem`, ssh keys, `build/`, `tmp/`) out of the layers. Reads and validates the `pack.provision` / `pack.persist` keys from `space.yaml` (see below). Writes the context only — no image is built.

```sh
architect space pack
architect space pack -o /tmp/space-ctx
```

| Option | Description |
|--------|-------------|
| `-o, --output=DIR` | Output directory for the build context (default: `build/oci/` under the space root). |

### `architect space build`

Pack, then build **and tag** the image via the `container` CLI. Two tags are applied: `<space-id>:<sha>` — where `<sha>` is the space repo's 12-char `HEAD`, suffixed `-dirty` when the working tree has uncommitted changes — and a moving `<space-id>:latest`. Same commit ⇒ same tag ⇒ same image (reproducible by SHA). Requires the space to be a Git repository with at least one commit. The generated context is a standard OCI/Docker build context, so `docker build -f build/oci/Dockerfile .` from the space root builds the same image with any OCI builder.

```sh
architect space build
```

### `architect space run [COMMAND]`

Run `<space-id>:latest` via `container run --rm`, injecting auth and mounting persisted state. With no `COMMAND` it starts a login shell; pass a command to run it once instead. Only the auth environment variables that are actually set are forwarded with bare `-e VAR` — `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_BASE_URL` — so credentials are never baked into the image. Each `pack.persist` path is bind-mounted from `<space>/.state<path>` on the host (created before the run) so container state survives across runs.

Vars declared under `run.env:` in `space.yaml` and vars passed via `--env` are also forwarded as bare `-e VAR` passthrough — values never appear in argv, `ps`, or the image. Declared vars that overlap the always-on auth trio are deduplicated to a single `-e`. A requested-but-unset var emits a stderr warning and is omitted from argv (it does not fail the run).

```sh
architect space run                         # login shell
architect space run architect status        # one-off command
architect space run --tty                   # force an interactive TTY
architect space run --env FIREWORKS_API_KEY -- hermes -z 'hello' # ad hoc env forward; -- keeps the payload's flags from the CLI parser
```

| Option | Description |
|--------|-------------|
| `--[no-]tty` | Force (or disable) an interactive TTY. Default: auto-detected from the output stream. |
| `--env VAR` | Forward a host env var into the container as bare `-e VAR` (repeatable; adds to `run.env:`). |

### Declaring provisioning, persistence & runtime env (`space.yaml`)

The `pack`-family commands and `space run` read optional keys from `space.yaml`:

```yaml
pack:
  provision:                 # build-time scripts, each COPY'd and RUN before the space tree lands
    - scripts/setup-toolchain.sh
  persist:                   # absolute guest paths, bind-mounted from <space>/.state<path> at run
    - /root/.claude
run:
  env:                       # host var names forwarded as bare -e VAR at run time (values never baked)
    - FIREWORKS_API_KEY
```

**`provision` contract.** Entries must be space-root-relative paths that exist under the space and must be executable (COPY preserves the bit from the build context). Each script is copied into the image individually — `COPY <script> /space/<script>` immediately followed by `RUN /space/<script>` — so its cache key is the script's own content: editing any other space file leaves its layer cached. Scripts run **before** the full space tree is copied and **before** the gem is installed, in declared order. A script therefore sees only the base system layers plus outputs of any earlier scripts; it must be self-contained (network + its own file only) and cannot read other space files or call `architect`/`space`. The payoff: after the first (cold) build, a space-content edit triggers only `COPY . /space` and later — provision and gem-install layers stay cached and the rebuild completes in seconds.

`persist` entries must be absolute. Both `provision` and `persist` are validated at pack time — an absolute or missing provision path, a provision path that escapes the space root, or a relative persist path fails the command before anything is written.

**`run.env` contract.** Entries are host env var **names only** — values are never written to `space.yaml` or baked into the image (R5). At `space run` time, each named var is read from the host and forwarded as bare `-e VAR` (no `=value` in argv). A var that is unset or empty on the host is omitted from argv and a stderr warning names it — the run continues so you can diagnose which credential is missing. Vars that overlap the always-on auth trio are deduplicated. Ad hoc additions use `space run --env VAR` (repeatable).

## Evergreen engine: `architect src …` 🌲

The evergreen engine (`space-src`, exposed as `src`) keeps canonical copies of tracked repos in sync so spaces can clone via fast APFS copy-on-write. Run `architect src --help` to list available subcommands.

> **Note:** these commands appear under `architect src <verb>` but are not listed in root `architect --help`. Discover them via `architect src --help`.

### `architect src clone NAMES`

Clone evergreen repo(s) into a working directory via APFS COW copy.

```sh
architect src clone example-app
architect src clone example-tools/alpha example-tools/beta
architect src clone github.com/example-org/api --into ~/work
```

| Option | Description |
|--------|-------------|
| `--into=DIR` | Destination parent directory (default: `$PWD`). |
| `--json` | JSON output (one object per event line). |
| `--plain` | Plain text output, no color. |
| `--quiet, -q` | Suppress non-essential output. |

### `architect src sync`

Run one sync pass — fetch + fast-forward all tracked repos.

```sh
architect src sync
architect src sync --repo github.com/example-org/api   # scope to one repo
```

### `architect src status`

Show the per-repo evergreen status table (source: `$XDG_STATE_HOME/space-src/state.yaml`).

```sh
architect src status
```

### `architect src repo [SUBCOMMAND]`

Manage tracked repos in the evergreen store.

```sh
architect src repo add example-org/api
architect src repo list
architect src repo remove example-org/api
```

### `architect src org [SUBCOMMAND]`

Manage tracked orgs (all repos under an org are synced automatically).

```sh
architect src org add github.com/example-org
architect src org list
architect src org remove github.com/example-org
```

### `architect src config [SUBCOMMAND]`

Show or locate the evergreen engine config (separate from space config).

```sh
architect src config show
architect src config path
```

### `architect src daemon [SUBCOMMAND]`

Manage the per-user launchd sync agent (macOS).

```sh
architect src daemon install
architect src daemon start
architect src daemon stop
architect src daemon restart
architect src daemon status
architect src daemon uninstall
```

## Exit codes 🚦

`architect` exits non-zero on failure — unknown space, ambiguous id, refusing to overwrite an existing file without `--force`, and so on — with a clear message on stderr.
