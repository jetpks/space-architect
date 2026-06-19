# AGENTS.md — repo-tender builder context

Standing context for build agents. The architect's per-slice spec and the
frozen gates in `docs/gates/` are the contract; this file is the repo's stable
how-to. Authority order: this file → `docs/prd/repo-tender.md` → `docs/gates/<slice>.md`.

## What this is

`repo-tender` keeps local git clones *evergreen* (clean · on default branch ·
fetched within `refresh_interval`) so a downstream tool can clone them from the
local filesystem instantly. A `dry-cli` binary plus a periodic launchd-invoked
`sync` sweep. Full design: `docs/prd/repo-tender.md`. macOS-only, GitHub-only
(behind decoupled SCM/forge interfaces). **Never** mutate a dirty/diverged repo.

## Toolchain (verified present 2026-06-12)

| Tool | Version | Notes |
|------|---------|-------|
| ruby | 4.0.5  | active via mise; pin in `mise.toml` |
| mise | 2026.6.0 | manages ruby |
| git  | 2.54.0 | the only SCM |
| gh   | 2.93.0 | GitHub forge listing |

## Build & test commands

```bash
bundle install
bundle exec rake test            # full suite (minitest)
bundle exec ruby -Itest test/path/to/foo_test.rb   # single file
bundle exec standardrb           # lint/format check
bundle exec standardrb --fix     # autofix
```

If you introduce a different test runner or linter, update this table and say so
in your lane report — the architect re-runs exactly these commands to judge gates.

## Conventions (from the PRD — non-negotiable)

- **Boundaries return `Result`** (`dry-monads`): `Shell`, `SCM::Git`,
  `Forge::GitHub`, `Config::Store`, `Sync::Engine`. Exceptions are for
  programmer error only — a dirty repo or a network failure is a `Failure`, not
  a raise.
- **Tests use real temp git repos + a local bare remote. No mocks/stubs** of
  classes under test. Forge tests use a recorded `gh --json` fixture (offline,
  deterministic).
- **Async only where needed:** the sync engine wraps work in `Sync do … end`
  using `Async::Barrier` + `Async::Semaphore`; CRUD/status commands are plain
  synchronous Ruby. Subprocesses use **stdlib `Open3.capture3`** (non-blocking
  inside an Async task via the Fiber scheduler) — **do not** add `async-process`.
- **External binaries** (`git`, `gh`, `mise`, `launchctl`) resolved via PATH at
  runtime.
- Format every change with the linter before reporting done.
- Idiomatic, well-factored, DRY-ish Ruby. Write only the code the slice needs.

## Gotchas (from the research ledger)

- Default branch is **not** assumed `main` — resolve from the remote's HEAD
  (`git symbolic-ref --short refs/remotes/origin/HEAD`; a plain `fetch` does not
  update `origin/HEAD`).
- `git status --porcelain=v2` is the parse target; any `1`/`2`/`u`/`?` line ⇒ dirty.
- `gh` can silently fall back to unauthenticated (60 req/hr) — check
  `gh auth status` before bulk listing and surface a clear `Failure`.
- There is **no** dry-rb config *persistence* gem — write-back is a small
  hand-rolled YAML emitter you own (`dry-validation` validates, `dry-struct`
  models).
