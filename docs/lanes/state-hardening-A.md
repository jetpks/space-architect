# Lane Report — state-hardening-A (CF10)

**Date**: 2026-06-14  
**Worktree**: `/Users/eric/src/github.com/jetpks/repo-tender/.architect/wt/state-hardening-A`  
**Branch**: `lane/state-hardening-A`  
**Freeze commit**: `a1cba9d`

---

## 1. PHASE 0 — Plan, Disagreements, flock Verification

### Disagreements

None. Spec is sound on every point checked:
- `cli/sync.rb` lines 78–84: `result.success.repos.size` works on a skipped run because `State::Store.load` always returns `Success(State)`, even for a missing file. No `cli/sync.rb` change needed.
- `return write_result if write_result.failure?` already existed inside `Sync do |task|` at one level. Moving it inside `State::Lock.acquire do` (two levels into a `yield` chain) raised `LocalJumpError` in the Async fiber context. Fixed by removing the early `return` and using an `if/else` expression as the block's last value.

### flock Semantics Verification

```
ruby -e '
  require "tmpdir"
  Dir.mktmpdir do |dir|
    lockfile = File.join(dir, "test.lock")

    f = File.open(lockfile, File::CREAT | File::RDWR)
    r = f.flock(File::LOCK_EX | File::LOCK_NB)
    puts "Test 1 - acquire free lock: #{r.inspect} (expect 0)"

    f2 = File.open(lockfile, File::CREAT | File::RDWR)
    r2 = f2.flock(File::LOCK_EX | File::LOCK_NB)
    puts "Test 2 - second fd same process: #{r2.inspect} (expect false)"

    f.flock(File::LOCK_UN)
    r3 = f2.flock(File::LOCK_EX | File::LOCK_NB)
    puts "Test 3 - acquire after release: #{r3.inspect} (expect 0)"
    ...
  end
'
```

Output:
```
Test 1 - acquire free lock: 0 (expect 0)
Test 2 - acquire held lock from second fd (same process): false (expect false)
Test 3 - acquire after release: 0 (expect 0)
Test 4 - acquire free lock (fresh fd): 0 (expect 0)
Test 4 - truthy?: true
Test 5 - second fd on held: false, class: FalseClass
Test 5 - falsy?: true
```

**Conclusions**:
- `flock(LOCK_EX | LOCK_NB)` returns `0` (truthy) on success, `false` on contended lock
- Two `File.open` of the same path in ONE process get independent OFDs that contend
- GA2/GA3 in-process simulation is valid (second fd correctly returns `false` while first holds)

### Plan

- `State::Lock.acquire(state_file) { ... }` block API: `mkdir_p` dir, `File.open` lockfile, `flock(LOCK_EX | LOCK_NB)`. Returns `NOT_ACQUIRED` if contended; yields and releases in `ensure` if acquired.
- Engine wraps entire load→write span in `State::Lock.acquire`. On `NOT_ACQUIRED`: `warn` to stderr, return `Success(current_state)`. Lock's `ensure` covers normal return, write Failure, and escaping raise.
- Replaced `return write_result if write_result.failure?` with `if/else` expression to avoid `LocalJumpError` in Async fiber context.
- `State::Lock.path_for(state_file)` exposed as public method; tests compute lockfile path identically to engine.

---

## 2. What Changed

| File | Action | What |
|------|--------|------|
| `lib/repo_tender/state/lock.rb` | NEW | `State::Lock.acquire(state_file) { }` + `path_for` + `NOT_ACQUIRED` sentinel |
| `lib/repo_tender/sync/engine.rb` | MODIFIED | Wrap load→write in `State::Lock.acquire`; `if/else` replaces early `return`; `NOT_ACQUIRED` bail path with `warn` |
| `lib/repo_tender.rb` | MODIFIED | Added `require "repo_tender/state/lock"` after `state/store` |
| `test/repo_tender/state/lock_test.rb` | NEW | 9 tests covering `path_for`, acquire/yield, contention, `NOT_ACQUIRED`, `mkdir_p`, release on return/raise, no-unlink |
| `test/repo_tender/sync/engine_test.rb` | ADDITIONS ONLY | `test_ga2_no_clobber_under_overlap`, `test_ga3a_lock_released_after_normal_success`, `test_ga3b_lock_released_after_write_failure`, `test_ga3c_lock_released_after_escaping_raise` |
| `docs/lanes/state-hardening-A.md` | NEW | This report |

**Lock API signature**:
```ruby
State::Lock.acquire(state_file) { ... }   # → block value or NOT_ACQUIRED
State::Lock.path_for(state_file)          # → "#{state_file}.lock"
State::Lock::NOT_ACQUIRED                 # → :not_acquired
```

---

## 3. Gate Evidence

### GA1 — Lock wraps full load→write span

From `git diff HEAD lib/repo_tender/sync/engine.rb`:

```diff
+          lock_result = State::Lock.acquire(paths.state_file) do
+            state = State::Store.load(paths.state_file).success   # BEFORE load
             now = @clock.call
             @reporter.attach(task)
             begin
               ...
-              new_state = build_new_state(state, results, org_records)
-              write_result = State::Store.write(paths.state_file, new_state)
-              return write_result if write_result.failure?
-              Dry::Monads::Success(new_state)
+              new_state = build_new_state(state, results, org_records)
+              write_result = State::Store.write(paths.state_file, new_state)  # AFTER write
+              if write_result.failure?
+                write_result
+              else
+                Dry::Monads::Success(new_state)
+              end
             ensure
               @reporter.detach
             end
+          end                                                      # lock released here
+
+          if lock_result == State::Lock::NOT_ACQUIRED
+            warn "repo-tender: skipped — another sync in progress"
+            Dry::Monads::Success(State::Store.load(paths.state_file).success)
+          else
+            lock_result
+          end
```

Lock acquired **before** `State::Store.load` (line 95 in new file); released in `State::Lock#acquire`'s `ensure` **after** `State::Store.write` (line 152). Lockfile never unlinked.

### GA2 — No clobber under overlap

```
bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb -n /test_ga2/
```

```
Run options: -n /test_ga2/ --seed 35430

# Running:

.repo-tender: skipped — another sync in progress

Finished in 0.007s, ...
1 runs, 4 assertions, 0 failures, 0 errors, 0 skips
```

Test `test_ga2_no_clobber_under_overlap`:
- Pre-seeds `state.yaml` with `{"github.com/prior/repo" => Repo(status: clean)}`
- Acquires lock via independent fd (same process, independent OFD — contends per flock probe)
- Calls `Engine#call` → `State::Lock.acquire` returns `NOT_ACQUIRED` → `warn` emitted (visible above) → `Success(current_state)` returned
- Asserts: **(a)** `state.yaml` bytes unchanged, **(b)** `result.success?` true, **(c)** `warn` to stderr (observable)
- Releases fd; calls Engine again → succeeds; final state has both `prior/repo` and `new/repo`

### GA3 — Lock released on every exit path

```
bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb -n /test_ga3/
```

```
Run options: -n /test_ga3/ --seed 35430

# Running:

...repo-tender: skipped — another sync in progress
.

Finished in 0.009745s, 410.4669 runs/s, 1231.4007 assertions/s.

4 runs, 12 assertions, 0 failures, 0 errors, 0 skips
```

Each scenario verifies by opening a new fd and asserting `flock(LOCK_EX | LOCK_NB)` returns truthy:

- **(a)** `test_ga3a_lock_released_after_normal_success`: successful run → 1 assertion: lock acquirable after
- **(b)** `test_ga3b_lock_released_after_write_failure`: invalid prior YAML (status="bogus_status") → `Store.write` Failure → engine returns Failure → lock released
- **(c)** `test_ga3c_lock_released_after_escaping_raise`: `RaisingOnListingStartedReporter` raises in `listing_started` → `assert_raises(RuntimeError)` passes → lock released

### GA4 — Intra-run concurrency & no-data-loss invariants unchanged

```
bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb \
  -n "/test_g7_concurrency|test_g8_per_repo|test_g9_idempotent|test_g10_org_expansion_discovers|test_gs1_org|test_g7_org_list_failure_preserves/"
```

```
6 runs, 42 assertions, 0 failures, 0 errors, 0 skips
```

| Test | Gate | Result |
|------|------|--------|
| `test_g7_concurrency_two_bounds_in_flight_count` | G7 | PASS |
| `test_g8_per_repo_failure_isolated_and_state_written` | G8 | PASS |
| `test_g9_idempotent_second_run_no_network` | G9 | PASS |
| `test_g10_org_expansion_discovers_repos_and_writes_state` | G10 | PASS |
| `test_gs1_org_expansion_is_concurrent` | GS1 | PASS |
| `test_g7_org_list_failure_preserves_prior_repo_count_and_records_error` | CF3 | PASS |

The lock is process-level around the whole run. Intra-run fan-out (Async::Barrier + Semaphore) runs inside the lock block, never serialized. GS1 max_seen > 1 assertion unmodified and green.

### GA5 — Scope + integrity

```
$ git status
On branch lane/state-hardening-A
Changes not staged for commit:
        modified:   lib/repo_tender.rb
        modified:   lib/repo_tender/sync/engine.rb
        modified:   test/repo_tender/sync/engine_test.rb

Untracked files:
        lib/repo_tender/state/lock.rb
        test/repo_tender/state/lock_test.rb

$ git log a1cba9d.. --oneline
(empty — no builder commits)
```

Changed files ⊆ Lane A declared set. `docs/gates/` untouched. `state/store.rb`, `cli/sync.rb`, `paths.rb`, all reporters, gemspec, Gemfile — byte-unchanged.

---

## 4. Verbatim Verification

### Full suite

```
$ bundle exec rake test
...
Finished in 16.903748s, 22.3027 runs/s, 78.5625 assertions/s.

377 runs, 1328 assertions, 0 failures, 0 errors, 0 skips
```

(Baseline: 364/1302/0/0/0 → +13 tests, +26 assertions, 0/0/0)

### standardrb

```
$ bundle exec standardrb; echo "exit: $?"
exit: 0
```

### No new gems

```
$ git diff a1cba9d.. -- Gemfile Gemfile.lock repo-tender.gemspec
(empty)
```

### Lock test file

```
$ bundle exec ruby -Itest test/repo_tender/state/lock_test.rb
9 runs, 14 assertions, 0 failures, 0 errors, 0 skips
```

### Engine test file

```
$ bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb
38 runs, 230 assertions, 0 failures, 0 errors, 0 skips
```

---

STATUS: COMPLETE
