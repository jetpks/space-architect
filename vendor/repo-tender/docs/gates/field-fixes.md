# Gates — Slice 6: field-fixes (SSH transport · ^C hygiene · binstub warning)

> FROZEN before dispatch. Read-only for everyone including the builder — any edit
> to a file under `docs/gates/` fails the slice regardless of results. The
> architect runs these gates in a LATER (fresh) session and compares output to
> the verbatim thresholds. Gate-pass is necessary, not sufficient: the architect
> also reads the diff against the intent below and runs the manual checklist.
>
> **Why this slice exists:** the project was PRD-complete, but the FIRST real
> `repo-tender sync` on a clean machine surfaced three field defects this slice
> closes:
> 1. **HTTPS transport** — `Sync::Engine::DEFAULT_URL_BUILDER` builds
>    `https://github.com/<owner>/<name>.git`, so `git clone` of a missing repo
>    prompts `Username for 'https://github.com':`. We require SSH transport
>    (key-based, no interactive prompt). This realizes the url_builder seam the
>    Slice 2 disagreement-#6 ruling already anticipated ("legit future seam
>    (ssh/token)").
> 2. **^C dumps stack traces** — SIGINT during a clone (e.g. at the username
>    prompt, or any long fetch) kills the `git` child; `Open3.capture3`'s internal
>    reader threads then raise `IOError: stream closed in another thread` and,
>    because `Thread.report_on_exception` is on, print multi-line backtraces; and
>    there is no top-level `Interrupt` rescue, so the main thread also dumps a
>    trace. A user ^C-ing a CLI must get a clean exit, not a stack dump.
> 3. **io-event experimental warning** — already fixed by the human in
>    `bin/repo-tender` (shebang `-W:no-experimental`, which RubyGems propagates
>    into the installed binstub on macOS — architect-verified). This slice just
>    carries that change into a judged commit.

## Intent / scope guard (read before coding)

- **SSH default only — no new config field.** Switching the default transport to
  SSH is in scope. Adding a configurable `transport:`/`url_template:` config key,
  token auth, or an `ssh://` vs scp-like toggle is **OUT of scope** — a future
  slice if wanted. Keep the change to the one default builder.
- **Do not weaken error reporting.** The ^C fix must silence *interrupt* noise
  only. A genuine non-interrupt failure (a real bug, a non-zero git exit) must
  still surface through the existing `Result`/exit-code/`last_error` paths exactly
  as today. In particular, do NOT blanket-rescue `StandardError` at the
  entrypoint, and do NOT suppress real failures by making everything exit 0.
- **No-data-loss invariant (PRD §1) still holds.** A ^C mid-run must not corrupt
  on-disk state. `State::Store.write` is already atomic (temp-write + rename); the
  interrupt handling must not introduce a partial write. If the handler exits hard
  (e.g. `exit!`), justify that it cannot land between the temp-write and the
  rename (PHASE 0).

## One lane (single lane, main checkout)

Per the repo's dispatch-mechanism lesson (`pi` worktree isolation does not hold;
HANDOFF decisions log 2026-06-13), this runs as ONE lane in the main checkout.

- **Extends (transport):** `lib/repo_tender/sync/engine.rb` —
  `DEFAULT_URL_BUILDER` only.
- **Extends (^C hygiene):** `bin/repo-tender` and/or `lib/repo_tender/cli.rb`
  (top-level `Interrupt` rescue → clean exit), and/or `lib/repo_tender/shell.rb`
  (suppress the Open3 reader-thread report). The exact seam(s) are a PHASE-0
  decision; you may touch any subset of these three files, no others.
- **Carry (binstub):** `bin/repo-tender` already has the `-W:no-experimental`
  shebang (uncommitted in the working tree at freeze). Preserve it; the architect
  commits it as part of this slice. Do not revert it.
- **Extends (tests):** `test/repo_tender/sync/engine_test.rb`,
  `test/repo_tender/cli/sync_test.rb`, `test/repo_tender/cli/test_helper.rb`
  (only if you need a new spawn/seam helper), `test/repo_tender/shell_test.rb`,
  and you MAY add `test/repo_tender/cli/interrupt_test.rb` (new file) for the
  signal behavior.
- **Report →** `docs/lanes/field-fixes-01.md`.
- **MUST NOT TOUCH:** everything else, including `lib/repo_tender/scm/*`,
  `lib/repo_tender/forge/*`, `lib/repo_tender/config/*`,
  `lib/repo_tender/state/*`, `lib/repo_tender/launchd/*`,
  `lib/repo_tender/sync/repo_plan.rb`, `lib/repo_tender/paths.rb`,
  `lib/repo_tender/log_rotator.rb`, `lib/repo_tender/cli/{repo,org,status,config,daemon}.rb`,
  `lib/repo_tender.rb`, `lib/repo_tender/version.rb`, the gemspec, `test/test_helper.rb`,
  any other `test_helper.rb`, and anything under `docs/gates/`.

---

## G0 — Suite green & reproducible

```bash
bundle install
bundle exec rake test
bundle exec standardrb
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all
  existing tests still passing** plus the new tests, **failures = 0, errors = 0,
  skips = 0**; `standardrb` exits 0. **No new gem dependencies**
  (`git diff Gemfile Gemfile.lock` empty). `ruby -W:no-experimental -Ilib
  bin/repo-tender --help` still exits 0 and lists the command groups.

## G1 — Default transport is SSH, not HTTPS [transport; unit]

```bash
bundle exec ruby -Ilib -e '
  require "repo_tender/sync/engine"
  RepoRef = Struct.new(:host, :owner, :name, keyword_init: true)
  ref = RepoRef.new(host: "github.com", owner: "foo", name: "bar")
  puts RepoTender::Sync::Engine::DEFAULT_URL_BUILDER.call(ref)
'
```

- **Threshold:** prints exactly `git@github.com:foo/bar.git` (scp-like SSH form:
  `git@<host>:<owner>/<name>.git`). The output MUST start with `git@` and MUST
  NOT contain `https://` or `Username`.
- **Unit test** in `engine_test.rb`: assert `DEFAULT_URL_BUILDER.call(ref)`
  equals `git@github.com:foo/bar.git` for a ref with host/owner/name, and a
  second host (e.g. a GHE-style host) interpolates correctly. Assert the result
  contains no `https`.
- **Regression:** the existing G6 missing-path clone test (engine_test.rb ~L488,
  which injects `url_builder = ->(_r) { "file://#{bare}" }`) must stay green
  **unmodified** — the injection seam is unchanged; only the default flips.

## G2 — A `^C` (Interrupt) produces a clean exit, never a backtrace [^C hygiene; deterministic automated]

There MUST be a deterministic, automated test (not the manual checklist) that
proves the **main-thread** interrupt path is clean. Drive an `Interrupt` raised
from inside command dispatch through the real `CLI.run` entrypoint (choose the
seam in PHASE 0 — e.g. a throwaway registered command that raises `Interrupt`, or
the existing `run_cli` subprocess helper that `SIGINT`s the spawned
`bin/repo-tender`). Assert:

- the process exits with code **130** (128 + SIGINT, the conventional value) —
  NOT 0 (an interrupt is not success) and NOT 1;
- **at most one** human-readable line is written to stderr (e.g. `interrupted`);
  an empty stderr is also acceptable;
- stderr contains **none** of: a multi-line Ruby backtrace, the substring
  `report_on_exception`, `open3.rb`, `(IOError)`, or
  `stream closed in another thread`.

A NON-interrupt failure path must be untouched: include/keep a test showing a
genuine command failure (e.g. `sync` with an invalid `--repo` reference, or any
existing failing-command test) still exits **1** and still writes its real error
to stderr — the interrupt handling does not swallow real errors.

## G3 — Open3 reader-thread noise on subprocess death is suppressed [^C hygiene; best-effort automated + manual]

When the spawned child dies while `Open3.capture3` reader threads are mid-read
(the SIGINT-at-clone scenario), no thread-exception backtrace may reach the
terminal.

- **Best-effort automated:** if you can construct a *deterministic, bounded*
  (hard-timeout) test that triggers a reader-thread `IOError` and asserts the
  process's stderr contains no `report_on_exception` / `stream closed in another
  thread`, add it. If you determine this cannot be made deterministic offline,
  state that in your report with the exact reason and rely on the manual checklist
  item M2 below — do NOT add a flaky/sleep-racy test. Gate verdicts are
  architect-run; an honest "covered by manual" is acceptable here.
- **Mechanism justification (PHASE 0, required):** state exactly how you suppress
  the reader-thread report and prove it is *targeted*. If you use a process-wide
  `Thread.report_on_exception = false`, you MUST first establish (and record) that
  this app spawns no worker threads of its own whose crashes you would be hiding
  — the Async engine uses fibers, and the only threads are Open3's internal reader
  threads. If you scope it more narrowly, describe the scope.

## Manual checklist (HUMAN-RUN — frozen here, the human executes on the judged branch)

These three behaviors are interactive/live and cannot be fully proven offline
(the Slice 4 lesson: DI/offline gates missed real runtime bugs the live checklist
caught). The architect records the human's sign-off in the HANDOFF.

- **M1 (SSH no prompt):** with SSH keys configured for GitHub, run
  `repo-tender sync` against a config containing one not-yet-cloned GitHub repo.
  Expected: it clones over SSH (`git@github.com:...`) and does **NOT** print
  `Username for 'https://github.com':`.
- **M2 (clean ^C):** run a `repo-tender sync` that is mid-clone/mid-fetch (or sits
  at any git prompt) and press `Ctrl-C`. Expected: a single clean line (or
  nothing) + prompt returns; exit status `130` (`echo $status` in fish);
  **ZERO** Ruby backtraces and **no** `... terminated with exception
  (report_on_exception is true)` / `stream closed in another thread` lines.
- **M3 (no warning):** run the installed `repo-tender version` (and `repo-tender
  --help`). Expected: clean output, exit 0, and **no** io-event experimental
  feature warning. (Architect pre-verified the binstub shebang propagation;
  human confirms on the merged binary.)

## G4 — No out-of-scope files; no builder commits [architect-checked]

`git diff --name-only <freeze>..<branch>` shows changes **only** within the
Extends/Carry sets above; nothing under `docs/gates/`; `git log <freeze>..` empty
(no builder commits). (Architect-checked, not a test.)

---

## PHASE-0 items the builder must rule on before coding

- **SSH URL form:** confirm the scp-like form `git@<host>:<owner>/<name>.git` is
  the right default for GitHub (it is the form `gh` and git docs use for SSH
  remotes and the one that uses the user's SSH keys with no username prompt).
  Note whether `ssh://git@<host>/<owner>/<name>.git` would behave identically;
  pick one and justify (recommend the scp-like form — it is the GitHub default).
- **Interrupt seam:** decide where the top-level `Interrupt` rescue lives
  (`CLI.run` is the testable seam; `bin/repo-tender` is the outermost frame). Note
  that `CLI.run` calls `Kernel.exit` already — ensure the rescue wraps the
  `Dry::CLI` dispatch and maps `Interrupt`/`SystemExit(SIGINT)` to exit 130 with a
  clean message, while top-level help/version (which also call `Kernel.exit`) are
  not affected.
- **Open3 thread-noise suppression:** decide the mechanism (see G3). Verify
  against the live behavior (reproduce the `IOError: stream closed in another
  thread` once, then confirm your fix silences it). Establish there are no
  app-owned threads before any process-wide `Thread.report_on_exception` change.
- **Atomicity (PHASE 0):** confirm your interrupt handling cannot corrupt
  `state.yaml` (the write is atomic temp+rename; an interrupt either lands before
  the rename — old state intact — or after — new state intact). If you use a hard
  exit, prove the window is safe.
