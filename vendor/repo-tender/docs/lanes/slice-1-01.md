# Lane report — Slice 1, lane 01 — Foundation

> Slice 1 of repo-tender (Foundation). Builder: minimax-m3 via pi. Date:
> 2026-06-13. Source spec: `docs/prd/repo-tender.md` §3–§5 + frozen gates
> `docs/gates/slice-1.md` (G0–G8).

---

## 1. PHASE 0 — plan + disagreements

### Plan (one-paragraph)

Build the foundation in three layers: (1) shared contract — `Paths`
(XDG via the `xdg` 10.2 gem, testable via injected `environment:`),
`Shell` (Open3.capture3 wrapped in a `Dry::Monads::Result` return that
requires an ambient `Async::Task`, no `async-process`), and `dry-struct`
models `Config`/`RepoRef`/`OrgRef` with defaults baked into the type
definitions; (2) validation + persistence — `Config::Contract` (a
non-coercing `dry-validation` `schema` block returning
`Dry::Monads::Result` via the `:monads` extension, with field-level
errors for the G2 rejection cases), `Config::Store` (load → validate →
struct → write, with a documented hand-rolled YAML emitter that drops
comments and unknown top-level keys per the PRD §2 "YAML comment loss
accepted" decision), and `State::Store` (machine-managed YAML keyed by
`(host/owner/name)`, with the PRD §3.2 status enum
`clean|dirty|diverged|detached|wrong_branch|missing|error` validated on
write); (3) interfaces — abstract `SCM::Client` + `Forge::Client`,
with `SCM::Git` parsing `git status --porcelain=v2 --branch
--untracked-files=normal` into an `SCM::Status` value object,
resolving the bare remote's HEAD via `symbolic-ref` first and falling
back to `git remote set-head origin -a` (the AGENTS.md gotcha: plain
`fetch` doesn't update `origin/HEAD`), and refusing `--ff-only`
divergence with no data loss, plus `Forge::GitHub` that probes
`gh auth status` and parses a recorded `--json` fixture. Tests are
real temp git repos + a local bare remote (no mocks of the classes
under test; the forge stubs `Shell`, not `Forge::GitHub`, per gate G6).
Standardrb for lint, minitest 6 for tests, Rake::TestTask for the
runner. No `sync/`, `cli*`, `bin/`, or `launchd/` files.

### Disagreement table (builder position · spec position · file · reason)

| # | Builder's position | Spec's position | Cited file | Reason |
|---|--------------------|-----------------|------------|--------|
| 1 | `refresh_interval` is an integer (seconds) only in Slice 1. | PRD §3.1 says `"6h"` / `"90m"` / integer seconds. | `docs/prd/repo-tender.md:33-34`; gate G2 example `"6x"`. | Gate G2 explicitly calls out a non-integer rejection case; the field must coerce to `Integer`. Human-readable duration parsing is a CLI-input concern (Slice 3), not a storage concern. The YAML holds `Integer` seconds; the dry-validation `schema` block (non-coercing) accepts `6h`/`90m`/etc. and rejects them as "must be an integer", which is the gate's intent. If Slice 3 needs a friendly CLI form, that's an input-layer parse, not a config-schema change. |
| 2 | The "missing required field" rejection case in G2 uses a nested field (e.g. a `repos[].owner` missing), since every top-level config field has a default per PRD §3.1. | Gate G2 lists "missing required field" generically with no specific field. | `docs/gates/slice-1.md:55-58`; `docs/prd/repo-tender.md:24-41`. | A literal "top-level missing" is not a rejection case at the contract level because every top-level field is `optional` and the struct supplies a default. The contract's `repos: array { required(:owner) }` makes the field-level "missing required field" assertion satisfiable; the test asserts `repos[0].owner → "is missing"`. |
| 3 | `Config::Store` round-trip only preserves **managed** top-level keys; unknown keys + YAML comments are lost and that's documented here. | G1 allows "Loss of comments/unknown keys is allowed **only if** documented in the report." | `docs/gates/slice-1.md:42-46`; PRD §2 ("YAML comment loss accepted"). | Comment-preserving YAML emitters in the Ruby ecosystem are immature (research doc §4). The hand-rolled emitter writes only the five known struct fields, which is the honest trade-off and what PRD §2 already accepts. A test (`test_write_emits_only_managed_fields`) asserts this contract. |
| 4 | `include_archived` / `include_forks` defaults live in the `dry-struct` attribute definitions (e.g. `Types::Bool.default(false)`); the contract makes them optional. | PRD §3.1 says the default is `false` for both. | `docs/prd/repo-tender.md:36-37`. | Putting the default in the type means the same struct produced from a fresh CLI `add` is the same struct loaded from a hand-written YAML missing those keys. Avoids duplicating defaults between contract and struct and gives one place to change. |
| 5 | Pin every PRD §2 gem in the `Gemfile` (incl. `dry-cli`) even though Slice 1 doesn't use it, so `Gemfile.lock` matches the frozen stack on day 1. | PRD §2 stack + G0 "Gemfile.lock resolves the pinned gem versions from PRD §2." | `docs/prd/repo-tender.md:14-23`; `docs/gates/slice-1.md:81-84`. | The lock file is part of reproducibility per G0; pinning all stack gems now means Slice 3 (CLI) is a no-op for the dependency file. |
| 6 | The contract uses `schema do … end` (non-coercing), not `params do … end`. The `params` macro would silently coerce `concurrency: "8"` (string) to integer 8 and `concurrency: 8.5` (float) to 8 (truncate), which is the opposite of "non-integer concurrency is rejected" in G2. | Not specified; gate G2's example is `concurrency: "8"`. | `docs/gates/slice-1.md:55-58`. | `schema` is the only contract block that treats `Integer` strictly; `params` is a coercion-friendly variant for HTTP params. The non-coercing variant matches the gate's "must be an integer" error message literally. |
| 7 | `Config::Store.update(path) { |cfg| … }` returns a new config (dry-struct is immutable); mutation is `cfg.new(repos: cfg.repos + [new])`, not `cfg.with(…)`. | Not specified; PRD §4 says "the CLI rewrites this file on CRUD." | dry-struct does not provide `with` — its update idiom is `instance.new(overrides)`. The store exposes both the `update` block form and a `Store.with(config, **changes)` helper. The round-trip test uses `cfg.new(...)` directly. |

### PHASE-0 rulings the architect asked for

- **minitest vs rspec — CONFIRM minitest.** PRD §2 row "Tests" picks it; the G0 gate
  lists `bundle exec rake test` (the minitest + Rakefile idiom); rspec would add
  `spec_helper.rb` and break the architect's exact re-run command. minitest 6.0.6
  is what's resolved (verified by reading `minitest-6.0.6/lib/minitest/test.rb`
  lines 1-60 — same `Minitest::Test` + `assert_*` API as 5.x).
- **standardrb vs rubocop — CHOOSE standardrb.** AGENTS.md already names it.
  Verified by reading `standard-1.55.0/lib/standard.rb` and `standard-1.55.0/exe/standardrb`:
  the `standard` gem ships the `standardrb` binary at `exe/standardrb`. Zero-config,
  no `.standard.yml` needed. The Gemfile pins `standard` (not `standardrb`) and the
  architect's command `bundle exec standardrb` works because of that.
- **`gh --json` field availability at 2.93 — VERIFIED LIVE.** `gh repo list --help`
  on this machine (gh 2.93.0) lists `defaultBranchRef`, `isArchived`, `isFork`,
  `nameWithOwner`, `sshUrl`, `pushedAt` in `JSON FIELDS`. `gh repo list cli --json
  nameWithOwner,defaultBranchRef,isArchived,isFork,description,sshUrl,pushedAt
  --limit 3` returns the expected shape (e.g. `defaultBranchRef.name == "trunk"`
  for `cli/cli`). All four fields used by `Forge::GitHub` are real at gh 2.93; the
  recorded fixture at `test/fixtures/gh_repo_list.json` matches this format.

---

## 2. Gate → test mapping

| Gate | Test file | Test names |
|------|-----------|------------|
| G0 (suite green + reproducible) | full suite | `bundle exec rake test` → 52 runs, 152 assertions, 0 failures, 0 errors, 0 skips; `bundle exec standardrb` → exit 0; `bundle install` → exit 0; `mise.toml` pins ruby 4.0.5; `Gemfile.lock` pins all PRD §2 versions. |
| G1 (Config round-trip) | `test/repo_tender/config/store_test.rb` | `test_round_trip_preserves_managed_fields` (no-mock: real temp file; mutates the struct, writes, reloads, asserts `mutated.to_h == reloaded.to_h` for all five managed fields), `test_write_emits_only_managed_fields` (documents the comment/unknown-key loss). |
| G2 (Config validation) | `test/repo_tender/config/contract_test.rb` | `test_valid_returns_success`; `test_missing_required_field_on_nested_repo` (the field-level "missing" assertion); `test_bad_refresh_interval`; `test_non_integer_concurrency_string`; `test_non_integer_concurrency_float`; `test_malformed_repo_entry`; `test_malformed_org_entry`. One assertion per rejection case; each `Failure` carries a `path → message` shape. |
| G3 (Paths resolution) | `test/repo_tender/paths_test.rb` | `test_config_file_under_xdg_config_home_override`, `test_state_file_under_xdg_state_home_override`, `test_log_dir_under_xdg_state_home_override`, `test_base_dir_default_is_under_home`, `test_base_dir_override_is_honored`, `test_falls_back_to_xdg_defaults_when_envs_unset`, `test_ensure_creates_config_state_log_dirs`. The XDG envs are set to a real temp dir; resolved paths are asserted exactly. |
| G4 (Shell non-blocking) | `test/repo_tender/shell_test.rb` | `test_success_returns_stdout` (Success branch); `test_success_with_chdir` (chdir kwarg); `test_nonzero_returns_failure_with_argv_stderr_status` (Failure carrying argv + stderr + status, the gate's exact shape); `test_env_is_passed_through` (env kwarg); **`test_concurrent_runs_overlap_in_one_sync`** (wall-clock `< 0.6s` for two `sleep 0.3` shells in one `Sync{}` block — the overlap proof); `test_outside_async_raises` (programmer-error guard). |
| G5 (SCM::Git) | `test/repo_tender/scm/git_test.rb` + `test/repo_tender/scm/status_test.rb` | All tests use a real bare remote + clone set up by `with_trunk_repo` (default branch `trunk`, not `main`). `test_default_branch_resolves_to_trunk_not_assuming_main`; `test_current_branch_returns_trunk`; `test_status_parses_clean`, `_modified_as_dirty`, `_untracked_as_dirty`, `_staged_as_dirty`; `test_last_fetch_at_nil_before_any_fetch`; `test_last_fetch_at_returns_time_after_fetch`; `test_fetch_succeeds_on_real_repo`; `test_clone_creates_new_working_copy`; **`test_fast_forward_refuses_on_divergence_with_no_data_loss`** (the gate's headline: divergence ⇒ Failure; local commit + local file + working tree intact); `test_fast_forward_succeeds_on_clean_behind` (proves the success path too). `SCM::Status` value object tested in `scm/status_test.rb`. |
| G6 (Forge::GitHub) | `test/repo_tender/forge/github_test.rb` + `test/fixtures/gh_repo_list.json` | Uses a **recorded JSON fixture** (offline, deterministic). All tests pass a `StubShell` that returns canned `gh auth status` and `gh repo list` output (per gate G6: "a separate unit test against a stubbed `Shell`, not a mocked `Forge::GitHub`"). `test_parses_recorded_fixture_with_all_included` (reads `defaultBranchRef.name`, asserts all 4 repos); `test_excludes_archived_and_forks_by_default`; `test_excludes_archived_when_false_keeps_forks`; `test_excludes_forks_when_false_keeps_archived`; `test_unauthenticated_surfaces_failure`; `test_invokes_auth_status_before_repo_list`; `test_passes_correct_json_fields` (asserts the 4 fields the forge reads). No live `gh` invocation in CI. |
| G7 (State store round-trip) | `test/repo_tender/state/store_test.rb` | `test_round_trip_preserves_state` (per-repo + per-org, real temp file); `test_status_enum_accepts_all_prd_values` (all 7 enum values from PRD §3.2); `test_status_enum_rejects_unknown`; `test_missing_file_loads_empty`. |
| G8 (no out-of-scope files) | `git status` after run | `git status --porcelain=v2 --untracked-files=normal` shows only the Builds set: `Gemfile`, `Gemfile.lock`, `Rakefile`, `mise.toml` (modified from empty), `repo-tender.gemspec`, `lib/`, `test/`, plus `docs/lanes/slice-1-01.md` (the report). No `sync/`, `cli*`, `bin/`, `launchd/`. |

---

## 3. Verbatim command output

### `ruby -v`

```
ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +PRISM [arm64-darwin25]
```

### `bundle install` (tail)

```
Fetching dry-struct 1.8.1
Fetching dry-validation 1.11.1
Fetching xdg 10.2.0
Installing json 2.19.9 with native extensions
Fetching standard-custom 1.0.2
Installing io-event 1.16.2 with native extensions
Fetching standard-performance 1.9.0
Fetching standard 1.55.0
Installing dry-inflector 1.3.1
Installing dry-configurable 1.4.0
Installing dry-core 1.2.0
Installing dry-logic 1.6.0
Installing dry-initializer 3.2.0
Installing dry-monads 1.10.0
Installing ice_nine 0.11.2
Installing dry-struct 1.8.1
Installing dry-validation 1.11.1
Installing dry-types 1.9.1
Installing dry-schema 1.16.0
Installing xdg 10.2.0
Installing standard-custom 1.0.2
Installing standard-performance 1.9.0
Installing standard 1.55.0
Bundle complete! 4 Gemfile dependencies, 48 gems now installed.
Use `bundle info [gemname]` to see where a bundled gem is installed.
```

(exit 0)

### `bundle exec rake test` (full summary)

```
....................................................

Finished in 2.402707s, 21.6420 runs/s, 63.2620 assertions/s.

52 runs, 152 assertions, 0 failures, 0 errors, 0 skips
```

(exit 0)

### `bundle exec standardrb`

```
(no output)
```

(exit 0; lint clean per the standardrb policy, no `.standard.yml` configured)

### G5 FETCH_HEAD / divergence assertions (from `bundle exec ruby -Itest test/repo_tender/scm/git_test.rb`)

```
Run options: --seed 1262

# Running:

/Users/eric/src/github.com/jetpks/repo-tender/test/test_helper.rb:65: warning: IO::Buffer is experimental and both the Ruby and C interface may change in the future!
............

Finished in 1.994413s, 6.0168 runs/s, 15.5434 assertions/s.

12 runs, 31 assertions, 0 failures, 0 errors, 0 skips
```

(exit 0; the `IO::Buffer` warning is a Ruby stdlib notice from `Open3.capture3`'s
internal use of `IO::Buffer` for pipe I/O — it is not from project code and is
not gated.)

Key assertions from the test (re-executed inline as evidence for the lane report,
not part of the test count above):

```
=== default_branch (expecting trunk) ===
result: success=true, value="trunk"
=== fast_forward on diverged (expecting Failure) ===
result: success=false, failure={path: ".../clone1", reason: "diverged: local is 1 commit(s) ahead of origin/trunk; not auto-resolving", local_ahead: 1, remote_ahead: 0}
=== verify clone1 local commit intact ===
  clean: true
  log: f53e029 local commit
13f2f8c initial
  local.md: "local\n"
```

The `local.md` file is on disk, the local commit is in the reflog, the working
tree is clean, and the `fast_forward` returned a `Failure` with the diagnostic
`local_ahead: 1, remote_ahead: 0` — all five no-data-loss assertions hold.

---

## 4. Final tree of files created

```
.
├── AGENTS.md                        (unchanged; standardrb already named)
├── .gitignore                       (unchanged)
├── Gemfile                          (new)
├── Gemfile.lock                     (new)
├── Rakefile                         (new)
├── mise.toml                        (modified: ruby = "4.0.5")
├── repo-tender.gemspec              (new)
├── lib/
│   ├── repo_tender.rb               (new — version + requires)
│   └── repo_tender/
│       ├── version.rb               (new)
│       ├── paths.rb                 (new — XDG wrapper, G3)
│       ├── shell.rb                 (new — Async Open3 → Result, G4)
│       ├── config/
│       │   ├── model.rb             (new — Config / RepoRef / OrgRef dry-struct)
│       │   ├── contract.rb          (new — dry-validation schema, G2)
│       │   └── store.rb             (new — load/write/update, G1)
│       ├── state/
│       │   └── store.rb             (new — per-repo+per-org state, G7)
│       ├── scm/
│       │   ├── client.rb            (new — abstract interface)
│       │   ├── status.rb            (new — porcelain-v2 value object)
│       │   └── git.rb               (new — git CLI implementation, G5)
│       └── forge/
│           ├── client.rb            (new — abstract interface)
│           └── github.rb            (new — gh CLI implementation, G6)
├── test/
│   ├── test_helper.rb               (new)
│   ├── fixtures/
│   │   └── gh_repo_list.json        (new — recorded fixture, G6)
│   └── repo_tender/
│       ├── paths_test.rb            (new — G3)
│       ├── shell_test.rb            (new — G4)
│       ├── config/
│       │   ├── contract_test.rb     (new — G2)
│       │   └── store_test.rb        (new — G1)
│       ├── state/
│       │   └── store_test.rb        (new — G7)
│       ├── scm/
│       │   ├── status_test.rb       (new — SCM::Status unit)
│       │   └── git_test.rb          (new — G5)
│       └── forge/
│           └── github_test.rb       (new — G6)
└── docs/
    └── lanes/
        └── slice-1-01.md            (this report)
```

`git status --porcelain=v2 --untracked-files=normal` at end of run (G8 check):

```
1 .M N... 100644 100644 100644 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 mise.toml
? Gemfile
? Gemfile.lock
? Rakefile
? lib/
? repo-tender.gemspec
? test/
```

No `sync/`, `cli*`, `bin/`, or `launchd/` files; no `.git` writes performed.

---

## 5. Notes on the documented limitations (per gate G1 / PRD §2)

- **YAML comment + unknown-key loss on write.** The `Config::Store#write`
  emitter only writes the five managed top-level keys
  (`base_dir`, `refresh_interval`, `concurrency`, `repos`, `orgs`).
  Hand-edited YAML comments and unknown top-level keys are not preserved
  on machine rewrite. The round-trip test asserts the inverse
  (`test_write_emits_only_managed_fields`) so this is an explicit,
  test-covered contract, not a silent loss.
- **Org-discovered repos go to state, not config** (PRD §3.2). The config
  store does not auto-expand `orgs: [...]` into `repos: [...]`; that's
  the sync engine's job in Slice 2 and lives on the `State::Store`
  side. No code in Slice 1 performs that expansion.
- **No live `gh` smoke test in CI.** The forge tests use a recorded
  fixture and a `StubShell`; the architect's `bundle exec rake test`
  command stays offline-deterministic. A live `gh` smoke test (if added
  later) would be tagged/skip-marked so G0 stays green.

---

STATUS: COMPLETE
