# Lane Report: ui-interactive-compact-01

Builder: Sonnet 4.6  
Branch: `slice/ui-interactive`  
FREEZE2: `b0103e8`

---

## 1. PHASE 0: Plan, Disagreements, and GC3 Empirical Observation

### Plan

Rewrote `InteractiveReporter` to the compact single-line model. Dropped `@refs`, `@indicators`, `PHASE_LABELS`, `LABEL_WIDTH`, `format_line`, `ref_label`, `colorize_status` (all were per-repo-line machinery). New state: five integers (`@total`, `@finished`, `@clean_count`, `@nonclean_count`, `@failed_count`) plus a `@pending_lines` queue. Render fiber: each `render_tick` drains pending queue, clears status line, emits each persistent line + `\n`, then rewrites `\r\e[K` + single status line. `ensure` block: flush any remaining pending, write summary line + `\n`, write cursor show. No cursor-up anywhere. `repo_started` and `repo_phase` are no-ops. Constructor signature unchanged; no new gems; `tty-screen` require dropped (unused). Test file: replaced old G3 section with GC1/GC2/GC3 sections; kept G1/G2/G4/G5.

### Disagreements

1. **Existing G3 tests incompatible with compact model** — `test_g3_all_repos_appear_in_output` (line 118), `test_g3_output_has_one_cr_per_repo_per_repaint` (line 133), `test_g3_terminal_states_visible_in_final_output` (line 147) in `interactive_reporter_test.rb` tested the per-repo-line model. In the compact model, clean repos emit no persistent line, so `REFS[0]` (clean) cannot appear in a per-line assertion. These three tests were replaced by GC1/GC2/GC3 sections per "rewrite/extend for GC1–GC3" in spec.

2. **Gate GC2 says `wrong-branch` (hyphen); engine emits `wrong_branch` (underscore)** — `docs/gates/ui-interactive-compact.md` line 84 uses the hyphenated display form. `repo_plan.rb` lines 27-30 document status `"wrong_branch"`. Implementation emits `status.to_s` verbatim (no transformation). Tests use the actual engine string `wrong_branch`.

3. **`TTY::Cursor.clear_line` ≠ `\r\e[K`** — `TTY::Cursor.clear_line` emits `\e[2K\e[1G` (erase line + goto col 1). The spec's `\r\e[K` is CR + clear-to-EOL. Used the raw `"\r\e[K"` sequence as spec mandates.

4. **`tty-screen` require removed** — Line 5 of original `interactive_reporter.rb` required `tty-screen` for `TTY::Screen.width` (per-repo line padding). No per-repo lines exist in the compact model, so the require was dropped. Gem remains installed; no test impact.

5. **GC3 empirical contradiction** — Spec says "PHASE 0 — Before any code" but also "once you have the compact renderer working, run a REAL sync." Implemented first, then ran the real-git repro below.

### GC3 Empirical Real-Sync Observation

**Command run:**
```
bundle exec ruby -Ilib .architect/gc3_liveness_repro.rb
```

Script created 20 real bare+clone git repos (each with an upstream commit that clones need to fast-forward to), ran `Sync::Engine` at `concurrency: 4` with a `SpyReporter` subclassing `InteractiveReporter` at `cadence: 0.05s` writing to a `StringIO`. The spy logged `(timestamp, @finished)` at each `render_tick`.

**Raw output:**
```
=== Creating 20 real git repos ===
Done creating repos.
=== GC3 Liveness Results ===
Total time: 769ms, N=20, concurrency=4
Render ticks recorded: 16
Observed @finished values across ticks: [0, 3, 4, 8, 12, 16, 20]
Intermediate values (> 0 and < 20): YES
GC3 LIVENESS: PASS — counter advanced during the run
Engine result: SUCCESS
```

**Liveness verdict:** PASS. `Open3.capture3` inside `Shell.run` yields the fiber scheduler on macOS (IO pipe reads are intercepted by Ruby's fiber scheduler → kqueue). The render fiber received 16 ticks during the 769ms run and observed intermediate `@finished` values `[3, 4, 8, 12, 16]` before the final `20`. Counter advances during the run without any subprocess-layer changes.

**Note on the real `bin/repo-tender sync`:** Running `bin/repo-tender sync` in the non-TTY Bash environment selects `PlainReporter` (`mode.animate = false` when `!out.tty?`). The InteractiveReporter path requires a real TTY. The real-git repro above (20 repos, real git operations, real SCM) is the "faithful real-git repro" the spec permits and provides the empirical liveness evidence.

---

## 2. Gate → Test Mapping

| Gate | Test file | Test name(s) |
|------|-----------|--------------|
| GC1 — clean repos zero persistent lines | `interactive_reporter_test.rb` | `test_gc1_clean_repos_produce_no_persistent_lines`, `test_gc1_nonclean_repos_each_produce_one_persistent_line`, `test_gc1_persistent_count_independent_of_clean_count`, `test_gc1_no_cursor_up_in_output` |
| GC2 — live counter, tallies, persistent set | `interactive_reporter_test.rb` | `test_gc2_status_line_contains_counter_and_tallies`, `test_gc2_nonclean_persistent_lines_have_correct_content`, `test_gc2_clean_repo_has_no_persistent_line`, `test_gc2_final_summary_emitted_at_detach`, `test_gc2_tallies_match_outcomes` |
| GC3 — deterministic intermediate values | `interactive_reporter_test.rb` | `test_gc3_counter_advances_intermediate_values` |
| GC3 — PHASE-0 empirical | `.architect/gc3_liveness_repro.rb` | (script, see above) |
| G0 — suite/lint/gems/help | full `rake test` + `standardrb` + gemspec diff + `--help` | (see section 3) |
| G1 — no Thread | `interactive_reporter_test.rb` | `test_g1_no_threads_created`, `test_g1_no_thread_new_in_source` |
| G2 — fiber child + detach | `interactive_reporter_test.rb` | `test_g2_render_task_nil_after_detach`, `test_g2_cursor_show_emitted_on_detach`, `test_g2_render_loop_suspends_between_repaints` |
| G4 — ^C cursor-restore | `interactive_reporter_test.rb` | `test_g4_cursor_show_emitted_when_task_stopped`, `test_g4_no_live_fiber_after_task_stop` |
| G5 — color gated + selection | `interactive_reporter_test.rb` | `test_g5_color_off_no_sgr_codes`, `test_g5_color_on_emits_sgr_codes`, `test_g5_still_animates_when_color_off` |
| G7 — file scope, no commits | `git diff --name-only HEAD` | (see section 3) |

---

## 3. Verbatim Verification Output

### `bundle exec rake test` (tail)

```
Finished in 15.691705s, 20.1380 runs/s, 71.5027 assertions/s.

316 runs, 1122 assertions, 0 failures, 0 errors, 0 skips
```

### `bundle exec ruby -Itest test/repo_tender/ui/interactive_reporter_test.rb`

```
Run options: --seed 44038

# Running:

....................

Finished in 0.449357s, 44.5080 runs/s, 109.0447 assertions/s.

20 runs, 49 assertions, 0 failures, 0 errors, 0 skips
```

### `bundle exec standardrb`

```
(no output — 0 offenses)
exit: 0
```

### `git diff --name-only b0103e8.. -- .`

```
(working tree changes, not committed)
lib/repo_tender/ui/interactive_reporter.rb
test/repo_tender/ui/interactive_reporter_test.rb
```

### `git diff --stat b0103e8.. -- lib/repo_tender/sync/engine.rb`

```
(empty — engine.rb unchanged)
```

### `git diff b0103e8.. -- repo-tender.gemspec Gemfile.lock`

```
(empty — no new gems)
```

### `git log --oneline b0103e8..`

```
(empty — no builder commits)
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

exit 0, 5 command groups ✓

---

## STATUS: COMPLETE
