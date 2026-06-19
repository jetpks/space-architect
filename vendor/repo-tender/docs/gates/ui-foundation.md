# Gates — CLI-UX Slice A: `ui-foundation` (Mode + Reporter seam + Plain/JSON, no animation)

> FROZEN before dispatch. Read-only for everyone including the builder — any
> edit to a file under `docs/gates/` fails the slice regardless of results.
> The architect re-runs G0–G6 in a later session (rule 4: never judged by the
> session that dispatched) and compares output to the verbatim thresholds here.
> Gate-pass is necessary, not sufficient: the architect also reads the diff
> against `docs/prd/cli-ux.md` §3/§5 (Slice A) and the no-behavior-change
> invariant before the verdict.
>
> **PRD:** `docs/prd/cli-ux.md` (Slice A). **Research:** `docs/research/cli-ux-interactive-daemon.md`.
> **Baseline suite at freeze (Slice 6 / `main`):** `rake test` **229/918/0/0/0**,
> `standardrb` 0. **No new gems in this slice** — `pastel`/`tty-*` are Slice B.

## Scope reminder (frozen)

Slice A builds the *seam and dual-mode plumbing*, **no color and no animation**.
On a TTY, `:pretty` resolves but is rendered by `PlainReporter` (color/animation
arrive in Slice B's `InteractiveReporter`). Adding any color, `pastel`, or `tty-*`
gem in this slice is **out of scope** and fails G7. The engine's render-fiber
seam (`attach`/`detach`) is wired now and is a **no-op** for every Slice-A
reporter, so Slice B need not re-touch the engine.

## How the architect measures these

The lane report (`docs/lanes/ui-foundation-01.md`) must include a **gate→test
mapping table** (each gate → test file + test name). The architect (a) runs the
suite and reads counts, (b) opens each named test and confirms it asserts the
gate's behavior (not a tautology — assert on real resolved `Mode` values / real
emitted events / real captured output, never on a hand-set stub of the thing
under test), (c) reads the diff against PRD intent.

---

## G0 — Suite green & reproducible; no new gems [whole slice]

```bash
bundle install
bundle exec rake test
bundle exec standardrb
git diff <freeze>.. -- Gemfile Gemfile.lock repo-tender.gemspec
ruby -W:no-experimental -Ilib bin/repo-tender --help
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all 229
  baseline tests still passing** plus the new Slice-A tests, **failures = 0,
  errors = 0, skips = 0** (any intentional skip must be named in the report with
  a reason and is judged separately); `standardrb` exits 0. **No new gem
  dependencies** — the `Gemfile`/`Gemfile.lock`/`gemspec` diff since the freeze
  is empty (Mode/Reporter/Plain/Json are pure Ruby + stdlib `json`, already a
  transitive dep). `bin/repo-tender --help` still exits 0 and lists the same 5
  command groups as before (no new/removed groups).

## G1 — `UI::Mode.resolve` precedence table [new unit]

A table-driven test exercises `UI::Mode.resolve(flags:, env:, out:)` (env via a
plain hash, `out` via an object whose `tty?` the test controls — e.g. a StringIO
flagged tty or a tiny double exposing `tty?`). Assert the **frozen PRD §3.1**
rules, at minimum these rows:

- **format:** `--json` → `:json`; `--plain` → `:plain`; non-TTY (no flag) →
  `:plain`; TTY + no flags → `:pretty`. (`--json` wins over `--plain` if both.)
- **color = false** for each of, independently: `NO_COLOR=1` (present & non-empty),
  `--no-color`, `TERM=dumb`, `format != :pretty`, `out` not a TTY.
- **color = true** on a TTY with none of the above; **`NO_COLOR=""` (empty) does
  NOT disable color**; **`CLICOLOR_FORCE=1` forces color = true even when `out`
  is not a TTY**.
- **animate = true** only when `format == :pretty` AND `out.tty?` AND `!quiet`
  AND `CI` unset; false if any of those fail (assert at least the `CI=1`,
  non-TTY, and `--quiet` cases turn it off).
- **quiet = true** under `--quiet` (and `-q` if implemented).
- **Precedence:** an explicit flag overrides the env/auto default (assert e.g.
  `--no-color` beats `CLICOLOR_FORCE`, or document the chosen order and test it —
  state it in the report). `Mode` is an immutable `dry-struct`; mutation raises.

There is **no `--daemon` flag** — assert it is **not** a recognized option
(parsing `--daemon` errors or is rejected, not silently honored).

## G2 — Engine default is `NullReporter`; **zero engine behavior change** [existing engine tests, unmodified]

- `Sync::Engine#initialize` gains a `reporter:` keyword defaulting to a
  `UI::NullReporter` (or equivalent no-op). **`test/repo_tender/sync/engine_test.rb`'s
  pre-existing tests are UNMODIFIED** (`git diff <freeze>.. -- test/repo_tender/sync/engine_test.rb`
  shows only **additions**, no changed/deleted pre-existing assertions) and all
  pass — proving the default reporter alters no engine result, state row, status,
  or control flow. An engine run with the default reporter writes a **byte-identical
  `state.yaml`** to the pre-slice engine for the same inputs (assert in a test, or
  the architect diffs a fixture run).
- `UI::NullReporter` implements every interface method (`run_started`,
  `repo_started`, `repo_phase`, `repo_finished`, `repo_failed`, `run_finished`,
  `attach`, `detach`) as a no-op.

## G3 — Engine emits the correct event sequence [new engine tests; recording reporter]

With an injected **recording reporter** (captures `(method, args)` in order) and
the existing Slice-2 real-temp-git seam (real bare remote + clones; **no mocks of
the engine**), a run over a set including at least {clean→behind (ff),
dirty, missing (clone), diverged} repos asserts:

- exactly one `run_started(total: N)` first and one `run_finished(...)` last;
- for **every** processed repo, a `repo_started(ref)` followed (eventually) by a
  terminal `repo_finished(ref, status)` **or** `repo_failed(ref, error)` — and the
  `status` passed to `repo_finished` **equals** the status written to that repo's
  state row (parity with Slice-2 G8; assert against the real `state.yaml`);
- a repo whose `process_one` hits the last-resort `rescue` still emits
  `repo_failed` (not a missing/`repo_finished` event) and the run does **not**
  abort — other repos still complete (Slice-2 G8 invariant preserved);
- `attach(task, total:)` and `detach` are each invoked once around the fan-out.

Because concurrent fibers interleave, assert on the **set/pairing** keyed by ref
(every repo has its started+terminal pair; statuses match state) — **not** a
fixed cross-repo ordering.

## G4 — `PlainReporter` deterministic & ANSI-free; `JsonReporter` parseable [new unit]

Feed a fixed event stream (constructed directly, or captured from a `concurrency:
1` run for determinism) to each reporter writing to a `StringIO`:

- **`PlainReporter`**: every line is **ANSI-free** (assert the output contains no
  `\e[` / `\x1b[` byte), and for each finished repo the line contains the repo
  ref and its status (e.g. `github.com/ruby/ruby\tclean` or equivalent stable
  format). No color regardless of `mode.color?`. `attach`/`detach` are no-ops
  (no output). A failure event renders a recognizable error line (ref + an error
  marker); errors may go to a separate stream — state which and assert it.
- **`JsonReporter`**: each emitted line is **one parseable JSON object**
  (`JSON.parse` succeeds per line) carrying at least an event/type key, the repo
  ref, and (for terminal events) the status. One object per event line (12-factor).

## G5 — Non-TTY (and `--plain`) select plain; `--json` selects JSON; no `--daemon` [new CLI tests]

Drive `sync`'s mode/reporter selection (unit-level on the resolved `Mode` +
constructed reporter, or via the command with a controllable `out`):

- `out` is **not a TTY** (no flag) → `Mode.format == :plain`, reporter is
  `PlainReporter` (the launchd/pipe case); a TTY with no flags → `:pretty`, also
  rendered by `PlainReporter` in this slice (no color/animation).
- `--plain` forces `:plain` even on a TTY; `--json` → `:json` + `JsonReporter`.
- The global output flags (`--plain`, `--json`, `--no-color`, `--quiet`) parse on
  `sync`; **`--daemon` is not a recognized flag** (assert it errors, is not
  silently accepted).

## G6 — `bin/repo-tender sync` end-to-end unchanged + plain when piped [subprocess]

A real-temp-git subprocess run of `bin/repo-tender sync` (reuse the Slice-3/6
subprocess harness):

- **Exit codes and the written `state.yaml` are unchanged** vs the pre-slice
  behavior for the same inputs (happy path exit 0; a scoping failure
  `sync --repo not-a-ref` still exits 1 with the same `invalid repo reference`
  stderr message — Slice-3 G4 / Slice-6 behavior un-regressed).
- With **stdout redirected to a pipe/file** (non-TTY, the launchd condition),
  stdout is plain structured lines (per-repo outcomes + the `synced N repo(s)`
  summary), stderr carries any errors, and **no ANSI byte** appears on either
  stream. The existing `synced N repo(s)` summary line is **preserved** (reporter
  output is additive).

## G7 — Only in-scope files; no builder commits; gates clean [architect-checked]

`git status` / `git diff --name-only <freeze>..` shows changes **only** within
the lane's declared Builds+Extends set (below); **nothing** under `docs/gates/`
changed since the freeze; `git log <freeze>..` in the checkout has **no builder
commits**; no new gems (G0). An out-of-bounds write or any builder commit fails
the slice.

### Lane file set (frozen)

**Builds (new):** `lib/repo_tender/ui/mode.rb`, `lib/repo_tender/ui/reporter.rb`
(interface + `NullReporter`), `lib/repo_tender/ui/plain_reporter.rb`,
`lib/repo_tender/ui/json_reporter.rb`, `lib/repo_tender/cli/options.rb`; one test
file per unit under `test/repo_tender/ui/` and `test/repo_tender/cli/`; the lane
report `docs/lanes/ui-foundation-01.md`.

**Extends (narrowly):** `lib/repo_tender/sync/engine.rb` (add `reporter:` keyword
+ emit events at the §3.3 seams — **no other engine logic/result/state/timing
change**); `lib/repo_tender/cli/sync.rb` (resolve `Mode`, construct the reporter,
pass to the engine, add the output flags — **do not** change `--repo` scoping or
exit codes; preserve the `synced N repo(s)` summary); `lib/repo_tender.rb` and/or
`lib/repo_tender/cli.rb` (requires for the new files);
`test/repo_tender/sync/engine_test.rb` (**additions only** — G2);
`test/repo_tender/cli/sync_test.rb` (additive).

**MUST NOT TOUCH:** `state/store.rb`, `scm/*`, `forge/*`, `config/*`,
`sync/repo_plan.rb`, `cli/{repo,org,status,config,daemon}.rb`, `launchd/*`,
`log_rotator.rb`, `shell.rb`, `paths.rb`, `test_helper.rb`, `Gemfile`,
`Gemfile.lock`, `repo-tender.gemspec`, anything under `docs/gates/`.

**OUT OF SCOPE (Slice B/C):** any color/`pastel`/`tty-*` gem; `InteractiveReporter`;
the render-loop fiber body; rolling color/spinners into other commands;
`cli/status.rb` and other command files.
