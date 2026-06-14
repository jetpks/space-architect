# Lane cf-cleanup-08 — CF8: concurrency-safe `report_on_exception`

Freeze commit: `5106b7b881e5c235e51fc69cc173080be341fa0b`

---

## PHASE 0 — Pre-coding verification

**Single-reactor model confirmed:**
`~/src/evergreen/github.com/socketry/async/lib/async/scheduler.rb:424-427` —
`io_select` spawns one `Thread.new` that immediately sets
`Thread.current.report_on_exception = false` (thread-local suppression only).
`lib/` has zero `Thread.new` calls. Fibers yield only at IO/scheduler points,
never mid-arithmetic. Class-ivar counter mutated between yield points is
fiber-safe without a Mutex. **No Mutex required; mandated approach confirmed.**

**`frozen_string_literal: true` does not freeze class ivars:** confirmed.
`@run_count` and `@saved_roe` assignments are unaffected by the pragma.

**Baseline:** 358 runs, 0 failures, 0 errors, 0 skips.

**No disagreements with the spec.**

---

## Production diff — `lib/repo_tender/shell.rb`

```diff
diff --git c/lib/repo_tender/shell.rb w/lib/repo_tender/shell.rb
index bc4e171..7a45ccf 100644
--- c/lib/repo_tender/shell.rb
+++ w/lib/repo_tender/shell.rb
@@ -16,6 +16,9 @@ module RepoTender
   class Shell
     extend Dry::Monads[:result]
 
+    @run_count = 0
+    @saved_roe = nil
+
     def self.run(*argv, chdir: nil, env: nil)
@@ -56,8 +59,16 @@ module RepoTender
       # the only thing it can raise is the IOError we explicitly
       # want to silence. The original value is restored in `ensure`
       # so we never leak the suppression past this call.
-      prev_report_on_exception = Thread.report_on_exception
-      Thread.report_on_exception = false
+      # Refcount the active Shell.run calls so the global flag is suppressed
+      # for the entire overlapping window, not just per-fiber. On 0→1: capture
+      # original and set false. On 1→0 (in ensure): restore the original.
+      # Safe without a Mutex: the reactor is single-threaded; fibers only yield
+      # at Open3.capture3's thread-join, never between these plain assignments.
+      if @run_count == 0
+        @saved_roe = Thread.report_on_exception
+        Thread.report_on_exception = false
+      end
+      @run_count += 1
       begin
         stdout, stderr, status = if full_env
           Open3.capture3(full_env, *argv, **opts)
@@ -65,7 +76,8 @@ module RepoTender
           Open3.capture3(*argv, **opts)
         end
       ensure
-        Thread.report_on_exception = prev_report_on_exception
+        @run_count -= 1
+        Thread.report_on_exception = @saved_roe if @run_count == 0
       end
```

**Summary:** Added `@run_count = 0` and `@saved_roe = nil` class-level ivars.
Replaced the 2-line unconditional save/set-false/restore with a refcount
pattern: 0→1 captures original + sets false; ensure decrements; 1→0 restores.
No Mutex. Signature, ambient-task guard, env/opts handling, and Result return
are byte-unchanged.

---

## Gate results

### G8.0 — Suite + lint + no new gems

**`bundle exec rake test`:**
```
Finished in 16.223499s, 22.1284 runs/s, 77.7268 assertions/s.
359 runs, 1261 assertions, 0 failures, 0 errors, 0 skips
```

**`bundle exec standardrb`:** exit 0 (no output)

**`git diff 5106b7b.. -- repo-tender.gemspec Gemfile.lock`:** EMPTY

**G8.0: PASS**

---

### G8.1 — Single-call semantics preserved; test file additions-only

**`git diff 5106b7b -- test/repo_tender/shell_test.rb` line count:** +40 / -0

**Shell-only run (`bundle exec ruby -Itest test/repo_tender/shell_test.rb`):**
```
9 runs, 24 assertions, 0 failures, 0 errors, 0 skips
```

Existing tests passing unchanged:
- `test_shell_run_disables_thread_report_on_exception_during_open3_capture3` — PASS
- `test_shell_run_restores_thread_report_on_exception_even_when_open3_raises` — PASS

**G8.1: PASS**

---

### G8.2 — No leak under concurrency

Test: `test_refcount_no_leak_and_suppression_during_concurrent_runs`
Sets `Thread.report_on_exception = true`, launches 3 overlapping `Shell.run`
calls (each `sleep 0.2s` via `Async::Barrier`), asserts
`Thread.report_on_exception == true` after all complete.

Result: **PASS** (included in 359-run suite above, 0 failures)

---

### G8.3 — Suppression active during overlap (G3 carry)

Same test as G8.2 (folded per spec). `Open3.capture3` shim records flag at
each in-flight call; asserts all 3 observations are `false`.

Result: **PASS** (included in 359-run suite above, 0 failures)

---

### G8.4 — Scope

**Touched files:** `lib/repo_tender/shell.rb`, `test/repo_tender/shell_test.rb`,
`docs/lanes/cf-cleanup-08.md`. No entrypoint / `bin/` / `cli` touched.

**`git status`:**
```
On branch lane/cf-cleanup-08
Changes not staged for commit:
	modified:   lib/repo_tender/shell.rb
	modified:   test/repo_tender/shell_test.rb

Untracked files:
	docs/lanes/cf-cleanup-08.md

no changes added to commit
```

**`git log 5106b7b..`:** (no output — no builder commits)

**`docs/gates/` diff:** unmodified

**G8.4: PASS**

---

STATUS: COMPLETE
