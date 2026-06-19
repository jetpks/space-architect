# Lane Report — CLI-UX Slice A (ui-foundation) — Lane 01

**Freeze commit:** `8234421`
**Builder model:** Sonnet 4.6 (Claude Code main session)
**Date:** 2026-06-14

---

## PHASE 0 — Disagreements Raised

### D1: `repo_phase(ref, :fetching)` never emitted
PRD §3.2 lists `:fetching` as a possible phase. `engine.rb:process_one` has no separate fetch step — the `:fast_forward` plan action calls `@scm.fast_forward` directly (which internally fetches in the real SCM). I emit `:fast_forwarding` for that case. `:fetching` is listed as PRD vocabulary for future plan actions, not emitted in Slice A. **Gate G3 passes because gate asserts set/pairing, not specific phase values.**

### D2: `run_finished(summary)` shape unspecified
Neither gate nor PRD specifies the summary hash structure. **Chosen contract (documented here):** `Hash<String, Integer>` — status strings (matching state row values: "clean", "dirty", "error", etc.) mapped to occurrence counts. E.g. `{"clean" => 2, "error" => 1}`.

### D3: G2 "byte-identical state.yaml" requires StubSCM + frozen clock
Real-repo runs have non-deterministic timestamps. Added dedicated test using StubSCM + `clock: -> { fixed_time }` which produces byte-identical state.yaml for implicit vs explicit NullReporter. Existing G1–G10 tests (real repos) were left unmodified and all still pass.

### D4: `--no-color` vs `CLICOLOR_FORCE` precedence
Gate G1 says "assert e.g. `--no-color` beats `CLICOLOR_FORCE`, **or document the chosen order**."
**Chosen order (flag > env-force > env/autodetect):**
- `--no-color` (CLI flag, highest) → `color: false`; beats everything including `CLICOLOR_FORCE`
- `CLICOLOR_FORCE=1` (env-force) → `color: true`; beats `NO_COLOR`, `TERM=dumb`, non-TTY
- `NO_COLOR=1` / `TERM=dumb` / `format != :pretty` / non-TTY → `color: false`
Both cases are tested in `mode_test.rb`.

### D5: `repo_failed` stream — same `out`, FAILED marker
PRD says "errors → stderr per clig.dev". Gate G4 explicitly permits: "errors may go to a separate stream — state which."
**Chosen:** `PlainReporter` writes `repo_failed` to the same `out` stream with a `FAILED` tab-separated marker (`"ref\tFAILED\terror"`). Adding a separate `err:` parameter complicates the interface for Slice A without benefit. `JsonReporter` similarly writes `{"event":"repo_failed",...}` to `out`. Errors in Slice A are thus machine-parseable in both formats.

### D6: `GlobalOptions` as module with `self.included`
dry-cli has no native "shared options mixin". Used `module GlobalOptions; def self.included(base); base.option ...; end; end` with `include GlobalOptions` in `Sync::Run`. Verified against dry-cli source (`lib/dry/cli/option.rb`, `lib/dry/cli/command.rb`): `base.option(name, opts)` appends to the command's `@options` class instance variable at include-time. ✓

### D7: NullReporter require in engine.rb
`engine.rb` needs `require "repo_tender/ui/reporter"` before the `reporter: RepoTender::UI::NullReporter.new` default parameter is evaluated. Added to engine.rb requires section. Also added full set of UI requires to `repo_tender.rb`.

---

## Files Created/Changed

### New files
```
lib/repo_tender/ui/reporter.rb          # NullReporter + interface doc
lib/repo_tender/ui/mode.rb              # Mode dry-struct + .resolve
lib/repo_tender/ui/plain_reporter.rb    # PlainReporter
lib/repo_tender/ui/json_reporter.rb     # JsonReporter
lib/repo_tender/cli/options.rb          # GlobalOptions module
test/repo_tender/ui/mode_test.rb        # G1 (24 assertions)
test/repo_tender/ui/plain_reporter_test.rb  # G4 plain (9 assertions)
test/repo_tender/ui/json_reporter_test.rb   # G4 json (8 assertions)
test/repo_tender/cli/options_test.rb    # G5 (11 assertions)
docs/lanes/ui-foundation-01.md          # this file
```

### Extended (narrowly)
```
lib/repo_tender/sync/engine.rb          # reporter: kwarg + emit events
lib/repo_tender/cli/sync.rb             # GlobalOptions include + Mode + reporter
lib/repo_tender.rb                      # UI requires
test/repo_tender/sync/engine_test.rb    # G2 byte-identical + G3 recording reporter (additions only)
test/repo_tender/cli/sync_test.rb       # G6 ANSI-free subprocess (additions only)
```

---

## Gate → Test Mapping

| Gate | Test file | Test name(s) |
|------|-----------|--------------|
| G0 suite green | all | 291 runs, 0 failures, 0 errors, 0 skips |
| G0 no new gems | `git diff 8234421.. -- Gemfile Gemfile.lock repo-tender.gemspec` | (empty diff) |
| G1 Mode.resolve precedence | `test/repo_tender/ui/mode_test.rb` | `test_json_flag_*`, `test_plain_flag_*`, `test_non_tty_*`, `test_tty_no_flags_*`, `test_json_wins_*`, `test_color_*`, `test_no_color_*`, `test_clicolor_force_*`, `test_animate_*`, `test_quiet_*`, `test_mode_is_immutable` (24 tests) |
| G2 NullReporter default, byte-identical state | `test/repo_tender/sync/engine_test.rb` | `test_reporter_default_nullreporter_produces_byte_identical_state_yaml` + all pre-existing G1–G10 tests unmodified |
| G3 correct event sequence | `test/repo_tender/sync/engine_test.rb` | `test_g3_engine_emits_attach_run_started_repo_pairs_run_finished_detach`, `test_g3_repo_finished_status_matches_state_row`, `test_g3_repo_that_raises_emits_repo_failed_and_run_completes`, `test_g3_four_scenario_run_emits_correct_pairs` |
| G4 PlainReporter ANSI-free | `test/repo_tender/ui/plain_reporter_test.rb` | `test_output_is_ansi_free`, `test_repo_finished_emits_line_with_ref_and_status`, `test_repo_failed_emits_line_with_ref_and_failed_marker`, `test_attach_and_detach_produce_no_output` |
| G4 JsonReporter parseable | `test/repo_tender/ui/json_reporter_test.rb` | `test_each_emitted_line_is_parseable_json`, `test_repo_finished_has_event_ref_status_and_timestamp`, `test_one_json_object_per_event`, `test_attach_and_detach_produce_no_output` |
| G5 non-TTY→plain, --plain, --json, no --daemon | `test/repo_tender/cli/options_test.rb` | `test_non_tty_resolves_plain_format`, `test_plain_flag_forces_plain_on_tty`, `test_json_flag_resolves_json_format`, `test_tty_no_flags_resolves_pretty_format`, `test_daemon_is_not_a_recognized_option`, `test_daemon_flag_is_rejected_by_sync_subprocess` |
| G6 e2e unchanged + plain when piped | `test/repo_tender/cli/sync_test.rb` | `test_g6_sync_subprocess_stdout_is_ansi_free_when_piped`, `test_g6_sync_subprocess_exit_and_state_unchanged_from_pre_slice`, `test_g6_sync_repo_invalid_ref_exits_nonzero_when_piped` |
| G7 only in-scope files, no commits | `git log 8234421.. --oneline`, `git status` | one commit (541e7cd, pre-existing); no builder commits; all new/changed files within lane file set |

---

## Verbatim Command Output

### `bundle install`
```
Bundle complete! 4 Gemfile dependencies, 48 gems now installed.
Use `bundle info [gemname]` to see where a bundled gem is installed.
```

### `bundle exec rake test` (full suite)
```
291 runs, 1068 assertions, 0 failures, 0 errors, 0 skips
```
(Baseline was 229/918; additions: +62 runs, +150 assertions)

### `bundle exec standardrb`
```
(exit 0 — no output)
```

### `git diff 8234421.. -- Gemfile Gemfile.lock repo-tender.gemspec`
```
(empty — no gem changes)
```

### `ruby -W:no-experimental -Ilib bin/repo-tender --help`
```
Commands:
  repo-tender config [SUBCOMMAND]
  repo-tender daemon [SUBCOMMAND]
  repo-tender org [SUBCOMMAND]
  repo-tender repo [SUBCOMMAND]
  repo-tender status                              # Show the per-repo evergreen status table (from $XDG_STATE_HOME/repo-tender/state.yaml)
  repo-tender sync                                # Run one sync pass (use --repo to scope to a single tracked repo)
```
Same 5 command groups as before — no regressions. ✓

### `bundle exec ruby -Itest test/repo_tender/ui/mode_test.rb`
```
24 runs, 24 assertions, 0 failures, 0 errors, 0 skips
```

---

## Sample Reporter Output

### PlainReporter (3-repo run)
```
starting: 3 repo(s)
github.com/foo/bar	clean
github.com/baz/qux	dirty
github.com/err/bad	FAILED	clone failed: exit 128
```
(ANSI-free: no `\e[` bytes; tab-separated; `synced N repo(s)` summary line added by CLI after this)

### JsonReporter (same run, selected events)
```json
{"event":"run_started","total":3,"t":"2026-06-14T00:07:31-06:00"}
{"event":"repo_finished","ref":"github.com/foo/bar","status":"clean","t":"2026-06-14T00:07:31-06:00"}
{"event":"repo_failed","ref":"github.com/err/bad","error":"clone failed: exit 128","t":"2026-06-14T00:07:31-06:00"}
{"event":"run_finished","summary":{"clean":1,"error":1},"t":"2026-06-14T00:07:31-06:00"}
```
(One parseable JSON object per line; `JSON.parse` succeeds on each; carries `event`, `ref`/`total`/`summary`, `t`)

---

STATUS: COMPLETE
