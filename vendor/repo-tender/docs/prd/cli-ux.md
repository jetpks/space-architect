# PRD — CLI UX: interactive vs daemon, animated & informative output

**Date:** 2026-06-13 · **Author:** architect · **Status:** build-ready (build loop not yet started)
**Source research:** `docs/research/cli-ux-interactive-daemon.md` (gem census + thread-usage verified by source-read + dual-mode mechanism)
**Decisions (frozen):** no Ruby Threads — animation driven by one Async render-loop fiber · home-grown `PlainReporter`/`JsonReporter` for daemon (NOT `socketry/console`) · Non-interactive use is detected (non-TTY → plain), with `--plain`/`--json` overrides · reporter injected into the engine like `scm:`/`forge:`, default `NullReporter` (zero behavior change until opted in)

> Build-loop note: PHASE 0 must challenge every **[CONFIRM]**-tagged claim below
> (version pins + the one novel integration: fiber-driven `tty-progressbar` under
> the Async reactor). Everything else was verified by reading gem source this
> session — see the research doc.

---

## 1. Goal & non-goals

**Goal.** Make every command *informative and delightful* when a human runs it —
bright, colorful, with live progress during long-running work (esp. the
concurrent `sync` sweep) — while degrading to clean, structured,
machine-readable output when run non-interactively (under launchd, in a pipe, or
in CI). Keeping the user informed *as it happens* is the point; entertainment is
the delivery mechanism, not the goal.

**The two modes.**
- **Interactive** (a TTY, color allowed, not quiet): color + animated live
  progress (spinners / progress bars), redrawn in place.
- **Non-interactive** (not a TTY, or `--plain`/`--json`, or
  `NO_COLOR`): no color, no animation, one structured line per event to stdout
  (12-factor style), logs/errors to stderr. The launchd run lands here by
  detection — the plist redirects stdio to log files, so it is not a TTY.

**Hard constraints (inherited).**
- **No Ruby Threads.** All concurrency is Async fibers on the existing reactor.
  Every animated Ruby spinner gem spawns a `Thread` and is therefore **out**
  (`tty-spinner#auto_spin`, `whirly`, `cli-ui` — verified by source-read).
- **dry-rb idioms** — `dry-struct` value objects, `Result` at boundaries.
- **Testable output** — assert on emitted *events* or deterministic ANSI-free
  lines, never on animation bytes. The existing `status` no-ANSI discipline
  (`cli/status.rb:24`) is preserved.
- **Uptime** — additive and opt-in. The engine default is `NullReporter`; no
  existing test or behavior changes until a command constructs a real reporter.

**Non-goals.** No full-screen TUI / alternate-screen takeover (no
`tty-prompt`/curses app). No interactive prompts in this epic. No adoption of
`socketry/console`'s global logger (decided against — it conflicts with the
injected-`out` testability discipline and doesn't honor `NO_COLOR`. No new
resident process — launchd still owns cadence, and its non-interactive output
is **detected** (the plist's log-file stdio redirect makes the run a non-TTY →
plain), not selected by a flag. The Slice-4 plist is **not** touched by this epic.

---

## 2. Frozen tech stack — additions (verified 2026-06-13)

All new gems are **MIT** and **spawn no Threads** (verified by reading source —
`pastel`, `tty-cursor`, `tty-screen` are pure; `tty-progressbar` repaints
synchronously on the caller's fiber, no animation thread).

| Concern | Choice | Constraint |
|---|---|---|
| Color | `pastel` **~> 0.8** | `Pastel.new(enabled: mode.color?)`; `enabled: false` is a pure passthrough → ANSI-free test output. dep: `tty-color`. **[CONFIRM latest @ PHASE 0]** |
| Cursor control | `tty-cursor` **~> 0.7** | save/restore/move escape codes only. |
| Terminal size | `tty-screen` **~> 0.8** | width/height for bar sizing + capability. |
| Progress | `tty-progressbar` **~> 0.18** | determinate/indeterminate; `Multi` for concurrent `sync`; advance **synchronously** (no thread); `frequency:` throttles repaint. deps: `strings-ansi`, `tty-cursor`, `tty-screen`, `unicode-display_width`. **[CONFIRM latest @ PHASE 0]** |

**Out.** `tty-spinner` (we hand-roll a frame string rather than pin a
low-activity gem for ~5 lines — but `#spin` is a viable thread-free fallback if
PHASE 0 prefers it); `whirly`, `cli-ui` (Thread-based); `socketry/console`
(decided against — though it's already transitive via `async`, we do not route
domain output through its global logger); `colorize` (GPL-2.0). The TTY
ecosystem is low-activity maintenance (sole maintainer; many gems last released
2020–2021) — acceptable for these stable primitives, flagged so PHASE 0 pins
exact versions and we vendor-review before adding.

---

## 3. Domain model

### 3.1 `UI::Mode` — the resolved output mode (immutable `dry-struct`)

Resolved **once** per command invocation from `(flags, env, out.tty?)` using the
canonical precedence **flag > env > autodetect**:

```ruby
Mode = Struct(
  color:   Bool,                 # apply ANSI color?
  animate: Bool,                 # live in-place animation? (implies color path)
  quiet:   Bool,                 # suppress non-essential human output
  format:  Symbol                # :pretty | :plain | :json
)
```

Resolution rules (frozen — see research F6):
- **`format`**: `--json` → `:json`; `--plain` or non-TTY → `:plain`;
  else `:pretty`. (The launchd case hits non-TTY → `:plain` with no flag.)
- **`color`**: `false` if any of — `NO_COLOR` present & non-empty · `--no-color` ·
  `TERM=dumb` · `format != :pretty` · `out` not a TTY. `CLICOLOR_FORCE` (non-empty)
  forces `true` even when piped. Else `true`.
- **`animate`**: `format == :pretty` && `out.tty?` && `!quiet` && `!CI`. (clig.dev:
  never animate when stdout isn't an interactive terminal.)
- **`quiet`**: `--quiet`/`-q`.

`Mode` is a pure value object → exhaustively unit-testable with a frozen
precedence table. Env is read from the existing `CLI.env` seam (test-injectable).

### 3.2 `UI::Reporter` — the event seam (fixed-method interface)

Bundler::UI / RSpec-formatter shape (closed, compile-checkable, trivially
null-able). The domain calls these; the renderer decides presentation:

```
run_started(total:)            # N repos about to process
repo_started(ref)              # work begins on one repo
repo_phase(ref, phase)         # :cloning | :fetching | :fast_forwarding | :switching
repo_finished(ref, status)     # clean | diverged | dirty | wrong_branch | ... 
repo_failed(ref, error)        # captured Failure / unhandled
run_finished(summary)          # counts by status
attach(task, total:)           # interactive: spawn the render-loop fiber as a child of `task`
detach                         # stop render fiber, final repaint, restore cursor, newline
```

Implementations:
- **`NullReporter`** — all no-ops. **Engine default.** Used by every existing
  unit test → no behavior change.
- **`PlainReporter(out, mode)`** — emits one line per event immediately
  (`synced github.com/ruby/ruby clean`), no color, no animation. `attach`/`detach`
  are no-ops. The daemon + `--plain` renderer.
- **`JsonReporter(out)`** — one JSON object per line per event
  (`{"event":"repo_finished","ref":"…","status":"clean","t":"…"}`) to stdout
  (12-factor). `attach`/`detach` no-ops.
- **`InteractiveReporter(out, mode)`** (Slice B) — owns a `tty-progressbar::Multi`
  (or N hand-rolled spinner lines) + a `pastel`; `attach` spawns one render-loop
  fiber; worker fibers only mutate per-repo bar state via the events above.

A **recording reporter** (captures the event sequence) is the test double for
asserting domain behavior without bytes.

### 3.3 Event emission points (in `Sync::Engine`)

Verified seams (`lib/repo_tender/sync/engine.rb`):
- `call` (engine.rb:69): inside the existing `Sync do |task|`, after building
  `semaphore`/`barrier` and computing `repos_to_process`, call
  `@reporter.attach(task, total: repos_to_process.size)`; after `barrier.wait`
  (engine.rb:113), call `@reporter.run_finished(...)` then `@reporter.detach`.
- `process_one` (engine.rb:181): `@reporter.repo_started(repo_ref)` at entry;
  `@reporter.repo_phase(repo_ref, :cloning|:fetching|...)` before each SCM action
  in the `case plan.action`; `@reporter.repo_finished(repo_ref, final_status)` /
  `@reporter.repo_failed(repo_ref, error)` before returning (including the
  last-resort `rescue`). The existing `results_mutex` is unaffected; the terminal
  needs no mutex — the single reactor serializes fiber resumption.

---

## 4. Project layout — additions

```
lib/repo_tender/
  ui/
    mode.rb              # dry-struct value + .resolve(flags:, env:, out:)
    reporter.rb          # the interface contract (method list) + NullReporter
    plain_reporter.rb    # one structured line per event (daemon / --plain)
    json_reporter.rb     # one JSON object per event line (--json)
    interactive_reporter.rb   # Slice B: pastel + tty-progressbar Multi + render fiber
    spinner.rb           # Slice B: hand-rolled frame cycle (or tty-spinner#spin)
  cli/
    options.rb           # shared global flags (--no-color/--quiet/--json/--plain) + Mode build
```

Extends (narrowly): `sync/engine.rb` (add `reporter:` to `initialize`; emit
events — §3.3); `cli/sync.rb` (build `Mode` + reporter from resolved flags/env,
pass to engine); `repo_tender.rb` + `cli.rb` (requires). Adds gems to the
gemspec. **The Slice-4 `launchd/plist` is not touched** — the daemon run is
plain by non-TTY detection.

Cross-cutting conventions (unchanged): boundaries return `Result`; Async only in
the sync engine; CRUD/status commands stay synchronous (their reporters are
`Plain`/`Interactive` with no render fiber — color only). Format with the
project linter every slice.

---

## 5. Slices (each independently shippable; gates frozen)

### Slice A — Mode + Reporter seam + Plain/JSON renderers (no animation)
**Depends on:** existing slices 1–4. **Builds:** `ui/mode`, `ui/reporter`
(+`NullReporter`), `ui/plain_reporter`, `ui/json_reporter`, `cli/options`; a test
per unit. **Extends:** `sync/engine.rb` (`reporter:` DI + event emission),
`cli/sync.rb` (Mode + reporter construction + global flags), requires.

This slice delivers the *dual-mode + informative* requirement and the whole
architecture **without** any animation — de-risking the seam before the novel
fiber-rendering work.

**Gates:**
1. **`Mode.resolve` precedence table.** A table-driven test asserts the frozen
   §3.1 rules: `--json`→`:json`; `--plain`/non-TTY→`:plain`; TTY+no
   flags→`:pretty`. `color=false` for each of `NO_COLOR=1`, `--no-color`,
   `TERM=dumb`, non-`:pretty` format, non-TTY; `NO_COLOR=` (empty) does **not**
   disable; `CLICOLOR_FORCE=1` forces color through a non-TTY. `animate` true
   only when `:pretty` + TTY + not-quiet + not-`CI`. Env via the `CLI.env` seam.
2. **`NullReporter` = zero behavior change.** The engine default is
   `NullReporter`; **all existing Slice 1–4 tests pass unchanged** (failures =
   errors = skips = 0), and an engine run with the default reporter produces a
   byte-identical state file to pre-slice.
3. **Engine emits the correct event sequence.** With an injected **recording
   reporter** and the Slice-2 real-temp-git seam: a run over {clean+behind,
   dirty, missing, diverged} repos emits `run_started(total: 4)`, a
   `repo_started`→`repo_finished(status)` (or `repo_failed`) pair per repo with
   the **same** final status the state row records (G8 of Slice 2 parity), and
   one `run_finished`. A repo that raises still emits `repo_failed` (parity with
   the engine's last-resort rescue) and does not abort the run.
4. **`PlainReporter` is deterministic and ANSI-free.** Feeding the Gate-3 event
   stream to `PlainReporter(out, mode: plain)` yields stable, sorted-or-ordered,
   **no-ANSI** lines (assert no `\e[` byte); `JsonReporter` yields one parseable
   JSON object per line with `event`/`ref`/`status` keys. `attach`/`detach` are
   no-ops for both.
5. **Non-TTY (and `--plain`) selects plain — no `--daemon` flag.** With `out` a
   non-TTY pipe (no flag) `sync` resolves `:plain` (autodetect — the launchd
   case, since the plist redirects stdio to log files); `--plain` forces `:plain`
   on a TTY; `--json` emits JSON lines; a TTY with no flags resolves `:pretty`.
   The global flags parse on `sync` and the resolved `Mode` matches §3.1. (There
   is no `--daemon` flag to parse — assert it is **not** a recognized option.)
6. **`bin/repo-tender sync` end-to-end** (subprocess, real temp git): exit codes
   and state writes are **unchanged** vs Slice 3/4; with stdout redirected to a
   pipe/file (non-TTY, as under launchd) stdout is plain structured lines, stderr
   carries errors, no ANSI anywhere.

**[CONFIRM] PHASE 0:** the `CLI.env`/`out` seam for reading env + TTY in
`Mode.resolve` (mirror `CLI.env`); whether global flags hang off each command or
a shared `cli/options` mixin under Dry::CLI; exact `NO_COLOR` empty-string rule.

---

### Slice B — Interactive animated renderer (color + live progress, fiber-driven)
**Depends on:** Slice A. **Builds:** `ui/interactive_reporter`, `ui/spinner`;
tests. **Extends:** gemspec (add `pastel`, `tty-cursor`, `tty-screen`,
`tty-progressbar`); `cli/sync.rb` (select `InteractiveReporter` when
`mode.animate?`).

This is the novel part — fiber-driven animation with **no Thread**. PHASE 0
runs the spike (research OQ2) before committing.

**Gates** (all with a **pseudo-TTY / injected writer**, deterministic — never the
real terminal in CI):
1. **No Thread is spawned.** During an `InteractiveReporter`-driven engine run
   (≥3 concurrent fake repos), assert `Thread.list.size` is **unchanged** from
   before `attach` to after `detach` — animation is fibers only. The render loop
   uses `Kernel#sleep` inside `task.async` (suspends the fiber, per research F3),
   not `Thread.new`.
2. **Render fiber is a child of the engine task.** `attach(task, total:)` spawns
   the render loop via `task.async`; it terminates on `detach` (assert the
   reporter holds no live fiber after `detach`; `barrier.wait` is not blocked by
   it). The loop repaints at a bounded rate (`frequency:`/sleep interval), and
   worker fibers only mutate bar state.
3. **N concurrent bars advance independently.** With `concurrency: 3` and 3 fake
   repos emitting staggered `repo_phase`/`repo_finished`, a
   `tty-progressbar::Multi` (advanced **synchronously** — no per-bar thread) ends
   with all 3 bars complete and the captured output shows 3 distinct lines, no
   interleaved/corrupted writes (single-writer invariant).
4. **Clean `^C` teardown.** A SIGINT mid-run unwinds through `detach`: the cursor
   is **restored** (assert the `tty-cursor` show sequence is emitted), the line
   is not left mid-animation, and the process still exits **130** via the
   existing `cli.rb:84` Interrupt handler (un-regressed).
5. **Color gated by `Mode`.** `InteractiveReporter` colors via
   `Pastel.new(enabled: mode.color?)`; with color off the output is ANSI-free
   (passthrough). It is only constructed when `mode.animate?`; otherwise `sync`
   falls back to `PlainReporter` (Slice A).
6. **Suite + lint green, gems vendor-reviewed.** `rake test` 0/0/0,
   `standardrb` 0; the 4 new gems resolve and are pinned with `~>`; `bundle`
   exits 0. `bin/repo-tender sync` on a real TTY shows live color progress
   (documented manual smoke, like Slice 4's launchctl checklist).

**[CONFIRM] PHASE 0 (the spike):** prove fiber-driven `tty-progressbar::Multi`
renders cleanly under the Async reactor with no flicker/corruption and clean
teardown — research found **no prior art** for this combination (NOT FOUND).
Decide bars vs hand-rolled spinner lines; decide `tty-spinner#spin` vs a
hand-rolled frame string; pin exact current gem versions (research saw `pastel`
0.8.0, `tty-cursor` 0.7.1, `tty-screen` 0.8.2, `tty-progressbar` 0.18.3 — confirm
latest at build time). If the spike shows corruption, fall back to a hand-rolled
`tty-cursor` + `pastel` line renderer (still thread-free) — the seam is unchanged.

---

### Slice C — Roll out across every command
**Depends on:** Slices A–B. **Builds:** apply `Mode` + `pastel` color to
`repo/org/status/config/daemon` commands; a brief spinner for the network-touching
quick ops (`org add`/`org list` via `gh`, `sync --repo`). **Gates:** every
command honors `Mode` (color off under `--no-color`/`NO_COLOR`/non-TTY); `status`
stays byte-compatible in `:plain` (its existing no-ANSI tests pass) and gains
color only in `:pretty`; confirmations (`added: …`, `removed: …`) are colorized
in `:pretty`, unchanged in `:plain`. Each command's existing Slice-3 tests stay
green (they run in `:plain` by default in-process).

---

## 6. Cross-slice risks / PHASE-0 challenge list

- **Novel integration (Slice B):** socketry/async + a tty progress gem has **no
  published prior art**. The Slice-A architecture is deliberately animation-free
  so the whole dual-mode + informative win ships even if Slice B needs the
  hand-rolled fallback. Spike first. **[CONFIRM]**
- **Render fiber lifecycle:** the render loop must be a child of the engine's
  `Sync` task (engine.rb:69) so it shares the reactor with the worker fibers and
  is torn down before `call` returns. `detach` must run on both the happy path
  (after `barrier.wait`) and the `Interrupt` path. **[CONFIRM teardown ordering]**
- **`NO_COLOR` is ours to honor:** `socketry/console` does **not** honor it
  (source-read) — another reason we own color resolution in `Mode` and do not
  route through console.
- **TTY detection alone is insufficient:** check `out.tty?` **and** env
  (`NO_COLOR`/`CLICOLOR_FORCE`/`CI`/`TERM`). stdout and stderr are independently
  TTY-or-not — gate the stream we actually style (`out`).
- **TTY gem maintenance:** low-activity (many gems 2020–2021). Pin exact versions,
  vendor-review the 4 gems, and keep the hand-rolled-renderer fallback viable so
  we're not blocked by an unmaintained dependency.
- **Daemon = non-TTY autodetect (no plist change):** Slice 4's plist already
  redirects stdout/stderr to log files, so the launchd run is not a TTY and
  resolves `:plain` automatically. **No `--daemon` flag and no plist change** —
  Slice-4 gate G1 stays untouched. (Escape hatch if a future stdio wiring ever
  attaches a TTY: add `--plain` to `ProgramArguments` then — not needed now.)

---

## 7. Definition of done (this epic)

Running any command interactively shows colorful output; `repo-tender sync` shows
live, in-place, **fiber-driven** progress (one indicator per concurrent repo,
torn down cleanly on completion or `^C`) with **no Ruby Thread** spawned; the same
command under launchd / in a pipe / with `--plain`/`--json`/`NO_COLOR`
emits clean, ANSI-free, structured output (one event per line) with unchanged exit
codes and state writes; the whole thing is testable via emitted-event assertions
and deterministic plain lines, with every prior slice's tests still green.
