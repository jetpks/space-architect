# CLI UX: interactive vs daemon, animated & informative output

_Research report — 2026-06-13. Decision-oriented; verify dates/tiers in Citations._

## BLUF (answer first)

**It works. Build a thin event/reporter seam, drive animation from the Async
reactor with no Threads, and select a renderer by mode.** Concretely:

1. **Don't add a spinner gem for animation.** Every *animated* Ruby spinner
   (`tty-spinner#auto_spin`, `whirly`, Shopify `cli-ui`) spawns a Ruby
   **Thread** — disqualified by our no-Threads rule. But the building blocks
   we need are thread-free: `pastel` (color), `tty-cursor`, `tty-screen`, and
   crucially `tty-progressbar` (caller-driven, no animation thread, has a
   `Multi` mode that advances *synchronously*) and `tty-spinner#spin` (a
   single-frame advance with **no** thread — only `auto_spin` threads). We
   drive the frames ourselves from one Async "render-loop" fiber.
2. **Animation under fibers is a solved mechanism.** `Kernel#sleep` inside an
   `Async` task is intercepted by the scheduler (`kernel_sleep → block(nil,
   duration)`) and suspends the *fiber*, not the thread. A single
   render-loop fiber (`task.async { loop { redraw; sleep 0.08 } }`) ticks the
   UI while the bounded worker fibers (the existing `Semaphore`+`Barrier` in
   `Sync::Engine`) only mutate shared progress state. The single-threaded
   reactor serializes everything — the cross-thread terminal-corruption bug
   class simply cannot occur.
3. **Build a small `Reporter` seam, injected into the engine.** Domain code
   emits events ("started X", "cloned X", "X diverged", "done"); a renderer
   decides presentation. This is the RSpec/Bundler-formatter pattern, sized
   down. Inject it like the engine's existing `scm:`/`forge:` deps; the
   default is a `NullReporter` so behavior and tests are unchanged until we
   opt in.
4. **Mode selection: flag > env > TTY autodetect.** Add the user-requested
   explicit `--daemon` flag (for the launchd plist) and honor the conventions:
   `--no-color`/`--quiet`, `NO_COLOR`, `CLICOLOR_FORCE`, `TERM=dumb`,
   `CI`, and `out.tty?`. Daemon/non-interactive → plain structured lines, no
   color, no animation.
5. **Daemon structured output: strong free option exists.** `socketry/console`
   is **already a transitive dependency of `async`** and auto-switches to
   one-JSON-record-per-line `Serialized` output when stderr is not a TTY —
   exactly the daemon behavior — with zero app code. Recommended as the
   daemon-side backbone *if* we accept its global-logger model; otherwise a
   ~30-line `PlainReporter` writing to the injected `out` preserves our
   injected-IO testability discipline. See Open Question 1.

## The brief (restated)

**Question:** Which gems and which home-grown modules should repo-tender adopt
to deliver a bright, animated, colorful, *informative* CLI experience for
interactive use — while degrading to clean structured output in
daemon/non-interactive mode (selected via a flag) — built on socketry/async
(no Ruby Threads) and the dry-rb suite?

**Decision it informs:** which gems to add, and what output/progress/reporting
abstraction to build, so long-running concurrent `sync` shows delightful live
progress interactively and quiet structured logs under launchd.

**Hard constraints:** no Ruby Threads (Async fibers only); dry-rb idioms;
testable output (status output is deliberately ANSI-free for assertions);
small, surgical additions to a working system.

**Repo seams this plugs into (verified by reading source):**
- `Sync::Engine#call` already runs the whole sync inside `Sync do |task|`
  (`lib/repo_tender/sync/engine.rb:69`) — bounded by `Async::Semaphore`
  (`config.concurrency`) + `Async::Barrier`. **This is where the render-loop
  fiber belongs.**
- `process_one` (`engine.rb:181`) is the per-repo lifecycle — `:clone` /
  `:fast_forward` / `:switch` / `:diverged` / `:up_to_date` / error — i.e. the
  exact event-emission points.
- The engine already takes injected deps `scm:`, `forge:`, `clock:`,
  `url_builder:` (`engine.rb:56`) — a `reporter:` follows the same DI pattern.
- Every CLI command receives injected `out`/`err` (Dry::CLI), and `status`
  deliberately emits tab-separated, **no-ANSI** output (`cli/status.rb:24`) —
  the testability value the renderer must respect.
- No TTY detection or interactive/daemon distinction exists today.

---

## Findings

Confidence tags: **high** = primary source (gem source/docs/spec) /
**med** = reputable secondary / **low** = single blog/forum.
Items marked _verified-by-source-read_ were confirmed by fetching the actual
implementation this session.

### F1 — Every animated Ruby spinner spawns a Thread. **high, verified-by-source-read**

`tty-spinner#auto_spin`, `whirly#start`, and Shopify `cli-ui` (a `WorkQueue`
thread-pool + `Mutex`/`ConditionVariable`) all create `Thread.new`. There is
**no thread-free animated spinner** among verified gems.

- **Implies:** we cannot adopt an off-the-shelf animated spinner and stay
  inside the no-Threads rule. We drive frames ourselves.
- **Changes this conclusion:** a maintained, fiber-aware spinner gem appearing
  — none found (Q4 of the animation lane was NOT FOUND).

### F2 — The thread-free building blocks exist and are caller-driven. **high, verified-by-source-read**

`tty-spinner#spin` advances one frame with no thread (only a `MonitorMixin`
`synchronize`); `tty-progressbar` has **no animation thread at all** — it
repaints synchronously on `advance`/`current=`/`ratio=`, throttleable via
`frequency:` (Hz); `pastel`, `tty-cursor`, `tty-screen`, `tty-box`,
`tty-table`, `strings` spawn no threads.

- **Implies:** the interactive renderer is assembled from `pastel` +
  `tty-cursor`/`tty-screen` + `tty-progressbar`/`tty-spinner#spin`, all
  caller-driven, all fiber-safe.
- **Caveat:** the TTY ecosystem is in low-activity maintenance (sole
  maintainer Piotr Murach; meta-gem last commit 2021; individual gems
  sporadic 2024 releases) — not dead, but not vibrant. License watch:
  `colorize` is **GPL-2.0** and `progress_bar` is WTFPL; the gems we want
  (`pastel`, `tty-*`) are MIT.

### F3 — `Kernel#sleep` in an Async task suspends the fiber, not the thread. **high, verified-by-source-read**

The Async scheduler implements `Fiber::Scheduler#kernel_sleep`, turning a
plain `sleep duration` into `block(nil, duration)` — fiber suspended, reactor
runs other fibers, no Thread. `Async::Task#sleep` is deprecated in favor of
plain `Kernel#sleep`. Corroborated by a runtime demo (concurrent staggered
sleeps complete in 2s not 7s).

- **Implies:** the render-loop fiber `task.async { loop { redraw; sleep 0.08 } }`
  is correct and idiomatic. No `Async::Timer` class is needed (and none was
  found by that name).
- **Changes this conclusion:** nothing credible contradicts the scheduler
  source.

### F4 — Concurrent multi-line progress maps cleanly onto one reactor. **high (mechanism) / med (no published recipe)**

`TTY::ProgressBar::Multi` documents that registered bars can be advanced
"synchronously" (threads explicitly *optional*); Multi handles cursor
save/restore/redraw internally. Because Async fibers are cooperative on a
single thread, no `advance`/`spin` call is ever interrupted mid-write — the
"single writer owns the terminal, tasks publish state" pattern (the same shape
as Rust `indicatif::MultiProgress`, which replaces each bar's draw target with
one intercepted by the coordinator under an internal lock) is the natural fit.

- **Implies:** N concurrent repos → N registered bars (or N spinner lines);
  worker fibers mutate their bar's state, one render fiber repaints. No mutex
  needed for the terminal.
- **NOT FOUND:** any published example of socketry/async + a tty progress gem.
  This integration is novel — hence we verify it ourselves with a spike (Open
  Question 2). _med._

### F5 — `socketry/console` already gives dual-mode output for free. **high, verified-by-source-read**

`console` (v1.36.0, released 2026-06-02, MIT, Ruby ≥ 3.3, **already pinned by
`async` as `console ~> 1.29`**) selects its output class by TTY detection
(`lib/console/output/default.rb`, fetched and quoted this session):

```ruby
stream ||= $stderr
if stream.tty?            then Terminal.new(stream)    # pretty + color
elsif self.mail?(env)     then Text.new(stream)        # MAILTO set (cron)
elsif self.github_actions?(env) then XTerm.new(stream) # colored CI
else                           Serialized.new(stream)  # one JSON-ish record/line
end
```

Under launchd (stderr not a TTY, no MAILTO, no GITHUB_ACTIONS) it
auto-selects `Serialized`: one structured record per line (`time` ISO-8601,
`severity`, `process_id`, `fiber_id`, `subject`, `message`, merged attrs),
single `IO#write` per record to avoid interleaving across fibers. It supports
**custom structured events** (`Console::Event::Generic` with `to_hash` for the
machine form + a terminal formatter for the pretty form), and carries
**per-fiber context** — the async-native answer to "N concurrent tasks each
reporting."

- **Implies:** the daemon/structured half of the requirement is essentially
  free if we route domain events through `console`.
- **Tension:** `console` is a *global* logger; our codebase deliberately
  injects `out`/`err` per command for testability. Reconcile via the reporter
  seam (Open Question 1).
- **Gaps (med-negative):** the color path keys purely off `stream.tty?` — it
  does **not** honor `NO_COLOR` in the source read; and the exact
  custom-terminal-formatter registration API wasn't confirmable in fetched
  docs. So we still own the `NO_COLOR`/interactive-color decision ourselves.

### F6 — Color/interactivity suppression has firm conventions; follow them. **high**

- **`NO_COLOR`** (no-color.org): when **present and non-empty** (any value),
  suppress ANSI color. `NO_COLOR=` (empty) does *not* suppress; `NO_COLOR=0`
  *does*.
- **`CLICOLOR_FORCE`** (non-empty) forces color even when piped; **`CLICOLOR`**
  enables color on a TTY. Precedence: `NO_COLOR` > `CLICOLOR_FORCE` >
  `CLICOLOR` > default.
- **`TERM=dumb`** → no color. **`--no-color`** flag → no color.
- **clig.dev:** "If `stdout` is not an interactive terminal, don't display any
  animations" (prevents progress bars becoming "Christmas trees" in logs);
  provide `--plain` for tabular/script output and `--json` for structured;
  `-q`/`--quiet` for less output; machine-readable output to **stdout**, logs
  to **stderr**, no log-level labels on stderr by default.
- **Precedence (canonical):** flag > env var > config > autodetect.
- **TTY detection alone is insufficient:** pipes/redirects read as non-TTY for
  humans (`less`); CI has no TTY but a human reads it (check `CI`); stdout and
  stderr are independently TTY-or-not; a systemd service can even get a false
  negative on `/dev/console`. So combine `out.tty?` with env signals.
- **Daemon signalling:** there is **no** standardized cross-tool
  `--non-interactive` *output* flag; `--daemon` conventionally governs
  backgrounding, not output. Tools rely on TTY autodetect + `--quiet`/`--json`.
  The 12-factor pattern is the daemon norm: write the event stream **unbuffered
  to stdout**, let the service manager capture/route it.

- **Implies our mode resolver** (precedence-ordered):
  `--daemon`/`--plain`/`--json` flag → `--no-color` / `NO_COLOR` /
  `CLICOLOR_FORCE` / `TERM=dumb` / `CI` env → `out.tty?` autodetect.
  Color and animation are independently gated (animation needs a TTY *and*
  non-quiet; color needs a TTY *and* not-`NO_COLOR`).

### F7 — The decoupled event→renderer pattern is well-trodden; dry-rb has a native fit. **high**

Two recurring interface shapes, both decoupling emit from render:
- **Fixed-method reporter** — RSpec (`register self, :example_passed, …`;
  formatters receive value objects, subscribe only to events they render;
  multiple formatters run independently), Minitest (`#record(result)` +
  `CompositeReporter` fan-out), **Bundler::UI** (`info/warn/confirm/debug`
  with a `Shell` impl and a **`Silent`** null impl that captures instead of
  printing — the testability pattern verbatim).
- **Named-event + payload pub/sub** — `ActiveSupport::Notifications`
  (`instrument(name, payload){ }` / `subscribe`), and the dry-native
  **`dry-events`** (`Dry::Events::Publisher[:id]`, `register_event`,
  `publish('repo.synced', repo: …)`, `subscribe('repo.synced'){ |e| e[:repo] }`,
  listener convention `on_repo_synced(event)`). **`dry-monitor`** is built on
  `dry-events` (`include Events::Publisher`) and is "interface compatible with
  ActiveSupport::Notifications" via `instrument(event_id, payload, &block)`
  (which also times the block).

- **Implies:** a fixed-method `Reporter` (closed, compile-checkable, trivially
  null-able) is the smallest thing that works and matches Bundler/RSpec. If we
  want an open event bus, `dry-events` is the idiomatic dry-rb choice — but
  it's heavier than this single-consumer need warrants.
- **Disagreement / open:** `dry-events`' sync-vs-async behavior is
  **undocumented** (one low-confidence secondary claims "fully synchronous").
  For our single-reactor use that's moot, but don't rely on it being async.
  Also note dry-rb/Hanami/ROM have merged under the **Hanakai** umbrella —
  docs now live at hanakai.org. _med._
- **Testability mechanisms confirmed:** `Bundler::UI::Silent` (no-op +
  capture); assert on emitted event objects not bytes; `Pastel.new(enabled:
  false)` is a pure passthrough and `pastel.strip(str)` removes color while
  keeping cursor codes — the clean way to keep test output ANSI-free.

---

## Recommended design (orchestrator judgment)

A small, surgical investment that matches the repo's values (injected IO,
minimal deps, "no more code than required", uptime via opt-in defaults).

### Gems to add (all MIT, all thread-free)
- **`pastel`** — color, with `enabled:` resolved from mode.
- **`tty-cursor`** + **`tty-screen`** — cursor control + terminal size.
- **`tty-progressbar`** — determinate/indeterminate bars + `Multi` for
  concurrent `sync`. (Drive `advance` ourselves; no thread.)
- _Optional_ **`tty-spinner`** — only for `#spin` single-frame ticks if we
  want spinner-style lines instead of bars. Or hand-roll a 6-frame braille
  spinner string (zero dep). Prefer hand-rolled to avoid a stale dependency
  for ~5 lines of code.
- **Daemon side:** either reuse the already-present **`console`** (F5) or a
  ~30-line home-grown `PlainReporter`. See Open Question 1.

### Modules to build
1. **`RepoTender::UI::Mode`** — a `dry-struct` value resolving
   `(flags, env, out.tty?)` → `{ color:, animate:, format: :pretty|:plain|:json,
   quiet: }` using the F6 precedence. Pure, fully unit-testable.
2. **`RepoTender::UI::Reporter`** — fixed-method interface, e.g.
   `run_started(total)`, `repo_started(ref)`, `repo_progress(ref, phase)`,
   `repo_finished(ref, status)`, `repo_failed(ref, error)`, `run_finished(summary)`.
   Implementations:
   - `NullReporter` — all no-ops. **The engine default**, so nothing changes
     until a command opts in (uptime value). Used by unit tests.
   - `InteractiveReporter(out, mode)` — owns a `tty-progressbar` `Multi` (or a
     spinner-line set) and, when attached to the engine's `task`, spawns **one
     render-loop child fiber** that repaints every ~80ms. Worker fibers only
     mutate bar state via the reporter methods.
   - `PlainReporter(out, mode)` / `JsonReporter(out)` — emit one structured
     line per event, immediately, no animation (daemon + `--plain`/`--json`).
3. **Engine wiring** — add `reporter: NullReporter.new` to
   `Engine#initialize`; inside the existing `Sync do |task|` block call
   `reporter.attach(task)` (spawns the render fiber as a child of the same
   reactor as the workers — the single-writer pattern), emit events from
   `process_one`, and `reporter.finish` after `barrier.wait`. The existing
   `results_mutex` stays for the results array; the terminal needs no mutex
   because the reactor serializes fiber resumption.
4. **CLI wiring** — `sync` (and later every command) builds the `Mode` from
   resolved flags/env/tty and constructs the matching reporter around the
   injected `out`. Add a global `--daemon` (and `--no-color`, `--quiet`,
   `--json`) option; the launchd plist invokes `repo-tender sync --daemon`.

### Why this shape
- **Uptime:** default `NullReporter` ⇒ zero behavior change until opted in;
  each command can adopt the reporter independently.
- **Testability:** assert on the emitted event sequence (Null/recording
  reporter) and on deterministic `PlainReporter` lines — no ANSI in tests,
  honoring the `status.rb:24` value.
- **No Threads:** every moving part is a fiber on the existing reactor.
- **Small:** one value object, one interface + 3–4 tiny impls, a few event
  emissions in `process_one`. No new architecture, just a clean seam.

---

## Open questions

1. **Daemon backbone: `console` vs home-grown `PlainReporter`?** `console` is
   free (already in-tree), auto-switches on TTY, and is async-native with
   per-fiber context — but it's a *global* logger, in tension with our
   injected-`out` testability discipline, and doesn't honor `NO_COLOR` in the
   path read. A ~30-line `PlainReporter`/`JsonReporter` writing to the injected
   `out` keeps full control and testability at the cost of reimplementing what
   `console` gives free. _Resolve by:_ prototyping the `PlainReporter` first
   (it's tiny); adopt `console` only if we later want its journald/Datadog
   adapters. **Leaning home-grown** for the injected-IO discipline.
2. **Does fiber-driven `tty-progressbar::Multi` render cleanly in practice?**
   The integration is novel (NOT FOUND in the wild). _Resolve by:_ a one-hour
   spike — 3 concurrent fake "repos", one render fiber, confirm no flicker/
   corruption and correct teardown on `^C` (we already map SIGINT→130 at
   `cli.rb:84`). Falsifier: terminal corruption under the single reactor would
   send us to a hand-rolled cursor+pastel renderer (still thread-free).
3. **`tty-progressbar` thread-safety claim** — a CHANGELOG line claims thread
   safety was added, but no maintainer statement was retrieved and issue #21's
   reply wasn't visible. Moot under a single-threaded reactor, but don't lean
   on it if we ever introduce a worker thread.
4. **Spinner frames: `tty-spinner#spin` vs hand-rolled?** For ~5 lines, a
   hand-rolled braille/dots frame cycle avoids a low-activity dependency.
   Decide during the spike.

---

## Citations

Primary (source/spec read this session):
- socketry/console `output/default.rb` — TTY→Terminal / else Serialized
  switch. `github.com/socketry/console` [primary, 2026-06] — verified by direct
  fetch.
- socketry/async `Scheduler#kernel_sleep` → `block(nil, duration)`;
  `Async::Task#sleep` deprecated. `socketry.github.io/async` [primary, 2026].
- tty-spinner `spin` (no thread) vs `auto_spin` (`Thread.new`). 
  `github.com/piotrmurach/tty-spinner` [primary, src 2024] — verified by direct
  fetch.
- whirly `start` (infinite-loop Thread); Shopify cli-ui `work_queue.rb`
  (`Thread.new` pool). [primary, src].
- tty-progressbar README — synchronous `Multi`, `advance`, `frequency:`.
  `github.com/piotrmurach/tty-progressbar` [primary, 2024-11].
- `console` v1.36.0 / `async` gemspec `console ~> 1.29`. rubygems.org
  [primary, 2026-06].
- NO_COLOR rule. `no-color.org` [primary]. CLICOLOR precedence.
  `bixense.com/clicolors` [primary].
- clig.dev — TTY/animation/`--plain`/`--json`/`--quiet`/precedence rules.
  `clig.dev` [primary, 2026-06].
- 12-factor logs. `12factor.net/logs` [primary].
- RSpec custom-formatter API (`register`); Bundler `UI::Shell`/`UI::Silent`;
  dry-events / dry-monitor (`instrument`, AS::Notifications-compatible);
  indicatif `MultiProgress`. [primary docs/source].

Secondary / leads (med–low):
- thoughtbot "My adventure with async Ruby" — fiber-sleep concurrency demo
  [secondary, 2023/2024].
- dry-events sync-vs-async = undocumented; one secondary claims fully
  synchronous [low].

NOT FOUND (honest gaps): any published socketry/async + tty-progress
integration (F4/OQ2); `NO_COLOR` handling in console's color path; a
standardized cross-tool `--non-interactive` *output* flag; a Ruby-specific
golden-output testing write-up.
```

_Raw per-lane findings: `.architect/research/0{1..5}-*.md` (gitignored)._
