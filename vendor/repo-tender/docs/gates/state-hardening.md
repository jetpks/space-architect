# Gates — slice `state-hardening` (CF10 + CF11)

> FROZEN. Read-only for everyone including the builder. A builder edit to any
> file under `docs/gates/` fails the slice regardless of results (hard rule 3).
> The architect re-runs every gate in a fresh session and compares against this
> verbatim text (hard rule 4). Gate-pass is necessary, not sufficient — the diff
> is also read against intent.

**Freeze baseline** (`main` @ the freeze commit that adds this file): suite
**364/1302/0/0/0**, `standardrb` 0, 51 gems. Two disjoint worktree-isolated
lanes off the freeze commit: **Lane A = CF10** (inter-process lock), **Lane B =
CF11** (temp-orphan cleanup + dead-code removal).

Verification commands (run from the lane's worktree root):

```bash
bundle install
bundle exec rake test            # tests grow, failures = 0, errors = 0, skips = 0
bundle exec standardrb           # exit 0
bundle exec ruby -Itest test/repo_tender/sync/engine_test.rb       # Lane A
bundle exec ruby -Itest test/repo_tender/state/store_test.rb       # Lane B
bundle exec ruby -Itest test/repo_tender/state/lock_test.rb        # Lane A (new)
```

---

## G0 — Suite green, lint clean, no new gems (BOTH lanes, integration)

- `bundle install` exits 0.
- `bundle exec rake test`: total tests **> 1302** (additions only), **failures
  = 0, errors = 0, skips = 0**.
- `bundle exec standardrb` exits 0.
- `git diff <freeze>.. -- Gemfile Gemfile.lock repo-tender.gemspec` shows **no
  new gems**. CF10 uses the stdlib (`File#flock`, `File::LOCK_*`) — no gem is
  permitted. The gem set stays exactly 51.
- Per-lane test diffs are **additions-only** on pre-existing test files
  (`git diff <freeze>.. -- <existing test file>` is `+N/−0`); existing test
  bodies are not edited (the anti-gaming / behavior-preservation check). New
  test files (`lock_test.rb`) are wholly additive by definition.

---

## Lane A — CF10: inter-process lock on `state.yaml`

**Intent.** Two overlapping `sync` processes (a launchd `StartInterval` tick
fires while a prior run is in flight, or an operator runs `repo-tender sync`
during the scheduled job) currently each `State::Store.load` → build → atomic
`write` independently → **last-writer-wins whole-file clobber** of the other's
rows. Serialize at the process level with an advisory lock on a sidecar lockfile
held across the engine's load→write span, so an overlapping run **never writes**
(and therefore cannot clobber the in-flight run's data).

**Design (gated as observable behavior; the encoding is a builder PHASE-0 call):**
a **non-blocking** `flock(LOCK_EX | LOCK_NB)` on a sidecar lockfile derived from
`paths.state_file` (e.g. `"#{state_file}.lock"`). If the lock is acquired, the
run proceeds and the lock is released on every exit path. If it is **not**
acquired (another run holds it), the run **bails cleanly**: it does not write
`state.yaml`, does not raise, and signals a "skipped — another sync in progress"
outcome. A *blocking* `LOCK_EX` is rejected by design: under an unattended
launchd daemon a hung run would block every subsequent tick forever, and it
cannot be tested in-process without hanging. Prefer returning the unchanged
loaded state as `Success` + a notice (via the existing reporter seam or a stderr
warning) so `cli/sync.rb` needs no change and the exit code stays 0 (a skipped
overlapping run is correct idempotent behavior, not an error — cf. CF5). If you
believe a `cli/sync.rb` change is required, raise it in PHASE 0.

### GA1 — Lock wraps the full load→write span
Architect reads the diff: an exclusive advisory lock on a sidecar lockfile
(path derived from `paths.state_file`, derivation exposed so a test can compute
the same path — e.g. `State::Lock.path_for(state_file)`) is acquired **before**
`State::Store.load` (engine.rb:91) and released **after** `State::Store.write`
(engine.rb:142), covering the entire span. The lockfile is created if missing
(`mkdir_p` its dir first — the state dir may not exist on a first run) and is
**never `unlink`ed** mid-run (deleting a flock'd file is a race; it is a
persistent zero-byte sentinel).

### GA2 — No clobber under overlap (CORE invariant)
Deterministic test, real `flock`, real temp `state.yaml`, no mock of
Store/Engine: pre-seed `state.yaml` with prior rows; acquire `flock(LOCK_EX)` on
the sidecar via an **independent fd** (simulates an in-flight run holding the
lock); snapshot `state.yaml` bytes; call `Engine#call`; assert **(a)**
`state.yaml` bytes are **unchanged** (the in-flight run's data was never
clobbered), **(b)** the call **returned without raising**, **(c)** a
distinguishable "skipped" signal (Result shape or reporter notice — builder's
choice, asserted). Then **release** the external lock and call `Engine#call`
again: it **proceeds**, writes, and the final `state.yaml` contains the run's
rows merged with the pre-seeded prior rows (CF3 preservation intact). (A blocking
design would hang step (b) indefinitely — that is the gate failing, not passing.)

### GA3 — Lock released on every exit path
After each of the three scenarios below, an independent
`flock(LOCK_EX | LOCK_NB)` on the sidecar **SUCCEEDS** (proving the engine
released its lock — via `ensure`):
- **(a) normal success** — a clean run completes.
- **(b) write Failure** — `State::Store.write` returns `Failure` (drive via an
  invalid state / injected write-failure seam); the engine returns the Failure
  AND released the lock.
- **(c) escaping raise** — a collaborator raises (use the existing `raise_on`
  SCM stub or a forge raise) so an exception propagates out of `Engine#call`;
  the lock is still released (mirrors the CF9 `ensure`-guarded `detach` idiom).

### GA4 — Intra-run concurrency & no-data-loss invariants unchanged
The lock is process-level around the **whole** run — it must NOT serialize the
intra-run repo/org fan-out. These pre-existing gates stay green and their test
bodies are **unmodified**:
- Slice-2 **G7** (intra-run concurrency ≤ configured limit),
- **G8** (per-repo Failure isolated + state written),
- **G9** (idempotent 2nd run, no network),
- **G10** (org expansion + resilience),
- **GS1** (concurrent `expand_orgs`: max in-flight bounded, wall-time ~slowest
  org — confirm this assertion is unmodified and green; the lock must not make it
  serial),
- **CF3** (org-list Failure preserves prior good `repo_count`/`last_listed_at`).

### GA5 — Scope + integrity (Lane A)
- `git diff --name-only <freeze>..` ⊆ **Lane A declared set**:
  `lib/repo_tender/state/lock.rb` (new), `lib/repo_tender/sync/engine.rb`,
  `lib/repo_tender.rb` (require wiring), `test/repo_tender/state/lock_test.rb`
  (new), `test/repo_tender/sync/engine_test.rb`,
  `docs/lanes/state-hardening-A.md`.
- **MUST-NOT-TOUCH byte-unchanged**: `lib/repo_tender/state/store.rb` (Lane B
  owns it), `scm/*`, `shell.rb`, all reporters, `cli/*`, `paths.rb`, gemspec,
  `Gemfile.lock`.
- `docs/gates/` diff-clean since freeze; `git log <freeze>..` shows **no builder
  commits**.

---

## Lane B — CF11: `State::Store.write` temp-orphan + dead `State::Store.update`

**Intent.** `State::Store.write` (`state/store.rb:78-84`) wraps its temp-write +
rename in a bare `rescue` (= `rescue StandardError`), so an `Interrupt` (or any
non-`StandardError`) landing **between** `File.write(tmp)` and `File.rename(tmp,
path)` skips the `File.delete(tmp)` cleanup → a harmless
`state.yaml.tmp.<pid>` orphan is left behind (the live `state.yaml` is
uncorrupted — CF7 intent intact). Also `State::Store.update` (`state/store.rb:88-92`)
has **zero callers** — dead code.

### GB1 — Temp cleaned up on a non-StandardError interrupt
Deterministic test that **distinguishes the fix**: inject a **non-StandardError**
(e.g. `Interrupt`, or a bare `Exception` subclass) raised at the rename step
(legitimate seam: `File.stub(:rename, ->(*) { raise Interrupt })` — `File` is not
the unit under test, `State::Store.write` is). Assert:
- **(a)** the pre-existing `state.yaml` is **byte-unchanged / uncorrupted** (CF7
  intact — the live file was never the write target),
- **(b)** **no** `state.yaml.tmp.*` orphan remains in the state dir,
- **(c)** the injected exception **still propagates** out of `write` (cleanup
  must not swallow it).

The current bare `rescue` must **FAIL** assertion (b) before the fix (an
`Interrupt` is not caught, so the temp is orphaned) — i.e. the new test is red on
freeze-state code and green after. Note this in the report.

### GB2 — Dead `State::Store.update` removed
- `State::Store.update` is deleted.
- `grep -rn "Store\.update\|State::Store.*update" lib bin exe test` (and a scan
  for any `.update(` call routed to `State::Store`) confirms **zero callers**
  existed and none remain.
- Full suite green proves nothing depended on it.

### GB3 — `write` still correct + atomic (CF7 unbroken)
- Existing `state/store.rb` tests (CF7 atomic-write incl. the ENOSPC mid-write
  injection, `validate`, round-trip, `emit`) pass **UNMODIFIED**
  (`git diff <freeze>.. -- test/repo_tender/state/store_test.rb` is `+N/−0`).
- A successful `write` still produces a complete valid `state.yaml` via same-dir
  temp + `File.rename` (no EXDEV); the file is never torn.

### GB4 — Scope + integrity (Lane B)
- `git diff --name-only <freeze>..` ⊆ **Lane B declared set**:
  `lib/repo_tender/state/store.rb`, `test/repo_tender/state/store_test.rb`,
  `docs/lanes/state-hardening-B.md`.
- **MUST-NOT-TOUCH byte-unchanged**: `lib/repo_tender/sync/engine.rb`,
  `lib/repo_tender/state/lock.rb` (Lane A owns it), `lib/repo_tender.rb`,
  everything else.
- `docs/gates/` diff-clean since freeze; `git log <freeze>..` shows **no builder
  commits**.

---

## Judgment notes (for the fresh judging session)

- **HIGH-STAKES** (persistence + inter-process concurrency + the no-data-loss
  cardinal invariant) → run the **cross-model adversarial pass** on Lane A
  (CF10): a fresh read-only `claude -p` reviewer prompted to break confidence on
  the lock's correctness — release on all paths (incl. raise/Interrupt), no
  intra-run serialization, no lockfile-unlink race, the skip path genuinely
  prevents the clobber, lockfile created on first run. File:line evidence only.
- Read GA2/GA3/GB1 test bodies to confirm **non-tautological**: real `flock` on a
  real temp lockfile, real `state.yaml`, real injected raise — never a stub of
  Store/Engine/Lock (the units under test).
- Lanes are disjoint by construction; a merge conflict on integration = spec
  defect → kill the conflicting lane and re-spec (do not hand-resolve).
