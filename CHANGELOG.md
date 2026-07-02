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

- **`architect bug-report`** — zero-friction bug-filing command. Gathers
  diagnostics (gem version, Ruby version/platform, and when run inside a space:
  space id, title, and iteration list with verdicts), writes a prefilled GitHub
  issue-body template to `<space>/build/bug-report/architect-bug-report-YYYYMMDD-HHMMSS.md`
  (or `./architect-bug-report-YYYYMMDD-HHMMSS.md` outside a space — timestamped so
  back-to-back runs in the same session never overwrite each other), and prints —
  never executes — the `gh issue create -R jetpks/space-architect` invocation to run.
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

### Fixed

- **`architect land` — paste-and-run block.** `architect land` stdout is now a
  copy-paste-ready block: a "Fill the placeholders in ~/…, then run:" instruction line
  naming the body file, followed by shell-only commands — `cd` to the space's repo
  checkout (`~`-contracted, unquoted), `git push -u origin <branch>`, and the wrapped
  `gh pr create` invocation. The false "(gh pushes it)" context line and the redundant
  `Body:` display line are gone; the push step is explicit. The generated PR body
  template now includes prefilled data (merge line, iteration list with verdicts) **and**
  `<…>` placeholder sections the human fills before running the command.
- **`architect bug-report` / `architect land` — `~`-contracted paths in printed commands.**
  The `gh issue create` / `gh pr create` invocations printed to stdout render the
  `--body-file` path as `~/…` instead of the user's expanded `$HOME`.
  `Space::Core::Paths.contract` is the single home-contraction helper; `Terminal#path`
  delegates to it.
- **Command wrapping for narrow terminals.** `gh pr create` and `gh issue create`
  commands are now rendered with trailing ` \` continuations broken at `--flag`
  boundaries, continuation lines indented two spaces. The wrapped output is valid shell
  (`bash -n` clean). `Space::Core::Commands.wrap` is the single wrapping helper; both
  commands call it.

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
