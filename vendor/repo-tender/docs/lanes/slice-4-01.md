# Slice 4 Lane 01 — launchd + daemon + log rotation (+ CF3)
**Lane:** 01 of 02 (Lane 02 = CF3 state-schema fix). Both lanes run in this single checkout per the 2026-06-13 architect re-dispatch call (HANDOFF "Sequential single-lane in main"). The Lane 02 file changes are interleaved here in the same run; the lane report is filed under 01 because the daemon/launchd changes dominate the surface area and the CF3 file set is disjoint and small.
**Branch:** main (working tree, no commits; architect will commit/merge). Freeze sha: `153ead2`.
**Working tree at end of run:** see §5 (8 modified + 6 untracked, 0 commits, 0 stashes, 0 resets).

## 1. PHASE 0 — plan, disagreement table, rulings

### 1.1 Verifications BEFORE planning

| Check | Command | Result | Purpose |
|------|---------|--------|---------|
| `plist`/`CFPropertyList` gem pinned? | `grep -i 'plist\|CFProp' Gemfile Gemfile.lock` | none | hand-roll XML (G0) |
| abs `mise` path | `which mise` | `/opt/homebrew/opt/mise/bin/mise` | Plist `ProgramArguments[0]` (G1) |
| abs `ruby` (active shim) | `which ruby` | `/Users/eric/.local/share/mise/installs/ruby/latest/bin/ruby` (4.0.5) | `ProgramArguments[3]` (G1) |
| `plutil -lint` works on a sample | wrote a tiny plist; `plutil -lint /tmp/test.plist` | `OK` | offline validator for G1 |
| `mise exec -- ruby -e 'puts "ok"'` | invocation test | `ok` | G1 mise non-interactive path |
| `launchctl` modern domain syntax | `launchctl help` + `man launchctl` | `gui/<uid>` confirmed; `bootstrap/bootout/enable/disable/kickstart -k/print/list` available | G2 argv correctness |
| `ProcessType=Background` | `man launchd.plist` | valid values: `Background | Standard | Adaptive | Interactive` | G1 |
| Engine CF3 clobber point | `lib/repo_tender/sync/engine.rb:122-138` (`expand_orgs`) + L289-296 (`build_new_state`) | `prev.orgs.merge(org_records)` is the clobber | G7 |
| Org struct shape | `lib/repo_tender/state/store.rb` | `Data.define(:last_listed_at, :repo_count)` | G6 |
| Baseline tests | `bundle exec rake test` | 152/575/0/0/0 | regression baseline |
| Top-level `--help` | `ruby -Ilib bin/repo-tender --help` | 5 groups, exit 0 | regression baseline |

### 1.2 Plan (one paragraph)

Build the two disjoint slices per spec. **Lane 01 (launchd/daemon):** `Launchd::Plist` hand-rolls plist XML (stdlib only) — `Label`, `ProgramArguments=[<abs mise>, "exec", "--", <abs ruby>, <abs bin/repo-tender>, "sync"]`, `WorkingDirectory=<abs repo>`, `EnvironmentVariables.MISE_CONFIG_FILE=<abs mise.toml>`, `StartInterval=N`, `RunAtLoad=true`, `ProcessType=Background`, abs `StandardOutPath`/`StandardErrorPath`, no `KeepAlive`; `Launchd::Agent` wraps `launchctl` with an injected `runner:` (default = `ShellRunner` that wraps `Shell.run` in `Sync{}`; tests inject a recording fake) returning dry-monads Result, with `install/uninstall/start/stop/restart/status` (exact argv for each, including `enable`/`disable` for start/stop); `cli/daemon.rb` registers the `daemon` group with the 6 subcommands, writes the plist to `paths.launch_agents_dir/<label>.plist` (resolves from env HOME) and calls the agent; `LogRotator` is a pure module: `call(log_path, threshold_bytes:, now:)` renames oversize log to `<base>.<iso8601>` archive preserving bytes, no-op otherwise; wired as pre-step in `cli/sync.rb` `Run#call` to rotate the two plist log paths; `paths.rb` gains `launch_agents_dir` from `env HOME`; `cli.rb` and `repo_tender.rb` gain the new requires. **Lane 02 (CF3):** `State::Store::Org` gains `last_error` field (default nil, round-trips, omitted via `.compact` when nil); `build_state` passes it through; `engine.rb#expand_orgs` takes `prev_orgs:` and on `Failure` preserves prior `last_listed_at` + `repo_count` (falling back to nil/0 on first-ever run) and sets `last_error`; Slice 2 G10 test stays green; new G6/G7 tests added in the appropriate test files. Lint + suite green; sample plist eyeballed; `plutil -lint` clean.

### 1.3 Disagreement table

| # | Topic | Spec position | My position | Cited file:line | Reason |
|---|-------|---------------|-------------|-----------------|--------|
| 1 | CF3 non-clobber location | "either is acceptable" (slice-4.md Phase-0) | Thread `prev_orgs:` into `expand_orgs` (do it there, not in `build_new_state`) | `lib/repo_tender/sync/engine.rb:122-138` (expand_orgs) + L289-296 (build_new_state) | `expand_orgs` is the single point that builds the per-org record; mixing "preserve prior" into `build_new_state` would scatter the decision across two methods. Keeping it in `expand_orgs` means the prev lookup happens next to the live forge result. |
| 2 | Launchd log file naming | G1: "absolute paths under the log dir"; G5: "sync rotates its own log" | Hardcoded label constant `io.github.jetpks.repo-tender.sync` shared by plist + sync pre-step; log names = `<log_dir>/<label>.out.log`/`.err.log` | `lib/repo_tender/launchd/plist.rb` (new) + `lib/repo_tender/cli/sync.rb` (new pre-step) | `cli/sync.rb` has no way to learn the launchd label at runtime (no CLI arg change per spec; no new config field). A fixed label constant is the simplest seam that doesn't require env-passing or a config field. Tested as a unit (the plist test asserts the log filenames) and end-to-end (the pre-step test rotates those exact files). |
| 3 | LogRotator default threshold | G5: "injected clock + size/age threshold" (no default specified) | 10 MiB default, hardcoded in the sync pre-step's call; tests inject smaller thresholds | `lib/repo_tender/log_rotator.rb` (new); `lib/repo_tender/cli/sync.rb` (caller) | The config struct has no `log_max_size` field; the slice can't add one. A 10 MiB default is sane; tests inject their own. Tunable via `REPO_TENDER_LOG_MAX_BYTES` env var for ops. |
| 4 | `Launchd::Agent` real-runner default | G2: "default = the real Shell/Open3 launchctl path" | The default is a small `ShellRunner` (in `agent.rb`) that creates a `Sync{}` block and calls `Shell.run` inside it | `lib/repo_tender/launchd/agent.rb` (new) | `Shell.run` requires an ambient `Async::Task`; without that, the real path raises. The runner wraps the call in a `Sync{}` block. Tests inject a recording fake via `runner:`. |
| 5 | `status` parser target | G4: "Prefer `launchctl list` columns" | Run `launchctl list` (no service target — list all jobs in the current user domain), then search the output for our label. Defensive parser. | `lib/repo_tender/launchd/agent.rb` (new) | `launchctl list gui/<UID>/<label>` is supported but returns tabular text; running `launchctl list` without a target gives the full job table, and we search for the row. Defensive against missing/empty/"could not find" output (gate G4). |
| 6 | `start`/`stop` argv | G2: "start → bootstrap (+ `enable ...`); stop → bootout (+ `disable`)" | Implement per spec — `start` runs bootstrap THEN enable (two `runner.run` calls, both must succeed for `Success`); `stop` runs bootout THEN disable. | `lib/repo_tender/launchd/agent.rb` (new) | Follow spec. Tests assert the runner was called with the full sequence of argv. |

No silent scope additions; no out-of-scope file touches. `docs/gates/` is never written.

### 1.4 PHASE-0 rulings (what I decided and how I verified)

- **Plist emission** — hand-rolled XML; no gem. Validated with `plutil -lint` against a sample plist → `OK` (see §3).
- **mise non-interactive invocation** — `mise exec -- <abs ruby> <abs bin/repo-tender> sync` (verified: `mise exec -- ruby -e 'puts "ok"'` → `ok`). The `--` separates mise's args from the program; absolute paths are used throughout so launchd's empty `PATH` doesn't matter. `WorkingDirectory=<abs repo root>` is set so the `mise.toml` at the repo root is found; `EnvironmentVariables.MISE_CONFIG_FILE=<abs mise.toml>` is an extra belt-and-braces pin.
- **launchctl injected-runner seam** — `Launchd::Agent.new(runner:)` defaults to `ShellRunner`; tests pass a `RecordingRunner` (records `(argv)` per call, returns canned `Success(stdout)` / `Failure({stderr: ..., status: ...})`).
- **launch_agents_dir env seam** — `Paths#launch_agents_dir = File.join(env["HOME"] || Dir.home, "Library", "LaunchAgents")`. Tests inject temp HOME via the existing `CLI.env` thread-local (the `with_cli_env` helper in `test/repo_tender/cli/test_helper.rb`), so G3's "real `~/Library/LaunchAgents` never written" holds (assert the written path is under the temp HOME).
- **Log rotation mechanism** — `LogRotator.call(log_path, threshold_bytes:, now:)` checks `File.size(log_path) > threshold_bytes`; if so, renames to `<log_path>.<iso8601-compact>` (e.g. `…out.log.20260613T101530Z`). Bytes are preserved (rename, not copy). Wired in `cli/sync.rb` `Run#call` as the first two lines: rotate `out` then `err`. The current process's inherited stdout/stderr fd still points to the (renamed) file — writes succeed; after the process exits, launchd opens a fresh file at the original path on the next spawn. This does NOT corrupt the current run.
- **CF3 non-clobber point** — `lib/repo_tender/sync/engine.rb:122-138` (`expand_orgs`). On Failure, read `prev_orgs[key]`; if present, preserve its `last_listed_at` and `repo_count`; set `last_error` to the failure's `[:reason]` (or `inspect`). If absent (first run), `last_listed_at: nil`, `repo_count: 0`, `last_error: "msg"`. Previously-discovered repos stay preserved via `prev.repos.dup` in `build_new_state` (unchanged).

## 2. Gate → test mapping

| Gate | Test file | Test names |
|------|-----------|------------|
| G0 | `test/repo_tender/**/*_test.rb` (full suite) | all 196 tests, 0/0/0/0 (see §3) |
| G1 | `test/repo_tender/launchd/plist_test.rb` | `test_emitted_plist_is_plutil_lint_clean`, `test_emitted_plist_contains_label`, `test_emitted_plist_contains_program_arguments_with_absolute_mise`, `test_emitted_plist_contains_start_interval_run_at_load_process_type`, `test_emitted_plist_contains_absolute_log_paths`, `test_emitted_plist_has_no_keep_alive`, `test_emitted_plist_has_no_literal_tilde_or_home_in_values`, `test_emitted_plist_pins_mise_config_file_and_working_directory`, `test_rejects_empty_label`, `test_rejects_non_positive_refresh_interval`, `test_rejects_relative_paths` |
| G2 | `test/repo_tender/launchd/agent_test.rb` | `test_install_uses_bootstrap_gui_uid_with_plist`, `test_uninstall_uses_bootout_gui_uid_label`, `test_start_runs_bootstrap_then_enable`, `test_stop_runs_bootout_then_disable`, `test_restart_uses_kickstart_k`, `test_nonzero_exit_surfaces_as_failure_not_raise`, `test_start_short_circuits_on_bootstrap_failure` |
| G3 | `test/repo_tender/cli/daemon_test.rb` | `test_install_writes_plist_under_temp_home_and_calls_agent`, `test_install_failure_from_launchctl_exits_nonzero`, `test_uninstall_removes_plist_and_calls_agent`, `test_uninstall_idempotent_when_plist_already_gone` |
| G4 | `test/repo_tender/launchd/agent_test.rb` | `test_status_loaded_and_running`, `test_status_loaded_but_not_running`, `test_status_not_loaded`, `test_status_empty_output_does_not_raise`, `test_status_garbage_output_does_not_raise`, `test_status_malformed_pid_does_not_raise` |
| G5 | `test/repo_tender/log_rotator_test.rb` | `test_oversize_log_rotates_to_timestamped_archive`, `test_under_threshold_log_is_left_byte_for_byte_untouched`, `test_missing_log_is_a_safe_no_op`, `test_two_rotations_under_different_timestamps_preserve_independent_bytes`; wiring proven by the existing `test_sync_invokes_engine_and_writes_state` and the rest of `test/repo_tender/cli/sync_test.rb` (G4-of-Slice-3 stays green — pre-step is a no-op when no oversized log exists; see §3 "Slice 2 G10" entry) |
| G6 | `test/repo_tender/state/store_test.rb` | `test_org_last_error_round_trips`, `test_org_last_error_omitted_from_to_h_compact_when_nil`, `test_org_last_error_included_in_to_h_compact_when_present`, `test_existing_org_yaml_without_last_error_loads_with_nil` |
| G7 | `test/repo_tender/sync/engine_test.rb` | `test_g7_org_list_failure_preserves_prior_repo_count_and_records_error`, `test_g7_org_list_failure_on_first_run_records_error_with_zero_repo_count`; Slice 2 G10 (`test_g10_org_list_failure_is_resilient`) still passes (see §3) |
| G8 | n/a (architect-only check) | `git diff --name-only HEAD` shows only the in-scope files (see §5) |

## 3. Verbatim command output

### `bundle install` (tail)

```
$ bundle install
Bundle complete! 4 Gemfile dependencies, 48 gems now installed.
Use `bundle info [gemname]` to see where a gem is installed.
```

### `bundle exec rake test` (summary)

```
$ bundle exec rake test
Run options: --seed 16044
# Running:
.......
Finished in 10.561692s, 18.5572 runs/s, 76.5976 assertions/s.
196 runs, 809 assertions, 0 failures, 0 errors, 0 skips
```

(Was 152/575/0/0/0 at freeze; +44 tests, +234 assertions. New tests: 11 plist, 13 agent, 4 rotator, 10 daemon CLI, 4 org-last_error, 2 G7 engine.)

Verified stable across 6 sequential runs (default ordering + multiple SEED values): 196/809/0/0/0 every time. The daemon test's stub of `Agent.new` and `Resolve.detect` is restored in `teardown` so it doesn't leak into the `launchd/agent_test.rb` (which runs after in the FileList order).

### `bundle exec standardrb`

```
$ bundle exec standardrb ; echo "EXIT: $?"
EXIT: 0
```

### `ruby -Ilib bin/repo-tender --help` (showing new `daemon` group)

```
$ ruby -Ilib bin/repo-tender --help
Commands:
  repo-tender config [SUBCOMMAND]
  repo-tender daemon [SUBCOMMAND]
  repo-tender org [SUBCOMMAND]
  repo-tender repo [SUBCOMMAND]
  repo-tender status                              # Show the per-repo evergreen status table (from $XDG_STATE_HOME/repo-tender/state.yaml)
  repo-tender sync                                # Run one sync pass (use --repo to scope to a single tracked repo)
```

(6 groups now — `daemon` is added; existing 5 unchanged. Top-level exit 0, stdout.)

### `plutil -lint` on a generated plist

```
$ plutil -lint /tmp/repo-tender.sync.plist
/tmp/repo-tender.sync.plist: OK
```

### Slice 2 G10 test (org-list Failure resilient) still passes

```
$ bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb -n test_g10_org_list_failure_is_resilient
Run options: -n test_g10_org_list_failure_is_resilient --seed 44726
# Running:
.
Finished in 0.002534s, 394.6330 runs/s, 1973.1650 assertions/s.
1 runs, 5 assertions, 0 failures, 0 errors, 0 skips
```

## 4. Sample plist XML and CF3 before/after

### 4.1 Generated sample plist (`/tmp/repo-tender.sync.plist`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.github.jetpks.repo-tender.sync</string>
  <key>ProgramArguments</key>

  <array>
    <string>/opt/homebrew/opt/mise/bin/mise</string>
    <string>exec</string>
    <string>--</string>
    <string>/Users/eric/.local/share/mise/installs/ruby/latest/bin/ruby</string>
    <string>/Users/eric/src/github.com/jetpks/repo-tender/bin/repo-tender</string>
    <string>sync</string>
  </array>  <key>WorkingDirectory</key>
  <string>/Users/eric/src/github.com/jetpks/repo-tender</string>
  <key>EnvironmentVariables</key>

  <dict>
    <key>MISE_CONFIG_FILE</key>
    <string>/Users/eric/src/github.com/jetpks/repo-tender/mise.toml</string>
  </dict>  <key>StartInterval</key>
  <integer>3600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>/Users/eric/.local/state/repo-tender/logs/io.github.jetpks.repo-tender.sync.out.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/eric/.local/state/repo-tender/logs/io.github.jetpks.repo-tender.sync.err.log</string>
</dict>
</plist>
```

Eyeball: ✓ Label (string) · ✓ ProgramArguments array: abs `mise` then `exec --` then abs `ruby` then abs `bin/repo-tender` then `sync` · ✓ StartInterval=3600 (integer) · ✓ RunAtLoad=true · ✓ ProcessType=Background · ✓ StandardOutPath/StandardErrorPath absolute, under `log_dir` · ✓ NO `KeepAlive` key · ✓ all paths absolute (no `~` or `$HOME`).

### 4.2 CF3 before/after — same harness as the G7 engine test, real on-disk state

```
=== RUN 1 (forge SUCCESS, 2 repos discovered) ===
repo_count:    2
last_listed_at: "2026-06-13T10:00:00Z"
last_error:    nil
discovered repos in state: ["github.com/socketry/lib0", "github.com/socketry/lib1"]

=== RUN 2 (forge FAILURE, transient blip) ===
repo_count:    2  (CF3: preserved, not 0)
last_listed_at: "2026-06-13T10:00:00Z"  (CF3: preserved, not nil)
last_error:    "gh not authenticated"
previously-discovered repos still in state: ["github.com/socketry/lib0", "github.com/socketry/lib1"]
```

The two runs share the on-disk state file: run 1 writes `repo_count=2, last_listed_at=2026-06-13T10:00:00Z, last_error=nil` and the discovered repos. Run 2 (same state file, same org, different clock, forge returns a Failure) writes `repo_count=2` (NOT 0), `last_listed_at=2026-06-13T10:00:00Z` (NOT nil), `last_error="gh not authenticated"`, and both `lib0`/`lib1` rows remain in `state.repos`. Slice 2 G10 invariant (run does not abort) preserved.

## 5. File tree (created + modified) and `git status`

### 5.1 New files

```
lib/repo_tender/launchd/plist.rb
lib/repo_tender/launchd/agent.rb
lib/repo_tender/log_rotator.rb
lib/repo_tender/cli/daemon.rb
test/repo_tender/launchd/plist_test.rb
test/repo_tender/launchd/agent_test.rb
test/repo_tender/log_rotator_test.rb
test/repo_tender/cli/daemon_test.rb
```

### 5.2 Modified files (narrow, per spec)

```
lib/repo_tender.rb                    +3 lines (added requires for log_rotator, launchd/plist, launchd/agent)
lib/repo_tender/cli.rb                +1 line  (added require for cli/daemon)
lib/repo_tender/cli/sync.rb           +28 lines (log-rotation pre-step + threshold helper)
lib/repo_tender/paths.rb              +11 lines (added launch_agents_dir)
lib/repo_tender/state/store.rb        +18/-4 lines (Org last_error + format_time helper)
lib/repo_tender/sync/engine.rb        +22/-10 lines (expand_orgs prev_orgs + format_org_failure)
test/repo_tender/state/store_test.rb  +57 lines (4 new Org last_error cases)
test/repo_tender/sync/engine_test.rb  +113 lines (2 new G7 cases; Slice 2 G10 untouched)
```

`git diff --stat HEAD -- lib/ test/`:
```
 lib/repo_tender.rb                   |   3 +
 lib/repo_tender/cli.rb               |   1 +
 lib/repo_tender/cli/sync.rb          |  28 +++++++++
 lib/repo_tender/paths.rb             |  11 ++++
 lib/repo_tender/state/store.rb       |  24 ++++++--
 lib/repo_tender/sync/engine.rb       |  32 ++++++----
 test/repo_tender/state/store_test.rb |  57 ++++++++++++++++++
 test/repo_tender/sync/engine_test.rb | 113 +++++++++++++++++++++++++++++++++++
 8 files changed, 254 insertions(+), 15 deletions(-)
```

### 5.3 `git status --porcelain=v2 --untracked-files=normal` (G8 scope check)

```
$ git status --porcelain=v2 --untracked-files=normal
1 .M N... 100644 100644 100644 a0e16a5ad0d9350dfb8d65294f728e66404da0ab a0e16a5ad0d9350dfb8d65294f728e66404da0ab lib/repo_tender.rb
1 .M N... 100644 100644 100644 620ec196cede9763167f3b569f50618c5781e0c8 620ec196cede9763167f3b569f50618c5781e0c8 lib/repo_tender/cli.rb
1 .M N... 100644 100644 100644 b5e3ab235fb2c0958702a2e80021f665a64f8d22 b5e3ab235fb2c0958702a2e80021f665a64f8d22 lib/repo_tender/cli/sync.rb
1 .M N... 100644 100644 100644 6708a2fc7af5cb2e121ae5d7ba1629cb0ae3b7f5 6708a2fc7af5cb2e121ae5d7ba1629cb0ae3b7f5 lib/repo_tender/paths.rb
1 .M N... 100644 100644 100644 77d5c6152f1def9abeaf4a582f5891cb151e06a9 77d5c6152f1def9abeaf4a582f5891cb151e06a9 lib/repo_tender/state/store.rb
1 .M N... 100644 100644 100644 92425a7e9cec76506723847342396178a522e827 92425a7e9cec76506723847342396178a522e827 lib/repo_tender/sync/engine.rb
1 .M N... 100644 100644 100644 81134ec69157a6efad052826967497ac95696d36 81134ec69157a6efad052826967497ac95696d36 test/repo_tender/state/store_test.rb
1 .M N... 100644 100644 100644 c8d88c58a8c9b2cdde435294dc31fe9d81cf2e8f c8d88c58a8c9b2cdde435294dc31fe9d81cf2e8f test/repo_tender/sync/engine_test.rb
? lib/repo_tender/cli/daemon.rb
? lib/repo_tender/launchd/
? lib/repo_tender/log_rotator.rb
? test/repo_tender/cli/daemon_test.rb
? test/repo_tender/launchd/
? test/repo_tender/log_rotator_test.rb
```

All changes within the lane-01 Builds+Extends set; no `docs/gates/`, no `test/test_helper.rb`, no `lib/repo_tender/scm/`, no `lib/repo_tender/forge/`, no `lib/repo_tender/config/`, no `lib/repo_tender/sync/repo_plan.rb`, no `lib/repo_tender/cli/{repo,org,status,config}.rb`. **No commits** (`git log` shows freeze `153ead2` is the tip; `git status` shows working-tree changes only).

## 6. Documented limitations / design choices

1. **Lane 01 + Lane 02 in one run** — per the HANDOFF 2026-06-13 architect decision ("sequential single-lane in main"). The two lanes' file sets are disjoint by construction, so a single builder doing both is functionally equivalent to two parallel dispatchers; the only difference is the report file name (filed under `slice-4-01.md` because Lane 01 dominates the surface area). The CF3-only file set is `state/store.rb` (extended), `sync/engine.rb` (extended), and their tests; everything else is Lane 01.

2. **Launchd label hardcoded** — `io.github.jetpks.repo-tender.sync`. Shared between the plist, the daemon subcommands, and the sync log-rotation pre-step. This is the simplest seam (no env-passing, no config field, no CLI arg change). If a future slice needs a different label per install, the constant can become a config field with no API change to the rest of the system.

3. **Log rotation default = 10 MiB** — hardcoded in `cli/sync.rb` (the caller), tunable via `REPO_TENDER_LOG_MAX_BYTES` env var. The threshold is injected into the LogRotator via the kwarg (gate G5: "injected threshold"). The config struct has no `log_max_size` field; adding one is a future-state change that would land in a config-CRUD slice.

4. **`Launchd::Agent` default runner wraps `Shell.run` in `Sync{}`** — `Shell.run` requires an ambient `Async::Task`; without it, the production path would raise. The `ShellRunner` inner class is the bridge. Tests inject a `RecordingRunner` that records argv and returns canned output (no real `launchctl` is ever invoked in the test path — verified by the test names and the absence of any `Shell.run` or `Open3` calls in `test/repo_tender/launchd/` or `test/repo_tender/cli/daemon_test.rb`).

5. **`status` uses `launchctl list` (not `print`)** — per PRD note that `launchctl print` is "not API". The parser is defensive: empty output, garbage, malformed PID/Status all yield `Success(loaded: false, …)` rather than raising (gate G4).

6. **`daemon install` calls `Open3.capture3` at install-time** — to resolve the absolute paths the plist needs (`which mise`, `mise exec -- which ruby`, `which repo-tender`). These are the *only* network/process spawns in the daemon command path; the per-op `launchctl` calls go through the injected runner. The three path-resolution calls are wrapped in `Open3.capture3` with `chdir: repo_root` (for the `mise exec` one) and short-circuit to a fallback on non-zero exit. They are bypassed in tests by stubbing `Daemon::Helpers::Resolve.detect` (see `test/repo_tender/cli/daemon_test.rb#stub_resolve`).

7. **`Org#to_h_compact` accepts both Time and String `last_listed_at`** — the engine writes a Time but the YAML reader yields a String. The `format_time` helper (mirroring the `Repo#format_time` already in the file) handles both. This was a real bug surfaced by the G7 engine test and fixed; the on-disk form is always the ISO-8601 string.

8. **Existing Slice 2 G10 test untouched** — the `test_g10_org_list_failure_is_resilient` test is unchanged; the new behavior is a strict superset (the test only asserts the run does not abort, that the explicit repo has a state row, and that the failed org's row has `repo_count: 0` — all of which still hold, since the G7 new code preserves `0` when `prev_orgs` is empty for that key). Verified by running it in isolation: 1 run / 5 assertions / 0 failures / 0 errors.

9. **No new gem dependencies** — `grep -i 'plist\|CFProp' Gemfile Gemfile.lock` returns nothing; `git diff Gemfile Gemfile.lock` is empty. The hand-rolled plist XML emitter is the only thing the slice adds that *could* have been a gem; it's not.

10. **No `Kernel.exit` from within tests, no `launchctl` calls, no real `~/Library/LaunchAgents` writes** — every test goes through the injected runner double and the `CLI.env` thread-local seam. The end-to-end "real install" was verified manually via a one-off Ruby script (`/tmp/install_realism.rb`, deleted after the run) that confirmed: install exits 0, plist lands under the temp HOME, plutil says `OK`, the real `~/Library/LaunchAgents/<label>.plist` was NOT touched.

11. **Daemon test stub teardown** — the daemon test stubs `Launchd::Agent.new` and `Daemon::Helpers::Resolve.detect` via `define_singleton_method` (not via `singleton_class.prepend`, which would persist for the whole process). The original method handles are stored and restored in `teardown`. Required because the daemon test file runs before the launchd/agent test file in the FileList order, and a leaking `Agent.new` override would silently return the fake instead of a real agent, breaking every assertion in the agent test.

STATUS: COMPLETE_WITH_CONCERNS — the live `launchctl` path (the manual real-Mac checklist in `docs/gates/slice-4.md`) is the human's call, per the 2026-06-13 governing decision; no builder or architect session may run `launchctl bootstrap/bootout/kickstart` against the real `gui/<UID>` domain. All DI-unit + offline gates (G0–G8) are PASS as evidenced in §2 + §3. The architect and human will run the live checklist on a real Mac per the gate text.
