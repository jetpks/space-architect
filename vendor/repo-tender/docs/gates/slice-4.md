# Gates — Slice 4: launchd integration + daemon control (+ CF3)

> FROZEN before dispatch. Read-only for everyone including the builders — any
> edit to a file under `docs/gates/` fails the slice regardless of results.
> The architect runs the CI-gates (G0–G8) in a later session and compares output
> to the verbatim thresholds below. Gate-pass is necessary, not sufficient: the
> architect also reads the diff against PRD §3.2 / §5 Slice 4 / §7 DoD and the
> no-data-loss invariant (PRD §1).
>
> **Human decision (2026-06-13) governing this slice:** the launchctl-touching
> behavior is proven two ways — (a) **DI-unit gates** (G2–G4) assert the exact
> `launchctl` argv / parsing through an **injected command runner**, never a real
> `launchctl` call against the live `gui/$UID` domain or the real
> `~/Library/LaunchAgents`; and (b) a **manual real-Mac smoke checklist** (below)
> the human runs and signs off. No builder or architect session may run
> `launchctl bootstrap/bootout/kickstart` against the real user domain.

## Two lanes (disjoint file sets — verified non-overlapping)

**Lane 01 — launchd + daemon control + log rotation.**
- **Builds (new):** `lib/repo_tender/launchd/plist.rb`,
  `lib/repo_tender/launchd/agent.rb`, `lib/repo_tender/log_rotator.rb`,
  `lib/repo_tender/cli/daemon.rb`, a test file per new unit under
  `test/repo_tender/launchd/`, `test/repo_tender/log_rotator_test.rb`,
  `test/repo_tender/cli/daemon_test.rb`, and `docs/lanes/slice-4-01.md`.
- **Extends (narrowly):** `lib/repo_tender/paths.rb` (add `launch_agents_dir`,
  resolved from the env `HOME`, test-overridable — nothing else); `lib/repo_tender/cli.rb`
  (`require "repo_tender/cli/daemon"` only); `lib/repo_tender.rb` (requires for
  the new files); `lib/repo_tender/cli/sync.rb` (add a log-rotation pre-step at the
  top of `Run#call`; **do not** change the `--repo` scoping / engine-call logic —
  G4 of Slice 3 must stay green).
- **MUST NOT TOUCH:** `lib/repo_tender/state/store.rb`,
  `lib/repo_tender/sync/engine.rb` (Lane 02 owns both), `sync/repo_plan.rb`,
  `scm/*`, `forge/*`, `config/*`, `cli/{repo,org,status,config}.rb`,
  `test_helper.rb`, anything under `docs/gates/`.

**Lane 02 — CF3 state-schema fix (org-list failure resilience).**
- **Extends:** `lib/repo_tender/state/store.rb` (add `last_error` to the `Org`
  struct + `to_h_compact` + `build_state`); `lib/repo_tender/sync/engine.rb`
  (`expand_orgs` / `build_new_state` only — on an org-list `Failure`, preserve the
  prior good `repo_count` + `last_listed_at` and record a `last_error` instead of
  clobbering with `nil`/`0`).
- **Extends (tests):** `test/repo_tender/state/store_test.rb`,
  `test/repo_tender/sync/engine_test.rb`. Report → `docs/lanes/slice-4-02.md`.
- **MUST NOT TOUCH:** every Lane 01 file above, `forge/*`, `config/*`,
  `paths.rb`, `cli/*`, `test_helper.rb`, anything under `docs/gates/`.

Lane 01 and Lane 02 share **no** files. A merge conflict at integration = a spec
defect (kill + re-spec the conflicting lane).

---

## How the architect measures these

Each lane report (`docs/lanes/slice-4-0N.md`) must include a **gate→test mapping
table** (each gate → test file + test name). The architect (a) runs the suite on
the integration branch and reads counts, (b) opens each named test and confirms
it asserts the gate's behavior, (c) reads the diff against PRD intent. All
launchctl interaction in tests goes through an **injected runner double** that
records argv and returns canned output — assert on the recorded argv / parsed
result, never on a real `launchctl` invocation. Plist validity is checked with
the offline macOS tool `plutil -lint` (deterministic, no network, no daemon).

---

## G0 — Suite green & reproducible (regression + new) [integration; both lanes]

```bash
bundle install
bundle exec rake test
bundle exec standardrb
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all Slice
  1–3 tests still passing** plus the new Slice 4 tests, **failures = 0, errors =
  0, skips = 0** (any intentional skip must be named in the report with a reason
  and is judged separately); `standardrb` exits 0. **No new gem dependencies**
  (launchd plist is a hand-rolled XML emitter using stdlib only — no `plist`/
  `CFPropertyList` gem; consistent with the hand-rolled YAML emitter precedent in
  `AGENTS.md`). `ruby -Ilib bin/repo-tender --help` still exits 0 and now lists a
  `daemon` group among the command groups.

## G1 — `Launchd::Plist` emits a valid, correct launchd plist [Lane 01]

Build a plist for a sample config (label, abs `bin/repo-tender` path,
`refresh_interval` seconds, log dir) and assert:
- Writing the emitted XML to a temp file and running `plutil -lint <file>` exits
  **0** ("OK").
- The plist contains: `Label` (string); `ProgramArguments` = an **array** whose
  first element is an **absolute `mise` path**, followed by `exec`, `--`, the
  resolved Ruby (shim or `mise`-run), the **absolute** `bin/repo-tender` path, and
  `sync`; `StartInterval` = the integer `refresh_interval` in **seconds**;
  `RunAtLoad` = true; `ProcessType` = `Background`; `StandardOutPath` and
  `StandardErrorPath` = **absolute** paths under the log dir.
- **No `KeepAlive` key** is present.
- **mise resolution (PRD gate 4):** the plist pins the right toolchain
  non-interactively — `WorkingDirectory` set to an absolute repo path and/or
  `EnvironmentVariables` pinning `MISE_CONFIG_FILE` to the absolute `mise.toml`
  (state the chosen mechanism in the report; `mise activate` is **not** used).
- **No `~` or `$HOME`** appears literally in any path value — all paths are
  expanded to absolute. (Assert no value matches `/(^~|\$HOME)/`.)

## G2 — `Launchd::Agent` builds correct `launchctl` argv [Lane 01; injected runner]

Through an **injected command runner** (a fake that records argv and returns a
canned `Success`/`Failure` — **no real `launchctl`**), assert the exact argv for
each operation against the active `$UID` and `<label>`:
- install → `launchctl bootstrap gui/<UID> <abs-plist-path>`
- uninstall → `launchctl bootout gui/<UID>/<label>`
- start → bootstrap (+ `enable gui/<UID>/<label>`)
- stop → `bootout` (+ `disable`)
- restart → `launchctl kickstart -k gui/<UID>/<label>`
- A non-zero `launchctl` exit surfaces as a `Failure` (carrying argv + stderr),
  not a raise. Assert no real `launchctl` process was spawned (the fake runner is
  the only call path).

## G3 — `daemon install` / `uninstall` filesystem effect [Lane 01; temp HOME]

Against a **temp `HOME`** (injected via the CLI env seam) and the injected
runner:
- `daemon install` writes the plist to
  `<tempHOME>/Library/LaunchAgents/<label>.plist` — assert the file exists, is
  `plutil -lint`-valid, and its contents equal `Launchd::Plist`'s output — and
  calls the runner with the G2 `bootstrap` argv. **The real
  `~/Library/LaunchAgents` is never written** (assert the written path is under
  the temp HOME).
- `daemon uninstall` removes that file and calls the runner with the `bootout`
  argv. Idempotent uninstall (file already gone) exits 0 with a clear message,
  not an error.

## G4 — `daemon status` parses `launchctl` output defensively [Lane 01; canned fixture]

Feed a **canned `launchctl print`/`list` fixture string** (recorded sample, not a
live call) to the status parser and assert it extracts: loaded? (registered in
the domain), running? (has a PID), and last exit code. A malformed/empty/"could
not find" output yields a safe "not loaded / unknown" result — **not a raise**.
Prefer `launchctl list` columns for the machine-readable checks (PRD note:
`launchctl print` is "not API").

## G5 — Log rotation: the sync process rotates its own log [Lane 01; temp log dir]

`RepoTender::LogRotator` (or equivalent), against a **temp log dir** with an
**injected clock + size/age threshold** (deterministic):
- A log file **exceeding** the threshold is renamed to a **timestamped** archive
  (assert the archive filename embeds the injected timestamp) and the original
  path is freed for a fresh log — **the archived bytes equal the pre-rotation
  bytes** (no data loss).
- A log file **under** the threshold is left **byte-for-byte untouched**.
- Rotation is wired into the `sync` path (`cli/sync.rb`) as a pre-step and is a
  **no-op when there is no oversized log** (Slice 3 `sync` tests / G4 stay green —
  rotation must not redirect `out` or change sync's exit/scoping behavior).

## G6 — CF3 part 1: `State::Store::Org` carries `last_error` [Lane 02; real temp state]

Against a real temp `$XDG_STATE_HOME`:
- `Org.new(last_listed_at:, repo_count:, last_error: "msg")` round-trips through
  `State::Store.write` → `load` (real `state.yaml` on disk): reload yields an
  `Org` whose `last_error == "msg"`. `to_h_compact` emits `last_error` when
  present and **omits** it (via `.compact`) when `nil`. The existing `Org` fields
  (`last_listed_at`, `repo_count`) and all `Repo`/`State` behavior are unchanged
  (Slice 1/2 state tests still pass).

## G7 — CF3 part 2: an org-list `Failure` does not clobber prior good org state [Lane 02; engine + injected forge]

Against the engine with an **injected forge double** (reuse the Slice 2 engine
test seam) and a real temp state:
- Run 1: forge lists the org successfully → state `Org(repo_count: N>0,
  last_listed_at: <set>, last_error: nil)` and the discovered repos are recorded.
- Run 2 (same state as prior): forge returns a `Failure` for that org → the
  resulting state's `Org` for that key **retains** `repo_count == N` and the prior
  `last_listed_at` (**NOT** `0` / `nil`) and now carries a non-nil `last_error`.
  Previously-discovered **repos** remain present (the Slice 2 G10 no-data-loss
  invariant holds). The run does not abort; other repos still process.
- The existing Slice 2 G10 test (org-list Failure resilient) still passes.

## G8 — No out-of-scope files; lanes disjoint [architect-checked; both lanes]

`git diff --name-only <freeze>..<lane-branch>` for each lane shows changes **only**
within that lane's Builds+Extends set above; the two sets do not intersect;
nothing under `docs/gates/`; no builder commits (`git log <freeze>..` empty in
each worktree). (Architect-checked, not a test.)

---

## MANUAL real-Mac smoke checklist (HUMAN-RUN — not CI, not architect-run)

Per the 2026-06-13 human decision, the live `launchctl` path is verified by the
human on a real Mac and **signed off in the handoff** (the architect records the
sign-off; it does not run these). Verdict on this checklist = the human's
recorded result, not a gate command.

1. `repo-tender daemon install` → `launchctl print gui/$UID/<label>` shows the
   job loaded; the plist is at `~/Library/LaunchAgents/<label>.plist`.
2. `repo-tender daemon status` reflects loaded (and running/last-exit after a run).
3. `repo-tender daemon restart` (`kickstart -k`) triggers one sync pass now; the
   log file under `$XDG_STATE_HOME/repo-tender/logs/` grows.
4. `repo-tender daemon uninstall` → `launchctl print gui/$UID/<label>` reports it
   gone and the plist file is removed.
5. (Optional) leave it installed and confirm a `StartInterval`-triggered run
   fires after `refresh_interval`.

---

## PHASE-0 items the builders must rule on before coding

**Lane 01:**
- **Plist emission** — confirm no plist gem is pinned (there isn't); hand-roll the
  XML (stdlib) and validate with `plutil -lint`. Decide how `ProgramArguments`
  invokes Ruby via mise non-interactively (resolved shim path vs `mise exec --`)
  and how the right `mise.toml` is pinned (`WorkingDirectory` / `MISE_CONFIG_FILE`)
  — `mise activate` is broken non-interactively. Cite what you verified
  (`mise --version`, the resolved ruby/mise abs paths on this machine).
- **launchctl seam** — `Launchd::Agent` takes an **injected command runner**
  (default = the real `Shell`/`Open3` launchctl path; tests inject a recording
  fake). State the seam (constructor arg vs thread-local, mirroring the existing
  `CLI.env` / engine `url_builder` DI patterns). The daemon command must resolve
  `gui/$UID` from the env; `~/Library/LaunchAgents` must come from a
  `Paths#launch_agents_dir` that honors the injected env `HOME` so the G3 test
  writes only under a temp HOME.
- **Log rotation vs launchd redirect** — PRD §3.2 warns external rotation breaks
  the inherited redirect fd. Decide the mechanism (e.g. rotate-at-startup by size,
  letting launchd reopen `StandardOutPath` on the next spawn) and state why it
  does not corrupt the current run's fd. Keep the rotator a pure, unit-testable
  module over a temp dir (injected clock + threshold).

**Lane 02:**
- **Non-clobber point** — decide whether to thread `prev` state into `expand_orgs`
  or to fix the preserve-on-failure logic in `build_new_state`'s `prev.orgs.merge`
  (engine.rb:293). Either is acceptable; the constraint is: a transient org-list
  `Failure` must not reduce `repo_count`/`last_listed_at` below the prior good
  values, and must set `last_error`. Cite the exact lines you change and confirm
  the Slice 2 G10 test stays green.
