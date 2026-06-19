# Lane cf-cleanup-09 — CF9: org fan-out rescue + ensure-guarded teardown

Freeze commit: `5106b7b881e5c235e51fc69cc173080be341fa0b`

---

## Production diff summary

Two changes to `lib/repo_tender/sync/engine.rb`:

**Part A — org-fiber rescue (lines 221-231 in new file):**
Added `rescue => e` at the bottom of the `semaphore.async do...end` block body
in `expand_orgs`. On any unhandled raise from `@forge.list_org` (or code inside
the block):
- Computes `key = org_key(org_ref)` (closure-captured `org_ref`)
- Gets `prev = prev_orgs[key]` to preserve CF3 prior counts
- Builds `State::Store::Org.new(last_listed_at: prev&.last_listed_at, repo_count: prev&.repo_count || 0, last_error: "unhandled: #{e.class}: #{e.message}")`
- Writes row under `org_mutex` (same as the Failure branch)
- Emits `@reporter.org_listed(org_ref, count: nil)` outside mutex (mirrors Failure branch shape exactly)

The raise no longer escapes `inner.wait` → `org_barrier.wait` → `Engine#call`.

**Part B — ensure-guarded detach (lines 97-148 in new file):**
Wrapped the body after `@reporter.attach(task)` in `begin...ensure @reporter.detach end`.
- `attach` unchanged at line 96 (before expansion)
- `@reporter.detach` moved from after `run_finished` into the `ensure` clause
- Happy-path event order unchanged: attach → listing_* → run_started → repo_* → run_finished → (begin exits) → ensure → detach
- Detach fires exactly once on all paths: normal, write-failure `return`, or escaping raise

Diff stats: `+26/-14` in `engine.rb` (structural indentation shift for Part B + 10 new rescue lines for Part A).

---

## Gate results

### G9.0 — Suite + lint + no new gems

```
bundle exec rake test
361 runs, 1291 assertions, 0 failures, 0 errors, 0 skips
(baseline was 358 runs — +3 new tests)
```

```
bundle exec standardrb
(exit 0, no output)
```

```
git diff 5106b7b881e5c235e51fc69cc173080be341fa0b -- repo-tender.gemspec Gemfile.lock
(empty — no new gems)
```

### G9.1 — Raising list_org isolated; run completes, state written, CF3 preserved

Tests added:

| Test | Covers |
|------|--------|
| `test_g9_1_raising_list_org_isolated_run_completes_state_written` | 3 orgs, 1 raises; Engine#call returns Success; raising org row has `last_error` containing `"unhandled:" + "RuntimeError"`; CF3: `repo_count: 5` and `last_listed_at: 2026-01-01T00:00:00Z` preserved from prev state; ok-org1/ok-org2 listed normally; state.yaml written |
| `test_g9_1_raising_list_org_first_run_records_error_with_zero_repo_count` | First run (no prev row): ArgumentError from list_org recorded with `repo_count: 0`, `last_listed_at: nil`, `last_error` contains `"unhandled:" + "ArgumentError"` |

All passed (0 failures).

### G9.2 — Teardown runs even on escaping raise (Part B ensure-guard)

Test added: `test_g9_2_ensure_detach_runs_on_escaping_raise_from_listing_started`

**Exact injection mechanism:** `RaisingOnListingStartedReporter` — a reporter class
defined in the test file whose `listing_started` method raises `RuntimeError` with
message `"injected raise in listing_started (G9.2)"`. This raise occurs directly in
`expand_orgs` line 166 (`@reporter.listing_started(total: config.orgs.size)`), which
is called from `Engine#call` inside the `begin` block, before any org-fiber rescue
can act. The raise escapes `expand_orgs` and propagates up through the `begin` block
in `Engine#call`, triggering the `ensure` clause.

Assertion: `reporter.events.count { |e| e.first == :detach } == 1` — passes.
Assertion: `reporter.events.count { |e| e.first == :attach } == 1` — passes.
The test wraps the call in `assert_raises(RuntimeError)` confirming the raise does
escape `Engine#call` (Part B's ensure does not swallow it).

### G9.3 — engine_test.rb diff is +N/-0

```
git diff 5106b7b881e5c235e51fc69cc173080be341fa0b -- test/repo_tender/sync/engine_test.rb --stat

 test/repo_tender/sync/engine_test.rb | 171 ++++++++++++++++++++++++++++++++++++++
 1 file changed, 171 insertions(+), 0 deletions(-)
```

Pure additions. All existing `test_gs1*`, `test_gs2*`, `test_gs3*`, `test_gs4*`,
`test_g10_*`, `test_g7_org_list_failure_*` tests pass unchanged (suite 0 failures).

### G9.4 — Scope check

```
git status
On branch lane/cf-cleanup-09
Changes not staged for commit:
    modified: lib/repo_tender/sync/engine.rb
    modified: test/repo_tender/sync/engine_test.rb
```

```
git diff 5106b7b881e5c235e51fc69cc173080be341fa0b -- lib/repo_tender/state/store.rb lib/repo_tender/shell.rb
(empty — 0 lines)
```

```
git log 5106b7b881e5c235e51fc69cc173080be341fa0b..
(empty — no commits)
```

Touched files: `lib/repo_tender/sync/engine.rb`, `test/repo_tender/sync/engine_test.rb`,
`docs/lanes/cf-cleanup-09.md`. `state/store.rb`, `shell.rb`, `scm/*`, `forge/*`
byte-unchanged. No builder commits. `docs/gates/` unmodified.

---

STATUS: COMPLETE
