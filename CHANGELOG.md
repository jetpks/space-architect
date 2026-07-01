# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-06-27

Re-architects the single `architect` gem into three composable binaries —
**`space` · `architect` · `src`** — over clean `Space::Core` / `Space::Architect`
/ `Space::Src` library seams. End-user CLI behaviour is preserved byte-for-byte
except where called out under **Changed** below.

### Added

- **`src` — standalone evergreen-engine binary** (`exe/src`). `repo`, `org`,
  `sync`, `status`, `config`, `daemon`, and `clone`, plus single-token fuzzy
  navigation (`src <query>` resolves to a repo and honours the `cd` contract)
  and native fish shell integration with completions. Previously this engine was
  reachable only as `architect src …`; it is now a first-class binary in its own
  right (and still forwarded by `architect src …`).
- **`architect research dispatch | status | wait`** — first-class parallel,
  read-only research lanes. Detached `claude -p` researchers (no Edit/Write/Bash)
  run in the background; a socketry/async fiber mux tails each lane's `run.jsonl`
  and extracts its report. The architect verifies claims and writes Grounds.
- **`architect dispatch --detach`** — detached builder launch that returns
  immediately with a PID and survives the harness wall-clock reap; poll the
  lane's report for completion.
- **`space pack | build | run` — containerize a space.** `space pack` renders a
  portable OCI build context under `build/oci/` (a `Dockerfile`, an
  `entrypoint.sh`, and a `Dockerfile.dockerignore` that keeps secrets and scratch
  out of the layers). `space build` packs and builds it via the `container` CLI,
  tagging `<space-id>:<git-sha>` (suffixed `-dirty` when the tree has uncommitted
  changes) plus a moving `:latest` — a reproducible-by-SHA image. `space run`
  runs `<space-id>:latest` with auth (`ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_BASE_URL`) injected at run time and never
  baked into the image, bind-mounting persisted state back to the host. Two
  optional `space.yaml` keys drive it: `pack.provision` (build-time scripts, run
  as `RUN /space/<script>`) and `pack.persist` (absolute guest paths mounted from
  `<space>/.state<path>`). All three are also reachable as
  `architect space pack|build|run`.

### Changed

- **BREAKING — three binaries over clean seams.** `space` now runs on
  `Space::Core` alone (`exe/space`); `architect` forwards `space …` / `src …` to
  their surfaces; `src` is its own executable (`exe/src`). The gem now installs
  three executables (`architect`, `space`, `src`) where 1.3.0 installed two.
- **BREAKING — Ruby namespace overhaul (library embedders).** The single
  `SpaceArchitect::*` module is retired and split into `Space::Core::*`
  (foundation: config, state, XDG, terminal, git/mise clients, space store),
  `Space::Architect::*` (mission, harness, dispatch, research), and
  `Space::Src::*` (the evergreen engine). Update any `require`s and constant
  references. The CLI surface is unaffected.
- **BREAKING — `repo-tender` absorbed into `space-src`.** The vendored
  `repo-tender` engine is gone; its functionality now ships as `Space::Src`.
  State migrates automatically from `$XDG_STATE_HOME/repo-tender/` to
  `$XDG_STATE_HOME/space-src/` on first run (data-preserving).
- **BREAKING — `space new` takes repeatable `-r` flags.** Repos are now passed
  as `space new "My Space" -r org/repo -r example/alpha` instead of as positional
  arguments after the title. Repeated `-r` accumulate; the comma form still works.
- **Colourful global help** for `space` and `architect` (`--help` listing), with
  global colour options (`--color` / `--colors`) inherited by every command via a
  shared `BaseCommand`. The `src` binary keeps its own `--plain` / `--json`
  output system.
- `space --version` now reports the space-surface (`Space::Core`) version
  independently of the architect mission tooling.

### Internal

- `Space::Core` carved out as a standalone, leak-free foundation (no
  `SpaceArchitect` references); behaviour preserved byte-for-byte across the
  carve, the module rename, and the binary split.
- CI: `softprops/action-gh-release` bumped to v3 (Node 24 runtime).
- Test suite: 762 runs, 0 failures.

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

[2.0.0]: https://github.com/jetpks/space-architect/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/jetpks/space-architect/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/jetpks/space-architect/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/jetpks/space-architect/releases/tag/v1.1.0
