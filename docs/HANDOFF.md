# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (Sonnet 4.6 via `claude -p`) writes
> raw evidence; architect (Opus 4.8) writes rulings and verdicts. **Not in this
> file = didn't happen.** Keep this a short table of contents: TL;DR + pointers +
> open work. Finished-slice detail lives in `docs/lanes/<slice>.md`; the full
> historical narrative (closed slices, decisions log, session log) is archived in
> `docs/archive/handoff-history-2026-06-14.md`.

## TL;DR

**Status (2026-06-14): repo-tender is feature-complete AND state-hardened; everything is merged to `main` (@ `4556e7f`). No open slice.** Feature slices 1–6 + the CLI-UX epic (A/B/C) + cf-cleanup + state-hardening are all JUDGED PASS and merged. Carry-forwards CF1–CF11 + tty-screen are CLOSED. The only remaining item is **CF12** — two low-severity, non-blocking robustness nits surfaced by the CF10 adversarial pass; neither touches the no-data-loss invariant. There is nothing forcing a next slice.

- **Last judged — slice `state-hardening` (CF10 + CF11): JUDGED PASS, merged `--no-ff` → `main` @ `4556e7f` (2026-06-14, fresh judging session).** G0 + GA1–GA5 + GB1–GB4 all PASS, re-run against the verbatim frozen `docs/gates/state-hardening.md`. Integration smoke on `main`: **378/1332/0/0/0**, `standardrb` 0, 51 gems (no new gems). Cross-model adversarial pass on CF10 confirmed the **no-data-loss invariant holds on every exit path** (release on normal/Failure/raise/Interrupt; skip path never writes; no unlink race; lockfile created on first run; no intra-run serialization). CF10 (inter-process `flock` lock across the engine load→write span) + CF11 (`ensure`-clean write temp + dead-code removal) both CLOSED. Detail: `docs/lanes/state-hardening-{A,B}.md`; verdict snapshot in the archive.

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

Baseline at `main` (`4556e7f`): **378/1332/0/0/0**, lint 0, 51 gems.

## Standing lessons (carried forward — not re-derivable from code)

- **Builder = Sonnet 4.6 via `claude -p`** (since the CLI-UX epic; slices 1–6 used minimax-m3 via `pi`). Canary before fan-out: `echo ok | claude -p --model claude-sonnet-4-6 --max-turns 1`.
- **Worktree isolation must be enforced in the block.** A past `pi` dispatch escaped its worktree and corrupted the main checkout (cwd not pinned). Bake the lane's worktree **absolute path** into the block as the repo root, forbid the main path, forbid all `git`. Post-flight always verifies `git -C <worktree> log <freeze>..` is empty (no builder commits).
- **High-stakes slices (schema/persistence/concurrency/API/security) get a cross-model adversarial pass at judgment** — a fresh-context reviewer prompted to break confidence on the invariants, file:line evidence only. (state-hardening CF10 followed this; it cleanly separated the cardinal invariant from two cosmetic nits — see CF12.)
- **No-data-loss is the cardinal invariant** (PRD §1): never mutate a dirty/diverged repo; state writes must not lose prior good rows.

## Open carry-forwards

| # | Item | Status | Lands in |
|---|------|--------|----------|
| CF12 | **Two low-severity nits on `State::Lock` (CF10), surfaced by the CF10 cross-model adversarial pass — neither touches no-data-loss.** **(a) fd leak if `flock` itself raises.** `State::Lock.acquire` (`state/lock.rb:37-41`) opens the fd *before* the `begin/ensure`; if `flock` raises (e.g. `EINTR` on a signal, `ENOLCK` on some filesystems) instead of returning `false`, the open fd leaks (the exception propagates before the `ensure` is established). Only on an already-aborting path; one fd on a terminating run. Fix: open the fd inside the `begin`, or wrap the flock attempt so the fd is closed on a raising flock. **(b) reactor-syscall nuance.** `LOCK_NB` makes the *lock* non-blocking, but `flock`/`File.open`/`mkdir_p`/`File.write`/`File.rename` are plain blocking syscalls with no Async scheduler hook — they run synchronously on the reactor fiber. **Pre-existing** (`state/store.rb` already does blocking File I/O on the reactor by design per `AGENTS.md`), NOT introduced by CF10; `LOCK_NB` remains the correct choice (a blocking `LOCK_EX` would hang the launchd daemon forever). Sub-ms on local FS. The `lock.rb` docstring slightly overstates "reactor-safe" — optionally soften the comment. | ⏳ **OPEN** — non-blocking; cardinal invariant intact. (a) = narrow fd-leak hardening; (b) = doc-wording / pre-existing architecture, no behavior change needed. | unscheduled — a tiny one-lane slice if/when desired |

## Next slice

**None scheduled.** repo-tender is feature-complete and state-hardened; all gates green on `main`. CF12 is optional polish (one small one-lane slice: fix the fd-leak in `state/lock.rb:37-41` + soften the docstring; gate = a test that injects a raising `flock` and asserts no fd leak). Spin it up only if the human wants it — there is no functional gap forcing it.

---

*Branch hygiene 2026-06-14: `slice/state-hardening` merged to `main` and deleted post-judgment; only `main` and `salvage/slice-4-raw-mixed` (deliberate unmerged scrap from the Slice-4 isolation failure) remain.*
