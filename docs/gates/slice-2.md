# Gates — Slice 2: Sync engine (evergreen evaluation + bounded async fan-out)

> FROZEN before dispatch. Read-only for everyone including the builder — any
> edit to this file under `docs/gates/` fails the slice regardless of results.
> The architect runs these commands in a later session and compares output to
> the verbatim thresholds below. Gate-pass is necessary, not sufficient: the
> architect also reads the diff against PRD §3.3 / §5 intent and the
> no-data-loss invariant (PRD §1).

**Builds (new):** `lib/repo_tender/sync/repo_plan.rb`,
`lib/repo_tender/sync/engine.rb`,
`test/repo_tender/sync/repo_plan_test.rb`,
`test/repo_tender/sync/engine_test.rb`, `docs/lanes/slice-2-01.md`.

**Extends (existing Slice 1 files — edits in scope for this single lane):**
`lib/repo_tender/scm/client.rb` + `lib/repo_tender/scm/git.rb` (add a
`switch(path, branch)` boundary method, returning `Result`), and
`lib/repo_tender/forge/github.rb` + `test/repo_tender/forge/github_test.rb`
(fix the invalid `gh` argv — see G11).

**Out of scope:** `cli*`, `bin/repo-tender`, `launchd/*`, `config/*`,
`state/store.rb` *internals* (the engine *uses* `State::Store` but must not
change its public API or storage format), `paths.rb`.

---

## How the architect measures these

The builder must include in `docs/lanes/slice-2-01.md` a **gate→test mapping
table**: each gate → the test file + test name(s) that prove it. The architect
then (a) runs the suite command below and reads the counts, (b) opens each
named test and confirms it asserts the gate's behavior. Gates G1–G6, G9, G10
must be proven against **real temp git repos + a local bare remote, no mocks of
the classes under test** (reuse the Slice 1 `test_helper.rb` `with_trunk_repo` /
`seed_initial_commit` harness). G7 (concurrency) and the org-expansion half of
G10 may use an **injected test double for the SCM / Forge dependency** — this is
dependency injection on the engine's collaborators, NOT a mock of the engine
(the class under test). A gate whose named test mocks the class under test, or
asserts something weaker than the threshold, is INVALID even if green.

## G0 — Suite green & reproducible (regression + new)

```bash
bundle install
bundle exec rake test
bundle exec standardrb
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all Slice 1
  tests still passing** plus the new Slice 2 tests, **failures = 0, errors = 0,
  skips = 0** (any intentional skip — e.g. a tagged live smoke test — must be
  named in the report with a reason and is judged separately); `standardrb`
  exits 0. No new gem dependencies (the stack is frozen at PRD §2; `async` is
  already pinned).

## G1 — Clean + behind → fast-forward

Real clone that is clean and behind `origin/<default>` → engine fetches and
`merge --ff-only`s → now up to date with origin; resulting status `clean`; the
new commit is present on disk. No data loss.

## G2 — Fresh → skipped, no network

A repo whose `.git/FETCH_HEAD` mtime is **within `refresh_interval`** is skipped
without any network call. **Proof:** assert `FETCH_HEAD` mtime is **unchanged**
across the run (and/or the injected SCM records zero `fetch` calls for that
repo). "Can't determine freshness" (no FETCH_HEAD) is treated as stale → fetch.

## G3 — Dirty → untouched + reported

A repo with a dirty working tree (modified / staged / untracked) is left
**byte-for-byte unchanged**; engine records status `dirty`; **no** fetch / merge
/ checkout / clone is performed against it. Assert the working-tree bytes and
HEAD are identical before and after.

## G4 — Diverged → reported, no destruction

A repo with local commits ahead of `origin/<default>` (diverged) → status
`diverged`; **no `reset --hard`, no `merge`, no force**. The local commit(s) and
working tree are intact afterward (assert the local commit is still in the log
and any local file is still on disk).

## G5 — Detached / wrong branch → switch only when clean

- **Clean tree** on a non-default / detached HEAD → engine switches it back to
  the default branch (assert `current_branch == default_branch` after; HEAD is
  attached). Switching uses the new `SCM#switch(path, branch)` boundary.
- **Dirty tree** on a non-default / detached HEAD → **never switched**; left
  as-is and reported (`wrong_branch` or `detached`). Assert the branch/HEAD is
  unchanged and the dirty bytes are intact.

## G6 — Missing path → clone

A tracked repo whose on-disk path does not exist → engine clones it into
**`$BASE_DIR/:host/:owner/:repo`** (assert the clone lands at exactly that
derived path and contains a `.git`). The clone URL is derived from
`(host, owner, name)`, not stored.

## G7 — Concurrency bound respected

With `concurrency: 2` and ≥5 repos whose per-repo work is artificially slow
(injected slow SCM double incrementing/decrementing a shared counter under the
engine's `Async::Semaphore`), the observed **maximum simultaneous in-flight
count never exceeds 2** (assert `max_seen <= 2` via the counter probe, or prove
it via wall-clock timing). All repos still complete.

## G8 — Per-repo failure isolation + state write

Engine writes a per-repo result to `State::Store` for every repo. A single
repo's `Failure` (e.g. one repo raises / returns Failure) does **not** abort the
run — the other repos are still processed, and the failed repo's `error` status
+ message are recorded in state. Assert: all repos have a state entry; the
failing one is `status: error` with `last_error` set; the others completed.

## G9 — Idempotent

Running the engine twice back-to-back over the same all-fresh repo set performs
**no network calls on the second run** (assert via FETCH_HEAD mtimes unchanged
on the second pass, or zero fetch/clone calls recorded by an injected SCM on
run 2). Second-run statuses match first-run statuses.

## G10 — Org expansion + resilience

Given a config with an `OrgRef`, the engine expands it into `RepoRef`s via the
(injected / stubbed `Shell`) `Forge::GitHub#list_org`, dedupes against
explicitly-tracked repos, and plans each discovered repo. An org-list `Failure`
(e.g. unauthenticated) is **recorded in state and does not abort the run** — the
explicitly-tracked repos still process. Org-discovered repos are written to
state, never to config (PRD §3.2).

## G11 — Forge argv is valid at real `gh` (Slice 1 defect fix)

`Forge::GitHub#build_argv` must emit **only flags that exist at `gh repo list`**.
The `--no-source` flag does NOT exist (valid: `--archived`, `--no-archived`,
`--fork`, `--source`, `--json`, `--limit`) and must be removed. Fork/archive
exclusion remains proven by the authoritative `parse_repos` filter (the existing
G6 behavioral tests for `include_forks` / `include_archived` must still pass).

- **Threshold:** a test asserts `build_argv` for every flag combination contains
  **no `--no-source`** and that every flag emitted is in the valid set above.
  The Slice 1 `include_*` behavioral tests remain green.

## G12 — No out-of-scope files

`git status` / `git diff --name-only` after the run shows changes **only** within
the Builds + Extends sets above — nothing under `cli*`, `bin/`, `launchd/`,
`config/`, `paths.rb`, or `state/store.rb`. (Architect-checked, not a test.)

---

## PHASE-0 items the builder must rule on before coding

- **repo_plan / engine seam** — PRD §3.3 puts the evergreen *decision* in
  `repo_plan` and *execution + orchestration + state write* in `engine`. Confirm
  this split (decision is unit-testable in isolation) or disagree with a cited
  reason.
- **FETCH_HEAD mtime tolerance** (PRD §6) — it's a hint, not an API. "Can't
  determine" ⇒ treat as stale and fetch. Confirm the freshness check tolerates
  skew and never *skips* on an unreadable/absent FETCH_HEAD.
- **`switch` semantics** — adding `SCM#switch(path, branch)`: confirm it refuses
  (or is never called) on a dirty tree, so the engine can never lose work via a
  branch switch. The dirty-tree precondition is the engine's responsibility per
  G5; state where the guard lives.
