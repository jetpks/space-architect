# Gates — Slice 5: daemon polish (CF5 launchctl status-3 idempotency + CF6 env parse hardening)

> FROZEN before dispatch. Read-only for everyone including the builder — any edit
> to a file under `docs/gates/` fails the slice regardless of results. The
> architect runs these gates in a LATER (fresh) session and compares output to
> the verbatim thresholds. Gate-pass is necessary, not sufficient: the architect
> also reads the diff against the CF5/CF6 intent (HANDOFF carry-forward table) and
> the launchctl-argv-stability constraint below.
>
> **Scope:** two small, disjoint fixes carried forward from the Slice 4 manual
> checklist + adversarial review. CF5 = make `daemon stop`/`uninstall` idempotent
> when the agent is already not-loaded (launchctl `bootout` returns status 3 /
> "No such process"); today `stop` wrongly returns exit 1 and `uninstall` prints
> error noise. CF6 = a malformed `REPO_TENDER_LOG_MAX_BYTES` must not crash `sync`.
> **No live `launchctl` is needed or permitted** — the status-3 case is simulated
> through the injected runner seam, so this slice is fully CI-judgeable (unlike
> Slice 4, no manual real-Mac checklist gate).

## One lane (single combined lane, main checkout)

Per the repo's dispatch-mechanism lesson (`pi` worktree isolation does not hold;
HANDOFF decisions log 2026-06-13), this runs as ONE lane in the main checkout.
CF5 and CF6 file sets are disjoint but small; one builder does both.

- **Extends (CF5):** `lib/repo_tender/launchd/agent.rb` (map a benign `bootout`
  Failure to Success in `stop` + `uninstall`); `lib/repo_tender/cli/daemon.rb`
  (the `Stop`/`Uninstall` commands — remove the now-unnecessary error noise; rely
  on the Agent returning Success).
- **Extends (CF6):** `lib/repo_tender/cli/sync.rb` (`rotate_plist_logs` /
  threshold resolution — parse `REPO_TENDER_LOG_MAX_BYTES` defensively).
- **Extends (tests):** `test/repo_tender/launchd/agent_test.rb`,
  `test/repo_tender/cli/daemon_test.rb`, `test/repo_tender/cli/sync_test.rb`.
- **Report →** `docs/lanes/daemon-polish-01.md`.
- **MUST NOT TOUCH:** `lib/repo_tender/state/store.rb`,
  `lib/repo_tender/sync/engine.rb`, `lib/repo_tender/sync/repo_plan.rb`,
  `lib/repo_tender/launchd/plist.rb`, `lib/repo_tender/log_rotator.rb`,
  `lib/repo_tender/paths.rb`, `lib/repo_tender/cli.rb`, `lib/repo_tender.rb`,
  `scm/*`, `forge/*`, `config/*`, `cli/{repo,org,status,config}.rb`,
  `test/test_helper.rb`, any `test_helper.rb`, anything under `docs/gates/`.

## Launchctl-argv stability constraint (read before touching `agent.rb`)

The exact `launchctl` argv for every op is fixed by Slice 4 and MUST NOT change:
`install`→`bootstrap gui/<UID> <plist>`; `uninstall`/`stop`→`bootout
gui/<UID>/<label>` (stop then also `disable gui/<UID>/<label>`);
`start`→`bootstrap`+`enable`; `restart`→`kickstart -k`. This slice changes only
how a **bootout Failure** is *interpreted*, never the argv. All existing
`agent_test.rb` / `daemon_test.rb` argv assertions must stay green **unmodified**.

---

## G0 — Suite green & reproducible

```bash
bundle install
bundle exec rake test
bundle exec standardrb
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all
  existing tests still passing** plus the new CF5/CF6 tests, **failures = 0,
  errors = 0, skips = 0**; `standardrb` exits 0. **No new gem dependencies**
  (`git diff Gemfile Gemfile.lock` empty). `ruby -Ilib bin/repo-tender --help`
  still exits 0 and lists the `daemon` group.

## G1 — `daemon stop` is idempotent on an already-stopped agent [CF5; real Agent via runner seam]

The status-3 bootout Failure MUST enter through the **runner seam on a real
`Launchd::Agent`** (a `RecordingRunner` that returns
`Failure({argv:, stderr: "Boot-out failed: 3: No such process", status: 3})` for
the `bootout` call) — **NOT** a fully class-stubbed Agent whose `stop_result` is
hand-set to Success (that would assert a tautology and codify nothing, exactly
the G2-of-Slice-4 blind spot). Drive the real `Daemon::Stop` command (inject the
real Agent + RecordingRunner via the test's Agent factory seam) and assert:

- exit code **0**;
- a success line on stdout (e.g. `stopped: <label>`);
- **no error line** is written to stderr (the old behavior wrote a `stop failed:`
  line and exited 1).
- **Regression guard:** a `bootout` Failure with a NON-benign status (e.g.
  `status: 1, stderr: "Operation not permitted"`) still exits **1** with the
  failure surfaced on stderr — real failures are NOT swallowed.

## G2 — `daemon uninstall` is idempotent and quiet on an already-stopped agent [CF5; real Agent via runner seam]

Same seam (real Agent + RecordingRunner returning the status-3 `bootout`
Failure), against a **temp HOME** so the real `~/Library/LaunchAgents` is never
touched. Assert:

- `daemon uninstall` exits **0**;
- the plist under the temp HOME is removed (or, if already absent, a
  "not present" line — idempotent), and the removal happens regardless of the
  benign bootout;
- **no** `bootout reported:` error noise on stderr (today this line is printed on
  every uninstall of a not-running agent — the common case at a 6h interval).
- Idempotent re-uninstall (plist already gone) still exits 0.

## G3 — `Launchd::Agent` maps a benign bootout to Success; preserves real failures + install semantics [CF5; unit, RecordingRunner]

Through the `RecordingRunner` against the **real `Agent`**:

- `Agent#stop`: a `bootout` Failure whose `status == 3` **OR** whose `stderr`
  matches `/No such process|Could not find specified service/i` is treated as
  **Success** (idempotent). `disable` is STILL invoked after a benign bootout —
  assert the recorded argv sequence is `[["launchctl","bootout",…],
  ["launchctl","disable",…]]` and the overall result is Success.
- `Agent#uninstall`: the same benign `bootout` Failure returns **Success** (argv
  = the single `bootout` call).
- A `bootout` Failure with `status` ∉ {3} **and** a non-matching stderr (e.g.
  `status: 1, stderr: "Operation not permitted"`) still surfaces as **Failure**
  from both `stop` and `uninstall`.
- **Regression (install semantics unchanged):** `Agent#install` and `Agent#start`
  (the `bootstrap` paths) with a `status: 3` Failure STILL return **Failure** —
  the benign mapping is `bootout`-only. The existing
  `test_nonzero_exit_surfaces_as_failure_not_raise` (install, status 3) must stay
  green **unmodified**.

## G4 — `REPO_TENDER_LOG_MAX_BYTES` parse hardening [CF6]

The threshold-resolution path in `cli/sync.rb` must not raise on a malformed env
value (today `Integer(ENV[...] || DEFAULT)` raises `ArgumentError` and crashes the
whole `sync` run before any repo work).

- **Unit:** the threshold helper returns the **10 MiB default** for each of:
  unset, empty/whitespace, non-numeric (`"10MB"`, `"abc"`), and non-positive
  (`"0"`, `"-5"`) values; and returns the parsed integer for a valid positive
  value (`"1048576"` → `1048576`). **No `ArgumentError` escapes** for any input.
- **Integration:** a `sync` run (reuse the existing `with_engine_home_2_repos` /
  `invoke_command(Sync::Run)` harness) with `REPO_TENDER_LOG_MAX_BYTES="10MB"`
  set exits **0** and writes state for both repos — i.e. the malformed value no
  longer crashes sync. Restore the env var in an `ensure`.
- A parse fallback MAY warn to stderr; if it does, the warning must not change the
  exit code and must not appear in the no-oversized-log happy path.

## G5 — No out-of-scope files; no builder commits [architect-checked]

`git diff --name-only <freeze>..<branch>` shows changes **only** within the lane's
Extends set above; nothing under `docs/gates/`; `git log <freeze>..` empty (no
builder commits). (Architect-checked, not a test.)

---

## PHASE-0 items the builder must rule on before coding

- **Benign-bootout predicate (CF5):** confirm against `launchctl` help / `man
  launchctl` (no live bootout needed) that a not-loaded `bootout` returns the
  status / stderr you key on. Decide the exact predicate (`status == 3` OR the
  stderr regex — recommend BOTH as an OR, defensive against status drift). Decide
  whether `stop` still runs `disable` after a benign bootout (recommended: yes —
  `disable` sets the persistent override and keeps `stop` meaning "stay stopped").
  State the helper's name/location (e.g. a private `benign_bootout(result)` in
  `Agent`).
- **CF5 daemon-command cleanup:** with the Agent now returning Success on a benign
  bootout, the `Uninstall` command's `if result.failure? … "bootout reported:"`
  branch becomes dead for the common case — decide whether to drop it or keep it
  for genuinely-failed bootouts. Keep `uninstall` exit 0 + plist removal intact
  (Slice 4 G3).
- **CF6 threshold seam:** decide where the parse lives (a small private helper in
  `Sync::Run`, e.g. `log_max_bytes`) and whether to read `ENV` directly (as the
  daemon's `Resolve` helpers already do) or via the `CLI.env` seam. Keep
  `LogRotator`'s injected-`threshold_bytes:` contract (Slice 4 G5) untouched — the
  hardening is only at the caller that computes the threshold.
