# Gates — CLI-UX Slice B CORRECTIVE: `ui-interactive-compact`

> FROZEN before dispatch. Read-only for everyone including the builder — any edit
> to a file under `docs/gates/` fails the slice. The architect re-runs these in a
> later session (rule 4) against the verbatim thresholds.
>
> **Why this exists:** M1 (human real-TTY smoke of `slice/ui-interactive`) surfaced
> two defects the headless gates couldn't: (1) on ~400+ repos the per-repo-line
> renderer floods scrollback and the in-place redraw breaks (`TTY::Cursor.up(n)`
> can't move above the top of the viewport, so every repaint re-emits all N lines
> and the terminal scrolls); (2) output "sits then flies out at once." This
> corrective lane replaces the per-repo-line model with a **compact** display.
>
> **Relationship to `docs/gates/ui-interactive.md`:** this file **SUPERSEDES G3**
> ("N concurrent indicators / 3 distinct lines") of that gate. The following carry
> UNCHANGED and must stay green: **G0** (suite/lint/gems — note now **3** gems,
> not 4, per the logged dep-drop ruling), **G1** (no Ruby Thread), **G2** (render
> fiber is a child of the engine task + `detach` teardown), **G4** (clean `^C`
> cursor-restore + Slice-6 exit-130), **G5** (color gated by `Mode` + `cli/sync.rb`
> selection), **G7** (file scope; `sync/engine.rb` unchanged; no builder commits).
>
> **Corrective freeze base:** `slice/ui-interactive` @ `<FREEZE2>` (recorded by the
> architect at dispatch). **Baseline at freeze:** `rake test` **309/1105/0/0/0**,
> `standardrb` 0, **3** runtime-dep additions (pastel, tty-cursor, tty-screen).

## Chosen display contract (frozen, human ruling 2026-06-14)

- **One live status line**, rewritten in place (`\r` + clear-to-EOL `\e[K`, **single
  line** — never a multi-line cursor-up block): a spinner frame + `X/total`
  progress (X = repos finished) + running tallies (at minimum: clean / non-clean /
  failed counts).
- **Persistent scrollback lines for NON-CLEAN repos only**, emitted once as each
  occurs, ABOVE the live line: `⚠ <ref>  <status>` for dirty/diverged/wrong-branch/
  detached; `✗ <ref>  <error>` for failed/error. **Clean repos produce NO
  persistent line** — they only increment the tally.
- **One final summary line** at `detach`.

## How the architect measures these

Lane report `docs/lanes/ui-interactive-compact-01.md` must include: the PHASE-0
empirical real-sync observation (GC3); a gate→test mapping table; verbatim
`bundle`/`rake test`/`standardrb` output; `git diff --name-only <FREEZE2>..`; and
proof `sync/engine.rb` is unchanged. The architect re-runs the suite, opens each
named test (assert on real emitted output to an injected StringIO under the real
reactor — never a hand-set stub of the renderer), and reads the diff.

All animation tests use an **injected StringIO / pseudo-TTY** — never the real
terminal in CI. Real-terminal behavior is M1 (human).

---

## GC1 — Bounded output: total lines do NOT scale with the clean count [new unit]

Drive a real engine run (Slice-2 real-temp-git seam or a faithful event driver)
writing to an injected `StringIO`, over a mix such as **{many clean, several
non-clean, a couple failed}** (e.g. 50 clean + 3 dirty + 1 diverged + 1
wrong_branch + 2 failed):

- a **clean** repo produces **zero** persistent (`\n`-terminated) log lines;
- each **non-clean** terminal status (dirty / diverged / wrong_branch / detached)
  and each **failed/error** repo produces **exactly one** persistent log line
  containing the repo ref + its status (⚠) or error (✗);
- plus at most a small constant of framing lines (the final summary; an optional
  header).
- **Independence assertion (the anti-flood gate):** a run with **50 clean + 7
  non-clean** and a run with **5 clean + 7 non-clean** emit the **same** number of
  persistent log lines. Persistent-line count == (non-clean + failed) + constant,
  **independent of clean count**.
- **Single-line live region:** the renderer must **not** emit `TTY::Cursor.up(k)`
  (i.e. `\e[<k>A`) with `k` that grows with the repo count; the live line is
  rewritten on one line via `\r` + `\e[K`. Assert the captured output contains no
  cursor-up whose argument scales with N (a fixed `up(1)`/`up(0)` for the single
  line is fine; growing-N cursor-up fails).

## GC2 — Live counter, correct tallies, correct persistent set [new unit]

Over a mixed run to an injected `StringIO`:

- the **live status line** carries a spinner frame, `X/total` (X = finished
  count), and running tallies (≥ clean / non-clean / failed). At completion the
  tallies **equal** the engine's `run_finished` summary / the state rows
  (Slice-A G3 parity: status counts match the real `state.yaml`).
- **persistent lines == exactly the non-clean+failed refs**, each with the correct
  status text (`dirty`/`diverged`/`wrong-branch`/`detached`) or error message;
  **no** persistent line for any clean ref.
- a **final summary line** is emitted at `detach`.

## GC3 — Live tick: the counter advances DURING the run, not only at detach [new unit + PHASE-0 empirical + M1]

- **Deterministic:** with a `SlowSCM` that yields the reactor (mirror
  `engine_test.rb`'s SlowSCM) over **≥4 repos at concurrency ≥2**, capture the
  sequence of live-line frames written to the StringIO and assert the progress
  count `X` takes **intermediate values** — `X` is observed `> 0` and `< total` in
  at least one frame **before** the final `detach` frame. This proves the render
  loop repaints with partial progress (ticks during the run) rather than jumping
  `0 → total` only at teardown.
- **PHASE-0 empirical (builder, recorded RAW — must NOT be silently skipped):**
  run a **real `bin/repo-tender sync` on ≥50 real repos** (or a faithful real-git
  repro) and report whether the live counter advances smoothly during the run and
  output stays bounded. **If the counter does NOT advance live even with the
  compact single-line display** (still updates only at the end), that indicates the
  render fiber is starved by the git workers (the reactor not yielding during
  subprocess waits). **RECORD it as a BLOCKED finding / disagreement with the
  evidence; do NOT touch the subprocess layer (`shell.rb`/`scm/*`) to fix it
  (out of scope) — escalate to the architect.** The render-side compact rewrite is
  in scope; a reactor-scheduling fix is a separate slice.
- **M1 (human, post-judgment, gates merge):** on a real TTY over the operator's
  full repo set, the live counter advances **smoothly during the run**, total
  output never exceeds ~one screen + the non-clean lines, the non-clean repos are
  individually visible, and `^C` restores the cursor + exits **130**.

## Carried gates (from `docs/gates/ui-interactive.md`, must stay green)

- **G0** — `bundle install` 0; `rake test` 0 fail/err/skip (baseline 309 + updated
  tests); `standardrb` 0; **no NEW gems** beyond the 3 already on the branch
  (pastel, tty-cursor, tty-screen — gemspec/lock diff vs `<FREEZE2>` empty);
  `bin/repo-tender --help` exit 0, 5 groups.
- **G1** — `Thread.list` unchanged across attach→detach on a ≥3-repo real-reactor
  run; no `Thread.new`/`start` in the new code.
- **G2** — render fiber spawned via `task.async` (child of the engine task), no
  live fiber after `detach`, does not block `barrier.wait`, bounded repaint cadence.
- **G4** — `^C` mid-run: cursor-restore emitted via the render fiber's `ensure`
  (engine.rb frozen); no leaked fiber/thread; Slice-6 `interrupt_test.rb` exit-130
  cases pass unchanged.
- **G5** — `Pastel.new(enabled: mode.color)`; color-off → no SGR color codes
  (still animates); `cli/sync.rb` builds `InteractiveReporter` only when
  `mode.animate`; `--repo`/exit-codes/`synced N repo(s)` summary unchanged.
- **G7** — changes only within the lane set below; `sync/engine.rb` **byte-
  unchanged**; `git log <FREEZE2>..` no builder commits; no new gems.

### Lane file set (frozen)

**MAY TOUCH:**
- `lib/repo_tender/ui/interactive_reporter.rb` (rewrite the render model: tally
  state + single live line + non-clean persistent lines)
- `test/repo_tender/ui/interactive_reporter_test.rb` (rewrite/extend for GC1–GC3 +
  the carried gates)
- `lib/repo_tender/ui/spinner.rb` + `test/repo_tender/ui/spinner_test.rb` (only if
  the design needs a frame helper)
- `lib/repo_tender/cli/sync.rb` — **only if** the `InteractiveReporter` constructor
  signature changes (e.g. injecting terminal width / cadence); the
  `mode.animate → InteractiveReporter` selection is already correct. Keep `--repo`,
  exit codes, log rotation, and the `synced N repo(s)` summary unchanged.
- `test/repo_tender/cli/sync_test.rb` (additions only, if the constructor changed)
- `docs/lanes/ui-interactive-compact-01.md` (the report)

**MUST NOT TOUCH:** `lib/repo_tender/sync/engine.rb` (event seam frozen — any diff
fails), `lib/repo_tender/shell.rb`, `scm/*` (the subprocess layer — see GC3
escalation), `ui/{mode,reporter,plain_reporter,json_reporter}.rb`, `cli.rb`,
`cli/options.rb`, the other command files, `config/*`, `forge/*`, `launchd/*`,
`state/*`, `sync/repo_plan.rb`, `paths.rb`, `log_rotator.rb`, `repo-tender.gemspec`,
`Gemfile`, `Gemfile.lock` (the 3 gems are already correct — **no new gems**),
`test_helper.rb`, all other tests, anything under `docs/gates/`.
