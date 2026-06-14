# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (Sonnet 4.6 via `claude -p`) writes
> raw evidence; architect (Opus 4.8) writes rulings and verdicts. **Not in this
> file = didn't happen.** Keep this a short table of contents: TL;DR + pointers +
> open work. Finished-slice detail lives in `docs/lanes/<slice>.md`; the full
> historical narrative (closed slices, decisions log, session log) is archived in
> `docs/archive/handoff-history-2026-06-14.md`.

## TL;DR

**Status (2026-06-14): repo-tender is feature-complete; every epic is merged to `main` (@ `56ba350`).** Feature slices 1–6 + the CLI-UX epic (A/B/C) + cf-cleanup are all JUDGED PASS and merged. Carry-forwards CF1–CF9 + tty-screen are CLOSED. The only open items are **CF10** and **CF11** — both non-blocking state-durability hardening, both grouped into one slice (`state-hardening`) below.

- **Last merged — slice `cf-cleanup` (CF7+CF8+CF9): 15/15 gates PASS → merged `274ef3d`.** CF7 atomic `State::Store.write` (same-dir temp + `File.rename`); CF8 refcounted `report_on_exception` suppression in `Shell.run`; CF9 org fan-out last-resort `rescue` + `ensure`-guarded `detach`. Detail: `docs/lanes/cf-cleanup-{07,08,09}.md`; history snapshot in the archive.

- **Open work — `state-hardening` (CF10 + CF11):** see the Open carry-forwards table + the slice spec below. CF10 is HIGH-STAKES (inter-process concurrency + no-data-loss invariant); CF11 is a cosmetic temp-orphan cleanup + dead-code removal.

## Pointers

- **PRD (build contract):** `docs/prd/repo-tender.md` · CLI-UX PRD `docs/prd/cli-ux.md`
- **Research (evidence ledger):** `docs/research/repo-tender.md`
- **Builder standing context:** `AGENTS.md`
- **Per-slice evidence:** `docs/lanes/<slice>.md` · **frozen gates:** `docs/gates/<slice>.md`
- **Full history (closed slices, decisions log, session log):** `docs/archive/handoff-history-2026-06-14.md`

## Verification gate (exact commands)

```
bundle install
bundle exec rake test        # tests > 0, failures = 0, errors = 0, skips = 0
bundle exec standardrb       # exit 0
```

Baseline at `main` (`56ba350`): **364/1302/0/0/0**, lint 0.

## Standing lessons (carried forward — not re-derivable from code)

- **Builder = Sonnet 4.6 via `claude -p`** (since the CLI-UX epic; slices 1–6 used minimax-m3 via `pi`). Canary before fan-out: `echo ok | claude -p --model claude-sonnet-4-6 --max-turns 1`.
- **Worktree isolation must be enforced in the block.** A past `pi` dispatch escaped its worktree and corrupted the main checkout (cwd not pinned). Bake the lane's worktree **absolute path** into the block as the repo root, forbid the main path, forbid all `git`. Post-flight always verifies `git -C <worktree> log <freeze>..` is empty (no builder commits).
- **High-stakes slices (schema/persistence/concurrency/API/security) get a cross-model adversarial pass at judgment** — a fresh-context reviewer prompted to break confidence on the invariants, file:line evidence only.
- **No-data-loss is the cardinal invariant** (PRD §1): never mutate a dirty/diverged repo; state writes must not lose prior good rows.

## Open carry-forwards

| # | Item | Status | Lands in |
|---|------|--------|----------|
| CF10 | **No inter-process lock on `state.yaml`.** CF7 made each write atomic (no torn file), but two overlapping `sync` processes (launchd `StartInterval` tick fires mid-run, OR an operator runs `repo-tender sync` while the scheduled job runs) each `State::Store.load` → build → atomic-rename independently → **last-writer-wins whole-file clobber** (lost org/repo rows; the file is always a *complete valid* emit, just stale). No `flock`/lockfile anywhere. Pre-existing; surfaced by the CF7 adversarial pass. Fix: `flock(LOCK_EX)` a sidecar lockfile around the load→write span (`Engine#call:91→142`). | ⏳ **OPEN** — non-blocking; atomicity holds (no corruption), only staleness under concurrent runs. | slice `state-hardening` (Lane A) |
| CF11 | **`State::Store.write` temp-orphan on SIGINT + dead `State::Store.update`.** The bare `rescue` in `write` (`state/store.rb:81`) catches only `StandardError`, so an `Interrupt`/non-`StandardError` landing between `File.write(tmp)` and `File.rename` skips the `File.delete(tmp)` cleanup → leaves a harmless `state.yaml.tmp.<pid>` orphan (live file uncorrupted — CF7 intent intact). Also: `State::Store.update` (`state/store.rb:88-92`) has **zero callers** (grep lib/exe/bin/test) — dead code. Fix: `ensure`-clean the temp (or `rescue Exception`); delete `State::Store.update`. | ⏳ **OPEN** — cosmetic (orphan temp) + dead-code removal, non-blocking. | slice `state-hardening` (Lane B) |

## Next slice — `state-hardening` (CF10 + CF11)

**SPEC'D + FROZEN + DISPATCHED + BUILT + POST-FLIGHTED + INTEGRATED this session (2026-06-14); NOT JUDGED (rule 4 — a fresh session judges).** Gates: `docs/gates/state-hardening.md`. **Freeze commit `a1cba9d`.** One slice, **two disjoint worktree-isolated lanes** (zero overlap), built in parallel (Sonnet 4.6 via `claude -p`), both **post-flight PASS**, merged onto **`slice/state-hardening` @ `1f61914`**. Lane reports: `docs/lanes/state-hardening-{A,B}.md`.

- **READY FOR JUDGING on `slice/state-hardening` @ `1f61914`.** Integration smoke (both lanes merged, `--no-ff`, zero conflicts — lanes truly disjoint): **378/1332/0/0/0**, `standardrb` 0, no new gems (51), diff = exactly the 7 expected files. `main` stays at the dispatch/post-flight record commit; nothing merged to `main` (verdict pending).

- **Lane A (CF10) — built, post-flight PASS.** Builder (Sonnet 4.6, 40 turns, $2.23, exit 0, STATUS COMPLETE): `State::Lock.acquire(state_file){}` (`flock LOCK_EX|LOCK_NB`) + `path_for` + `NOT_ACQUIRED` sentinel; engine wraps the whole load→write span, bails `Success(current_state)` + `warn` when another run holds the lock (no clobber), releases on every path via `ensure`. **2 PHASE-0 findings (both sound):** (1) `cli/sync.rb` needs no change — `NOT_ACQUIRED` returns `Success(current_state)`, matching the spec steer; (2) `return write_result if …failure?` raised `LocalJumpError` inside the lock block's nested yield under Async → rewritten as `if/else`. +9 `lock_test`, +4 `engine_test` (GA2 no-clobber, GA3 release-on-all-paths). Lane-alone suite 377/1328/0/0/0. Post-flight: no builder commits, scope ⊆ {`state/lock.rb`(new), `sync/engine.rb`, `lib/repo_tender.rb`, `lock_test.rb`(new), `engine_test.rb`, report}; `store.rb`/`cli`/`scm`/`shell`/gems/gates byte-unchanged. Preserved `999b52b`.
- **Lane B (CF11) — built, post-flight PASS.** Builder (Sonnet 4.6, exit 0, STATUS COMPLETE, **0 disagreements**): `State::Store.write` `rescue/raise` → `ensure` (cleans orphan tmp on `StandardError` AND `Interrupt`/non-`StandardError`; exception propagates automatically); deleted zero-caller `State::Store.update` (verified — all `.update(` grep hits were `Config::Store`, a different class). +44/−0 `store_test` (`File.stub(:rename)` raises `Interrupt` → asserts original intact, no `.tmp.*` orphan, exception propagates). Lane-alone suite 365/1306/0/0/0. Post-flight: no builder commits, scope ⊆ {`state/store.rb`, `store_test.rb`, report}; everything else byte-unchanged. Preserved `727137f`.

- **Objective.** Close the two remaining open carry-forwards, both `state.yaml` durability hardening. **CF10** (HIGH-STAKES): no inter-process lock → overlapping `sync` runs clobber each other's rows (last-writer-wins). **CF11** (cosmetic): `State::Store.write` orphans a temp file on `Interrupt`, and `State::Store.update` is dead code.
- **Lane A — CF10.** Non-blocking advisory lock (`flock(LOCK_EX|LOCK_NB)`) on a sidecar lockfile, held across the engine's load→write span (`Engine#call:91→142`); an overlapping run **bails cleanly without writing** (never clobbers), releases on every exit path (incl. raise/Interrupt via `ensure`). New `state/lock.rb` + `engine.rb` + require wiring. Gates **GA1–GA5**. Files: `state/lock.rb` (new), `sync/engine.rb`, `lib/repo_tender.rb`, `state/lock_test.rb` (new), `sync/engine_test.rb`.
- **Lane B — CF11.** `ensure`-clean the temp in `State::Store.write` so a non-`StandardError` interrupt can't orphan `state.yaml.tmp.<pid>` (CF7 intact); delete dead `State::Store.update`. Gates **GB1–GB4**. Files: `state/store.rb`, `state/store_test.rb`.
- **Lane plan / disjointness.** Lane A owns `engine.rb` + `state/lock.rb` + `lib/repo_tender.rb`; Lane B owns `state/store.rb`. No file overlap → parallel worktrees merge clean. `status.rb` reads state but never writes → needs no lock (untouched).
- **Why one slice / two lanes** (human-confirmed): closely-related one-subsystem work; CF11 too small for its own slice (would be an inline fix), but a parallel lane gives it a real Interrupt-injection test + dead-code-removal suite check at ~zero extra wall-clock; risk-isolated (a CF11 bug fails only Lane B; CF10 still gets the cross-model pass).
- **Effort:** Lane A `ultrathink` (novel concurrency + the no-data-loss invariant); Lane B `think harder` (small, tightly specified, but the Interrupt-injection test wants care).
- **Judging session (next, fresh — rule 4):** on `slice/state-hardening` @ `1f61914`, re-run **G0 + GA1–GA5 + GB1–GB4** yourself against the frozen `docs/gates/state-hardening.md` (verbatim); read the GA2/GA3/GB1 test bodies to confirm non-tautological (real `flock`/real temp `state.yaml`/real injected `Interrupt`, no stub of Store/Engine/Lock); **run the mandated cross-model adversarial pass on CF10** (lock released on all paths incl. raise/Interrupt, no intra-run serialization, no lockfile-unlink race, the skip path truly prevents the clobber, lockfile created on first run); read the diff vs intent (the `return`→`if/else` change + the `ensure` cleanup); arbitrate Lane A's 2 PHASE-0 findings → **KILL/CONTINUE** → merge `--no-ff` to `main` on PASS, integration smoke. Then CF10 + CF11 close → **no open carry-forwards, no open slice.**

---

*Branch hygiene 2026-06-14: all merged `slice/*` + `lane/cf-cleanup-*` branches deleted; only `main` and `salvage/slice-4-raw-mixed` (deliberate unmerged scrap from the Slice-4 isolation failure) remain.*
