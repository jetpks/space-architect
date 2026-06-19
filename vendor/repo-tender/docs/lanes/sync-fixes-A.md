# Lane A — ui-listing-order — sync-fixes

## Diff summary

### `lib/repo_tender/ui/interactive_reporter.rb`

Lines 162–174: `render_sweep_tick` extended to drain `@pending_org_lines` before
draining `@pending_lines`. Previously only `@pending_lines` was drained; any
org lines queued after the last listing tick stayed in `@pending_org_lines` until
the `ensure` block, by which point sweep lines had already been written.

```diff
       def render_sweep_tick
+        org_pending = @pending_org_lines.slice!(0, @pending_org_lines.length)
+        if org_pending.any?
+          @out.write("\r\e[K")
+          org_pending.each { |line| @out.write("#{line}\n") }
+        end
         pending = @pending_lines.slice!(0, @pending_lines.length)
         if pending.any?
           @out.write("\r\e[K")
           pending.each { |line| @out.write("#{line}\n") }
         end
         @out.write("\r\e[K#{build_status_line}")
       end
```

### `test/repo_tender/ui/interactive_reporter_test.rb`

Lines 539–577: New test `test_ga1_ga2_last_org_line_precedes_sweep_lines` added
after the existing GS6 block. No existing tests modified.

---

## Lane A gate command — verbatim output

```
bundle exec ruby -Itest test/repo_tender/ui/interactive_reporter_test.rb

Run options: --seed 15928

# Running:

.........................

Finished in 0.504407s, 49.5632 runs/s, 138.7768 assertions/s.

25 runs, 70 assertions, 0 failures, 0 errors, 0 skips
```

---

## Full suite — verbatim output

```
bundle exec rake test

Run options: --seed 26197

# Running:

[...test output and warnings omitted for brevity...]

Finished in 16.194577s, 23.4646 runs/s, 82.5585 assertions/s.

380 runs, 1337 assertions, 0 failures, 0 errors, 0 skips
```

380 runs > baseline 379. 0 failures, 0 errors, 0 skips.

---

## Lint — verbatim output

```
bundle exec standardrb
(exit 0, no output)
```

---

## Before/after ANSI-stripped output stream (new regression test)

**PRE-FIX** (`render_sweep_tick` reverted to original; test run
`--name test_ga1_ga2_last_org_line_precedes_sweep_lines`):

```
[0] ⠋ listing 0 org(s)…  ✓ 0 done
[1] ⚠ github.com/owner/dirty-repo  dirty          ← sweep line
[2] ⠙ synced 1/1   ✓ 0   ⚠ 1   ✗ 0
[3] ✓ first-org  10 repo(s)
[4] ✓ last-org  20 repo(s)                        ← LAST ORG (wrong position)
[5] synced 1/1   ✓ 0 clean   ⚠ 1 non-clean   ✗ 0 failed
```

Test failure:
```
last org line (idx=4) must precede sweep ⚠ line (idx=1)
1 runs, 3 assertions, 1 failures, 0 errors, 0 skips
```

**POST-FIX** (fix restored):

```
[0] ⠋ listing 0 org(s)…  ✓ 0 done
[1] ✓ first-org  10 repo(s)
[2] ✓ last-org  20 repo(s)                        ← both org lines (correct block)
[3] ⚠ github.com/owner/dirty-repo  dirty          ← sweep line (after org block)
[4] ⠙ synced 1/1   ✓ 0   ⚠ 1   ✗ 0
[5] synced 1/1   ✓ 0 clean   ⚠ 1 non-clean   ✗ 0 failed
```

Test result:
```
1 runs, 3 assertions, 0 failures, 0 errors, 0 skips
```

---

## Pre-fix failure confirmation

Method:
1. Reverted `render_sweep_tick` in `lib/repo_tender/ui/interactive_reporter.rb` to
   the original single-drain form (only `@pending_lines`, no `@pending_org_lines`).
2. Ran `bundle exec ruby -Itest test/repo_tender/ui/interactive_reporter_test.rb
   --name test_ga1_ga2_last_org_line_precedes_sweep_lines`
3. Confirmed 1 failure: `last org line (idx=4) must precede sweep ⚠ line (idx=1)`
4. Restored the fix.
5. Re-ran — 0 failures.

No git commands used. Edit/restore was done via file edit only.

---

STATUS: COMPLETE
