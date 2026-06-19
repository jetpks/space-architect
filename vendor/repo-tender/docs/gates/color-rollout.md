# Gates — CLI-UX Slice C: `color-rollout` (Mode + pastel color across every command)

> FROZEN before dispatch. Read-only for everyone including the builder — any
> edit to a file under `docs/gates/` fails the slice regardless of results.
> The architect re-runs RC0–RC6 in a later session (rule 4: never judged by the
> session that dispatched) and compares output to the verbatim thresholds here.
> Gate-pass is necessary, not sufficient: the architect also reads the diff
> against `docs/prd/cli-ux.md` §5 (Slice C) and the **byte-compatible `:plain`**
> + **`mode.rb`/reporters/engine untouched** invariants before the verdict.
>
> **PRD:** `docs/prd/cli-ux.md` (Slice C). **Baseline suite at freeze (`main`):**
> `rake test` **338/1213/0/0/0**, `standardrb` 0. **Runtime deps at freeze (3
> tty/color):** pastel, tty-cursor, tty-screen.

## Scope reminder (frozen)

Slice C is the **final, mechanical** CLI-UX slice: roll the already-built
`UI::Mode` + `pastel` color into the **non-sync** commands —
`repo` (add/remove/list), `org` (add/remove/list), `status`, `config`
(path/show), `daemon` (install/uninstall/start/stop/restart/status). Color is
gated by `UI::Mode` exactly as `sync` does it (`Pastel.new(enabled: mode.color)`,
resolved via `UI::Mode.resolve(flags:, env: CLI.env, out: out)`).

**NO SPINNER / NO ANIMATION in this slice (architect ruling 2026-06-14, human
confirmed).** The PRD's "spinner for network quick-ops (org add/list via gh,
sync --repo)" is **dropped as moot**: `org add`/`org list` are pure local
`config.yaml` operations (they do **not** call `gh` — the `gh list_org` network
call lives in `sync`/`Engine#expand_orgs`), `repo`/`config`/`daemon` are all
local, and `sync --repo` already animates via the Slice-B `InteractiveReporter`.
No op needs a new spinner. This slice adds **color only**.

**Also folded in (human ruling 2026-06-14): drop the dead `tty-screen` dep.**
`tty-screen` is declared in the gemspec but unused (zero refs in `lib`/`test`/`bin`
— the width require was removed in the compact rewrite). Remove it → **2** tty
gems (pastel, tty-cursor). This is the ONLY permitted gemspec/Gemfile.lock change.

**`UI::Mode` is frozen (Slice A) — MUST NOT TOUCH `ui/mode.rb`.** Use its real
readers (`mode.color`, `mode.format`, `mode.quiet`); the color decision is
`mode.color` (already encodes `--no-color` > `CLICOLOR_FORCE` > `NO_COLOR`/
`TERM=dumb`/non-`:pretty`/non-TTY). The reporters (`ui/{reporter,plain_reporter,
json_reporter,interactive_reporter}.rb`), `sync/engine.rb`, and `cli/sync.rb` are
DONE in Slices A/B — **MUST NOT TOUCH** them.

## How the architect measures these

The lane report (`docs/lanes/color-rollout-01.md`) must include: (a) the PHASE-0
plan + EVERY disagreement (e.g. shared-helper-vs-per-command Pastel; which flag
surface the non-sync commands expose; whether/how stderr errors are styled);
(b) a **gate→test mapping table** (each gate → test file + test name);
(c) verbatim `bundle install` / `rake test` / `standardrb` / `--help` output;
(d) `git diff --name-only <freeze>..` and proof `ui/mode.rb`, the reporters,
`sync/engine.rb`, and `cli/sync.rb` are byte-unchanged. The architect re-runs
the suite, opens each named test (assert on **real** command output captured to
an injected `StringIO`, with the `:pretty`/color path driven by a TTY-reporting
out double + `CLICOLOR_FORCE` through the real `UI::Mode.resolve` — never a
hand-set color flag bypassing `Mode`), and reads the diff against the byte-compat
invariant.

All color tests use an **injected `StringIO` / out double** — never the real
terminal. "Has color" = the captured output contains an SGR sequence matching
`/\e\[[0-9;]*m/`; "no color" = it contains **none**.

---

## RC0 — Suite green & reproducible; tty-screen dropped (3→2 gems), no other gem change [whole slice]

```bash
bundle install
bundle exec rake test
bundle exec standardrb
git diff <freeze>.. -- repo-tender.gemspec Gemfile.lock
ruby -W:no-experimental -Ilib bin/repo-tender --help
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all 338
  baseline tests still passing** plus the new Slice-C color tests, **failures = 0,
  errors = 0, skips = 0** (any intentional skip named in the report + judged
  separately); `standardrb` exits 0; `bin/repo-tender --help` exits 0 and lists
  the **same command groups** as baseline (config, daemon, org, repo, status,
  sync).
- **Gems:** the **only** dependency change is **removing** `tty-screen` from the
  gemspec → **2** tty/color runtime deps remain (`pastel`, `tty-cursor`). The
  `Gemfile.lock` diff removes `tty-screen` (and any now-orphaned transitive) and
  changes **nothing else** (`pastel`/`tty-cursor`/`tty-color`/`unicode-*` lines
  unchanged). **No gem is added.**

## RC1 — Every targeted command honors `Mode`: color in `:pretty`, none otherwise [new tests, injected out]

For **each** command — `repo add`/`remove`/`list`, `org add`/`remove`/`list`,
`status`, `config path`/`show`, `daemon status` (+ at least one daemon action
via the injected agent/runner seam) — driven in-process with a captured
`StringIO`:

- **Color ON** (a TTY-reporting out double + `CLICOLOR_FORCE` in the injected
  env, so `UI::Mode.resolve` yields `color: true`, `format: :pretty`): the
  command's **stdout** contains at least one SGR sequence (`/\e\[[0-9;]*m/`).
- **Color OFF** — assert **no** SGR sequence (`/\e\[[0-9;]*m/` absent) under
  **each** of: `--no-color`; `NO_COLOR=1` (non-empty env); a non-TTY out
  (`out.tty? == false`, the default in-process path); `--plain`.
- Color is produced via `Pastel.new(enabled: mode.color)` with `mode` from the
  real `UI::Mode.resolve` (`ui/mode.rb` unmodified — assert it is byte-unchanged
  in RC6).

## RC2 — `status` byte-identical in `:plain`; colored only in `:pretty` [new + existing tests]

- **`:plain` / non-TTY (default in-process):** `status` stdout is **byte-identical**
  to the pre-slice output — the existing `test/repo_tender/cli/status_test.rb`
  assertions (tab-separated `REPO\tSTATUS\t…` header + one row per repo key, no
  ANSI) **pass unchanged**.
- **`:pretty` (color on):** the per-repo **STATUS cell** is colorized (a sensible
  mapping, builder's call, e.g. `clean`→green, `dirty`/`diverged`/`wrong_branch`/
  `detached`→yellow, `error`→red), but **stripping the SGR sequences reproduces
  the exact `:plain` bytes** (same keys, same status strings, same tab structure,
  same sort order). Assert: `pretty_output.gsub(/\e\[[0-9;]*m/, "")` == the
  `:plain` output for the same state.

## RC3 — Confirmations colorized in `:pretty`, unchanged in `:plain` [new tests]

For the human confirmation lines on **stdout** (`added:`, `removed:`,
`already tracked:` for repo/org; `installed:`/`removed plist:`/`started:`/
`stopped:`/`restarted:` and the `label:/loaded:/running:/pid:/last_exit:` block
for daemon; the path/YAML for config; the list lines for repo/org list):

- **`:pretty`:** colorized (at least the success confirmations carry color).
- **`:plain` / non-TTY:** **byte-identical** to the pre-slice text (no ANSI),
  i.e. stripping SGR from the `:pretty` line reproduces the `:plain` line.
- **Error lines** (the `fail_with` / `err.puts` paths — "invalid … reference",
  "not tracked", "failed to update config", "bootout reported", "… failed") go to
  **stderr** and are **OUT OF SCOPE for coloring** here: they must stay on stderr
  with their **exact existing text** (existing error tests stay green). The
  builder MAY color them only if gated on `err.tty?` (a PHASE-0 disagreement to
  raise) — but the existing stderr-text assertions must remain byte-exact when
  not a TTY.

## RC4 — Existing command tests stay green, unmodified [regression — the byte-compat gate]

`test/repo_tender/cli/{repo,org,status,config,daemon}_test.rb` and
`config_test.rb`/`org_test.rb` etc. **all pass UNCHANGED** — no existing assertion
edited to accommodate color (changes to these files are **additive only**: new
color tests appended; existing test bodies byte-identical). These run in-process
with a `StringIO` out → non-TTY → `:plain` → `color: false` → no ANSI, which is
exactly the byte-compat contract. The architect diffs these test files against
`<freeze>` and confirms only **additions** (no deletions/edits to existing
`test_*` bodies).

## RC5 — `Mode` resolved per command via the frozen Slice-A seam; styles `out` [new tests]

- Each targeted command resolves output mode via
  `UI::Mode.resolve(flags: {...}, env: CLI.env, out: out)` (the frozen Slice-A
  API; `ui/mode.rb` unmodified). The color decision gates on **`out`** (the
  stdout stream actually styled) — not stderr, not a global (PRD §6: stdout and
  stderr are independently TTY-or-not).
- Flag precedence comes through `Mode` unchanged: `--no-color` → off;
  `CLICOLOR_FORCE` (TTY) → on; `NO_COLOR` (non-empty) → off; non-TTY → off.
  Assert via the real `Mode.resolve` with an injected env + out double (the
  command must NOT re-implement color precedence — it reads `mode.color`).

## RC6 — File scope; no builder commits; mode.rb/reporters/engine/sync untouched [architect-checked]

`git diff --name-only <freeze>..` shows changes **only** within the lane set
below; `git log <freeze>..` has **no builder commits**; the **only** gemspec/lock
change is the `tty-screen` drop (RC0); **nothing** under `docs/gates/` changed
since the freeze. These files are **byte-unchanged** (`git diff <freeze>.. --`
empty): `lib/repo_tender/ui/mode.rb`, `ui/reporter.rb`, `ui/plain_reporter.rb`,
`ui/json_reporter.rb`, `ui/interactive_reporter.rb`, `lib/repo_tender/sync/engine.rb`,
`lib/repo_tender/cli/sync.rb`. An out-of-bounds write or any builder commit fails
the slice.

### Lane file set (frozen) — ONE lane

**MAY TOUCH:**
- `lib/repo_tender/cli/repo.rb`, `org.rb`, `status.rb`, `config.rb`, `daemon.rb`
  (resolve `Mode` + apply `pastel` color to stdout human output)
- `lib/repo_tender/cli/options.rb` (**only if** the design adds/uses a
  color-only flag mixin or reuses `GlobalOptions`; additive only — do not change
  the existing `GlobalOptions` flags `sync` depends on)
- a small shared color helper **only if** the design needs one:
  `lib/repo_tender/ui/palette.rb` (+ `test/repo_tender/ui/palette_test.rb`) —
  the DRY home for "style a confirmation / status cell given a `Mode`". Builder's
  PHASE-0 call: shared helper vs per-command `Pastel.new`.
- `repo-tender.gemspec` + `Gemfile.lock` — **the `tty-screen` drop ONLY** (RC0)
- tests: `test/repo_tender/cli/{repo,org,status,config,daemon}_test.rb` +
  `config_test.rb`/`org_test.rb` (**additions only** — existing bodies unchanged,
  RC4), `test/repo_tender/cli/options_test.rb` (only if the mixin changed)
- `docs/lanes/color-rollout-01.md` (the report)

**MUST NOT TOUCH:** `lib/repo_tender/ui/mode.rb` (frozen Slice-A),
`ui/reporter.rb`, `ui/plain_reporter.rb`, `ui/json_reporter.rb`,
`ui/interactive_reporter.rb`, `lib/repo_tender/cli/sync.rb` (Slice B — done),
`cli.rb`, `sync/engine.rb`, `sync/repo_plan.rb`, `forge/*`, `scm/*`, `state/*`,
`config/*` (the store; the CLI command files above are the only config-touching
code), `launchd/*`, `paths.rb`, `shell.rb`, `log_rotator.rb`, `Gemfile`,
`test_helper.rb`, all other existing test files, anything under `docs/gates/`.

**OUT OF SCOPE:** any spinner/animation (dropped — see scope reminder); coloring
`sync`'s own output (Slice B's domain); structured `--json` output for the
non-sync commands (they are not event streams — `--json`/`--plain` may exist via
the mixin but only affect color/format gating, not a new JSON schema); changing
`UI::Mode` precedence or adding `Mode` readers.
