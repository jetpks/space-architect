# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.3] - 2026-07-01

### Added

- **`architect bug-report`** — zero-friction bug-filing command. Gathers
  diagnostics (gem version, Ruby version/platform, and when run inside a space:
  space id, title, and iteration list with verdicts), writes a prefilled GitHub
  issue-body template to `<space>/build/bug-report/architect-bug-report-YYYYMMDD-HHMMSS.md`
  (or `./architect-bug-report-YYYYMMDD-HHMMSS.md` outside a space — timestamped so
  back-to-back runs in the same session never overwrite each other), and prints —
  never executes — the `gh issue create -R jetpks/space-architect` invocation to run.

### Removed

- **`architect land` removed** (added in 2.0.0) — landing is the architect
  skill's procedure: the architect writes the PR body and presents the push +
  PR command. The command as shipped never produced a runnable block (#25) and
  authored content the CLI has no context for (#24).

### Fixed

- **`architect bug-report` — `~`-contracted paths in printed commands.**
  The `gh issue create` invocation printed to stdout renders the
  `--body-file` path as `~/…` instead of the user's expanded `$HOME`.
  `Space::Core::Paths.contract` is the single home-contraction helper; `Terminal#path`
  delegates to it.
- **Command wrapping for narrow terminals.** The `gh issue create` command is
  now rendered with trailing ` \` continuations broken at `--flag` boundaries,
  continuation lines indented two spaces. The wrapped output is valid shell
  (`bash -n` clean). `Space::Core::Commands.wrap` is the single wrapping helper.

## [2.0.2] - 2026-07-01

### Added

- **Declarative runtime env forwarding for `space run`.** A space can declare
  `run.env:` in `space.yaml` — a list of host env vars forwarded into the
  container as bare `-e VAR` passthrough (value never lands in argv/`ps`), on top
  of the always-on substrate auth vars. `space run --env VAR` (repeatable) adds
  more ad hoc. A requested-but-unset var warns on stderr instead of failing
  opaquely in-guest. This lets credentialed payloads (e.g. a Fireworks/OpenAI key)
  run via a plain `space run <cmd>` with no wall of flags, without baking secrets.

## [2.0.1] - 2026-07-01

Fast-follow completing the `pack.persist:` story from 2.0.0.

### Added

- **Seed-on-empty for `pack.persist:`.** Content baked at a persisted path now
  survives a first-run empty bind mount. `space pack` snapshots each persisted
  dir to a `/opt/space-seed<path>` sidecar after provisioning, and the entrypoint
  restores an empty mount from its seed on first run only (a non-empty mount
  keeps its evolving state). Previously the empty host mount shadowed the baked
  content — e.g. a provisioned `~/.hermes/config.yaml` was hidden once
  `/root/.hermes` was persisted. Template-only; a space with no `pack.persist:`
  renders an identical Dockerfile and entrypoint.

### Fixed

- **First-run boot on bind-mount-root-restricted runtimes.** The seed restore
  tolerates a benign copy failure (`2>/dev/null || true`) so that on runtimes
  where the persisted path is a bind mount whose root rejects utime updates
  (virtiofs under Apple `container`), the entrypoint's `set -e` no longer turns a
  cosmetic `cp` EPERM into a fatal abort before the payload execs.

## [2.0.0] - 2026-07-01

A ground-up release across four fronts:

1. **Three composable binaries** — `space` · `architect` · `src` — over clean
   `Space::Core` / `Space::Architect` / `Space::Src` library seams (retiring the
   single `SpaceArchitect` namespace).
2. **An overhauled Architect Loop** — the "mission" vocabulary becomes
   "project," Acceptance Criteria gain a structured, runnable `gates` block, and
   the loop grows first-class verbs (`gate`, `verdict`, `land`, `ground`), an
   integration-branch-by-default workflow, and a SessionStart re-grounding hook.
3. **Reproducible space containers** — `space pack` / `build` / `run` turn a
   space into an OCI image.
4. **`space-server`** — a new Hanami + React web app to import, view, and share
   Architect spaces and AI-agent transcripts. **It ships in the repo, not in the
   gem** (the gem packages only `lib/`, `exe/`, and `skill/`).

This is a major, breaking release for both CLI users and library embedders — see
the **BREAKING** items under Changed. The repository is now a monorepo; the
`space-architect` gem lives at the root and the server under `server/`.

### Added

#### CLI — binaries, research, and dispatch

- **`src` — standalone evergreen-engine binary** (`exe/src`). `repo`, `org`,
  `sync`, `status`, `config`, `daemon`, and `clone`, plus single-token fuzzy
  navigation (`src <query>` resolves to a repo and honours the `cd` contract)
  and native fish shell integration with completions. Previously reachable only
  as `architect src …`; now a first-class binary (and still forwarded by
  `architect src …`).
- **`architect research dispatch | status | wait`** — first-class parallel,
  read-only research lanes. Detached `claude -p` researchers restricted to
  `Read,Grep,Glob,WebSearch,WebFetch` (no Edit/Write/Bash) run in the background;
  a socketry/async fiber mux tails each lane's `run.jsonl` and extracts its
  report. The architect verifies claims and writes Grounds.
- **`architect dispatch --detach`** — detached builder launch that returns
  immediately with a PID and survives the harness wall-clock reap; poll the
  lane's report for completion.
- **`architect dispatch` HTTP push** — stream a builder's live output to an
  ingest server. `--push-url <url> --push-token <tok>` POSTs the NDJSON stream to
  an existing run's ingest URL; `--push-host <host> --push-token <tok>` first
  creates the run (`POST <host>/runs`), derives `<host>/runs/<id>/ingest`, streams
  there, and prints the run id. `--push-url`/`--push-host` are mutually exclusive,
  both require `--push-token` (Bearer auth), and neither combines with `--detach`.
  The stream is teed to the run log and the endpoint concurrently over fibers.
- **`architect dispatch --timeout`** — wall-clock timeout for a builder (default
  `14400`s / 4h; `0` disables; foreground only). A wedged builder's process group
  is escalated TERM→grace→KILL and reported as timed out (exit 124).

#### Architect Loop — gates and new verbs

- **A fenced ` ```gates ` block inside each iteration's Acceptance Criteria.**
  Runnable checks are now structured YAML gates — `id`, `ac` (which prose AC it
  backs), `cmd`, optional `cwd`, an `expect` block (`exit_code` / `stdout_match`
  / `threshold`), and an optional per-gate `timeout` (seconds; default 900),
  replacing the old free-text AC table.
- **Gate linting at freeze time** (`GateLint`, via dry-validation). `architect
  freeze` validates the gates block: malformed gates fail the freeze; absent or
  empty gates warn but are allowed (prose-judged iterations); duplicate ids, bad
  threshold operators, and non-single-capture regexes are caught.
- **`architect gate` — a gate runner.** Runs the frozen Acceptance-Criteria gate
  commands (always read from the freeze commit, never the working copy) in the
  resolved repo or lane worktree, scoring captured output against each `expect`
  block with a pure `GateEvaluator`.
- **`architect verdict <iteration> continue|kill`** — records the decision in the
  `project:` block and writes the `## Verdict` prose in one commit; the first tool
  that actually persists a verdict decision.
- **`architect land`** — generates the end-of-project PR for each integrated repo
  (writes a `build/land/<repo>-pr-body.md` and prints the `gh pr create …`
  invocation). Side-effect-free: no git write, no push, no `gh` call.
- **`architect ground` + a SessionStart re-grounding hook.** `architect init`
  now also writes `.claude/settings.json` registering SessionStart hooks
  (startup/clear/resume) that run `architect ground`, re-emitting `ARCHITECT.md`,
  `BRIEF.md`, and the in-flight iteration file so a freshly cleared or resumed
  session self-orients. A worktree guard suppresses grounding inside builder
  worktrees, so builders are never fed architect context.

#### Space containers (require a `container` / OCI runtime)

- **`space pack`** — generate a portable OCI build context for the current space
  (writes `Dockerfile`, `entrypoint.sh`, and a `.dockerignore` into `build/oci/`,
  overridable with `-o/--output`) and print a build hint.
- **`space build`** — pack, then `container build`, tagging reproducibly by commit
  as `<space-id>:<git-short-sha>` plus `<space-id>:latest` (SHA suffixed `-dirty`
  when the tree is dirty).
- **`space run`** — `container run --rm` on `<space-id>:latest`, defaulting to an
  interactive login shell or a passed command, auto-detecting TTY (`--tty` to
  force). Forwards `ANTHROPIC_API_KEY` / `CLAUDE_CODE_OAUTH_TOKEN` /
  `ANTHROPIC_BASE_URL` from the host only if set — credentials are never baked
  into a layer. (All three commands are also reachable as `architect space …`.)
- **Declarative `pack:` config in `space.yaml`.** `pack.provision` — build-time
  provisioning scripts (space-relative) emitted as ordered `RUN` steps;
  `pack.persist` — absolute guest paths bind-mounted from `.state/<guest>` so
  state survives across runs. Provision paths are validated (must exist, be
  relative, and stay within the space root).
- **Git baked into the image + in-container worktrees.** The image copies the
  whole space tree (repos and history) into `/space`, installs the pinned
  in-space `space-architect`, seeds a default git identity, and sets `git
  safe.directory '*'` so `git worktree` works on the root-owned tree.

#### `space-server` (repo, not shipped in the gem)

- **A Hanami web app to view and share Architect work** (`server/`). Imports an
  Architect space and renders its iterations against the canonical six-section
  shape (Grounds · Specification · Acceptance Criteria · Builder Prompt · Builder
  Report · Verdict), alongside that space's runs and artifacts; separately ingests
  exported AI chat transcripts (Claude Code, Codex, pi, opencode) for markdown/code
  browsing, per-turn annotation, and read-only public sharing.
- **Architect-space data model + `SpaceImporter`.** New `spaces` / `iterations` /
  `artifacts` tables and a `rake space:import[/path]` task that reads a space's
  `space.yaml`, markdown artifacts, and builder run streams (`build/*/run.jsonl`)
  into Postgres — idempotent, keyed by slug/ordinal/path.
- **A stitched per-space read view (Inertia/React).** `Spaces/Index` and
  `Spaces/Show` interleave iterations and architect sessions into one
  timestamp-ordered timeline with inline transcript cards and run/artifact
  drill-downs; imported timestamps are timezone-faithful and each run carries a
  `harness · model` badge.
- **Live agent-run streaming.** Machine clients push run events over Bearer token
  auth; browsers replay them live over SSE. Pairs with the CLI's
  `architect dispatch --push-*`.
- **Session normalizers for architect transcripts.** `Normalizer::ClaudeSession`
  understands Claude Code's `~/.claude/projects/**.jsonl` session-log shape and
  `Normalizer::OpencodeSession` reads opencode's SQLite DB read-only, both
  emitting the same normalized event stream as the builder-dispatch parser.
- **Five in-tree Hanami extension gems** under `server/gems/*` (each path-loaded,
  with its own gemspec and tests): `hanami-healthcheck` (a `/up` endpoint),
  `inertia-hanami` (an Inertia.js protocol adapter), `hanami-credentials`
  (encrypted credentials store), `hanami-force-ssl` (Rack 3 HTTPS/HSTS
  middleware), and `vite-hanami` (Vite tag helpers + dev-server proxy).

### Changed

- **BREAKING — three binaries over clean seams.** `space` runs on `Space::Core`
  alone (`exe/space`); `architect` (`exe/architect`) forwards `space …` / `src …`
  to their surfaces; `src` is its own executable. The gem now installs three
  executables where 1.3.0 installed two.
- **BREAKING — Ruby namespace overhaul (library embedders).** The single
  `SpaceArchitect::*` module is retired and split into `Space::Core::*`
  (config, state, XDG, terminal, git/mise clients, space store),
  `Space::Architect::*` (project, harness, dispatch, research), and
  `Space::Src::*` (the evergreen engine). No `SpaceArchitect` constant remains —
  update any `require`s and constant references. The CLI surface is unaffected.
- **BREAKING — "mission" is now "project," with no back-compat shim.** The
  `space.yaml` project-state key `architect:` becomes `project:`; existing spaces
  are not read until the key is renamed. The core class `ArchitectMission` becomes
  `ArchitectProject`, all user-facing output follows (`Project ready:` /
  `Project status:`), and the default integration branch is `project/<slug>`.
  No deprecation alias is provided.
- **BREAKING — `repo-tender` absorbed into `space-src`.** The vendored
  `repo-tender` engine is gone; its functionality now ships as `Space::Src`. State
  migrates automatically from `$XDG_STATE_HOME/repo-tender/` to
  `$XDG_STATE_HOME/space-src/` (and the launchd label likewise) on first run,
  data-preserving.
- **BREAKING — `space new` takes repeatable `-r` flags.** Repos are passed as
  `space new "My Space" -r org/repo -r example/alpha` instead of as trailing
  positional arguments. Repeated `-r` accumulate; the comma form still works.
- **Acceptance Criteria are prose (AC1, AC2, …) plus the gates block, not a
  `| AC# | Command | Threshold |` table.** The prose is what the architect judges
  against; gates are the necessary-not-sufficient mechanical check.
- **`architect new` allocates the ordinal at spec-time.** The `I<NN>` number is
  assigned by `new`, not pre-numbered; `ARCHITECT.md` gains an un-numbered ordered
  **Backlog** so reshuffling priorities no longer forces renumber churn.
- **Integration branch by default.** Lanes merge `--no-ff` into one shared,
  stable `project/<slug>` branch instead of into `main` or per-iteration branches;
  the end-of-project PR is deferred to `architect land`. Merge conflicts abort
  cleanly and are treated as a lane-plan disjointness defect.
- **`architect gate` reports PASS/FAIL per gate and exits nonzero on any
  failure** (it began as a raw-output-only runner) — while the framing keeps the
  Acceptance-Criteria verdict with the architect, not the runner.
- **Post-flight moved out of the dispatching session.** The dispatch session now
  only babysits builders to completion and hands off; a fresh judging session owns
  post-flight checks, gates, verdict, and integration. Two first-class lane
  patterns are documented: **parallel + fast-follow** and **serial deferred
  judgment**.
- **`architect status` tells the truth about verdicts** — rendering
  `awaiting-verdict` for integrated-but-unjudged iterations and the recorded
  `continue`/`kill`, instead of a freeze/lane placeholder.
- **The loop is model-agnostic.** `dispatch --model` help clarifies any
  provider/tier is fine (pin a full id, not a floating alias); the probe/spike is
  documented as a first-class iteration type; `docs/DESIGN.md` was revived.
- **Builder streams now include partial messages.** The claude harness argv gained
  `--include-partial-messages`, so `run.jsonl` (and any HTTP push) carries
  streaming partial-message events, not just completed turns — consumers should
  expect the finer-grained shape.
- **Colourful global help** for `space` and `architect`, with global colour
  options `--color` (auto/always/never) and its `--colors` alias inherited by
  every command via a shared `BaseCommand`. `src` keeps its own `--plain` /
  `--json` system.
- **`space --version`** now reports the space-surface (`Space::Core`) version
  independently of the architect project tooling.
- **The repository is now a monorepo.** The gem keeps the root (`lib/`, `exe/`,
  `skill/`, `space-architect.gemspec`); the `space-server` app lives under
  `server/`. Gem consumers are unaffected — `server/` is never packaged.

### Removed

- **The `architect:` `space.yaml` key and the `ArchitectMission` class** —
  renamed to `project:` / `ArchitectProject` with no alias (BREAKING; see above).
- **The Acceptance-Criteria command/threshold markdown table** — replaced by
  prose ACs plus the fenced `gates` block.
- **The post-flight phase in the dispatching session** — that work now belongs to
  a fresh judging session.

### Fixed

- **Gate thresholds matched the first occurrence instead of the last.**
  `GateEvaluator#check_threshold` now takes the last regex match, repairing frozen
  `(\d+) runs`-style suite-green gates without editing the frozen AC.
- **A frozen per-gate `cwd` ran against the checked-out repo instead of the lane
  worktree.** `run_gates` now re-roots a `cwd` pointing into the lane's repo onto
  the lane worktree.
- **`architect verify` false-FAILed "no builder commits" after integration.** The
  architect's own `integrate` commit was miscounted; `merge_lane!` now records
  `integrate_sha` and the mechanical checks exclude exactly that SHA.
- **A missing `touch_set` rendered a silent `N/A`.** Bounds now render
  `WARN — no touch_set recorded`, distinguishing "unchecked" from "clean."
- **Bounds glob matching was unsafe.** `fnmatch` now uses
  `FNM_PATHNAME | FNM_EXTGLOB` and parses NUL-delimited `git status --porcelain
  -z`, so `*` no longer crosses `/`, `**` works, and renames/spaced paths are
  handled.
- **HTTP push is now best-effort and isolated.** If the ingest server's transport
  fails or a push write errors mid-stream, `dispatch` logs a one-line warning and
  keeps the run log intact rather than tearing down the builder; a failed push
  disables further pushes for that run without dropping log output.
- **Container login-shell PATH and git identity.** The image writes
  `/etc/profile.d/space-architect.sh` so `bash --login` finds `architect` /
  `space` / `claude`, and the entrypoint seeds `user.name` / `user.email` if
  unset so in-image commits and worktrees no longer fail on a missing identity.
- **The gate evaluator lacked a discriminating threshold test** — added one that
  genuinely separates pass from fail, closing a hole where a broken evaluator
  could still pass its own suite.

### Internal

- **`Space::Core` carved out as a standalone, leak-free foundation** (no
  `SpaceArchitect` references), with behaviour preserved across the carve, the
  module rename, and the binary split.
- **New runtime dependencies:** `async-http ~> 0.95` and `protocol-http ~> 0.62`
  (backing the HTTP push tee and the research mux).
- **Split, per-subtree CI.** The gem keeps a lean workflow (Ruby tests +
  bundler-audit); a separate `server-ci.yml` runs the server suite against
  Postgres 17 / Redis 7 service containers, a Node 24 frontend job, a matrix that
  tests all five `server/gems/*` independently, and a server bundler-audit.
  Toolchain is pinned via `mise.toml` (Ruby 4.0.5) at both the root and `server/`.
- **CI bumps:** `softprops/action-gh-release` v2 → v3 (Node 24 runtime),
  `actions/cache` 5 → 6, `actions/checkout` 5 → 7, `actions/setup-node` 5 → 6,
  and `shrine` 3.8.0 (server).
- **Prerelease-aware release pipeline.** `release.yml` marks rc/beta/alpha/pre
  tags as GitHub prereleases so an RC tag is not published as `latest`; `2.0.0.rc1`
  and `2.0.0.rc2` were cut ahead of this final.
- Gem test suite: 948 runs, 3611 assertions, 0 failures, 0 errors, 0 skips.

## [1.3.0] - 2026-06-25

### Added

- `architect install-skills` — install the bundled skills (architect,
  architect-research, architect-vocabulary) for claude / codex / opencode / pi,
  globally or per-project, with `--dry-run` and `--force`.
- `architect-vocabulary` skill — a self-contained glossary of the Architect
  system, loadable without running the loop.

### Fixed

- Broke a circular `require` in the vendored `pristine/cli`; silenced stray git
  worktree output in the test suite.

## [1.2.0] - 2026-06-24

### Added

- §-anchored mission **BRIEF** (`architect brief new`) cited as `BRIEF §N` across
  iterations, and persistence absorbed into the CLI: `architect section`,
  `evidence`, `merge`, `integrate`, and `gate` (the architect authors content;
  the CLI owns the commit). `architect freeze` now prints the frozen Acceptance
  Criteria back; `worktree add --touch` records a lane's touch set.

### Changed

- Reduced Architect Loop ceremony; restored the § citation anchor.

## [1.1.0] - 2026-06-21

- First tagged release: the Architect Loop CLI — spaces, missions, iterations,
  lanes, worktrees, and headless `claude -p` dispatch, with variant sets and the
  claude-code and opencode harnesses.

[2.0.2]: https://github.com/jetpks/space-architect/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/jetpks/space-architect/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/jetpks/space-architect/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/jetpks/space-architect/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/jetpks/space-architect/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/jetpks/space-architect/releases/tag/v1.1.0
