# Gates — slice `cf-cleanup` (CF7 · CF8 · CF9)

> FROZEN before dispatch. Read-only for everyone including the architect — a
> builder edit to anything under `docs/gates/` is an automatic slice FAIL
> (rule 3). Three independent robustness carry-forwards, one lane each, file
> sets disjoint (checked: zero overlap). The architect re-runs every gate
> command itself at judgment; builder claims are hearsay.

Three lanes, three worktrees off the freeze commit, dispatched in parallel:

| Lane | CF | Production file (only) | Test file (only) |
|------|----|------------------------|------------------|
| `cf-cleanup-07` | CF7 | `lib/repo_tender/state/store.rb` | `test/repo_tender/state/store_test.rb` |
| `cf-cleanup-08` | CF8 | `lib/repo_tender/shell.rb` | `test/repo_tender/shell_test.rb` |
| `cf-cleanup-09` | CF9 | `lib/repo_tender/sync/engine.rb` | `test/repo_tender/sync/engine_test.rb` |

**Shared verification commands (run in each lane's worktree; architect re-runs
at judgment and on every integration merge):**

```
bundle exec rake test       # failures = 0, errors = 0, skips = 0; count ≥ freeze baseline
bundle exec standardrb      # exit 0
git diff <freeze>.. -- repo-tender.gemspec Gemfile.lock   # EMPTY (no new gems)
```

The freeze-commit test baseline is whatever `bundle exec rake test` reports on
the freeze commit (≈358 tests at slice start). Every lane is **additions-only**
to its test file, so each lane's count is **strictly greater** than the
baseline with 0 failures / 0 errors / 0 skips.

---

## Lane `cf-cleanup-07` — CF7: atomic `State::Store.write`

**Intent.** `State::Store.write` (`lib/repo_tender/state/store.rb:72-79`) is a
direct `File.write(path, emit(state))` that **truncates the live `state.yaml`
in place**. A crash/SIGINT landing in the kernel mid-`write(2)` can leave a
truncated/corrupt `state.yaml`. Harden to **temp-sibling-write + `File.rename`**
so the live file is never opened for truncation and the swap is atomic. This is
the no-data-loss invariant (PRD) applied to the state file. HIGH-STAKES
(persistence) → the architect adds a cross-model adversarial diff pass at
judgment.

- **G7.0 — Suite + lint + no new gems.** Shared commands all green in the
  worktree.
- **G7.1 — Mid-write failure never corrupts the existing file.** With a good
  `state.yaml` already on disk, inject a failure so a write is abandoned partway
  (e.g. arrange the serialize/write step to raise before the rename completes).
  Assert the **pre-existing `state.yaml` is byte-identical to before** the failed
  write (old good content intact — never truncated/empty). The production code
  must write a sibling temp file and `File.rename` it over `path`; the live file
  is never the truncation target, so a crash before the rename leaves the old
  state whole.
- **G7.2 — Same-directory temp + atomic rename (no `EXDEV`).** The temp file is
  created under `File.dirname(path)` (NOT `Dir.tmpdir`), so `File.rename` is an
  atomic same-filesystem swap, never a cross-device copy. Assert a write into a
  directory that differs from the system tmpdir succeeds, lands the correct
  bytes, and leaves **no stray temp/sibling file** behind in that directory.
- **G7.3 — Round-trip + emitted bytes unchanged (anti-gaming).**
  `git diff <freeze>.. -- test/repo_tender/state/store_test.rb` is **+N/−0**
  (pure additions; no existing test body edited). The existing round-trip tests
  pass unchanged, and the emitted YAML for a given state is **byte-identical** to
  the pre-fix output (the `emit`/`validate` methods and the validation-failure
  early-return path are unchanged — only the physical write mechanism changes).
- **G7.4 — Scope.** Touched files ⊆ {`lib/repo_tender/state/store.rb`,
  `test/repo_tender/state/store_test.rb`, `docs/lanes/cf-cleanup-07.md`}.
  `lib/repo_tender/config/store.rb` (the OTHER store with the same `File.write`
  pattern) is **OUT OF SCOPE and byte-unchanged**. No builder commits
  (`git log <freeze>.. == empty`). `docs/gates/` diff-clean.

---

## Lane `cf-cleanup-08` — CF8: concurrency-safe `report_on_exception`

**Intent.** `Shell.run` (`lib/repo_tender/shell.rb:59-69`) save/restores the
**process-global** `Thread.report_on_exception` around `Open3.capture3`, but
`Shell.run` runs **concurrently** under `Sync{}` (fibers interleave at
`Open3.capture3`'s thread-join). The global is empirically **left `false` after
concurrent runs unwind** (the inner fiber's `ensure` restores a `prev` that was
already `false`). Fix: **refcount the active `Shell.run` calls** — capture the
original value on the 0→1 transition, set `false`; restore the captured original
on the 1→0 transition. Keep `Shell.run`'s signature and `Result` semantics
identical.

**Mandated approach (pre-frozen disagreement ruling):** the refcount lives
**inside `Shell.run`** (a class-level counter + saved original). The alternative
"set `report_on_exception = false` once at process startup without restoring" is
**REJECTED** — it would touch a CLI entrypoint (out of this lane) and leaves the
process-global flag mutated for any library consumer (repo-tender ships as an
installed gem). The refcount keeps the good-citizen restore semantics AND
confines the change to `shell.rb`. The reactor is single-threaded (`lib/` spawns
no app threads — see the existing comment block at `shell.rb:42-56`), so a plain
class-ivar counter mutated only between fiber yield points is fiber-safe without
a `Mutex`; a `Mutex` is permitted only if the builder justifies it against the
actual concurrency model (no true thread parallelism exists here).

- **G8.0 — Suite + lint + no new gems.** Shared commands all green in the
  worktree.
- **G8.1 — Single-call semantics preserved (anti-gaming).**
  `git diff <freeze>.. -- test/repo_tender/shell_test.rb` is **+N/−0** (no
  existing test body edited). The two existing tests
  (`test_shell_run_disables_thread_report_on_exception_during_open3_capture3`,
  `test_shell_run_restores_thread_report_on_exception_even_when_open3_raises`)
  pass **unchanged**: during a single in-flight `Shell.run` the global is
  observed `false`, and after it returns the global is restored to the pre-call
  value (including when `Open3.capture3` raises).
- **G8.2 — No leak under concurrency (the CF8 fix).** With
  `Thread.report_on_exception = true` set before the run, launch **≥2 genuinely
  overlapping** `Shell.run` calls inside one `Sync{}`/`Async::Barrier` (each
  sleeping so they overlap — reuse the `test_concurrent_runs_overlap` pattern),
  wait for all, then assert `Thread.report_on_exception == true` — restored to
  the original, **NOT leaked `false`**. The post-condition proves the
  first-to-finish run did not prematurely restore while another was in flight.
- **G8.3 — Suppression still effective during overlap (G3 carry).** While ≥1
  `Shell.run` is in flight (including with ≥2 active), the global is `false` — the
  Slice-6 G3 reader-thread-noise suppression is not regressed. (Demonstrated via
  an observation shim asserting `false` at an in-flight `capture3` with ≥2
  active; may be folded into G8.2's test.)
- **G8.4 — Scope.** Touched files ⊆ {`lib/repo_tender/shell.rb`,
  `test/repo_tender/shell_test.rb`, `docs/lanes/cf-cleanup-08.md`}. No
  entrypoint / `bin/` / `cli` touched. No builder commits. `docs/gates/`
  diff-clean.

---

## Lane `cf-cleanup-09` — CF9: org fan-out rescue + ensure-guarded teardown

**Intent.** The concurrent org fan-out in `Engine#expand_orgs`
(`lib/repo_tender/sync/engine.rb:193-223`) lacks the last-resort `rescue => e`
that the repo sweep's `process_one` has (`:371-377`). A `list_org` that **raises**
(vs returns `Failure`) — e.g. `gh` emitting schema-violating JSON so
`parse_repos` hits `nil.split`/`KeyError` — propagates through
`inner.wait` → `org_barrier.wait` → out of `Engine#call` as a raw raise,
aborting all other orgs + the entire repo sweep and **writing no state**.
Compounded: `@reporter.detach` (`:139`) is not `ensure`-guarded now that
`attach` fires before expansion (`:96`). Fix both halves:

- **Part A** — give the org fiber the same last-resort `rescue => e` as
  `process_one`: record the raising org as a **failed row** (mirror the existing
  `Failure` branch — preserve prior `last_listed_at`/`repo_count` from
  `prev_orgs[key]` (CF3), set `last_error: "unhandled: #{e.class}: #{e.message}"`,
  emit `@reporter.org_listed(org_ref, count: nil)` under `org_mutex`), so the
  raise no longer escapes and the run completes + writes state.
- **Part B** — wrap the `@reporter.attach(task)` … `@reporter.detach` span so
  `detach` runs in an `ensure` (teardown survives any escaping raise).

**NOT a regression** (the old sequential `expand_orgs` had the identical gap) and
**NOT a no-data-loss change to the happy path** — it makes the raise path
recoverable. MEDIUM-HIGH stakes (engine concurrency) → architect cross-model
adversarial pass at judgment.

- **G9.0 — Suite + lint + no new gems.** Shared commands all green in the
  worktree. (This alone re-proves GS1–GS6 / G10 / CF3, whose tests live in
  `engine_test.rb`.)
- **G9.1 — A raising org is isolated; the run completes and writes state (the
  CF9 fix; mirrors the repo-sweep G3/G8).** With a forge double whose `list_org`
  **raises** for ONE org among several: `Engine#call` returns **`Success`** (does
  NOT propagate the raise); the run completes; the raising org is recorded with a
  non-nil `last_error` (and CF3-preserved prior `repo_count`/`last_listed_at` when
  a prev row exists); the OTHER orgs are listed normally and their discovered
  repos are processed; and `state.yaml` **IS written** (no-data-loss — state
  persisted, in contrast to the pre-fix raw-raise/no-write behavior).
- **G9.2 — Teardown runs even on an escaping raise (Part B ensure-guard).**
  Inject an exception that escapes the `attach…detach` span (e.g. a recording
  reporter whose `listing_started`/`listing_finished` raises, OR another
  deterministic source the builder picks) and assert `@reporter.detach` is still
  invoked exactly once (recording reporter asserts the `detach` event is seen).
  The builder records the exact injection mechanism used.
- **G9.3 — Carried behaviors unchanged (anti-gaming).**
  `git diff <freeze>.. -- test/repo_tender/sync/engine_test.rb` is **+N/−0** (no
  existing test body edited). All existing `test_gs1*`/`test_gs2*`/`test_gs3*`/
  `test_gs4*`, `test_g10_*`, and `test_g7_org_list_failure_*` (CF3 preserve) pass
  **unchanged** — the `Result.Failure` isolation contract (org returns `Failure`
  → recorded, run continues), auth-once, dedupe explicit-wins, and per-repo
  isolation are byte-unchanged behavior.
- **G9.4 — No-data-loss + scope.** Touched files ⊆ {`lib/repo_tender/sync/engine.rb`,
  `test/repo_tender/sync/engine_test.rb`, `docs/lanes/cf-cleanup-09.md`}.
  `state/store.rb`, `shell.rb`, `scm/*`, `forge/*` are **byte-unchanged** (CF9
  touches only `engine.rb` + its test). No builder commits. `docs/gates/`
  diff-clean.

---

## Judgment notes (for the next, fresh session — NOT this one)

- Rule 4: this session dispatches all three lanes, so it **cannot judge** them.
- CF7 and CF9 are higher-stakes → run the cross-model adversarial diff pass
  (`claude -p --model claude-sonnet-4-6 --allowedTools 'Read,Grep,Glob'`) in
  addition to the architect's own diff read.
- Read each production diff against intent, not just gate-green: CF7's rename
  must target a **same-dir** sibling (cross-device `File.rename` raises EXDEV);
  CF8 must **not** have quietly switched to the rejected set-once-at-startup
  approach; CF9's rescue must preserve CF3 (prior counts), not zero them.
- All three test files must be **additions-only** vs the freeze (the anti-gaming
  / byte-compat check) — verify the `git diff … -- <test file>` is `+N/−0`.
