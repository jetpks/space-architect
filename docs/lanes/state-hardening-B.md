# Lane B — state-hardening CF11

## 1. PHASE 0: Plan + Disagreements + Pre-checks

### Disagreements with spec
None. Spec is consistent with the live code.

### Files read before planning
- `AGENTS.md`, `docs/gates/state-hardening.md`, `lib/repo_tender/state/store.rb`, `test/repo_tender/state/store_test.rb`

### `State::Store.update` zero-caller confirmation

```
$ grep -rn "Store\.update\|State::Store.*update" lib bin exe test
lib/repo_tender/cli/repo.rb:77:          result = Config::Store.update(paths.config_file) do |c|
lib/repo_tender/cli/repo.rb:121:          result = Config::Store.update(paths.config_file) do |c|
lib/repo_tender/cli/org.rb:95:          result = Config::Store.update(paths.config_file) do |c|
lib/repo_tender/cli/org.rb:140:          result = Config::Store.update(paths.config_file) do |c|
test/repo_tender/cli/repo_test.rb:48:      RepoTender::Config::Store.update(paths.config_file) do |c|
test/repo_tender/cli/org_test.rb:80:      RepoTender::Config::Store.update(paths.config_file) do |c|
test/repo_tender/cli/nested_registration_test.rb:34:      RepoTender::Config::Store.update(paths.config_file) do |c|
```

All matches are `Config::Store.update` (a different class). `State::Store.update` (line 88, now deleted) had zero callers.

### `Interrupt` is NOT a `StandardError`

```
$ ruby -e "puts Interrupt.ancestors.inspect"
[Interrupt, SignalException, Exception, Object, Kernel, BasicObject]
```

`Interrupt < SignalException < Exception`. A bare `rescue` = `rescue StandardError`. `Interrupt` does NOT inherit from `StandardError` — the old bare `rescue` block was never entered when `Interrupt` was raised.

### Plan
1. `lib/repo_tender/state/store.rb`: replace `begin/rescue/raise/end` with `begin/ensure/end`; delete `update` method.
2. `test/repo_tender/state/store_test.rb`: add GB1 test (Interrupt injection, additions-only).
3. Run gate commands; write report.

---

## 2. What Changed

### `lib/repo_tender/state/store.rb` diff (working tree vs freeze `a1cba9d`)

```diff
@@ -78,19 +78,12 @@
         begin
           File.write(tmp, emit(state))
           File.rename(tmp, path)
-        rescue
+        ensure
           File.delete(tmp) if File.exist?(tmp)
-          raise
         end
         Success(state)
       end
 
-      def self.update(path)
-        state = load(path).success
-        new_state = yield(state)
-        write(path, new_state)
-      end
-
       def self.validate(state)
```

### `test/repo_tender/state/store_test.rb` diff (working tree vs freeze `a1cba9d`)

+44 lines / −0 lines. New test `test_write_no_orphan_on_interrupt_at_rename` appended after the last existing test body. Zero existing test bodies edited.

---

## 3. Gate Evidence

### GB1 — Interrupt injection

#### Red baseline analysis (no git write commands used)

Old code (`store.rb:81`, freeze state):
```ruby
rescue
  File.delete(tmp) if File.exist?(tmp)
  raise
end
```

`rescue` (bare) = `rescue StandardError`. When `File.rename` raises `Interrupt`:
- `Interrupt < SignalException < Exception` — NOT a `StandardError`.
- The `rescue` block is **never entered**.
- `File.delete(tmp)` is **never called**.
- The tmp file (`state.yaml.tmp.<pid>`) remains on disk → orphan.

This is an analytical assertion backed by line citation (`store.rb:81` at freeze `a1cba9d`) and Ruby's exception hierarchy (`Interrupt.ancestors` above). A test asserting `stray.empty?` would FAIL on the old code because `File.exist?(tmp)` would return true after `Interrupt` escapes the begin block.

#### Green result (after fix)

```
$ bundle exec ruby -Itest test/repo_tender/state/store_test.rb

Run options: --seed 20812

# Running:

...........

Finished in 0.005047s, 2179.5126 runs/s, 7925.5003 assertions/s.

11 runs, 40 assertions, 0 failures, 0 errors, 0 skips
```

All 11 tests pass including `test_write_no_orphan_on_interrupt_at_rename`. The new `ensure` runs on ALL exit paths — `Interrupt` included — and `File.exist?(tmp)` is false after a successful rename (no-op) or true after a failed rename (deletes orphan). Exception propagation is implicit with `ensure`.

### GB2 — Dead `State::Store.update` removed

Grep after deletion (zero `State::Store` hits):
```
$ grep -rn "Store\.update\|State::Store.*update" lib bin exe test
lib/repo_tender/cli/repo.rb:77:          result = Config::Store.update(paths.config_file) ...
lib/repo_tender/cli/repo.rb:121:          result = Config::Store.update(paths.config_file) ...
lib/repo_tender/cli/org.rb:95:          result = Config::Store.update(paths.config_file) ...
lib/repo_tender/cli/org.rb:140:          result = Config::Store.update(paths.config_file) ...
test/repo_tender/cli/repo_test.rb:48:      RepoTender::Config::Store.update(paths.config_file) ...
test/repo_tender/cli/org_test.rb:80:      RepoTender::Config::Store.update(paths.config_file) ...
test/repo_tender/cli/nested_registration_test.rb:34:      RepoTender::Config::Store.update(paths.config_file) ...
```

All remaining hits are `Config::Store.update`. `State::Store.update` deleted, no callers remain.

Full suite green (365 runs, 0 failures) proves nothing depended on it.

### GB3 — `write` correct + atomic (CF7 unbroken)

`git diff a1cba9d -- test/repo_tender/state/store_test.rb`: `+44/−0` (additions only, zero existing test bodies edited). Existing CF7 tests (`test_write_atomic_midwrite_failure_leaves_original_intact`, `test_write_uses_same_dir_temp_no_stray_files`) pass unmodified — confirmed by the 11-run/40-assertion clean run above.

Note: `git diff a1cba9d..` (two-dot, commit-to-commit) is empty because no commits were made per lane rules. Working-tree diff uses `git diff a1cba9d` (one argument).

---

## 4. Verbatim Gate Commands

### `bundle exec rake test`

```
Finished in 15.482802s, 23.5745 runs/s, 84.3517 assertions/s.

365 runs, 1306 assertions, 0 failures, 0 errors, 0 skips
```

(Freeze baseline: 364 runs. Net: +1 test added.)

### `bundle exec standardrb`

Exit 0, no output.

### `git diff a1cba9d -- Gemfile Gemfile.lock repo-tender.gemspec`

(empty — no gem changes)

### `bundle install`

```
Bundle complete! 4 Gemfile dependencies, 51 gems now installed.
```

51 gems — unchanged from freeze.

---

STATUS: COMPLETE
