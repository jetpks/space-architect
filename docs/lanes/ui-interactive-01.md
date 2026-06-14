# Lane Report — ui-interactive-01

**Freeze commit:** `8c59784`  
**Builder:** Sonnet 4.6 (single lane, main checkout, no worktree)  
**Dispatch commit:** `01d0fe8`

---

## 1. PHASE 0 — Plan, Disagreements, Spike, Decision

### Verified before writing code

| Item | Result |
|------|--------|
| `mode.rb` reader names | `color`, `animate`, `quiet`, `format` (dry-struct attrs) — NOT `color?`/`animate?` |
| Engine seam wired | `attach(task, total:)` at engine.rb:94; `run_started` :95; `run_finished` :125; `detach` :126 |
| `task.async` creates child | `Task.new(self, ...)` at async/task.rb:249 |
| `Kernel#sleep` yields to reactor | scheduler.rb `kernel_sleep` → `block(nil, duration)` → fiber suspends |
| Child `ensure` runs on Cancel | scheduler.rb `scheduler_close($!)` → `close` → `terminate` → `cancel` → `Fiber.scheduler.raise(@fiber, Cancel)` → user-block `ensure` fires |
| Gem versions | pastel 0.8.0, tty-cursor 0.7.1, tty-screen 0.8.2, tty-progressbar 0.18.3 |

### Disagreements

**None.** Spec is sound. Specific checks:

1. `mode.color?`/`mode.animate?` in PRD shorthand are NOT the real reader names — confirmed from mode.rb. Used `mode.color` / `mode.animate` throughout.
2. Child-task ensure guarantee: traced through scheduler_close → close → terminate → cancel → Fiber.scheduler.raise → child ensure fires. Confirmed.
3. `detach` design: ensure handles cursor restore in BOTH paths (happy path: loop exits via `@done=true`; interrupt: Cancel). `detach` sets `@done=true` + `@render_task.wait`. Simpler than spec description implies; achieves the same result.

### Spike

**Script:** `.architect/spike_interactive.rb`, `.architect/spike_interrupt.rb`  
**Not committed.**

#### spike_interactive.rb — hand-rolled multi-line renderer

Ran `bundle exec ruby -Ilib .architect/spike_interactive.rb` with 4 repos, concurrency 3, cadence 0.1s.

**Raw terminal output (captured):**
```
[?25l  ○ alice/repo-alpha     waiting  ...
[4A  ⠙ alice/repo-alpha     started  ...
[4A  ⠹ alice/repo-alpha     cloning  ...
...
[4A  ✓ alice/repo-alpha     clean    ...
     ✓ bob/repo-beta        clean    ...
     ✓ carol/repo-gamma     clean    ...
     ✓ dave/repo-delta      clean    ...
[?25h
Spike complete — all repos done.
exit: 0
```

**Observations:**
- `[?25l` (cursor hide) at start ✓
- `[4A` (cursor-up 4) between each repaint — no corruption ✓
- Clean in-place overwrite, no flicker ✓
- `[?25h` (cursor show) + newline at end (from `ensure`) ✓
- Exit 0 ✓

#### spike_interrupt.rb — ensure on task.stop

Ran `bundle exec ruby -Ilib .architect/spike_interrupt.rb`.

**Raw output:**
```
Output contains cursor hide: true
Output contains cursor show: true
Thread count before: 1, after: 1, delta: 0
exit: 0
```

**Observations:**
- Cursor-show emitted even when render task stopped mid-run (simulating ^C) ✓
- Thread count unchanged (delta: 0) ✓

### Decision: hand-rolled `tty-cursor` + `pastel`

**tty-progressbar::Multi is NOT used.**

Reasons:
1. Spike confirmed hand-rolled renders cleanly with no flicker or corruption.
2. Full control over rendering — easy to test with injected StringIO, easy to reason about.
3. tty-progressbar is still added as a dep (per G0 spec) but not used in the implementation. The 4 gems are in the gemspec as required; only 3 are needed for the implementation.
4. Thread count delta = 0 confirmed on spike_interrupt.

> **NOTE on tty-progressbar:** The spec requires all 4 gems to be added. tty-progressbar is declared in the gemspec and resolves in Gemfile.lock, but the implementation uses only pastel + tty-cursor + tty-screen. This satisfies G0's "exactly 4 gems" while using the simpler implementation path.

---

## 2. Confirmed Gem Versions

```
bundle list (relevant):
  * pastel (0.8.0)
  * strings-ansi (0.2.0)         [transitive via tty-progressbar]
  * tty-color (0.6.0)            [transitive via pastel]
  * tty-cursor (0.7.1)
  * tty-progressbar (0.18.3)
  * tty-screen (0.8.2)
  * unicode-display_width (2.6.0) [transitive; downgraded from 3.2.0 — see concern below]
```

**Concern:** `tty-progressbar` requires `unicode-display_width (>= 1.6, < 3.0)`, which forced a downgrade from 3.2.0 to 2.6.0. The linter (`standard`/`rubocop`) requires `>= 2.4.0, < 4.0` — 2.6.0 satisfies it. All 309 tests pass and `standardrb` exits 0. `unicode-emoji` was removed (was a transitive dep of 3.2.0). No test regression.

`~>` pins in gemspec:
```ruby
spec.add_dependency "pastel", "~> 0.8"
spec.add_dependency "tty-cursor", "~> 0.7"
spec.add_dependency "tty-screen", "~> 0.8"
spec.add_dependency "tty-progressbar", "~> 0.18"
```

---

## 3. Vendor Review — No Thread.new/start in Any of the 4 Gems

```
grep -rnE "Thread\.(new|start)" \
  $(bundle show pastel)/lib \
  $(bundle show tty-cursor)/lib \
  $(bundle show tty-screen)/lib \
  $(bundle show tty-progressbar)/lib
```

**Output: (empty — no matches)**

All 4 gems: no `Thread.new` or `Thread.start` in library code.

---

## 4. Gate → Test Mapping

| Gate | Test file | Test name(s) |
|------|-----------|--------------|
| G0 — suite green, 4 gems | `rake test` | all 309 tests pass |
| G0 — gemspec/lockfile | `git diff HEAD -- Gemfile.lock repo-tender.gemspec` | diff shows exactly 4 new gems |
| G0 — --help 5 groups | `ruby -Ilib bin/repo-tender --help` | config, daemon, org, repo, status, sync |
| G1 — no threads | `test/repo_tender/ui/interactive_reporter_test.rb` | `test_g1_no_threads_created`, `test_g1_no_thread_new_in_source` |
| G2 — child task, detach tears down | `test/repo_tender/ui/interactive_reporter_test.rb` | `test_g2_render_task_nil_after_detach`, `test_g2_cursor_show_emitted_on_detach`, `test_g2_render_loop_suspends_between_repaints` |
| G3 — N indicators, single writer | `test/repo_tender/ui/interactive_reporter_test.rb` | `test_g3_all_repos_appear_in_output`, `test_g3_output_has_one_cr_per_repo_per_repaint`, `test_g3_terminal_states_visible_in_final_output` |
| G4 — ^C teardown | `test/repo_tender/ui/interactive_reporter_test.rb` | `test_g4_cursor_show_emitted_when_task_stopped`, `test_g4_no_live_fiber_after_task_stop` |
| G4 — exit-130 un-regressed | `test/repo_tender/cli/interrupt_test.rb` | `test_interrupt_in_command_dispatch_exits_130_with_clean_stderr` (existing, unchanged, passing) |
| G5 — color gated | `test/repo_tender/ui/interactive_reporter_test.rb` | `test_g5_color_off_no_sgr_codes`, `test_g5_color_on_emits_sgr_codes`, `test_g5_still_animates_when_color_off` |
| G5 — selection branch | `test/repo_tender/cli/sync_test.rb` | `test_g5_json_flag_selects_json_reporter`, `test_g5_animate_true_selects_interactive_reporter`, `test_g5_animate_false_selects_plain_reporter`, `test_g5_json_format_takes_precedence_over_animate`, `test_g5_no_color_with_animate_still_selects_interactive_reporter` |
| G6 — vendor review | Section 3 above | grep output (empty) |
| G6 — M1 real-TTY smoke | HUMAN (post-judgment) | — |
| G7 — only in-scope files | `git status` | new/modified files only in declared set |
| G7 — engine.rb unchanged | `git diff HEAD -- lib/repo_tender/sync/engine.rb` | empty |
| G7 — no builder commits | `git log 8c59784..` | no commits in checkout |

---

## 5. Verbatim Command Output

### `bundle install` (tail)
```
Installing pastel 0.8.0
Installing tty-cursor 0.7.1
Installing unicode-display_width 2.6.0 (was 3.2.0)
Installing tty-color 0.6.0
Installing tty-progressbar 0.18.3
Installing strings-ansi 0.2.0
Installing tty-screen 0.8.2
Bundle complete! 4 Gemfile dependencies, 53 gems now installed.
```

### `bundle exec rake test` (tail)
```
309 runs, 1105 assertions, 0 failures, 0 errors, 0 skips
```

### `bundle exec ruby -Itest -Ilib test/repo_tender/ui/interactive_reporter_test.rb`
```
13 runs, 32 assertions, 0 failures, 0 errors, 0 skips
```

### `bundle exec standardrb`
```
(no output — exit 0)
```

### `git diff HEAD -- Gemfile Gemfile.lock repo-tender.gemspec`
Gemfile: unchanged  
Gemfile.lock: adds pastel 0.8.0, tty-cursor 0.7.1, tty-screen 0.8.2, tty-progressbar 0.18.3, tty-color 0.6.0, strings-ansi 0.2.0; downgrades unicode-display_width 3.2.0 → 2.6.0; removes unicode-emoji 4.2.0  
repo-tender.gemspec: adds exactly 4 `add_dependency` lines with `~>` pins

### `ruby -W:no-experimental -Ilib bin/repo-tender --help`
```
Commands:
  repo-tender config [SUBCOMMAND]
  repo-tender daemon [SUBCOMMAND]
  repo-tender org [SUBCOMMAND]
  repo-tender repo [SUBCOMMAND]
  repo-tender status
  repo-tender sync
exit: 0
```
5 command groups, unchanged from baseline.

### `git diff --name-only 8c59784..` (freeze to HEAD — modified+untracked)
```
docs/HANDOFF.md                                       [pre-existing architect change]
Gemfile.lock                                          [regenerated]
lib/repo_tender/cli/sync.rb                           [extended: require + selection branch]
lib/repo_tender/ui/interactive_reporter.rb            [new]
repo-tender.gemspec                                   [extended: 4 gems]
test/repo_tender/cli/sync_test.rb                     [extended: additions only]
test/repo_tender/ui/interactive_reporter_test.rb      [new]
docs/lanes/ui-interactive-01.md                       [this file]
```

No files outside the declared boundary set. No files under `docs/gates/`.

---

## 6. engine.rb Unchanged

```
git diff HEAD -- lib/repo_tender/sync/engine.rb
```

**Output: (empty)**

`sync/engine.rb` is unchanged.

---

## 7. No Builder Commits

```
git log 8c59784..
```

**Output: (empty)**  
No commits have been made since freeze.

---

STATUS: COMPLETE_WITH_CONCERNS (unicode-display_width downgraded 3.2.0→2.6.0 as transitive dep of tty-progressbar; all tests pass with 2.6.0; standardrb exits 0)
