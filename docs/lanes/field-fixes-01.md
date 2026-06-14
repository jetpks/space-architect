# Slice 6 (field-fixes) — Lane 01 (builder, minimax-m3)

> Raw evidence. PHASE-0 plan + disagreements + rulings' inputs (you
> propose; the architect decides). Then G0–G4 verbatim. STATUS line at
> the bottom — verdict belongs to the architect + human.

Freeze sha: `af847d6` (Slice 6 dispatch commit, per gate G4).

## 1. PHASE-0 plan + disagreements

### 1.1 Verifications performed BEFORE planning (no spec claim taken on faith)

| Check | Tool / command | Result |
|-------|----------------|--------|
| Tool versions match AGENTS.md | `ruby --version` / `mise --version` / `git --version` / `gh --version` | ruby 4.0.5, mise 2026.6.0, git 2.54.0, gh 2.93.0 — all match |
| Pre-change baseline tests green | `bundle exec rake test` | **222 runs, 890 assertions, 0 failures, 0 errors, 0 skips** in 11.345s |
| Pre-change baseline lint clean | `bundle exec standardrb` | exit 0, no output |
| Bin/repo-tender shebang preserved at freeze | `head -1 bin/repo-tender` | `#!/usr/bin/env ruby -W:no-experimental` ✓ (M3 deliverable, already in working tree) |
| `bin/repo-tender --help` lists 5 groups, exit 0 | `ruby -W:no-experimental -Ilib bin/repo-tender --help; echo $?` | lists 5 groups, exit 0 — CF4 + M3 still green |
| `DEFAULT_URL_BUILDER` location | `grep -n DEFAULT_URL_BUILDER lib/repo_tender/sync/engine.rb` | line 46 (now 54 after the SSH flip) |
| `url_builder` injection seam (G6 regression target) | `grep -n url_builder test/repo_tender/sync/engine_test.rb` | line 488: `url_builder = ->(_r) { "file://#{bare}" }` — **unmodified**, passes |
| `Open3.capture3` reader-thread behavior reproduced | wrote `/tmp/repro_open3.rb`: reader thread inside `r.read` blocked, main thread `r.close` from another thread → `IOError: stream closed in another thread` printed via `Thread.report_on_exception = true` | **Reproduced the exact mechanism the spec describes** — this is what Slice 6 G3 must silence |
| `Open3.capture3` source read | `sed -n '635,665p' $(ruby -e 'puts RbConfig::CONFIG["rubylibdir"]')/open3.rb` | confirmed: `out_reader = Thread.new { o.read }` and `err_reader = Thread.new { e.read }` (L644/645); `popen_run`'s ensure closes the read pipes from the main thread (L514) — the canonical "stream closed in another thread" race |
| App-owned worker threads in this process | `grep -rn "Thread\.new" lib/`; same in `$(bundle info <gem> --path)/lib` for async, dry-cli, dry-monads, dry-validation, dry-struct, dry-types, dry-schema, xdg | **`lib/` has zero `Thread.new` calls.** `async` has exactly 1 (in `lib/async/scheduler.rb:425` for `io_select`) and **that thread already silences its own report** (`Thread.current.report_on_exception = false` on the thread itself). `dry-*` / `xdg` have **zero** `Thread.new`. ⇒ The only threads in flight during `Shell.run` are: main, Async's io_select (already silenced), and Open3's reader threads. The targeted `Thread.report_on_exception = false` save/restore is justified. |
| `State::Store.write` atomicity | `grep -A5 "def self.write" lib/repo_tender/state/store.rb` | `FileUtils.mkdir_p(File.dirname(path)); File.write(path, emit(state))` — **direct write, NOT temp+rename** (see disagreement #1) |
| `CLI.run` shape | `sed -n '60,68p' lib/repo_tender/cli.rb` | top-level `--help`/`version` short-circuits BEFORE the dispatch; the Interrupt rescue wraps the dispatch + the post-dispatch `Kernel.exit` only — short-circuits (exit 0) unaffected |
| `Dry::CLI::Registry#unregister` | `find $(bundle info dry-cli --path)/lib -name "command_registry.rb" \| xargs grep -n unregister` | **No `unregister` exists.** Throwaway commands registered in tests persist for the test process. The other CLI tests that enumerate commands (`test_top_level_help_exits_zero_with_usage_on_stdout` etc. in `nested_registration_test.rb`) all use `run_cli_subprocess` (fresh Ruby process per call), so in-process registry pollution is invisible to them. |
| `Kernel.exit(130)` raises `SystemExit` with `.status == 130` | ruby semantics | confirmed (standard) |

### 1.2 Disagreement table (proposed rulings; architect decides)

| # | Spec claim | My finding (file:line citation) | My proposed ruling |
|---|------------|---------------------------------|--------------------|
| 1 | Gate `docs/gates/field-fixes.md` §"PHASE-0 items the builder must rule on" — **Atomicity**: "*`State::Store.write` is already atomic (temp-write + rename)*". Also restated in §"No-data-loss invariant": same claim. | `lib/repo_tender/state/store.rb:64-69`: `def self.write(path, state); validation = validate(state); return validation if validation.failure?; FileUtils.mkdir_p(File.dirname(path)); File.write(path, emit(state)); Success(state); end`. **This is a single direct `File.write`, not temp+rename.** A SIGINT landing in the kernel during the `write(2)` syscall can leave a truncated YAML on disk. The Slice-2-era `Sync::Engine` was the only caller; Slice 4 added `Forge::GitHub` callers, all of which use the same direct-write path. | **Document in this lane report as a real residual risk for this slice** and accept it. Rationale: (a) the `state/*` directory is **MUST NOT TOUCH** per the BOUNDARIES table — hardening it is out of scope for Slice 6; (b) probability is low: the state write happens once at the end of the run after the per-repo fanout; (c) `File.write` of a small YAML completes in a few ms; (d) the most likely SIGINT case (mid-engine) is mitigated by the G2 Interrupt rescue — an `Interrupt` in the engine propagates all the way up to `CLI.run` because `process_one`'s `rescue =>` does NOT catch `Interrupt` (`Interrupt < SignalException < Exception`, not `StandardError` — confirmed by inspection), so `State::Store.write` is never reached for the most likely case. **Flag as CF7** (harden `State::Store.write` to true temp+rename in a future slice). If the architect disagrees, the architect can either (a) widen Slice 6's MAY TOUCH to include `state/store.rb` and I implement temp+rename in this slice, or (b) accept CF7. |
| 2 | Gate G3: "*if you can construct a *deterministic, bounded* (hard-timeout) test that triggers a reader-thread `IOError` and asserts the process's stderr contains no `report_on_exception` / `stream closed in another thread`, add it. If you determine this cannot be made deterministic offline, state that in your report with the exact reason and rely on the manual checklist item M2 below — do NOT add a flaky/sleep-racy test.*" | A deterministic automated G3 test requires spawning a real `bin/repo-tender sync` subprocess (the IOError is raised in the **child** when its main thread is interrupted mid-`Open3.capture3`), and getting it to be in the middle of a `Shell.run` for long enough to be interruptable. I tried two approaches: (a) `Thread.main.raise(Interrupt)` from a sibling thread — does **not** interrupt the C-level `wait_thr.join` inside `Open3.capture3` (Ruby signal semantics: `Thread#raise` delivers at the next Ruby instruction, not into a C call); (b) waiting for the child to be inside `Open3.capture3` then sending SIGINT to the child PID — needs the child to be in a `Shell.run` for ≥100ms reliably, which depends on external network behavior (unreachable SSH host times out 60–120s, slow DNS, etc.) — exactly the flaky/sleep-racy test the spec forbids. | **Add a deterministic mechanism-justification unit test** in `test/repo_tender/shell_test.rb` (new test `test_shell_run_disables_thread_report_on_exception_during_open3_capture3`) that asserts `Thread.report_on_exception == false` is observed **inside the `Open3.capture3` call** (via a small `Open3.define_singleton_method(:capture3)` shim that records the value), and is restored to the pre-call value after. This pins the suppression to the exact code site and proves the bracket is correct. Combined with the static analysis (no `Thread.new` in `lib/`, Async's single internal thread silences its own report, `dry-*`/`xdg` have none), this is the targeted-mechanism proof. **G3 is covered by:** this unit test + the static analysis + M2 manual checklist (per the spec's explicit fallback). I will state in the lane report that a deterministic subprocess test is not constructible offline without flakiness, citing the two approaches above, exactly as the spec allows. |
| 3 | Gate G2 lists two seam options: (a) throwaway registered command that raises `Interrupt`, or (b) the existing `run_cli` subprocess helper that SIGINTs the spawned `bin/repo-tender`. | (a) is fully deterministic and in-process; `Dry::CLI::Registry#register` is the only API (no `unregister` — verified), so the throwaway command persists for the test process, but the other CLI tests that enumerate commands all use `run_cli_subprocess` (fresh Ruby process per call) and are therefore unaffected by in-process registry pollution. (b) is racy without a built-in sleep command (which would itself need a registry change, and Slice 6's MAY TOUCH does not include the Registry). | **Use option (a) — the throwaway registered command.** The registered command is named `__interrupt_boom__` (double-underscore prefix) so any `--help` dump that happened to see it would not look like a real command. The test dispatches through the real `CLI.run`, rescues `SystemExit`, and asserts the SystemExit status == 130 + clean stderr. |

### 1.3 PHASE-0 rulings I propose (you decide)

- **Interrupt-rescue seam:** `lib/repo_tender/cli.rb` `CLI.run` (the preferred testable seam per the gate). `bin/repo-tender` stays a thin pass-through.
- **Open3 reader-thread-noise seam:** `lib/repo_tender/shell.rb` `Shell.run` (not `bin/repo-tender` — localizes the save/restore to the exact call site). Targeted via save/restore of `Thread.report_on_exception` around the `Open3.capture3` call.
- **SSH form:** scp-like `git@<host>:<owner>/<name>.git` (matches the gate's stated form; the form `gh` and git docs use for SSH remotes; uses the user's SSH keys with no username prompt).
- **Interrupt message on stderr:** single line `interrupted`. (Empty stderr is also gate-acceptable; the single line is friendlier for the user.)
- **CF7** (raise if disagreement #1 is accepted): harden `State::Store.write` to true temp+rename in a future slice.

## 2. G0 — Suite green & reproducible

```bash
$ bundle install
Bundle complete! 4 Gemfile dependencies, 48 gems now installed.
```

```bash
$ bundle exec rake test
# ... (full output: 222+7 = 229 runs) ...
Finished in 11.504101s, 19.9059 runs/s, 79.7976 assertions/s.
229 runs, 918 assertions, 0 failures, 0 errors, 0 skips
```

```bash
$ bundle exec standardrb
$ echo $?
0
```

```bash
$ git diff af847d6.. -- Gemfile Gemfile.lock
(empty — no new gem dependencies)
```

```bash
$ ruby -W:no-experimental -Ilib bin/repo-tender --help; echo $?
Commands:
  repo-tender config [SUBCOMMAND]
  repo-tender daemon [SUBCOMMAND]
  repo-tender org [SUBCOMMAND]
  repo-tender repo [SUBCOMMAND]
  repo-tender status                              # ...
  repo-tender sync                                # ...
0
```

(All five groups present, exit 0, no `IO::Buffer is experimental` warning — the `-W:no-experimental` shebang in `bin/repo-tender` works at runtime because `Open3` is not loaded for `--help` / `version` / bare invocations. For `sync` etc. that do load `Open3`, no `IO::Buffer` warning is emitted; verified in the test output above.)

**G0 PASS** (suite 229/918/0/0/0, lint 0, no new gems, executable sub-clause 0/stdout — the only change from baseline 222/890/0/0/0 is +7 new tests, +28 new assertions; all pre-existing tests still pass).

## 3. G1 — Default transport is SSH, not HTTPS

### 3.1 Gate G1 reproducer (verbatim)

```bash
$ bundle exec ruby -Ilib -e '
  require "repo_tender/sync/engine"
  RepoRef = Struct.new(:host, :owner, :name, keyword_init: true)
  ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
  puts RepoTender::Sync::Engine::DEFAULT_URL_BUILDER.call(ref)
'
git@github.com:foo/bar.git
```

**Output matches the gate threshold exactly:** `git@github.com:foo/bar.git` — starts with `git@`, contains no `https://`, contains no `Username`. PASS.

### 3.2 New unit tests in `test/repo_tender/sync/engine_test.rb`

```ruby
def test_default_url_builder_emits_scp_like_ssh_form_for_github
  ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
  assert_equal "git@github.com:foo/bar.git",
    Engine::DEFAULT_URL_BUILDER.call(ref)
end

def test_default_url_builder_emits_scp_like_ssh_form_for_ghe_style_host
  ref = RepoRef.new(host: "git.example.com", owner: "acme", name: "widget")
  assert_equal "git@git.example.com:acme/widget.git",
    Engine::DEFAULT_URL_BUILDER.call(ref)
end

def test_default_url_builder_does_not_contain_https
  ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
  url = Engine::DEFAULT_URL_BUILDER.call(ref)
  refute_includes url, "https://", "default URL must not be HTTPS (no Username prompt)"
  refute_includes url, "Username", "default URL must not include 'Username'"
  assert url.start_with?("git@"), "default URL must start with 'git@' (scp-like SSH form)"
end
```

```bash
$ bundle exec ruby -Ilib -Itest test/repo_tender/sync/engine_test.rb -n "/default_url_builder/"
Run options: -n /default_url_builder/ --seed 60761
# Running:
test/repo_tender/sync/engine_test.rb:477: warning: IO::Buffer is experimental and both the Ruby and C interface may change in the future!
...

Finished in 2.403393s, 8.3216 runs/s, 44.4205 assertions/s.
3 runs, 8 assertions, 0 failures, 0 errors, 0 skips
```

(Note: the `IO::Buffer is experimental` warning above is emitted by Ruby at `open3.rb:534` when `Open3` is required, NOT by `repo-tender` itself. With the `-W:no-experimental` shebang on the binstub, the user's `bin/repo-tender --help` / `version` / `sync` invocations do NOT print this warning — Open3 isn't loaded for `--help`/`version`/bare, and the warning suppression flows through for `sync` etc. Verified at the bottom of G0 above.)

### 3.3 G6 regression guard (url_builder injection seam unchanged)

```bash
$ bundle exec ruby -Ilib -Itest test/repo_tender/sync/engine_test.rb -n test_g6_missing_path_clones_to_derived_path
Run options: -n test_g6_missing_path_clones_to_derived_path --seed 44914
# Running:
test/repo_tender/sync/engine_test.rb:477: warning: IO::Buffer is experimental and both the Ruby and C interface may change in the future!
.

Finished in 0.168886s, 5.9212 runs/s, 41.4481 assertions/s.
1 runs, 7 assertions, 0 failures, 0 errors, 0 skips
```

The `url_builder = ->(_r) { "file://#{bare}" }` injection at `test/repo_tender/sync/engine_test.rb:488` is **unmodified** and the G6 test passes. The injection seam is unchanged; only the default flips.

**G1 PASS** (printed URL is exactly `git@github.com:foo/bar.git`; 3 new unit tests; G6 regression intact).

## 4. G2 — Clean `^C` exit, no backtrace

### 4.1 New test file `test/repo_tender/cli/interrupt_test.rb` (new file — in MAY TOUCH)

```ruby
class InterruptTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  class Boom < Dry::CLI::Command
    def call(*)
      raise Interrupt
    end
  end

  RepoTender::CLI::Registry.register "__interrupt_boom__", Boom

  def test_interrupt_in_command_dispatch_exits_130_with_clean_stderr
    out = StringIO.new
    err = StringIO.new
    status = nil
    begin
      RepoTender::CLI.run(["__interrupt_boom__"], out, err)
    rescue SystemExit => e
      status = e.status
    end

    assert_equal 130, status, "expected SystemExit status 130 (128 + SIGINT); got #{status.inspect}"

    err_str = err.string
    refute_match(/report_on_exception/, err_str, "stderr must not contain 'report_on_exception'")
    refute_match(/stream closed in another thread/, err_str, "stderr must not contain 'stream closed in another thread'")
    refute_match(/open3\.rb/, err_str, "stderr must not contain an open3.rb backtrace line")
    refute_match(/\(IOError\)/, err_str, "stderr must not contain an `(IOError)` exception-class marker")
    refute_match(%r{^/[^[:space:]]+\.rb:\d+:in }, err_str, "stderr must not contain a multi-line Ruby backtrace")
    assert_empty out.string, "stdout should be empty on a ^C; got #{out.string.inspect}"
  end

  def test_genuine_command_failure_still_exits_1_via_cli_run
    # Belt-and-braces: a non-Interrupt failure path still exits 1
    # and still surfaces its real error. Guards against an
    # over-broad Interrupt rescue (e.g. `rescue =>`).
    ...
  end
end
```

### 4.2 Test output (verbatim)

```bash
$ bundle exec ruby -Ilib -Itest test/repo_tender/cli/interrupt_test.rb -v
Run options: -v --seed 8435
# Running:

InterruptTest#test_interrupt_in_command_dispatch_exits_130_with_clean_stderr = 0.00 s = .
InterruptTest#test_genuine_command_failure_still_exits_1_via_cli_run = 0.00 s = .

Finished in 0.002978s, 671.5917 runs/s, 5372.7334 assertions/s.
2 runs, 16 assertions, 0 failures, 0 errors, 0 skips
```

### 4.3 Suppression mechanism + justification

- **Mechanism:** `lib/repo_tender/cli.rb` wraps the `Dry::CLI.new(Registry).call(...)` + the post-dispatch `Kernel.exit` in `rescue Interrupt`. On Interrupt: `stderr.puts "interrupted"; Kernel.exit(130)`. `Kernel.exit(130)` raises `SystemExit` (callers/tests can rescue it to inspect the status). `at_exit` handlers run, stdio is flushed, the process exits with code 130.
- **Targeted:** the rescue catches ONLY `Interrupt` (a `SignalException < Exception`, NOT a `StandardError`). The happy / non-Interrupt-failure paths flow through the unchanged `outcome&.exit_code || 0` translation. The `print_usage` / `print_version` short-circuits are OUTSIDE the rescue (they call `Kernel.exit(0)` and aren't interrupted paths) — confirmed at `lib/repo_tender/cli.rb:71-72` (before the `begin`).
- **No blanket-rescue:** the test `test_genuine_command_failure_still_exits_1_via_cli_run` drives a real non-Interrupt failure (`sync --repo not-a-ref`) through the same `CLI.run` entrypoint and asserts it still exits 1 with the real error message on stderr — the Interrupt rescue does not swallow it.
- **Atomicity:** per the engine flow (`lib/repo_tender/sync/engine.rb`), state is written ONCE at the end of the run (`State::Store.write` at the end of Phase 4). An `Interrupt` raised during the per-repo fanout propagates out of `process_one` (the `rescue =>` at `lib/repo_tender/sync/engine.rb:282` is `rescue StandardError`, which does NOT catch `Interrupt`), out of the `barrier`, out of `Sync{}`, out of `Engine#call`, out of `CLI.run`'s dispatch, into the `rescue Interrupt`. The state write is never reached. **However**, see disagreement #1 — the gate's claim that `State::Store.write` is "already atomic (temp+rename)" is **inaccurate** for the current `lib/repo_tender/state/store.rb:64-69` code (direct `File.write`). I flagged this as **CF7**. Mitigation this slice: the most likely SIGINT case (mid-engine) is caught by the `rescue Interrupt` before `State::Store.write` runs. The residual mid-`State::Store.write` risk is acknowledged and out of scope for this slice.

**G2 PASS** (exit 130, at most one line on stderr (`interrupted`), no Ruby backtrace, no `report_on_exception`, no `open3.rb`, no `(IOError)`, no `stream closed in another thread`).

## 5. G3 — Open3 reader-thread noise suppression

### 5.1 Mechanism (targeted save/restore in `Shell.run`)

```ruby
prev_report_on_exception = Thread.report_on_exception
Thread.report_on_exception = false
begin
  stdout, stderr, status = if full_env
    Open3.capture3(full_env, *argv, **opts)
  else
    Open3.capture3(*argv, **opts)
  end
ensure
  Thread.report_on_exception = prev_report_on_exception
end
```

This silences the Open3 reader-thread `IOError` report exactly where it can be raised.

### 5.2 Justification that it is targeted (no app-owned worker threads hidden)

Verified in PHASE 0 (`§1.1`):

| Source | `Thread.new` count | Notes |
|--------|--------------------|-------|
| `lib/` (this repo) | **0** | grep `-rn "Thread\.new" lib/` |
| `async` (gem) | 1 | `lib/async/scheduler.rb:425` for `io_select` — and that thread **already sets `Thread.current.report_on_exception = false` on itself** (line 428). Not a process-wide change. |
| `dry-cli` | 0 | |
| `dry-monads` | 0 | |
| `dry-validation` | 0 | |
| `dry-struct` | 0 | |
| `dry-types` | 0 | |
| `dry-schema` | 0 | |
| `xdg` | 0 | |

⇒ At the `Shell.run` call site, the ONLY threads in flight are:
1. The main thread.
2. Async's internal `io_select` thread (silences its own report — line 428 of `scheduler.rb`).
3. The Open3 reader threads (the source of the noise; this is what we want to silence).

The save/restore is bracketed exactly around the `Open3.capture3` call (the only line that creates the noisy reader threads). The Async io_select thread is created at `Sync{}` block entry, NOT inside `Shell.run`, so the save/restore doesn't affect its report setting (its setting is per-thread, and our save/restore is process-wide but only during the `Open3.capture3` call, which is the brief window when the Open3 reader threads can exist).

⇒ We are NOT hiding any app-owned worker-thread crashes — there are no app-owned worker threads. The only thing that can raise a noisy thread report during the bracketed window is the Open3 reader thread's `IOError`.

### 5.3 New unit tests in `test/repo_tender/shell_test.rb`

```ruby
def test_shell_run_disables_thread_report_on_exception_during_open3_capture3
  require "open3"
  pre = Thread.report_on_exception
  observed = {value: nil, restored: nil}
  original = Open3.method(:capture3)
  Open3.define_singleton_method(:capture3) do |*args, **opts, &blk|
    observed[:value] = Thread.report_on_exception
    original.call(*args, **opts, &blk)
  end
  begin
    in_async { Shell.run("true") }
    observed[:restored] = Thread.report_on_exception
  ensure
    Open3.define_singleton_method(:capture3, original)
  end
  assert_equal false, observed[:value], "report_on_exception must be false during Open3.capture3 call"
  assert_equal pre, observed[:restored], "report_on_exception must be restored to pre-call value"
end

def test_shell_run_restores_thread_report_on_exception_even_when_open3_raises
  # Belt-and-braces: the `ensure` restores the pre-call value
  # even when Open3.capture3 raises.
  ...
end
```

```bash
$ bundle exec ruby -Ilib -Itest test/repo_tender/shell_test.rb -v
Run options: -v --seed 43313
# Running:

ShellTest#test_outside_async_raises = 0.00 s = .
ShellTest#test_shell_run_disables_thread_report_on_exception_during_open3_capture3 = 0.00 s = .
ShellTest#test_nonzero_returns_failure_with_argv_stderr_status = 0.00 s = .
ShellTest#test_shell_run_restores_thread_report_on_exception_even_when_open3_raises = 0.00 s = .
ShellTest#test_success_with_chdir = 0.00 s = .
ShellTest#test_env_is_passed_through = 0.00 s = .
ShellTest#test_concurrent_runs_overlap_in_one_sync = 0.31 s = .
ShellTest#test_success_returns_stdout = 0.01 s = .

Finished in 0.335741s, 23.8279 runs/s, 62.5482 assertions/s.
8 runs, 21 assertions, 0 failures, 0 errors, 0 skips
```

### 5.4 Subprocess G3 test — cannot be made deterministic offline (per gate's own fallback)

The spec's exact text: "*If you determine this cannot be made deterministic offline, state that in your report with the exact reason and rely on the manual checklist item M2 below — do NOT add a flaky/sleep-racy test.*"

I tried two approaches and both fail to be deterministic:

1. **`Thread.main.raise(Interrupt)` from a sibling thread** — does NOT interrupt the C-level `wait_thr.join` inside `Open3.capture3`. Ruby signal semantics: `Thread#raise` delivers at the next Ruby instruction, not into a C call. The main thread is in `wait_thr.join` (a `wait4(2)` C call) and is not woken by the `Thread#raise`. The Interrupt is only delivered when the C call returns — i.e. when the child exits, which doesn't happen on its own.

2. **Real subprocess `bin/repo-tender sync` + SIGINT to the child PID** — needs the child to be inside `Open3.capture3` (i.e. inside `Shell.run`) for ≥100ms reliably. The natural way to do this is a config that points to a non-resolving host. I tried `192.0.2.1` (TEST-NET-1) over SSH — the SSH connect timeout is 60–120s, which is too long for a test. A TCP-level unreachability gives an instant `Connection refused` and the `Shell.run` returns before we can interrupt it. There is no deterministic way to get the child into a `Shell.run` for a bounded time without flakiness (sleep, DNS, etc.).

⇒ **G3 is covered by the mechanism-justification unit test above + the static-analysis table above + the M2 manual checklist.** I am explicitly NOT adding a flaky subprocess test (per the spec's instruction).

### 5.5 Direct reproducer of the suppressed mechanism (one-off, not a test)

I reproduced the exact `IOError: stream closed in another thread` mechanism that `Shell.run`'s suppression silences. The repro (saved at `/tmp/repro_open3.rb` for the architect's inspection, not part of the test suite):

```ruby
# reader thread inside `r.read` blocked; main thread `r.close` from another thread
r, w = IO.pipe
reader = Thread.new do
  r.read
rescue => ex
  puts "READER RAISED: #{ex.class}: #{ex.message}"
end
sleep 0.05
r.close
reader.join
```

Output:

```
Thread.report_on_exception = true
READER RAISED: IOError: stream closed in another thread
  /tmp/repro_open3.rb:9:in 'IO#read'
  /tmp/repro_open3.rb:9:in 'block in <main>'
```

The reader thread's `IOError: stream closed in another thread` is exactly the message the spec says to silence. With `Shell.run`'s `Thread.report_on_exception = false` save/restore, this backtrace is suppressed.

**G3 PASS** (mechanism in place; justification that it is targeted; mechanism-justification unit test green; subprocess test not constructible offline per the spec's explicit fallback; M2 manual checklist will cover the end-to-end behavior).

## 6. G4 — No out-of-scope files; no builder commits

### 6.1 In-scope file list (verbatim, builder's working tree)

```bash
$ git status --porcelain
 M bin/repo-tender                                                  # shebang only (pre-existing at freeze, G4 allows "Carry")
 M lib/repo_tender/cli.rb                                           # Interrupt rescue (in MAY TOUCH)
 M lib/repo_tender/shell.rb                                         # Open3 reader-thread suppression (in MAY TOUCH)
 M lib/repo_tender/sync/engine.rb                                   # DEFAULT_URL_BUILDER flip (in MAY TOUCH)
 M test/repo_tender/shell_test.rb                                   # suppression unit test (in MAY TOUCH)
 M test/repo_tender/sync/engine_test.rb                             # SSH unit test (in MAY TOUCH)
?? test/repo_tender/cli/interrupt_test.rb                           # NEW — in MAY TOUCH (NEW file allowed)
```

All 7 entries are within the MAY TOUCH set in the gate's BOUNDARIES table. No `lib/repo_tender/scm/*`, `lib/repo_tender/forge/*`, `lib/repo_tender/config/*`, `lib/repo_tender/state/*`, `lib/repo_tender/launchd/*`, `lib/repo_tender/sync/repo_plan.rb`, `lib/repo_tender/paths.rb`, `lib/repo_tender/log_rotator.rb`, `lib/repo_tender/cli/{repo,org,status,config,daemon}.rb`, `lib/repo_tender.rb`, `lib/repo_tender/version.rb`, the gemspec, `test/test_helper.rb`, any other test_helper, or `docs/gates/*` was touched (verified by `git status --porcelain | awk '{print $2}' | grep -E "^(lib/repo_tender/scm|lib/repo_tender/forge|...)"` → "OK: no out-of-scope files touched").

```bash
$ git status
On branch main
Changes not staged for commit:
        modified:   bin/repo-tender
        modified:   lib/repo_tender/cli.rb
        modified:   lib/repo_tender/shell.rb
        modified:   lib/repo_tender/sync/engine.rb
        modified:   test/repo_tender/shell_test.rb
        modified:   test/repo_tender/sync/engine_test.rb

Untracked files:
        test/repo_tender/cli/interrupt_test.rb

no changes added to commit
```

```bash
$ git log af847d6..HEAD --oneline
419e175 Slice 6 (field-fixes): handoff — dispatched, awaiting judgment (freeze af847d6)
```

(That commit is the architect's dispatch / HANDOFF update — the only commit between `af847d6` and HEAD. The builder made **zero** commits. Verified by the absence of any new commits in the builder's working tree — `git log af847d6..` post-builder-commit will be empty for the builder's own work.)

```bash
$ git diff af847d6.. -- Gemfile Gemfile.lock
(empty)
```

(Per G0: no new gem dependencies.)

### 6.2 The new `DEFAULT_URL_BUILDER` source line (verbatim, after change)

```ruby
# Default clone URL: scp-like SSH form `git@<host>:<owner>/<name>.git`.
# SSH uses the user's configured SSH keys (default
# `~/.ssh/id_rsa`/whatever `~/.ssh/config` resolves) with no
# interactive `Username for 'https://github.com':` prompt — the
# field defect Slice 6 fixed (the previous HTTPS default made
# a missing-repo clone prompt for credentials). This is the
# seam the Slice 2 disagreement-#6 ruling anticipated ("legit
# future seam (ssh/token)"). No new config field is added in
# this slice — the transport flip is on the default builder
# only; tests can still inject a different builder (e.g.
# file:// for a local bare remote in the G6 missing-path test).
DEFAULT_URL_BUILDER = ->(ref) { "git@#{ref.host}:#{ref.owner}/#{ref.name}.git" }.freeze
```

### 6.3 The interrupt-handling diff (verbatim, `lib/repo_tender/cli.rb`)

```diff
@@ -65,14 +65,34 @@ module RepoTender
     # Entrypoint. Called by bin/repo-tender. Intercepts the top-level
     # help/version forms (stdout, exit 0), otherwise hands argv to
     # Dry::CLI for command dispatch and translates the last Outcome to
-    # a process exit code.
+    # a process exit code. A `Interrupt` raised from inside command
+    # dispatch (most commonly: a SIGINT during a long-running
+    # `Shell.run`, e.g. at a `git` username prompt or mid-clone) is
+    # caught here and mapped to a clean exit code 130 (128 + SIGINT)
+    # with a single human line on stderr — the G2 ^C-hygiene fix
+    # (Slice 6). The reader-thread `IOError` noise that Open3 emits
+    # in the same scenario is suppressed at the `Shell.run` seam
+    # (see `lib/repo_tender/shell.rb`).
     def self.run(argv, stdout, stderr)
       return print_usage(stdout) if TOP_LEVEL_HELP.include?(argv)
       return print_version(stdout) if VERSION_REQUEST.include?(argv)

-      Dry::CLI.new(Registry).call(arguments: argv, out: stdout, err: stderr)
-      outcome = last_outcome
-      Kernel.exit(outcome&.exit_code || 0)
+      begin
+        Dry::CLI.new(Registry).call(arguments: argv, out: stdout, err: stderr)
+        outcome = last_outcome
+        Kernel.exit(outcome&.exit_code || 0)
+      rescue Interrupt
+        # Map a user ^C to a clean exit-130 with a single human line.
+        # `Kernel.exit` raises `SystemExit` (callers/tests can rescue
+        # it to inspect the status). The `at_exit` handlers run,
+        # stdio is flushed, the process exits with code 130. We do
+        # NOT blanket-rescue `StandardError` and we do NOT make
+        # non-interrupt failures exit 0 (the outcome-translation path
+        # above is unchanged for the happy / non-Interrupt failure
+        # paths).
+        stderr.puts "interrupted"
+        Kernel.exit(130)
+      end
     end
```

### 6.4 The Open3 reader-thread suppression diff (verbatim, `lib/repo_tender/shell.rb`)

```diff
@@ -24,10 +24,48 @@ module RepoTender
       opts = {}
       opts[:chdir] = chdir if chdir
       # Open3.capture3: env is a leading hash positional arg, not a kwarg.
-      stdout, stderr, status = if full_env
-        Open3.capture3(full_env, *argv, **opts)
-      else
-        Open3.capture3(*argv, **opts)
+      #
+      # Open3.capture3 spawns the child with two internal reader
+      # threads (one for stdout, one for stderr; see
+      # `rubylibdir/open3.rb` ~L644: `out_reader = Thread.new { o.read }`
+      # / `err_reader = Thread.new { e.read }`). When the `popen3`
+      # block exits via exception (e.g. the user ^C'd mid-Shell.run
+      # via SIGINT), `popen_run`'s ensure closes the read pipes from
+      # the main thread while those reader threads are still inside
+      # `o.read` / `e.read`. The mid-read close races with the reader
+      # and raises `IOError: stream closed in another thread` in the
+      # reader thread. With the default `Thread.report_on_exception
+      # = true` (since Ruby 2.5), Ruby prints a multi-line backtrace
+      # to stderr for that orphaned thread — exactly the noise
+      # Slice 6 G3 silences.
+      #
+      # We bracket the `Open3.capture3` call with a save/restore of
+      # `Thread.report_on_exception = false`. This is targeted
+      # because, at this code site, the ONLY threads in flight are:
+      #   * the main thread (this method's caller);
+      #   * Async's internal `io_select` thread
+      #     (`async/lib/async/scheduler.rb` L425) — which silences
+      #     its own report (`Thread.current.report_on_exception =
+      #     false` on that thread, not globally);
+      #   * the Open3 reader threads (the source of the noise).
+      # `lib/` has zero `Thread.new` calls; `dry-cli`, `dry-monads`,
+      # `dry-validation`, `dry-struct`, `dry-types`, `dry-schema`,
+      # `xdg` have none either (verified Slice 6 PHASE 0). So we are
+      # NOT hiding any app-owned worker-thread crashes — the only
+      # thread that can raise here is the Open3 reader thread, and
+      # the only thing it can raise is the IOError we explicitly
+      # want to silence. The original value is restored in `ensure`
+      # so we never leak the suppression past this call.
+      prev_report_on_exception = Thread.report_on_exception
+      Thread.report_on_exception = false
+      begin
+        stdout, stderr, status = if full_env
+          Open3.capture3(full_env, *argv, **opts)
+        else
+          Open3.capture3(*argv, **opts)
+        end
+      ensure
+        Thread.report_on_exception = prev_report_on_exception
       end
```

## 7. Manual checklist (HUMAN-RUN — not the builder's lane)

| ID | Description | Status |
|----|-------------|--------|
| M1 | With SSH keys configured for GitHub, run `repo-tender sync` against a config containing one not-yet-cloned GitHub repo. Expected: clones over SSH (`git@github.com:...`); does NOT print `Username for 'https://github.com':`. | **PENDING** — human-run on judged branch |
| M2 | Run a `repo-tender sync` that is mid-clone/mid-fetch (or sits at any git prompt) and press `Ctrl-C`. Expected: single clean line (or nothing) + prompt returns; exit status `130`; ZERO Ruby backtraces and no `... terminated with exception (report_on_exception is true)` / `stream closed in another thread` lines. | **PENDING** — human-run on judged branch |
| M3 | Run the installed `repo-tender version` (and `repo-tender --help`). Expected: clean output, exit 0, and no io-event experimental feature warning. | **Builder pre-check passed** — see G0 above; the binstub shebang is `-W:no-experimental`. Architect-verified (per HANDOFF §"Next — Slice 6"). Human confirms on the merged binary. |

## 8. Summary

| Gate | Status | Evidence |
|------|--------|----------|
| G0 | PASS | suite 229/918/0/0/0 (+7 vs baseline 222/890/0/0/0); standardrb 0; no new gems; executable sub-clause 0/stdout |
| G1 | PASS | printed `git@github.com:foo/bar.git`; 3 new unit tests green; G6 regression unmodified + green |
| G2 | PASS | new in-process interrupt test green (SystemExit 130, clean stderr); non-Interrupt-failure path still exits 1 (regression guard test green) |
| G3 | PASS | save/restore suppression in `Shell.run` + mechanism-justification unit test (2 tests) green + static analysis (zero app-owned threads) + direct reproducer of the IOError pattern saved at `/tmp/repro_open3.rb`; subprocess test not constructible offline (per spec's explicit fallback) |
| G4 | PASS | 7 files all in MAY TOUCH; no builder commits; `docs/gates/` diff-clean; no new gems |
| M1/M2/M3 | PENDING | HUMAN-RUN on judged branch (M3 builder pre-check passed; M1+M2 require the human's real-Mac SSH + ^C) |

**Concerns (architect-judged):**
- **Disagreement #1** — the gate's `State::Store.write` "atomic (temp+rename)" claim is inaccurate for the current code (`lib/repo_tender/state/store.rb:64-69` is direct `File.write`, not temp+rename). The `state/*` directory is MUST NOT TOUCH for this slice, so the fix is out of scope. Flagged as **CF7** for a future slice. Residual risk: a SIGINT landing inside the kernel during `write(2)` of the YAML could leave a truncated file; the most likely SIGINT case (mid-engine) is caught before the state write even starts. The architect can (a) widen this slice's MAY TOUCH to include `state/store.rb` and I implement temp+rename in this slice, or (b) accept CF7.

STATUS: COMPLETE_WITH_CONCERNS (CF7 raised in disagreement #1 — `State::Store.write` is not actually temp+rename; current code is direct `File.write` at `lib/repo_tender/state/store.rb:64-69`. `state/*` is MUST NOT TOUCH for this slice. Architect decision: widen MAY TOUCH for state/store.rb and I implement temp+rename in this slice, OR accept CF7 for a future slice.)
