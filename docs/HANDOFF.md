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

**SPEC'D + GATES FROZEN this session (2026-06-14). Dispatch + post-flight recorded once the lanes complete (rule 4: a fresh session judges).** Gates: `docs/gates/state-hardening.md`. One slice, **two disjoint worktree-isolated lanes** (file sets checked — zero overlap), dispatched in parallel.

- **Objective.** Close the two remaining open carry-forwards, both `state.yaml` durability hardening. **CF10** (HIGH-STAKES): no inter-process lock → overlapping `sync` runs clobber each other's rows (last-writer-wins). **CF11** (cosmetic): `State::Store.write` orphans a temp file on `Interrupt`, and `State::Store.update` is dead code.
- **Lane A — CF10.** Non-blocking advisory lock (`flock(LOCK_EX|LOCK_NB)`) on a sidecar lockfile, held across the engine's load→write span (`Engine#call:91→142`); an overlapping run **bails cleanly without writing** (never clobbers), releases on every exit path (incl. raise/Interrupt via `ensure`). New `state/lock.rb` + `engine.rb` + require wiring. Gates **GA1–GA5**. Files: `state/lock.rb` (new), `sync/engine.rb`, `lib/repo_tender.rb`, `state/lock_test.rb` (new), `sync/engine_test.rb`.
- **Lane B — CF11.** `ensure`-clean the temp in `State::Store.write` so a non-`StandardError` interrupt can't orphan `state.yaml.tmp.<pid>` (CF7 intact); delete dead `State::Store.update`. Gates **GB1–GB4**. Files: `state/store.rb`, `state/store_test.rb`.
- **Lane plan / disjointness.** Lane A owns `engine.rb` + `state/lock.rb` + `lib/repo_tender.rb`; Lane B owns `state/store.rb`. No file overlap → parallel worktrees merge clean. `status.rb` reads state but never writes → needs no lock (untouched).
- **Why one slice / two lanes** (human-confirmed): closely-related one-subsystem work; CF11 too small for its own slice (would be an inline fix), but a parallel lane gives it a real Interrupt-injection test + dead-code-removal suite check at ~zero extra wall-clock; risk-isolated (a CF11 bug fails only Lane B; CF10 still gets the cross-model pass).
- **Effort:** Lane A `ultrathink` (novel concurrency + the no-data-loss invariant); Lane B `think harder` (small, tightly specified, but the Interrupt-injection test wants care).
- **Judging session (next, fresh):** post-flight both lanes (no commits, scope ⊆ declared set, gates rule-3 clean) → re-run G0/GA*/GB* → **cross-model adversarial pass on CF10** → arbitrate PHASE-0 → merge each passing lane → integrate onto `slice/state-hardening` → integration smoke after each merge.

---

*Branch hygiene 2026-06-14: all merged `slice/*` + `lane/cf-cleanup-*` branches deleted; only `main` and `salvage/slice-4-raw-mixed` (deliberate unmerged scrap from the Slice-4 isolation failure) remain.*
