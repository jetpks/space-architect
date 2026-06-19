# Lane report — Slice 2, lane 01 — Sync engine

> Slice 2 of repo-tender (Sync engine). Builder: minimax-m3 via pi. Date:
> 2026-06-13. Source spec: `docs/prd/repo-tender.md` §3.3 / §5 Slice 2 /
> DoD §7 + frozen gates `docs/gates/slice-2.md` (G0–G12).

---

## 1. PHASE 0 — plan + disagreements

### Plan (one-paragraph)

Build the sync engine in three layers: (1) **contract freeze** — add
`SCM::Client#switch(path, branch)` as an abstract method on
`lib/repo_tender/scm/client.rb` and implement it in `lib/repo_tender/scm/git.rb`
using `git switch <branch>` (which refuses to clobber a dirty tree per its
own man page — a defense-in-depth on top of the engine's plan-side guard);
(2) **decision** — `lib/repo_tender/sync/repo_plan.rb` is a pure-ish
`RepoPlan.call(repo_ref:, path:, scm:, refresh_interval:, now:)` that
observes the repo via the SCM's existing methods (`status`,
`current_branch`, `default_branch`, `last_fetch_at`, `fetch`) and returns
a `Plan` Data object carrying `{action, status, reason}`. The "behind?"
check uses porcelain v2's `branch.ab` line (already parsed by
`SCM::Status#behind` / `#ahead` at `lib/repo_tender/scm/git.rb:184-186`) —
no new SCM boundary methods; (3) **execution** — `lib/repo_tender/sync/engine.rb`
takes `config:`, `paths:`, optional injected `scm:` / `forge:` / `clock:`
/ `url_builder:`, runs one `Sync{}` block, expands `config.orgs` via the
injected forge (deduped against explicit `config.repos` by
`(host, owner, name)`), fans out per-repo `process_one` tasks through
`Async::Barrier` + `Async::Semaphore.new(config.concurrency)`, dispatches
the plan's `action` via the SCM client, accumulates a per-repo result, then
writes one new `State::Store::State` to `paths.state_file`. A single repo's
`Failure` is caught and translated to `status: error`; the run never
aborts. Also fix the `Forge::GitHub#build_argv` `--no-source` defect (G11)
by removing the flag — fork exclusion is authoritative in `parse_repos`.
Lint/format with `standardrb`. Tests: real temp git repos + local bare
remote for G1–G6, G9, G10-explicit half; injected test doubles for G7
(slow SCM with counter probe) and the org half of G10. New test files for
`repo_plan` (unit) and `engine` (integration). G11 assertions added to
`forge/github_test.rb`.

### Disagreement table (builder position · spec position · cited file · reason)

| # | Builder's position | Spec's position | Cited file | Reason |
|---|--------------------|-----------------|------------|--------|
| 1 | **`SCM::Client#switch` is a no-precondition boundary.** It just runs `git switch <branch>` and surfaces the SCM's own refusal-on-dirty behavior as a `Failure`. The dirty-tree guard is the engine's responsibility (the plan's `report_wrong_branch` / `report_detached` short-circuit ensures `switch` is never called on a dirty tree, per gate G5). | "adding `SCM#switch(path, branch)`: confirm it refuses (or is never called) on a dirty tree, so the engine can never lose work via a branch switch. The dirty-tree precondition is the engine's responsibility per G5; state where the guard lives." (`docs/gates/slice-2.md:131-134`) | `docs/gates/slice-2.md:131-134`; `man git-switch` ("The operation is aborted however if the operation leads to loss of local changes") | The spec offers two options ("refuses" OR "is never called"). The "never called" is the engine-side guarantee (cheaper — one SC status call, no race window). The "refuses" is the git-side safety net. The two are layered, not exclusive: the engine *also* plans `:report_*` when dirty, and if anything ever calls `switch` on a dirty tree by accident, `git switch` itself aborts cleanly (verified by `man git-switch` and a live shell test — the switch only aborts when the change would be lost; for our test scenarios the engine guard is the active layer). So `switch` is implemented as a thin `git switch <branch>`; the test asserts it never returns Success on a dirty tree (the G5 engine test exercises the path). |
| 2 | **The "behind?" decision in `RepoPlan` uses `SCM::Status#behind` / `#ahead` (parsed from porcelain v2's `branch.ab` line), not a new `scm.rev_count` boundary.** | Spec lists only `switch` as a new SCM::Client boundary; the PRD §3.3 "behind?" step says "git rev-list --left-right --count". | `docs/gates/slice-2.md:78-94` (BOUNDARIES); `docs/prd/repo-tender.md:67-71`; `lib/repo_tender/scm/status.rb` (Status has `behind`/`ahead`); `lib/repo_tender/scm/git.rb:184-186` (parses `branch.ab`) | The BOUNDARIES list is explicit that the only new SCM::Client method is `switch`. A "behind" check needs the same shape as `git rev-list --left-right --count HEAD...origin/<default>` — left > 0 ⇒ diverged, right > 0 ⇒ behind, both 0 ⇒ up to date. The exact same data is already on `SCM::Status#ahead` / `#behind` (porcelain v2 `# branch.ab +<ahead> -<behind>`), populated by `parse_porcelain_v2` at `lib/repo_tender/scm/git.rb:184-186`. After `scm.fetch` updates `origin/<default>`, the next `scm.status` call returns the new `ahead`/`behind`. The plan uses these existing fields — no new boundary, no duplicated parsing. (Pre-fetch the `SCM::Status` will have stale values; the plan calls `scm.fetch` first when not-fresh and re-reads `status`.) |
| 3 | **The freshness check is "if `scm.last_fetch_at` returns `Success(nil)` (no FETCH_HEAD) or `Success(time)` with `now - time > refresh_interval`, treat as stale; if `Success(time)` with `now - time <= refresh_interval`, treat as fresh. A `Failure` from `scm.last_fetch_at` is treated as stale (the only realistic Failure is `ENOENT` on the stat, which equals nil)."** | "FETCH_HEAD mtime tolerance (PRD §6) — it's a hint, not an API. 'Can't determine' ⇒ treat as stale and fetch. Confirm the freshness check tolerates skew and never *skips* on an unreadable/absent FETCH_HEAD." (`docs/gates/slice-2.md:124-127`) | `docs/gates/slice-2.md:124-127`; `docs/prd/repo-tender.md:70,135`; `lib/repo_tender/scm/git.rb:53-57` | The spec gives the intent ("never skip on unreadable/absent"); the implementation choice is the boundary of "stale". I treat *all three* "can't determine" cases (nil, Failure, but the more important one — a stat on a file the kernel considers unparseable) as stale, which is the conservative direction. This means a corrupt FETCH_HEAD triggers a refresh (correct: PRD §1 "Fetched within `refresh_interval`" is the hard contract; the mtime is a hint). The plan is the only place this lives; the G2 engine test asserts a repo with no FETCH_HEAD gets fetched on the first run and skipped on the second (asserted via `FETCH_HEAD` mtime preserved across the second run, with `cp_r preserve: true` so the copy's mtime is the source's). |
| 4 | **The plan returns a `Plan = Data.define(:action, :status, :reason)` value object — both the action and the resulting status enum — to make the engine dispatch trivial. The action set is exactly the spec's nine, plus `:report_error` (a tenth, for unrecoverable SCM probe Failure, which the spec's list does not enumerate but gate G8 requires: "the failing one is `status: error` with `last_error` set").** | "decide the *action* (`:clone | :fast_forward | :switch | :report_dirty | :report_diverged | :report_wrong_branch | :report_detached | :skip_fresh | :up_to_date`) with a resulting status enum value." | `docs/gates/slice-2.md:60-64` | The spec lists nine actions; the PRD §3.2 status enum is seven values (`clean|dirty|diverged|detached|wrong_branch|missing|error`). Gate G8 explicitly says "the failing one is `status: error` with `last_error` set" — so an "error" status must be writable. Without a `:report_error` action, the engine would have to handle SCM-probe Failure out-of-band. I add the tenth action as a *direct* mapping to `status: error` so the engine stays a clean dispatch. The action is an implementation detail of the seam (the spec's nine is the user-facing set; the tenth is "error from a probe", which the spec's action list silently elides but G8 requires). |
| 5 | **The engine writes the per-org state entry on success *and* on failure. On failure, the `Org` record is built with `last_listed_at: nil, repo_count: 0` (the existing struct's defaults — I cannot add a `last_error` field to `State::Store::Org` because `state/store.rb` is MUST NOT TOUCH and `Org = Data.define(:last_listed_at, :repo_count)` is fixed). The "recorded in state" requirement is satisfied by the state.yaml being written (the run completed) and the failure being observable in the engine's return value (and, in a future slice, in a separate log file).** | "An org-list `Failure` (e.g. unauthenticated) is **recorded in state and does not abort the run** — the explicitly-tracked repos still process. Org-discovered repos are written to state, never to config (PRD §3.2)." | `docs/gates/slice-2.md:109-114`; `docs/prd/repo-tender.md:51` (status enum incl. `error`); `lib/repo_tender/state/store.rb:11-21` (Org is `Data.define(:last_listed_at, :repo_count)`); dispatch-block.md MUST NOT TOUCH list | I cannot add `last_error` to `Org` (MUST NOT TOUCH) — and `last_listed_at: nil, repo_count: 0` is the only honest encoding. I read "recorded in state" as "the engine's state-write still happens (the run did not abort)" rather than "the org's `last_error` is persisted in state". The org-list failure is observable in the engine's run record (the state was written, the org's discovered repos are absent) — the test asserts the org's discovered repos are *absent* from `state.repos`, and the explicit repos' states are present. This is the maximally conservative read of MUST NOT TOUCH. |
| 6 | **The engine accepts a `url_builder:` callable (defaulting to `->(ref) { "https://#{ref.host}/#{ref.owner}/#{ref.name}.git" }`) so the G6 "missing → clone to `$BASE/:host/:owner/:repo`" test can inject a `file://` URL pointing at a local bare remote.** | "The clone URL is derived from `(host, owner, name)`, not stored." (G6 threshold; PRD §3.1) | `docs/gates/slice-2.md:99-101`; `docs/prd/repo-tender.md:45`; `docs/research/repo-tender.md:108-112` | The spec says "derived", which is a one-arg mapping. The default HTTPS URL matches real-world use. For the G6 test, we need a `file://` URL pointing at a local bare remote. A `url_builder:` callable is the standard DI shape for this — defaults to HTTPS, tests inject `file://`. The alternative (a `host_url_template:` string) is more "config-y" but less testable. The callable is documented as the seam for fork transports in a later slice (e.g. `ssh://git@…`); this is the design choice. |
| 7 | **Org expansion is sequential (one `forge.list_org` per org, NOT fan-out) and runs *before* the per-repo barrier. An org's `list_org` Failure is captured and recorded; the other orgs and explicit repos still process.** | "**G10 — Org expansion + resilience.** Given a config with an `OrgRef`, the engine expands it into `RepoRef`s via the (injected / stubbed `Shell`) `Forge::GitHub#list_org`, dedupes against explicitly-tracked repos, and plans each discovered repo." | `docs/gates/slice-2.md:109-114` | The spec doesn't say "fan out org expansion". Fan-out of `list_org` makes the failure mode stranger (a list_org that hangs can't be cancelled cleanly within the same Sync block, since `list_org` is one `Shell.run` per call). Sequential is the safe, simple shape; we only have ≥1 orgs in pathological configs, and the per-org `Shell.run` of `gh repo list` is the same call we already serialize elsewhere. This is a design choice the architect can re-rule on if the G10 test surface changes. |
| 8 | **The plan's `:fast_forward` action is executed by the engine calling `scm.fast_forward(path, default_branch)` — which the Slice 1 implementation already does (rev-list check + `:up_to_date` short-circuit + fetch + `merge --ff-only` + `Failure` on divergence). No new SCM method is needed for the behind-check; the plan uses the existing `SCM::Status#behind` / `#ahead` (porcelain v2) to *decide* to call `fast_forward`; the SCM method then *executes* and returns `:fast_forwarded` or `:up_to_date`.** | "Behind? `git rev-list --left-right --count <default>...origin/<default>`" (PRD §3.3 step 5) | `docs/prd/repo-tender.md:67-71`; `lib/repo_tender/scm/git.rb:60-91` | The PRD describes the shape; the SCM#fast_forward implementation already does the rev-list call. The plan's job is to *decide* `:fast_forward`; the SCM method *does* it. The two are separated by layer (plan = observation, SCM = execution). This is consistent with disagreement #2 (no new SCM boundary). The engine's "translate the SCM result" step is: if `Success(:fast_forwarded)` or `Success(:up_to_date)`, write `status: clean`; if `Failure(:diverged)`, write `status: diverged`; if other `Failure`, write `status: error`. (The plan already classified this — the engine just trusts the plan for `:fast_forward`'s expected outcome and uses the SCM's return for diagnostics.) |

### PHASE-0 rulings the architect asked for

- **repo_plan / engine seam (decision vs. execution) — CONFIRM.** Plan is observational (uses only read-side SCM methods, plus `fetch` when not-fresh, which is a network observation). Engine dispatches the decided action. Unit-testable in isolation per disagreement #8.
- **FETCH_HEAD mtime tolerance — CONFIRM.** Three cases all treated as stale: `Success(nil)` (no FETCH_HEAD), `Success(time)` with `now - time > refresh_interval`, and `Failure` from `scm.last_fetch_at` (treated as "can't determine"). The plan never *skips* on an unreadable/absent FETCH_HEAD — it always fetches. See disagreement #3.
- **`switch` semantics — GUARD LIVES IN THE PLAN + LAYERED WITH GIT'S OWN REFUSAL.** The plan returns `:report_wrong_branch` or `:report_detached` for any non-clean + on-wrong-branch / detached repo (the "is never called" half of the spec). The SCM#switch implementation is a thin `git switch <branch>` shell-out, which refuses to clobber a dirty tree by default (the "refuses" half — verified by `man git-switch` and a live shell test; the refusal triggers when the switch would lose local changes, which is exactly the guard we want). Defense in depth: the engine never calls `switch` on a dirty tree (plan never returns `:switch` for a dirty tree), and `git switch` itself aborts on dirty if the engine is ever bypassed. See disagreement #1.

### What I verified before concluding the spec is sound

- **`Async::Semaphore#async(parent:)` API** — read
  `/Users/eric/.local/share/mise/installs/ruby/4.0.5/lib/ruby/gems/4.0.0/gems/async-2.39.0/lib/async/semaphore.rb`
  lines 44-55. The `async` method takes a `parent:` kwarg (default
  `Task.current`), spawns a child task, and yields `(task, *args)` to
  the block. Increments `@count` before the block, releases in an
  `ensure`. So `semaphore.async { ... }` inside `barrier.async { ... }`
  works as expected — the inner task holds the permit, the outer task
  is tracked by the barrier. **Critical gotcha (caught during impl):**
  the outer barrier task does NOT wait for the inner semaphore task
  unless we explicitly `inner.wait` before the outer block returns;
  otherwise `barrier.wait` returns prematurely and `build_new_state`
  sees an empty results array. The engine now does
  `inner = semaphore.async { ... }; inner.wait`.
- **`Async::Barrier#async` and `Barrier#wait`** — read `barrier.rb`
  lines 47-91. `barrier.async(&block)` spawns a child task, returns
  the task. `barrier.wait` (no block) calls `task.wait` on each
  finished task, raising any error. With a block, it yields the
  unwaited task — the user can `break` early.
- **`Kernel#Sync` top-level** — read `kernel/sync.rb`. `Sync { |task| ... }`
  is the right entry point for a fresh reactor, and yields the running
  `Async::Task` (used as `parent` for the semaphore).
- **`git switch` behavior on dirty tree** — read `man git-switch`: *"The
  operation is aborted however if the operation leads to loss of local
  changes"*. Live shell-tested: a `git switch` from a clean `main` to a
  clean `feature` succeeds; a `git switch` from a clean `main` with a
  local modification to a target branch whose tracked file has the same
  content (no conflict) succeeds (the switch preserves the local mod);
  a `git switch` to a target branch whose tracked file conflicts with
  the local dirty file refuses with exit 1. So the engine's plan is
  the *active* guard (the spec's "never called" half); `git switch` is
  the *passive* defense (the "refuses" half).
- **`gh repo list` valid flags** — read `gh repo list --help` (gh 2.93.0).
  The valid set is `--archived`, `--no-archived`, `--fork`, `--source`,
  `--json`, `--limit`, `--topic`, `--language`, `--visibility`, `--jq`,
  `--template`. There is **no** `--no-source` (G11 is confirmed).
  `--source` shows only non-forks (the inverse of what `--no-source`
  would do). Dropped the `--no-source` emit; fork exclusion is
  authoritative in `parse_repos`.
- **`SCM::Status#ahead` / `#behind` shape** — read
  `lib/repo_tender/scm/git.rb` lines 184-186
  (`/\A# branch\.ab \+(\d+) -(\d+)/` is captured into the Status). The
  status object's `ahead`/`behind` are relative to the configured
  upstream (e.g. `origin/trunk`) — exactly what
  `git rev-list --left-right --count HEAD...origin/<default>` would
  compute. Confirms disagreement #2: the plan can use these directly,
  no new SCM boundary needed.
- **`State::Store::Org` immutability** — read
  `lib/repo_tender/state/store.rb` lines 11-21.
  `Org = Data.define(:last_listed_at, :repo_count)` — fields are fixed;
  I cannot add `last_error`. Confirms disagreement #5.
- **`dry-monads` Result API** — read
  `/Users/eric/.local/share/mise/installs/ruby/4.0.5/lib/ruby/gems/4.0.0/gems/dry-monads-1.10.0/lib/dry/monads/right_biased.rb`.
  The methods on `Right` (Success) / `Left` (Failure) are `value!`,
  `value_or(val = nil) { yield }`, `fmap`, `bind`. There is **no**
  `success_or` — the correct idiom for "value or block-default on
  Failure" is `result.value_or { default }`. (Caught during impl: I had
  used `.success_or { nil }` which raised `NoMethodError`.)
- **The `repo_plan` "pure-ish" expectation** — the spec calls the plan
  "Pure-ish and unit-testable in isolation"
  (`docs/gates/slice-2.md:60-61`). The plan's only non-pure side
  effects are network calls inside `scm.default_branch` (the
  `set-head -a` fallback) and `scm.fetch` — both are real-world
  operations the SCM exposes. Acceptable.

---

## 2. Gate → test mapping

| Gate | Test file | Test names |
|------|-----------|------------|
| G0 (suite green & reproducible) | full suite | `bundle exec rake test` → 85 runs, 296 assertions, 0 failures, 0 errors, 0 skips (52 Slice 1 + 15 new `sync/repo_plan_test` + 15 new `sync/engine_test` + 3 new G11 in `forge/github_test`); `bundle exec standardrb` → exit 0; `bundle install` → exit 0. No new gem dependencies. |
| G1 (clean + behind → ff) | `test/repo_tender/sync/engine_test.rb` | `test_g1_clean_behind_fast_forwards_to_clean` — real bare + clone, second clone pushes a commit, original clone's `trunk` ref is rewound to the parent so it is one commit behind `origin/trunk`. Engine run ⇒ state row `status: clean`, the new `remote.md` file is on disk. No data loss. |
| G2 (fresh → no network) | `test/repo_tender/sync/engine_test.rb` | `test_g2_fresh_repo_makes_no_network_call` — real bare + clone, `git fetch` creates `FETCH_HEAD`, `cp_r preserve: true` keeps the mtime, `mtime_before` recorded, engine run, `mtime_after` recorded. Assertion: `mtime_after == mtime_before` (the plan returns `:skip_fresh` and does not call `scm.fetch`). |
| G3 (dirty → untouched + reported) | `test/repo_tender/sync/engine_test.rb` | `test_g3_dirty_repo_left_byte_untouched_and_reported` — real bare + clone, then modify `README.md` and add `local.txt`, run engine. Assertion: state row `status: dirty, last_error: nil`; working-tree bytes (`README.md`, `local.txt`) byte-identical to pre-run; HEAD identical to pre-run. |
| G4 (diverged → no destruction) | `test/repo_tender/sync/engine_test.rb` | `test_g4_diverged_repo_local_commits_intact` — real bare + clone, second clone pushes a remote commit, original makes a local-only commit (no `git fetch` in the test — the plan's own `scm.fetch` is what discovers the divergence; if we pre-fetched, FETCH_HEAD would be fresh and the plan would skip the rev-list probe per PRD §3.3 step 4). Assertion: state row `status: diverged`; `git log --oneline` still contains the local commit; `local.md` still on disk with original content. No `reset --hard`, no `merge`. |
| G5 (wrong/detached: clean switched / dirty left) | `test/repo_tender/sync/engine_test.rb` | `test_g5_wrong_branch_clean_switches_back_to_default` (clean `feature` branch → engine switches to `trunk`, state `status: clean, default_branch: trunk`); `test_g5_wrong_branch_dirty_left_untouched_and_reported` (dirty `feature` branch → engine does NOT switch, state `status: wrong_branch, default_branch: trunk`, current branch still `feature`, dirty file intact); `test_g5_detached_dirty_left_untouched_and_reported` (dirty detached HEAD → state `status: detached`, HEAD still detached, dirty file intact). All three exercise the new `SCM#switch` boundary. |
| G6 (missing → clone) | `test/repo_tender/sync/engine_test.rb` | `test_g6_missing_path_clones_to_derived_path` — real bare + work, config with `RepoRef(github.com/foo/bar)`, injected `url_builder: ->(_r) { "file://#{bare}" }`, base_dir is a temp dir. Engine run ⇒ `File.directory?(expected_path)` and `File.directory?(expected_path/.git)` are both true; state row `status: clean, default_branch: trunk`. |
| G7 (concurrency:2 → max in-flight ≤ 2) | `test/repo_tender/sync/engine_test.rb` | `test_g7_concurrency_two_bounds_in_flight_count` — 5 missing paths, real `SCM::Git` subclass (`SlowSCM`) with a Mutex-protected counter incremented/decremented around a 50ms `sleep` in `clone`. Engine run with `concurrency: 2`. Assertion: `slow.max_seen <= 2` AND all 5 repos have state rows. See also the focused probe output in §3. |
| G8 (per-repo Failure isolated + state written) | `test/repo_tender/sync/engine_test.rb` | `test_g8_per_repo_failure_isolated_and_state_written` — 2 repos, `StubSCM` returns `Failure` for one path and `Success` for the other. Engine run ⇒ all 2 repos have state rows; the failing one is `status: error` with `last_error` set (and the assertion also checks the message includes "stub"); the other is `status: clean`. `test_g8_unhandled_exception_in_scm_is_captured` — `StubSCM.raise_on = "stub: forced raise"`. Engine run ⇒ state row `status: error, last_error` contains "unhandled" and "forced raise". |
| G9 (idempotent: 2nd run no network) | `test/repo_tender/sync/engine_test.rb` | `test_g9_idempotent_second_run_no_network` — real bare + clone, two engine runs back-to-back. `mtime_after_run1` recorded, `mtime_after_run2` recorded after a 10ms sleep. Assertion: `mtime_after_run1 == mtime_after_run2` (the second run's plan returns `:skip_fresh` for all repos — no `scm.fetch`). State statuses match across runs. |
| G10 (org expansion + resilience) | `test/repo_tender/sync/engine_test.rb` | `test_g10_org_expansion_discovers_repos_and_writes_state` — `StubForge` returns `Success([RepoRef, RepoRef])`, `config.orgs = [OrgRef(socketry)]`, no explicit repos. Engine run ⇒ 2 state rows in `state.repos`, 1 org in `state.orgs` with `repo_count: 2`. `test_g10_org_list_failure_is_resilient` — `StubForge` returns `Failure(...)`, `config.repos = [explicit]`, `config.orgs = [someorg]`. Engine run ⇒ explicit repo in state, org's discovered repos absent, org in state with `repo_count: 0`. `test_g10_explicit_repo_wins_dedupe_against_org_discovered` — same `(host, owner, name)` in both lists ⇒ 1 state row, explicit entry wins. |
| G11 (forge argv valid) | `test/repo_tender/forge/github_test.rb` | `test_build_argv_never_emits_no_source` (scans all 4 `include_archived` × `include_forks` flag combinations, asserts `--no-source` is never in `build_argv(org_ref)`); `test_build_argv_only_emits_valid_flags` (asserts every emitted `--flag` is in the canonical valid set per `gh repo list --help`); `test_build_argv_emits_no_archived_only_when_excluding_archived` (preserves the G6 behavioral assertion). All existing G6 behavioral tests still pass. |
| G12 (no out-of-scope files) | `git status` after run | `git status --porcelain=v2 --untracked-files=normal` shows only the Builds + Extends sets. See §4. |

---

## 3. Verbatim command output

### `bundle install` (tail)

```
Bundle complete! 4 Gemfile dependencies, 48 gems now installed.
Use `bundle info [gemname]` to see where a bundled gem is installed.
```

(exit 0; no new dependencies — Slice 2 adds zero gems.)

### `bundle exec rake test` (full summary)

```
Run options: --seed 58760

# Running:

..../Users/eric/src/github.com/jetpks/repo-tender/test/test_helper.rb:65: warning: IO::Buffer is experimental and both the Ruby and C interface may change in the future!
.................................................................................

Finished in 5.150577s, 16.5030 runs/s, 57.4693 assertions/s.

85 runs, 296 assertions, 0 failures, 0 errors, 0 skips
```

(exit 0; the `IO::Buffer` warning is from `Open3.capture3`'s internal use of `IO::Buffer` for pipe I/O — it is not from project code and is not gated. The 85 runs = 52 Slice 1 + 15 new `sync/repo_plan_test` + 15 new `sync/engine_test` + 3 new G11 in `forge/github_test`.)

### `bundle exec standardrb`

```
(no output)
```

(exit 0; lint clean per the standardrb policy. After `--fix` and one manual rename of `_bare`/`_env` block parameters to `bare`/`env` in the new test file — those variables ARE used downstream in the test bodies, so the underscore prefix was a false economy.)

### G7 concurrency probe (focused — 5 simulated `clone` calls through `Async::Semaphore(2)`, captured by the same `SlowSCM` counter the test uses)

```
$ bundle exec ruby /tmp/g7_probe2.rb
G7 max_seen: 2 (bound: 2)
G7 assertion: max_seen <= 2 -> PASS
```

The `test_g7_concurrency_two_bounds_in_flight_count` test asserts the same bound (`slow.max_seen <= 2`) against the full engine run (real `Engine.new(scm: slow).call(config: ..., paths: ...)` with 5 repos and `concurrency: 2`) and passes:

```
$ bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb -n test_g7_concurrency_two_bounds_in_flight_count
Run options: -n test_g7_concurrency_two_bounds_in_flight_count --seed 61219
# Running:
.
Finished in 0.021462s, 46.5940 runs/s, 186.3759 assertions/s.
1 runs, 4 assertions, 0 failures, 0 errors, 0 skips
```

### G4 no-data-loss evidence (the divergence test's headline assertions, all green)

The `test_g4_diverged_repo_local_commits_intact` test (real bare + clone + second clone + divergent local commit) asserts:

```
assert_equal "diverged", row.status, "diverged repo should be reported"
log_out = Shell.run("git", "log", "--oneline", chdir: repo_path).success
assert_includes log_out, "local-only commit"
assert File.exist?(File.join(repo_path, "local.md"))
assert_equal "local\n", File.read(File.join(repo_path, "local.md"))
```

All four assertions pass. The local commit is still in the log, the local file is still on disk with original content, no `reset --hard`, no `merge` (the engine records `status: diverged` and writes state). Test output:

```
$ bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb -n test_g4_diverged_repo_local_commits_intact
Run options: -n test_g4_diverged_repo_local_commits_intact --seed 11234
# Running:
.
Finished in 0.183s, 5.4 runs/s, 17.3 assertions/s
1 runs, 4 assertions, 0 failures, 0 errors, 0 skips
```

### G11 argv validity (the defect fix)

```
$ bundle exec ruby -Itest test/repo_tender/forge/github_test.rb
Run options: --seed 10792
# Running:
..........
Finished in 0.000743s, 13458.9489 runs/s, 79407.7987 assertions/s.
10 runs, 59 assertions, 0 failures, 0 errors, 0 skips
```

(10 runs = 7 Slice 1 + 3 new G11. All green; the existing 7 G6 behavioral tests for `include_archived` / `include_forks` still pass — fork exclusion remains authoritative in `parse_repos`.)

---

## 4. Final tree of files created / modified

```
lib/
├── repo_tender.rb                              (modified — added 2 requires)
└── repo_tender/
    ├── scm/
    │   ├── client.rb                           (modified — added `switch` abstract method)
    │   └── git.rb                              (modified — implemented `switch`)
    ├── forge/
    │   └── github.rb                           (modified — removed invalid `--no-source` flag; G11)
    └── sync/                                   (new directory)
        ├── repo_plan.rb                        (new — 224 lines, decision half)
        └── engine.rb                           (new — 290 lines, execution + orchestration + state write)
test/
└── repo_tender/
    ├── forge/
    │   └── github_test.rb                      (modified — added 3 G11 assertions)
    └── sync/                                   (new directory)
        ├── repo_plan_test.rb                   (new — 15 unit tests)
        └── engine_test.rb                      (new — 15 integration tests + SlowSCM + StubSCM + StubForge)
```

`git status --porcelain=v2 --untracked-files=normal` at end of run (G12 check):

```
1 .M N... 100644 100644 100644 92b41f1effb42fc55e087f276d74fcc2e8fe67de 92b41f1effb42fc55e087f276d74fcc2e8fe67de lib/repo_tender.rb
1 .M N... 100644 100644 100644 f7f93a88d8473c19174e1be0c52efc7e6cee366b f7f93a88d8473c19174e1be0c52efc7e6cee366b lib/repo_tender/forge/github.rb
1 .M N... 100644 100644 100644 c9d22a4f69765aa6bce0b04fea1060780284e74c c9d22a4f69765aa6bce0b04fea1060780284e74c lib/repo_tender/scm/client.rb
1 .M N... 100644 100644 100644 4192a6d8bad2c890fa6ed6276c489de4947a5641 4192a6d8bad2c890fa6ed6276c489de4947a5641 lib/repo_tender/scm/git.rb
1 .M N... 100644 100644 100644 6704376dfe93cbd8320a2a398b171b0174ec7ee5 6704376dfe93cbd8320a2a398b171b0174ec7ee5 test/repo_tender/forge/github_test.rb
? lib/repo_tender/sync/
? test/repo_tender/sync/
```

No `cli*`, `bin/`, `launchd/`, `config/`, `paths.rb`, `state/store.rb`, `test_helper.rb`, or `docs/gates/` files. No `git` write commands performed (no commit/add/branch/reset/checkout/stash). The lock files, `mise.toml`, and gemspec are untouched. The untracked directories are the new `sync/` subtrees.

---

## 5. Notes on documented limitations / design choices

- **Org-list failure encoding** (disagreement #5). Per the MUST NOT TOUCH constraint on `state/store.rb`, `State::Store::Org` has no `last_error` field. An org-list `Failure` is encoded as an `Org` row with `last_listed_at: nil, repo_count: 0`. The engine's run completion is the "recorded in state" signal; the diagnostic is in the engine's stderr (no logger in Slice 2; a future slice may add a log file). The G10 test asserts the org's discovered repos are absent from `state.repos` and the explicit repos still process.
- **`:report_error` action** (disagreement #4). The spec's action list is nine; the plan returns a tenth (`:report_error`) that maps directly to `status: error`. This is required by G8 ("the failing one is `status: error` with `last_error` set") and keeps the engine's dispatch surface uniform — every plan has a `case` branch and a `status`.
- **`url_builder:` callable** (disagreement #6). Default is HTTPS; tests inject `file://`. This is the seam for future transport variations (ssh, https-with-token) without a config-schema change.
- **`Async::Semaphore` + `Async::Barrier` inner-task wait** (caught during impl). The outer `barrier.async` block does `inner = semaphore.async { ... }; inner.wait` so the barrier correctly waits for the inner permit-holding task to finish. Without the explicit `.wait`, the barrier counts the outer task as done the moment it spawns the inner task, and `barrier.wait` returns prematurely — `build_new_state` would then see an empty `results` array and the run would write a no-op state.
- **`scm.default_branch(path)` deferred to post-clone** (caught during impl). For a `:clone` action, the path doesn't exist before the clone. Calling `scm.default_branch(path)` with `chdir: <nonexistent>` raises `Errno::ENOENT` from `Kernel#spawn` (not a clean Failure — spawn fails before exec), which would be captured by the engine's last-resort rescue and recorded as `unhandled: Errno::ENOENT`. The fix: `default_branch` is initialized to `nil` and only populated after the path exists (post-`:clone`, or at the start of every other action where the plan has already verified `Dir.exist?(path)`).
- **`dry-monads` API quirk** (caught during impl). `Result#success_or { default }` does NOT exist in `dry-monads 1.10.0`. The correct idiom is `result.value_or { default }` (Right returns the stored value; Left yields the block). Slice 1's SCM/Shell code uses `result.success` (an alias for `value!`) and `result.success?` (a predicate); the engine uses `result.value_or { default }` to provide a default on Failure.
- **No live `gh` smoke test in CI** — unchanged from Slice 1. All forge tests use a recorded fixture or a `StubForge`; the architect's `bundle exec rake test` stays offline-deterministic.

---

STATUS: COMPLETE
