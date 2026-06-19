# Gates — Slice 1: Foundation (paths · config · state · shell · scm · forge)

> FROZEN before dispatch. Read-only for everyone including the builder — any
> edit to this file under `docs/gates/` fails the slice regardless of results.
> The architect runs these commands in a later session and compares output to
> the verbatim thresholds below. Gate-pass is necessary, not sufficient: the
> architect also reads the diff against PRD §3/§5 intent.

**Builds:** `lib/repo_tender/paths.rb`, `config/{model,contract,store}.rb`,
`state/store.rb`, `shell.rb`, `scm/{client,git,status}.rb`, `forge/{client,github}.rb`,
plus project skeleton (`repo-tender.gemspec`, `Gemfile`, `mise.toml`,
`lib/repo_tender.rb`, `test/` harness, `Rakefile`).

**Out of scope:** `sync/*`, `cli*`, `bin/repo-tender`, `launchd/*` (later slices).

---

## How the architect measures these

The builder must include in `docs/lanes/slice-1-01.md` a **gate→test mapping
table**: each gate G0–G8 → the test file + test name(s) that prove it. The
architect then (a) runs the suite command below and reads the counts, (b) opens
each named test and confirms it asserts the gate's behavior against a **real
temp git repo / real fixture, no mocks of the class under test**. A gate whose
named test mocks the class under test, or asserts something weaker than the
threshold, is INVALID even if green.

## G0 — Suite green & reproducible

```bash
bundle install
bundle exec rake test
bundle exec standardrb
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **tests > 0,
  failures = 0, errors = 0, skips = 0** (any intentional skip must be named in
  the report with a reason and is judged separately); `standardrb` exits 0.
- `mise.toml` pins ruby 4.0.5; `Gemfile.lock` is present and resolves the pinned
  gem versions from PRD §2.

## G1 — Config round-trip (`Config::Store`)

Load a YAML config, mutate via the struct, write back, reload → **managed
fields byte-identical** to the mutated struct. Loss of comments/unknown keys is
allowed **only if** documented in the report. Proven by a no-mock test using a
real temp file.

## G2 — Config validation (`Config::Contract`)

`Failure` with **field-level messages** for each of: missing required field, bad
`refresh_interval` (e.g. `"6x"`), non-integer `concurrency`, malformed repo
entry, malformed org entry. A valid config returns `Success`. One assertion per
rejection case.

## G3 — Path resolution (`Paths`)

Resolves config / state / log / base paths honoring `$XDG_CONFIG_HOME` and
`$XDG_STATE_HOME` overrides, and defaults `base_dir` to `~/src/evergreen` when
absent. Test sets the XDG envs to temp dirs and asserts exact resolved paths.

## G4 — Shell is non-blocking (`Shell`)

- `Shell.run("git","--version", chdir:)` inside `Sync{}` ⇒ `Success(stdout)`.
- A nonzero exit ⇒ `Failure` carrying **argv + stderr + status**.
- **Concurrency proof:** two concurrent `Shell.run("sh","-c","sleep 0.3")` in
  one `Sync{}` complete in **wall-clock < 0.6s** (asserted), proving overlap via
  the Fiber scheduler (not sequential).

## G5 — SCM::Git against a real temp repo + local bare remote (no mocks)

All proven against real on-disk git repos:
- `status` parses **clean vs dirty** correctly for modified, staged, and
  untracked cases (porcelain v2).
- `default_branch` returns the bare remote's HEAD **even when named `trunk`**
  (not assumed `main`).
- `current_branch`, `last_fetch_at`, `fetch`, `fast_forward`, `clone` behave.
- `fast_forward` **refuses on divergence** → `Failure`, working tree + local
  commits intact (assert no data loss).

## G6 — Forge::GitHub#list_org (`Forge::GitHub`)

Parses `gh repo list <org> --json …` (recorded JSON fixture, offline) into
`RepoRef`s; reads `.defaultBranchRef.name`; honors `include_archived` /
`include_forks`. Surfaces a `Failure` if `gh auth status` reports unauthenticated
(may be a separate unit test against a stubbed `Shell`, not a mocked
`Forge::GitHub`). A live smoke test is allowed but must NOT be in the CI suite
(tag/skip it so G0 stays offline-deterministic).

## G7 — State store round-trip (`State::Store`)

Write per-repo + per-org state to `$XDG_STATE_HOME/repo-tender/state.yaml`,
reload → identical. Status enum accepts the PRD §3.2 set
(`clean|dirty|diverged|detached|wrong_branch|missing|error`).

## G8 — No out-of-scope files

`git status` after the run shows **only** files within the Builds set above —
nothing under `sync/`, `cli*`, `bin/`, `launchd/`. (Architect-checked, not a
test.)

---

## PHASE-0 items the builder must rule on before coding (PRD §2, §6)

- **minitest vs rspec** — PRD picks minitest `[CONFIRM]`. Confirm or disagree
  with a cited reason.
- **standardrb vs rubocop** — builder's choice; record it and update `AGENTS.md`.
- **`gh` 2.93 `--json` field availability** — verify `defaultBranchRef`,
  `isArchived`, `isFork` are real fields at the installed `gh` against live docs.
