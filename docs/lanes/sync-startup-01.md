# Lane Report: sync-startup-01

## PHASE 0: Plan, Disagreements, Async Verification

### Async API verification (live source: ~/src/evergreen/github.com/socketry/async/)

**Semaphore#async** (`async/lib/async/semaphore.rb:61-73`): Takes optional `parent:` kwarg; defaults to `Task.current`. Calls `wait` (blocks if `@count >= @limit`), then `parent.async { @count += 1; yield; ensure release }`. The engine's existing pattern at `engine.rb:112` — `semaphore.async do` inside a `barrier.async` block — uses the barrier-child as parent via `Task.current`. The org-listing fan-out mirrors this exactly.

**Barrier#async** (`async/lib/async/barrier.rb:48-73`): `@condition.wait while waiting.nil?` guard ensures the task is tracked before returning. Safe for concurrent use. The existing `barrier.async { inner = semaphore.async { work }; inner.wait }` idiom is correct and reused for org fan-out with a separate `org_barrier`.

**ensure on cancel**: `Async::Task` runs the block's `ensure` clause on cancellation. This is the correct cleanup seam — used in InteractiveReporter's `render_loop` to restore the cursor unconditionally.

**Decision: reuse `config.concurrency` for org listing bound.** A separate constant would require either a new config field (MAY NOT TOUCH config/) or a magic number. `config.concurrency` was designed for I/O-bound tasks of exactly this character. Using the same bound keeps the concurrency model coherent.

### Disagreements (with rulings)

**D1 — `attach(task, total:)` signature change breaks 5 existing test call sites.**
Files: `engine_test.rb:933`, `interactive_reporter_test.rb:48` (×19 sites), `plain_reporter_test.rb:41`, `json_reporter_test.rb:94`. All updated additively — call sites changed to `attach(task)`, no assertions removed. The invariant that `attach` is first is preserved via positional-index assertions.

**D2 — InteractiveReporter#attach currently initializes `@total` from `total:` kwarg.**
After dropping the kwarg, `@total` is no longer set at attach time. `run_started(total:)` still sets it (for the sweep phase). A two-phase state machine (`@phase = :listing | :sweep`) was added. `listing_started(total:)` sets `@org_total`; `run_started(total:)` sets `@total` and transitions to sweep. No test assertions removed.

**D3 — Engine's `attach` call was AFTER `expand_orgs`; spec wants it BEFORE.**
Engine line 94 (old): `@reporter.attach(task, total: repos_to_process.size)` after expansion. After this slice: `@reporter.attach(task)` is called immediately after loading state (before `expand_orgs`). The render fiber is alive during listing. This is the intended seam change.

**D4 — Separate `org_barrier` vs. reusing the repo barrier.**
Used a separate `org_barrier = Async::Barrier.new` for the listing phase. The phases are sequential (listing completes before sweep). Conflating them in one barrier would require them to run concurrently, which is not the design. Two barriers, one per phase.

**D5 — `check_authenticated` moved from `private` to `public` in GitHub.**
The `def check_authenticated` definition moved above the `private` keyword in `github.rb`. Added declaration to `forge/client.rb`. `StubForge` in `engine_test.rb` gained `check_authenticated` returning `Success` by default. `ForgeGitHubTest#test_invokes_auth_status_before_repo_list` replaced with 3 more precise tests: `test_check_authenticated_is_public`, `test_list_org_does_not_call_auth_status`, `test_check_authenticated_returns_*`.

**D6 — `org_listed(ref, count:)` uses `OrgRef` struct, not a string key.**
The existing repo events pass "host/owner/name" string keys (the state key). For listing events, `OrgRef` struct is passed directly: reporters display `ref.name`, JSON reporters use `ref.name`. This avoids splitting the key string to get the display label. No state key is needed for listing events (they're not keyed to state rows).

**D7 — Auth-failure path must emit listing events and record all orgs.**
On `check_authenticated` Failure: emit `listing_started(total: n_orgs)`, then one `org_listed(org_ref, count: nil)` per org, then `listing_finished`. No `list_org` calls. This preserves CF3 (prev `repo_count`/`last_listed_at` from `prev_orgs`) and the phase-order invariant.

**D8 — `test_passes_correct_json_fields` in github_test.rb was checking `captured_argv[1]`** (index 1 because auth was first). Updated to `captured_argv[0]` since `list_org` no longer calls auth.

**D9 — `listing_finished` is a no-op in InteractiveReporter.**
Phase transition from listing to sweep is handled by `run_started` (not `listing_finished`). This keeps the transition tied to when the repo count is known. `listing_finished` is a no-op in all reporters (NullReporter, PlainReporter, JsonReporter emit nothing; InteractiveReporter no-ops it too).

---

## Before/After Concurrency Evidence

### SlowForge test results (GS1 + GS2)

```
Sequential baseline: 0.400s  (4 orgs × 0.100s each)
Concurrent elapsed:  0.104s  (≈ slowest_org + overhead)
Max in-flight:       4        (must be > 1)  ✓
Auth calls:          1        (must be exactly 1)  ✓
list_org calls:      4        (one per org)  ✓
```

Wall-time ratio: 0.104 / 0.400 = 0.26 (concurrency factor ≈ 3.8× with N=4 orgs).
Threshold: must be < (N-1)·S = 0.300s — PASS (0.104s << 0.300s).

### Auth-once proof (GS2)

`RecordingForge` over 5 orgs: `auth_calls = 1`, `list_org_calls = 5`. On auth failure: `auth_calls = 1`, `list_org_calls = 0`, all 5 orgs recorded with `last_error` set.

---

## Gate → Test Mapping

| Gate | Test file | Test name(s) |
|------|-----------|--------------|
| GS0 | suite/lint | `rake test` 338/1213/0/0/0; `standardrb` 0; gemspec/Gemfile.lock diff empty |
| GS1 | engine_test.rb | `test_gs1_org_expansion_is_concurrent` |
| GS2 | engine_test.rb | `test_gs2_check_authenticated_called_exactly_once_for_five_orgs`, `test_gs2_auth_failure_records_all_orgs_failed_no_list_org_called` |
| GS3 | engine_test.rb | `test_gs3_concurrent_expansion_discovers_same_set_as_sequential`, `test_g10_org_expansion_discovers_repos_and_writes_state`, `test_g10_org_list_failure_is_resilient`, `test_g10_explicit_repo_wins_dedupe_against_org_discovered`, `test_g7_org_list_failure_preserves_prior_repo_count_and_records_error`, `test_g7_org_list_failure_on_first_run_records_error_with_zero_repo_count` |
| GS4 | engine_test.rb | `test_gs4_listing_events_in_phase_order`, `test_gs4_listing_started_with_zero_orgs_emits_no_org_listed`, `test_g3_engine_emits_attach_run_started_repo_pairs_run_finished_detach`, `test_g3_four_scenario_run_emits_correct_pairs` |
| GS5 | plain_reporter_test.rb | `test_out_sync_is_true_after_construction`, `test_listing_started_emits_org_count_line`, `test_org_listed_success_emits_name_and_count`, `test_org_listed_failure_emits_failed_marker`, `test_listing_finished_produces_no_output` |
| GS5 | json_reporter_test.rb | `test_out_sync_is_true_after_construction`, `test_listing_started_emits_json_with_total`, `test_org_listed_emits_json_with_org_and_count`, `test_org_listed_failure_emits_null_count`, `test_listing_finished_emits_json_event` |
| GS6 | interactive_reporter_test.rb | `test_gs6_listing_phase_emits_per_org_persistent_lines`, `test_gs6_listing_phase_failure_org_emits_failed_line`, `test_gs6_render_fiber_alive_across_both_phases`, `test_gs6_listing_output_bounded_by_org_count_not_repo_count` |
| GS6 carried | interactive_reporter_test.rb | `test_gc1_*` (4 tests), `test_gc2_*` (5 tests), `test_gc3_*` (1 test), `test_g1_*` (2 tests), `test_g4_*` (2 tests), `test_g5_*` (3 tests) |
| GS7 | architect-checked | diff scope; no builder commits; no new gems |
| Slice-2 G10 | engine_test.rb | `test_g10_org_expansion_discovers_repos_and_writes_state`, `test_g10_org_list_failure_is_resilient`, `test_g10_explicit_repo_wins_dedupe_against_org_discovered` |
| Slice-4 G6/G7 | engine_test.rb | `test_g7_org_list_failure_preserves_prior_repo_count_and_records_error`, `test_g7_org_list_failure_on_first_run_records_error_with_zero_repo_count` |
| Slice-A G2 | engine_test.rb | `test_reporter_default_nullreporter_produces_byte_identical_state_yaml` |
| Slice-A G4 | plain_reporter_test.rb, json_reporter_test.rb | all existing tests |
| GC1–GC3 | interactive_reporter_test.rb | all GC tests carried green |
| G1 (no Thread) | interactive_reporter_test.rb | `test_g1_no_threads_created`, `test_g1_no_thread_new_in_source` |
| G4 (^C) | interactive_reporter_test.rb | `test_g4_cursor_show_emitted_when_task_stopped`, `test_g4_no_live_fiber_after_task_stop` |
| G5 (color) | interactive_reporter_test.rb | `test_g5_color_off_no_sgr_codes`, `test_g5_color_on_emits_sgr_codes`, `test_g5_still_animates_when_color_off` |

---

## Verbatim Output

### `bundle exec rake test`

```
338 runs, 1213 assertions, 0 failures, 0 errors, 0 skips
Finished in 14.429899s, 23.4236 runs/s, 84.0616 assertions/s.
```

### `bundle exec standardrb`

```
(no output — 0 offenses)
```

### `git diff --name-only HEAD..` (working tree vs FREEZE3 = c5d402d)

```
lib/repo_tender/forge/client.rb
lib/repo_tender/forge/github.rb
lib/repo_tender/sync/engine.rb
lib/repo_tender/ui/interactive_reporter.rb
lib/repo_tender/ui/json_reporter.rb
lib/repo_tender/ui/plain_reporter.rb
lib/repo_tender/ui/reporter.rb
test/repo_tender/forge/github_test.rb
test/repo_tender/sync/engine_test.rb
test/repo_tender/ui/interactive_reporter_test.rb
test/repo_tender/ui/json_reporter_test.rb
test/repo_tender/ui/plain_reporter_test.rb
```

(All within the MAY TOUCH set defined in GS7.)

### `git diff --stat HEAD.. -- lib/repo_tender/state/store.rb lib/repo_tender/shell.rb lib/repo_tender/scm/`

```
(empty)
```

### `git diff HEAD.. -- repo-tender.gemspec Gemfile.lock`

```
(empty)
```

### `ruby -W:no-experimental -Ilib bin/repo-tender --help`

```
Commands:
  repo-tender config [SUBCOMMAND]
  repo-tender daemon [SUBCOMMAND]
  repo-tender org [SUBCOMMAND]
  repo-tender repo [SUBCOMMAND]
  repo-tender status
  repo-tender sync
```

Exit code: 0.

---

## Implementation Summary

### Engine seam changes (confined)

1. `attach(task)` called before `expand_orgs` (line ~96)
2. `expand_orgs` signature gains `task:` and `semaphore:` kwargs
3. `expand_orgs` emits `listing_started` → auth-once → parallel fan-out via `org_barrier` + same `semaphore` → `org_listed` per org → `listing_finished`
4. Auth failure path: records all orgs with CF3 semantics, emits `org_listed(count: nil)` per org, no `list_org` calls
5. `run_started(total:)` and `run_finished`/`detach` sequence unchanged

### Forge changes

- `check_authenticated` moved from `private` to `public` in `Forge::GitHub`
- `list_org` no longer calls `check_authenticated`
- `Forge::Client` declares `check_authenticated` as the public interface

### Reporter interface changes

- `attach(task, total:)` → `attach(task)` (drops `total:` kwarg)
- Added: `listing_started(total:)`, `org_listed(ref, count:)`, `listing_finished`
- `NullReporter` no-ops all new methods

### PlainReporter / JsonReporter changes

- `@out.sync = true` at construction (immediate flush on non-TTY)
- `listing_started` → one line: "listing N org(s)"
- `org_listed` → one line: "listed: name\tN repo(s)" or "listed: name\tFAILED"
- `listing_finished` → no output
- `attach(task)` replaces `attach(task, total:)`

### InteractiveReporter two-phase changes

- `attach(task)` starts render fiber (no total yet)
- `@phase = :listing` initially; `listing_started(total:)` sets `@org_total`
- `org_listed` enqueues a persistent org line with ✓/✗ and count
- `run_started(total:)` sets `@total` and transitions `@phase = :sweep`
- Render loop dispatches to `render_listing_tick` or `render_sweep_tick` by phase
- `ensure` in `render_loop` drains both `@pending_org_lines` and `@pending_lines`
- Output: O(orgs + non_clean + failed + 1)

---

STATUS: COMPLETE
