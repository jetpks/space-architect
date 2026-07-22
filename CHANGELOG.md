# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [5.4.0] - 2026-07-21

### Changed

- **`architect sessions agent install` resolves an `op://` token at install
  time** — the ref is resolved once via `op read` and the raw value is written
  to the plist's `EnvironmentVariables` dict (`SPACE_ARCHITECT_INGEST_TOKEN`),
  with the plist written mode 0600 and ProgramArguments carrying no token
  material. Interval runs no longer invoke `op` at all, so a locked 1Password
  can no longer fail the sync (previously the ref rode argv and every fire ran
  `op read`). Reinstall existing agents to migrate; a non-`op://` token passes
  through to the env dict unresolved.

### Added

- **`architect sessions sync` env-token fallback** — `--token` is now
  optional: when absent, the token is read from `SPACE_ARCHITECT_INGEST_TOKEN`.
  An explicit `--token` always wins; with neither present, the error names
  both sources.
- **Server: conversation session links** — importers preserve a session file's
  own `session_id` and record a differing content-derived id as
  `parent_session_id`; conversations resolve `parent`/`children` links
  (owner-scoped) and Conversations/Show renders "part of" / "Subagent
  transcripts" navigation between them.
- **Server: denormalized `turns_count` on conversations** — the conversations
  index reads a counter column recomputed at import instead of loading every
  conversation's messages, fixing index-page timeouts (502s) at
  thousand-conversation scale.

## [5.3.0] - 2026-07-20

### Added

- **`architect sessions sync`** — scans local pi (`~/.pi/agent/sessions`) and
  claude (`~/.claude/projects`) session stores and uploads new/grown `.jsonl`
  files to a space-server over the bearer-authenticated `POST /conversations`
  wire contract. Per-file `{size, mtime}` cursor at
  `$XDG_STATE_HOME/space-architect/session-sync.yaml`, a 60-second recent-mtime
  guard against mid-write reads, `--dry-run`, and per-file
  uploaded/updated/skipped/failed reporting (non-zero exit on any failure).
  An `op://` token is resolved once per run via `op read`.
- **`architect sessions agent install|uninstall|status`** — manages a per-user
  launchd agent (`io.github.jetpks.space-architect.session-sync`, default
  `StartInterval` 900s) that runs the sync on an interval. An `op://` token is
  stored in the plist as the ref, never as a resolved secret.
- **Server: bearer branch + upsert on `POST /conversations`** — machine uploads
  authenticate with the ingest bearer token and upsert by `(user, session_id)`:
  re-uploading a grown session file updates the existing conversation row
  (source file replaced, import re-enqueued) instead of duplicating it.
  The browser upload path is unchanged.
- **Server: run-fidelity surfaces** — the pi opening prompt is persisted and
  rendered as a leading user turn on Runs/Show (owner-gated); runs/jobs indexes
  carry harness/model/lane and an owner-gated prompt snippet; absolute
  timestamps render the wire value honestly (RFC3339 offsets, millis only when
  present).

## [5.2.1] - 2026-07-19

### Fixed

- **`integrate` final line no longer claims "the verdict is the next session's"**
  — the clause assumed a handoff to a fresh judging session, but the common
  workflow starts a session that waits on the background builder jobs and then
  judges in the *same* session. The line now reads "Gates NOT run — run gates:
  `architect gate <iteration>`", a neutral instruction that holds in both the
  same-session and fresh-session workflows.

## [5.2.0] - 2026-07-19

### Added

- **`pi` harness (`PiHarness`)** — `pi -p --mode json --model <m> --session-dir
  <build_dir> --no-approve` as a first-class dispatch harness alongside
  claude-code and opencode. The session dir is redirected into the lane's
  `build/` dir via `--session-dir` so nothing leaks to
  `~/.pi/agent/sessions/`. `when "pi"` factory branch; `dispatch`/
  `worktree_add` recognize `pi`; CLI descs updated to include `pi`. opencode
  and claude-code paths byte-for-byte unchanged (I09).
- **Unified `--effort` / `--thinking` / `--reasoning` knob** — three aliases
  for one thinking-level setting, normalized to
  `off, minimal, low, medium, high, xhigh, max`. Per-harness
  `translate_thinking`: claude `--effort` (low/medium/high/xhigh/max,
  off→omit, minimal→low); opencode `reasoningEffort` (low/medium/high,
  xhigh/max→high, off/minimal→omit); pi `--thinking` passthrough (pi's
  `thinkingLevelMap` clamps, architect doesn't). `--force-{effort,thinking,reasoning}`
  (dispatch-only) skips the clamp and passes the literal — binary rejection is
  final. `--quiet` threads a null `err:` sink. A trailing `:level` model-suffix
  (e.g. `foo:high`) is parsed and translated across all harnesses
  (explicit > suffix > stored) (I10).
- **Per-harness sensible model defaults** via `Harness.default_model_for`:
  `claude-code → claude-sonnet-5`, `pi → qwen3-27b-optiq`,
  `opencode → fireworks-ai/accounts/fireworks/models/glm-5p2`. The constant
  `CLAUDE_DEFAULT_MODEL` keeps its name (to avoid a `research/supervisor.rb`
  ripple) but its value is now `claude-sonnet-5` (I12).
- **`space.yaml` project defaults** — `project.harness` / `project.model` /
  `project.effort` (all optional) may be declared in `space.yaml` and sit
  between the CLI flag and the per-harness default in the resolution chain.
  Pin a project's harness/model/effort once instead of per command; the user
  authors them in `space.yaml` directly (no new CLI setter) (I12).
- **Dispatch stamp** (fixes the `status`-wrong-harness-model bug): `dispatch`
  now stamps the resolved `harness`/`model`/`effort` onto the lane entry
  alongside `dispatched_at`, so `architect status` reads what actually ran on
  the last dispatch — not the `worktree_add`-time values or the global default
  (I12).

### Changed

- **Shared `resolve_harness_model` helper** DRY across `worktree_add` and
  `dispatch`. Precedence: explicit CLI flag > lane entry's stored value >
  `space.yaml` project default > per-harness sensible default. A stored model
  is only honored when the stored harness still matches the resolved harness,
  so a `--harness` override drops the old harness's model instead of leaking it
  (I12).
- **Section-write idempotence** — `replace_section_body` now strips a leading
  line equal to the target `## <Heading>` from the supplied body before
  writing. Makes `architect section <it> <sec>` idempotent: `--from
  <file-with-heading>` and `--from <body-only>` produce byte-identical output;
  running it twice never accumulates a duplicate heading. Narrow — only the
  target heading, so `### fix` sub-headings and wrong-section headings survive
  (I11).

### Removed

- The `worktree_add` opencode/pi nil-model guards and the factory opencode/pi
  `model == CLAUDE_DEFAULT_MODEL` guards — per-harness defaults cover nil, and
  an explicit `--model claude-sonnet-5 --harness pi` is a valid deliberate
  choice (via openrouter/anthropic routing); the binary rejects an invalid
  model. Stale "Pass --model" tests rewritten to assert default-resolution
  (I12).

## [5.1.0] - 2026-07-19

### Added

- **`architect integrate --into <branch>`** — merge a lane into a named branch
  instead of the slug-derived `project/<slug>` default (#47). Outside-touch-set
  conflict message gains an `--into` hint; inside-touch conflict keeps "spec
  defect".
- **Conductor commit-mode** — `commit_mode: conductor` in `space.yaml` plus a
  `--commit-mode` CLI flag on `verify`/`integrate`: canonical conductor commits
  are classified as non-builder in the lane mechanical check, with canonical
  message-shape matching (#55).
- **`architect sync` subcommand** (`--ff-only`, per-repo status) plus a
  `ground` stale-repo WARNING with behind count and `--into` hint. **No
  auto-sync** — the operator runs `sync` (#49).
- **`architect freeze --force` / `section --force`** — re-freeze an iteration
  whose frozen region changed since the last freeze, or write a frozen section
  after the freeze (pre-dispatch amend paths). Both refuse if any lane has
  `dispatched_at` OR `integrate_sha` — moving `freeze_sha` or rewriting a frozen
  section after a builder has run against the AC breaks the cardinal invariant
  (AC freeze before results exist; judging quotes the freeze commit). The guard
  names the offending lane and the reason.
- **`architect merge --into <branch>` / `--commit-mode <mode>`** — wires the
  existing `merge_lane!` `into:`/`commit_mode:` kwargs through the `Merge` CLI,
  matching `Integrate`'s surface.
- **`architect provision --force` / `worktree add --force`** — `worktree_add`
  gains a `force: false` kwarg. When a worktree dir exists but is unknown to git
  (stale, e.g. left by an aborted provision), `force: true` clears it via
  `FileUtils.rm_rf` and re-creates; without `force` it still raises with a
  `--force` hint so a genuine git-tracked dir is never silently destroyed.
  `ensure_lane_materialized` (the auto-recovery path) stays non-force —
  auto-recovery never silently `rm -rf`s; only an explicit operator `--force`.

### Changed

- **`dir/**` in-bounds touch glob is now recursive** — matches
  `Dir.glob('**/**')` semantics; single-star `*` stays non-recursive.
  Deep-globbed files inside a lane's declared touch set are in-bounds; outside
  is still a spec defect (#52, #54).
- **`dispatched_at` recorded in `space.yaml` at dispatch time** (#18).

### Fixed

- **Canonical `section`/`freeze` commit message shape** — per-section commits
  and the freeze commit carry the correct canonical prefix and body.
- **`space run --help` steers to the `--` separator** — a quoted multi-word
  command otherwise arrives as one argv token → opaque in-guest failure; the
  desc/argument/example now show the `--` form, with a subprocess test (#28).
- **Dropped a load-time "assigned but unused variable" warning** — `build_dir`
  in `worktree_add` was computed but never read.

## [5.0.0] - 2026-07-06

### Added

- **`architect dispatch --prompt <file>`** — the lane prompt is authored anywhere
  (a fresh scratch file) and dispatch copies it byte-for-byte to the canonical
  `build/<id>-<lane>/prompt.md` before launch, announcing the copy. The CLI owns
  the canonical path; the architect never blind-writes it (#48, #42).
- **`architect brief new --from <file>` / `--stdin`** — write the authored brief
  in one step instead of filling a pre-seeded template. Bare `brief new` still
  scaffolds the placeholder, and now says so
  (`Brief ready: … (template — Read it before editing)`).
- **Flexible commit messages on every committing loop command** — `init`, `new`,
  `freeze`, `brief new`, `section`, `verdict`, `evidence`, `merge`, and
  `integrate` all take `-m`/`--message` and `--message-from <file>`. The first
  line completes the subject after a short canonical prefix (`I01 spec: <your
  subject>`, `lane <lane>: <your subject>`); remaining lines become the commit
  body. Without the flags, the canonical messages are unchanged. The space's git
  log is the loop's durable memory — detailed bodies are the point.

### Changed

- **`worktree add`/`provision` no longer pre-seed `prompt.md` with a placeholder
  stub.** The unannounced stub made the architect's first `Write` trip the
  harness read-before-write guard on every single lane (a failed-write → read →
  rewrite round trip; 40 occurrences mined from real transcripts). Dispatch
  still refuses a missing, empty, or legacy-stub prompt (#48, #42).
- **`architect merge --message` semantics** — the message now composes with the
  canonical `lane <lane>:` prefix (subject + body) instead of replacing the
  whole message, matching every other committing command.
- **Skill prose** — the architect authors all content (lane prompts, brief, PR
  bodies) in fresh timestamped scratch files and hands them to the CLI via
  `--from`/`--prompt`; PR bodies land at
  `build/land/<repo>-pr-body-<yyyymmdd-hhmm>.md`; committing commands should
  carry detailed `--message-from` bodies.

## [4.0.0] - 2026-07-05

Backfilled — the bump shipped without an entry. Five iterations run through the
Architect Loop against `space-architect`'s own live-loop papercuts (#46), plus
the `dispatched_at` producer (#45) and a test-suite hygiene pass (#32).

### Added

- **`architect provision <iteration> [--base <ref>] [--lane <name>]`** — materializes
  every declared lane's worktree + `lane/<id>-<lane>` branch in one shot from the
  frozen lane plan (idempotent; base resolves `--base`, else `project/<slug>` HEAD,
  else the repo's default branch). `dispatch`/`integrate`/`gate`/`verify`
  auto-materialize a missing worktree from the frozen declaration, so the flow
  can't dead-end (#26).
- **Fenced ` ```lanes ` block in the Specification** — `name`, `repo`, `touch`
  globs, parsed at **freeze** into `space.yaml` lane entries, making the lane plan
  (including the out-of-bounds touch-set contract) part of the frozen spec (#26).
- **`space.yaml` schema v2** — the never-bumped `version` key now means something:
  canonicalize on save, read + self-heal the two known v1 variants (v1a
  `architect:`, v1b `project:`+`version: 1`) on load; a both-keys conflict refuses
  and names both blocks rather than silently picking one (#33).
- **`dispatched_at` on lane entries** — every dispatch stamps an ISO 8601 launch
  time after preflight, before the run, on both foreground and detached paths
  (#18, producer landed via #45).
- **Self-verifying dispatch liveness** — a transient fiber inside dispatch checks
  the launched run matches intent (model, growth of `run.jsonl`), retiring the
  manual "canary" ceremony (#43, #44).
- **`architect help` grouped by loop phase** — Spec / Build / Judge / Land /
  Project, commands in loop order, with an embedded loop-status block when run
  inside a project space; `space status` reports on a bare call and still sets on
  `space status <value>`.

### Changed

- **Lane declaration is single-source-of-truth** — lanes were declared twice
  (Specification prose + `worktree add` flags) with the touch-set divorced from
  the frozen spec; the ` ```lanes ` block at freeze is now the one declaration.
  The single-lane "dispatch in the repo checkout" fast path is removed (it never
  worked with `merge_lane!`); manual `worktree add` remains as the internal
  primitive `provision` wraps (#26).
- **Skill prose** (`SKILL.md` §4–§6, `dispatch.md`) rewritten to the
  declare → freeze → provision → dispatch lane lifecycle.

### Fixed

- **`architect integrate <it> --teardown`** (no `--lanes`) backtraced; teardown-only
  mode now deletes per-lane branches and worktrees, never `project/<slug>` or
  `main` (#30).
- **Test suite hygiene** — zero warnings, zero stray output, 58.8s → 49.1s (#32).

## [3.0.0] - 2026-07-01

### Added

- **`architect bug-report`** — zero-friction bug-filing command. Gathers
  diagnostics (gem version, Ruby version/platform, and when run inside a space:
  space id, title, and iteration list with verdicts), writes a prefilled GitHub
  issue-body template to `<space>/build/bug-report/architect-bug-report-YYYYMMDD-HHMMSS.md`
  (or `./architect-bug-report-YYYYMMDD-HHMMSS.md` outside a space — timestamped so
  back-to-back runs in the same session never overwrite each other), and prints —
  never executes — the `gh issue create -R jetpks/space-architect` invocation to run.

### Removed

- **BREAKING — `architect land` removed** (added in 2.0.0) — landing is the architect
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
