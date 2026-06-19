# Gates — Slice 3: CLI surface + config CRUD (+ CF1 duration parsing)

> FROZEN before dispatch. Read-only for everyone including the builder — any
> edit to a file under `docs/gates/` fails the slice regardless of results.
> The architect runs these commands in a later session and compares output to
> the verbatim thresholds below. Gate-pass is necessary, not sufficient: the
> architect also reads the diff against PRD §3.1 / §3.3 / §5 Slice 3 intent and
> the no-data-loss invariant (PRD §1 — the CLI must never mutate a dirty/diverged
> repo; it only delegates to the already-judged Sync::Engine for that).

**Builds (new):**
`lib/repo_tender/cli.rb` (Dry::CLI::Registry),
`lib/repo_tender/cli/repo.rb`, `lib/repo_tender/cli/org.rb`,
`lib/repo_tender/cli/sync.rb`, `lib/repo_tender/cli/status.rb`,
`lib/repo_tender/cli/config.rb`,
`bin/repo-tender` (executable entrypoint),
`lib/repo_tender/config/duration.rb` (CF1 — string→seconds parser),
plus a test file per new unit (`test/repo_tender/cli/*_test.rb`,
`test/repo_tender/config/duration_test.rb`) and the lane report
`docs/lanes/slice-3-01.md`.

**Extends (existing Slice 1 files — edits in scope for this single lane):**
- `lib/repo_tender/config/store.rb` — normalize `refresh_interval` through the
  new duration parser **at load time, before contract validation** (CF1). The
  contract + model stay integer-typed (refresh_interval is integer seconds
  internally); only the load path gains string tolerance.
- `lib/repo_tender.rb` — add the new `require`s.
- `repo-tender.gemspec` — register the executable (`bindir`/`executables` and
  add `bin/**` to `spec.files`) so `gem install` exposes `repo-tender`. **Only**
  those lines; do not touch dependencies (no new gems — `dry-cli ~> 1.4` is
  already pinned).

**Out of scope / MUST NOT TOUCH:** `sync/engine.rb`, `sync/repo_plan.rb`
(the CLI *uses* the engine via its existing `call(config:, paths:)` signature —
`--repo` scoping is done by the CLI building a filtered Config, NOT by changing
the engine), `state/store.rb` (the `status` command *reads* `State::Store.load`;
CF3 — adding `Org#last_error` — is deferred to a later slice and is NOT in this
slice), `scm/*`, `forge/*`, `paths.rb`, `config/model.rb`, `config/contract.rb`
(refresh_interval stays integer-typed; CF1 is a load-layer normalization, not a
schema change), `test_helper.rb`.

---

## How the architect measures these

The lane report `docs/lanes/slice-3-01.md` must include a **gate→test mapping
table** (each gate → test file + test name). The architect then (a) runs the
suite command below and reads counts, (b) opens each named test and confirms it
asserts the gate's behavior. CRUD-persistence gates (G1–G3, G6, G8) must assert
against a **real on-disk config.yaml under a temp `$XDG_CONFIG_HOME`** (reuse the
Slice 1 `with_temp_home` / `with_paths` helpers — do NOT mock `Config::Store`).
G4 (sync) must run against **real temp git repos + a local bare remote** (reuse
`with_trunk_repo` / `seed_initial_commit`); an injected SCM/forge double on the
*engine's collaborators* is allowed only for a non-network scoping assertion, not
to mock the engine itself. G5/G7 assert on captured CLI stdout/stderr.

Exit-code semantics (G3) are a PHASE-0 design choice (see below) — whatever seam
is chosen, the gate must be provable: either an in-process injected exit/return
seam asserted directly, or one subprocess invocation of `bin/repo-tender` that
asserts the real process exit status. State the choice in the report.

## G0 — Suite green & reproducible (regression + new)

```bash
bundle install
bundle exec rake test
bundle exec standardrb
```

- **Threshold:** `bundle install` exits 0; `rake test` exits 0 with **all Slice 1
  + Slice 2 tests still passing** plus the new Slice 3 tests, **failures = 0,
  errors = 0, skips = 0** (any intentional skip must be named in the report with
  a reason and is judged separately); `standardrb` exits 0. **No new gem
  dependencies** (`dry-cli ~> 1.4` is already in the gemspec/lockfile). The
  executable runs: `ruby -Ilib bin/repo-tender --help` (or `version`) exits 0 and
  prints usage listing the command groups.

## G1 — `repo` CRUD persists to validated config.yaml

Against a real temp `$XDG_CONFIG_HOME`:
- `repo add github.com/ruby/ruby` (accept both `host/owner/name` and an
  `--host/--owner/--name` form — builder's choice; state which) → the entry is
  **validated then written** to `config.yaml`; reloading the file yields a
  `RepoRef(github.com, ruby, ruby)`.
- `repo list` prints the tracked repo(s).
- `repo remove github.com/ruby/ruby` deletes the entry; reload shows it gone.
- **Idempotent add:** adding the same repo twice does **not** create a duplicate
  (reload shows exactly one entry) and exits 0 with a clear "already tracked"
  message — not an error.

## G2 — `org` CRUD persists to validated config.yaml

Against a real temp `$XDG_CONFIG_HOME`:
- `org add github.com/socketry` → validated + written; reload yields an
  `OrgRef`. `org list` prints it. `org remove github.com/socketry` deletes it.
  `include_archived` / `include_forks` flags (if accepted) round-trip.

## G3 — Invalid input → nonzero exit + Failure-derived stderr + config untouched

- `repo add not-a-ref` (un-parseable identity) → **nonzero exit**, a stderr
  message derived from the `Failure` (names the problem), and the config file is
  **byte-for-byte unchanged** (assert the file's bytes/mtime are identical, or
  that it was never created if absent). The same holds for an `org add` with a
  malformed identity.

## G4 — `sync` invokes the engine; `--repo` scopes to one repo

Against real temp git repos + a local bare remote, with a config tracking ≥2
repos:
- `sync` (no args) invokes `Sync::Engine#call(config:, paths:)` over the full
  config and writes `state.yaml` (assert a state row exists for each tracked
  repo afterward).
- `sync --repo github.com/ruby/ruby` processes **only** that repo — assert the
  other tracked repo gets **no** new/changed state row this run (scoping is done
  by the CLI passing the engine a Config filtered to the one repo + empty orgs;
  the engine is unchanged). At least one assertion must prove the non-targeted
  repo was not processed.

## G5 — `status` renders a per-repo evergreen table

Seed a real `state.yaml` (via `State::Store.write`) with ≥2 repos of differing
status → `status` reads `State::Store.load` and prints a table whose rows include
each repo key with its **status**, **last_synced_at**, and **default_branch**.
Assert the captured stdout contains each repo key and its status string.

## G6 — `config path` / `config show`

- `config path` prints the resolved config file path (matches
  `Paths#config_file` under the active XDG env).
- `config show` prints the **effective** config — validated, with defaults
  applied (so `concurrency: 8`, `refresh_interval: 21600`, `base_dir` default
  appear even for an empty/absent config file). Assert the output reflects
  defaults for an empty config.

## G7 — Nested subcommand registration

- `repo add …` dispatches to the add command; `org remove …` to org-remove, etc.
  (`Dry::CLI` nested `register` with block sub-registration).
- `repo` with no subcommand prints the `repo` group help/usage (lists
  `add`/`remove`/`list`) and exits 0 (or dry-cli's documented help behavior).
- Unknown command (`repo frobnicate`) → nonzero exit with a usage/error message.

## G8 — CF1: human-duration `refresh_interval` parses at the config-load layer

`Config::Duration` (or equivalent) parses, **at `Config::Store.load` time before
contract validation**:
- `"6h"` → `21600`, `"90m"` → `5400`, `"45s"` → `45`, a bare integer `21600`
  → `21600`, a bare numeric string `"21600"` → `21600`.
- An invalid duration (`"6x"`, `""`, `"-3h"`) → the load returns a **`Failure`**
  with a field-level message for `refresh_interval` (not a raise, not a silent
  default). 
- **Proof:** a `Config::Duration` unit test for each case **and** an integration
  assertion that a `config.yaml` containing `refresh_interval: 6h` loads to a
  `Config` whose `refresh_interval == 21600` (and that `config show` displays
  `21600`). Per the disagreement-#1 MODIFY ruling, durations must parse at the
  load layer, not only at CLI input — so the gate is proven by writing the string
  into the file and loading it, not by passing it through a CLI flag.

## G9 — No out-of-scope files

`git status` / `git diff --name-only` after the run shows changes **only** within
the Builds + Extends sets above — nothing under `sync/`, `state/store.rb`,
`scm/`, `forge/`, `paths.rb`, `config/model.rb`, `config/contract.rb`, or
`test_helper.rb`. (Architect-checked, not a test.)

---

## PHASE-0 items the builder must rule on before coding

- **dry-cli API** — verify the installed `dry-cli` (~> 1.4) API for nested
  subcommand registration (`register "repo" do … register "add", … end` vs the
  flat `register "repo add", Cmd` form), option/argument declaration
  (`argument`/`option`), and how `call(**)` receives parsed args. Build against
  what the installed gem actually exposes; cite the gem source path you read.
- **Exit-code seam** — `dry-cli` does not manage process exit codes for command
  failures. Decide and state the seam: commands return/raise a Result that
  `bin/repo-tender` translates to `exit 0/1` (preferred — testable in-process and
  via subprocess), vs commands calling `Kernel.exit` directly. The gate (G3/G7)
  must be provable either way.
- **`--repo` scoping** — confirm scoping is implemented by the CLI constructing a
  filtered `Config` (e.g. `Config::Store.with(config, repos: [match], orgs: [])`)
  and calling the **unchanged** engine, NOT by adding a parameter to
  `Sync::Engine#call`. If you believe the engine must change, raise it as a
  disagreement with a cited reason — do not silently edit `sync/engine.rb`.
- **CF1 normalization point** — confirm the duration string→seconds conversion
  happens in `Config::Store.load` **before** `Contract#call` (which still
  validates `:integer, gt?: 0`), so the contract and model are untouched. The
  write-back path emits integer seconds (human strings are not preserved on
  rewrite — consistent with the documented YAML comment-loss limitation; note
  this in the report).
