# Lane `cf-cleanup-07` — CF7: atomic `State::Store.write`

Freeze: `5106b7b881e5c235e51fc69cc173080be341fa0b`

---

## Production diff summary

`lib/repo_tender/state/store.rb` — `self.write` method only (+7/-1 net):

```diff
         FileUtils.mkdir_p(File.dirname(path))
-        File.write(path, emit(state))
+        tmp = "#{path}.tmp.#{Process.pid}"
+        begin
+          File.write(tmp, emit(state))
+          File.rename(tmp, path)
+        rescue
+          File.delete(tmp) if File.exist?(tmp)
+          raise
+        end
         Success(state)
```

The live `path` is never opened for truncation. Temp file lives at
`"#{path}.tmp.#{Process.pid}"` — same directory as `path`, guaranteeing
same-filesystem for the atomic POSIX `rename(2)`. Rescue deletes the temp if
present and re-raises, preserving existing exception semantics.
`validate`, `emit`, `mkdir_p`, and `Success(state)` return are unchanged.

---

## `bundle exec rake test`

```
360 runs, 1266 assertions, 0 failures, 0 errors, 0 skips
```

Baseline freeze: 358 runs. +2 new tests.

---

## `bundle exec ruby -Itest test/repo_tender/state/store_test.rb`

```
10 runs, 36 assertions, 0 failures, 0 errors, 0 skips
```

---

## `bundle exec standardrb`

```
(exit 0, no output)
```

---

## `git diff 5106b7b.. -- repo-tender.gemspec Gemfile.lock`

```
(empty — no new gems)
```

---

## `git diff 5106b7b -- test/repo_tender/state/store_test.rb --stat`

```diff
 test/repo_tender/state/store_test.rb | 56 ++++++++++++++++++++++++++++++++++++++++++++++++++++++++
 1 file changed, 56 insertions(+), 0 deletions(-)
```

Pure additions: `+56/-0`.

---

## Gate results

| Gate | Command / Test | Result |
|------|----------------|--------|
| G7.0 suite | `bundle exec rake test` | 360 runs, 0 failures, 0 errors, 0 skips ✓ |
| G7.0 lint | `bundle exec standardrb` | exit 0, no output ✓ |
| G7.0 no new gems | `git diff 5106b7b.. -- repo-tender.gemspec Gemfile.lock` | empty ✓ |
| G7.1 mid-write failure | `test_write_atomic_midwrite_failure_leaves_original_intact` | PASS ✓ |
| G7.2 same-dir temp + no stray | `test_write_uses_same_dir_temp_no_stray_files` | PASS ✓ |
| G7.3 additions-only | `git diff 5106b7b -- store_test.rb` | +56/-0 ✓ |
| G7.3 round-trips pass | all 8 pre-existing store tests | PASS (0 failures) ✓ |
| G7.4 scope | `git status` | only `state/store.rb`, `state/store_test.rb`, `docs/lanes/cf-cleanup-07.md` ✓ |
| G7.4 config/store.rb unchanged | `git diff 5106b7b -- lib/repo_tender/config/store.rb` \| wc -l | 0 ✓ |
| G7.4 no commits | `git log 5106b7b.. --oneline` | empty ✓ |
| G7.4 gates clean | `git diff 5106b7b -- docs/gates/` \| wc -l | 0 ✓ |

---

## `git status`

```
On branch lane/cf-cleanup-07
Changes not staged for commit:
	modified:   lib/repo_tender/state/store.rb
	modified:   test/repo_tender/state/store_test.rb

Untracked files:
	docs/lanes/cf-cleanup-07.md

no changes added to commit
```

## `git log 5106b7b.. --oneline`

```
(empty)
```

---

## G7.1 injection mechanism

`minitest/mock` (`File.stub`) does not exist in minitest 6.0.6. Failure was
injected with `File.define_singleton_method(:rename) { |*| raise Errno::ENOSPC, "injected failure" }`,
restored in an `ensure` via the saved `File.method(:rename)` bound method. The
rescue branch in `self.write` deletes the stray temp file and re-raises. Test
asserts both: original content byte-identical, and no stray temp file in dir.

---

STATUS: COMPLETE
