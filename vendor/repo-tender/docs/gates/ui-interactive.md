# Gates — CLI-UX Slice B: `ui-interactive` (color + fiber-driven live progress, no Thread)

> FROZEN before dispatch. Read-only for everyone including the builder — any
> edit to a file under `docs/gates/` fails the slice regardless of results.
> The architect re-runs G0–G7 in a later session (rule 4: never judged by the
> session that dispatched) and compares output to the verbatim thresholds here.
> Gate-pass is necessary, not sufficient: the architect also reads the diff
> against `docs/prd/cli-ux.md` §5 (Slice B) + §6 risks and the **no-Thread**
> + **engine-untouched** invariants before the verdict.
>
> **PRD:** `docs/prd/cli-ux.md` (Slice B). **Research:** `docs/research/cli-ux-interactive-daemon.md`.
> **Baseline suite at freeze (`main` @ `d65c560`):** `rake test` **291/1068/0/0/0**,
> `standardrb` 0. **Runtime deps at freeze (8):** async, dry-cli, dry-monads,
> dry-schema, dry-struct, dry-types, dry-validation, xdg.

## Scope reminder (frozen)

Slice B is the **novel** part: a colorful, in-place, live progress renderer for
the concurrent `sync` sweep, driven entirely by **Async fibers — NO Ruby
Thread**. The engine event seam already exists from Slice A:
`Sync::Engine#call` already calls `@reporter.attach(task, total:)` (engine.rb:94),
`run_started`/`repo_started`/`repo_phase`/`repo_finished`/`repo_failed`/
`run_finished`, and `@reporter.detach` (engine.rb:126). **`sync/engine.rb` is
therefore MUST-NOT-TOUCH — re-touching the engine fails G7.** Slice B only adds
`UI::InteractiveReporter` (and, if the spike chooses it, a small `UI::Spinner`
frame helper) and selects it in `cli/sync.rb` when `mode.animate` is true.

`UI::Mode` is frozen from Slice A (MUST-NOT-TOUCH): use the readers it actually
exposes (`mode.color`, `mode.animate`, `mode.quiet`, `mode.format`) — do **not**
add predicate methods to it. (PHASE 0: confirm the real reader names against
`lib/repo_tender/ui/mode.rb`; the PRD's `mode.color?`/`mode.animate?` are
shorthand, not the actual API.)

The bars-vs-hand-rolled-lines decision is the PHASE-0 **spike** (PRD §5 Slice B /
§6, research OQ2 — "no prior art"). These gates assert the **behavior** (no
thread, fiber-child lifecycle, N independent indicators, clean ^C teardown,
color gated by Mode) and are judgeable **whichever** primitive the spike selects
(`tty-progressbar::Multi` advanced synchronously, OR a hand-rolled
`tty-cursor` + `pastel` multi-line renderer).

## How the architect measures these

The lane report (`docs/lanes/ui-interactive-01.md`) must include (a) the **spike
result** — what was tried, raw observations, the bars-vs-hand-rolled decision and
why; (b) the confirmed gem versions; (c) a **gate→test mapping table** (each gate
→ test file + test name). The architect (1) runs the suite + lint and reads
counts, (2) opens each named test and confirms it asserts the gate's behavior on
**real** resolved `Mode` values / **real** emitted events under the **real**
Async reactor / **real** captured writer output — never a hand-set stub of the
thing under test, (3) reads the diff against PRD intent + the no-Thread and
engine-untouched invariants.

All animation tests run with a **pseudo-TTY / injected StringIO writer** —
**never the real terminal in CI**. The real-terminal visual is M1 (human).

---

## G0 — Suite green & reproducible; exactly the 4 new gems, pinned & resolved [whole slice]

```bash
bundle install
bundle exec rake test
bundle exec standardrb
git diff <freeze>.. -- Gemfile Gemfile.lock repo-tender.gemspec
ruby -W:no-experimental -Ilib bin/repo-tender --help
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all 291
  baseline tests still passing** plus the new Slice-B tests, **failures = 0,
  errors = 0, skips = 0** (any intentional skip must be named in the report with a
  reason and is judged separately); `standardrb` exits 0; `bin/repo-tender --help`
  still exits 0 and lists the **same 5 command groups** as before.
- **New gems:** the gemspec adds **exactly these 4** runtime deps and no others —
  `pastel`, `tty-cursor`, `tty-screen`, `tty-progressbar` — each pinned with
  `~>` at a version confirmed current at build time, each **MIT**. `Gemfile.lock`
  resolves them and only their expected transitive deps (`tty-color`,
  `strings-ansi`, `unicode-display_width`). The `Gemfile` itself is unchanged
  (deps flow through the gemspec). No runtime dep beyond these 4 + their
  transitives appears in the diff.

## G1 — No Ruby Thread is spawned by the animation [new test, real reactor]

During an `InteractiveReporter`-driven engine run (≥3 concurrent fake/real-temp
repos) under the **real** Async reactor (`Sync{}`):

- **`Thread.list` is unchanged** from immediately before `attach` to immediately
  after `detach` (capture the baseline *after* the reactor is already running so
  Async's own reactor thread, if any, is in the baseline; assert no net thread is
  created across the attach→render→detach lifecycle).
- Static check passes: `grep -nE "Thread\.(new|start|fork)" lib/repo_tender/ui/interactive_reporter.rb lib/repo_tender/ui/spinner.rb` returns **nothing** (the file(s) that exist). The render loop suspends via `Kernel#sleep`/`task.sleep` inside a fiber (`task.async`), never `Thread.new`. (Mirrors Slice-6 G3 thread-accounting.)

## G2 — Render fiber is a child of the engine task, torn down by `detach` [new test]

- `attach(task, total:)` spawns the render loop via **`task.async`** (a child of
  the passed engine task), so it shares the one reactor with the worker fibers.
- After `detach`, the reporter holds **no live render fiber** (assert the stored
  task/fiber is nil, finished, or stopped). `detach` does the final repaint and
  restores the terminal (cursor shown, trailing newline).
- The render loop does **not** block the engine: a full `InteractiveReporter`
  engine run reaches `run_finished`/`detach` and returns `Success` (i.e.
  `barrier.wait` is not held open by the render fiber). The loop repaints at a
  **bounded cadence** (a sleep/`frequency:` interval between repaints), not a
  busy-loop — assert it suspends between repaints (e.g. via an injected
  sleep/clock seam or a repaint counter that stays bounded over a fixed run).

## G3 — N concurrent indicators advance independently; single-writer, no corruption [new test, injected writer]

With `concurrency: 3` and ≥3 fake/real-temp repos emitting staggered
`repo_started`/`repo_phase`/`repo_finished` through a **real engine run** (reuse
the Slice-2 real-temp-git seam or a faithful event driver), writing to an
**injected StringIO / pseudo-TTY**:

- the run ends with **all 3 repos shown complete**, and the captured output
  contains **3 distinct per-repo indicators** (one per ref) — no interleaved or
  garbled writes (the single reactor serializes fiber resumption → single-writer
  invariant). Assert each repo ref and its terminal state are present and the
  output segments are coherent (no torn mid-escape lines).
- indicators advance **synchronously on the render/caller fiber — no per-bar
  Thread** (ties to G1).
- **Either primitive satisfies this** (`tty-progressbar::Multi` advanced
  synchronously, or hand-rolled `tty-cursor`+`pastel` lines) — the spike's choice
  is recorded in the lane report; the gate judges the behavior, not the gem.

## G4 — Clean `^C` teardown: cursor restored, exit 130 un-regressed [new test + M1]

- **Deterministic interrupt test:** when the run is torn down while the render
  fiber is live (a worker action raises `Interrupt`, or the engine task is
  stopped mid-run), the **cursor-show / restore sequence is emitted** to the
  injected writer (the terminal is not left with a hidden cursor or a half-drawn
  line). Teardown must restore the terminal whether it fires via `detach` (happy
  path) **or** via the render fiber's own `ensure` under Async task cancellation
  (the interrupt path) — engine.rb is frozen, so the interrupt-path restore is
  expected to come from the fiber's `ensure`, not a new engine `detach` call.
  Assert the show-cursor escape (`tty-cursor`'s show, e.g. `\e[?25h`) appears on
  the unwind.
- **No leaked fiber/thread** after the interrupt unwind (ties G1/G2).
- **Exit-130 un-regressed:** the existing Slice-6 `interrupt_test.rb` cases still
  pass unchanged — a `^C` through `CLI.run` maps to `SystemExit` **130** with a
  single `interrupted` line and **no backtrace** (the `cli.rb:84` `rescue
  Interrupt` path is untouched).
- The real-terminal `^C` visual is **M1** (human, below).

## G5 — Color gated by `Mode`; reporter constructed only when `animate` [new tests]

- `InteractiveReporter` colorizes via `Pastel.new(enabled: <mode color reader>)`
  using `UI::Mode`'s **actual** reader (do not modify `mode.rb`). With color
  **off** (`mode.color == false` — e.g. `--no-color` on an interactive TTY, where
  `format == :pretty` and `animate == true` but color is forced off), the
  reporter still animates (cursor/progress movement allowed) but emits **no SGR
  color codes** (pastel passthrough). Assert: color-off output contains no color
  SGR sequence (e.g. no `\e[3Xm`/`\e[1m` color/style codes), while
  cursor-movement codes from `tty-cursor` are permitted.
- **Selection branch** in `cli/sync.rb` (assert on the resolved `Mode` + the
  constructed reporter class): `--json` → `JsonReporter`; else `mode.animate ==
  true` → `InteractiveReporter`; else → `PlainReporter`. Concretely: TTY + no
  flags (animate true) → `InteractiveReporter`; non-TTY or `--plain` →
  `PlainReporter`; `--json` → `JsonReporter`; `--quiet` or `CI=1` on a TTY
  (animate false) → `PlainReporter`. The `--repo` scoping, exit codes, and the
  `synced N repo(s)` summary line are **unchanged** vs Slice A.

## G6 — Gems vendor-reviewed (no Thread) + manual real-TTY smoke [whole slice + M1 human]

- **Vendor review (builder-reported, architect spot-checked):** each of the 4 new
  gems is confirmed to spawn **no Thread** by source-read —
  `grep -rnE "Thread\.(new|start)" $(bundle show pastel)/lib $(bundle show tty-cursor)/lib $(bundle show tty-screen)/lib $(bundle show tty-progressbar)/lib`
  returns nothing relevant (matches PRD §2's verified-by-source-read claim;
  `tty-progressbar` repaints synchronously on the caller, no animation thread).
  If `tty-spinner` is used (the `#spin` synchronous form only), it is reviewed the
  same way; `#auto_spin` is forbidden (it spawns a Thread).
- **M1 — manual real-TTY smoke (HUMAN-RUN, post-judgment, gates merge):** on a
  real interactive terminal, `bin/repo-tender sync` shows live, in-place, **color**
  progress — one indicator per concurrent repo, advancing and completing, torn
  down cleanly to the final `synced N repo(s)` summary on completion. A real
  `^C` mid-run restores the cursor, leaves **no** half-drawn line, prints
  `interrupted`, and exits **130**. (Like Slice 4's launchctl checklist / Slice 6
  M1–M3 — the human signs off before merge.)

## G7 — Only in-scope files; no builder commits; gates clean [architect-checked]

`git diff --name-only <freeze>..` shows changes **only** within the lane's
declared Builds+Extends set (below); **nothing** under `docs/gates/` changed
since the freeze; `git log <freeze>..` in the checkout has **no builder commits**;
no new gems beyond the 4 in G0. **`sync/engine.rb` is unchanged** (the event seam
is already wired) — any engine diff fails the slice. An out-of-bounds write or any
builder commit fails the slice.

### Lane file set (frozen)

**Builds (new):** `lib/repo_tender/ui/interactive_reporter.rb`; **optionally**
`lib/repo_tender/ui/spinner.rb` (create only if the spike's chosen design needs a
frame helper); test file(s) under `test/repo_tender/ui/`
(`interactive_reporter_test.rb`, optionally `spinner_test.rb`); the lane report
`docs/lanes/ui-interactive-01.md`.

**Extends (narrowly):** `repo-tender.gemspec` (add the 4 gems, `~>` pins);
`Gemfile.lock` (regenerated by `bundle install`); `lib/repo_tender/cli/sync.rb`
(`require "repo_tender/ui/interactive_reporter"` + the `mode.animate` selection
branch — **do not** change `--repo` scoping, exit codes, log rotation, or the
`synced N repo(s)` summary); `test/repo_tender/cli/sync_test.rb` (**additions
only** — the selection branch).

**MUST NOT TOUCH:** `lib/repo_tender/sync/engine.rb` (event seam already wired —
re-touching it fails this slice), `ui/mode.rb`, `ui/reporter.rb`,
`ui/plain_reporter.rb`, `ui/json_reporter.rb`, `cli.rb`, `cli/options.rb`,
`config/*`, `scm/*`, `forge/*`, `launchd/*`, `state/*`, `sync/repo_plan.rb`,
`cli/{repo,org,status,config,daemon}.rb`, `paths.rb`, `shell.rb`,
`log_rotator.rb`, `Gemfile`, `test_helper.rb`, all other existing test files,
anything under `docs/gates/`.

**OUT OF SCOPE (Slice C):** rolling `Mode`/`pastel` color + spinners into the
other commands (`repo`/`org`/`status`/`config`/`daemon`); the quick-op spinner
for `org add`/`org list`/`sync --repo`. Slice B is `sync`'s animated reporter
only.
