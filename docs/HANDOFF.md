# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (Sonnet 4.6 via `claude -p`) writes
> raw evidence; architect (Opus 4.8) writes rulings and verdicts. **Not in this
> file = didn't happen.** Keep this a short table of contents: TL;DR + pointers +
> open work. Finished-slice detail lives in `docs/lanes/<slice>.md`; the full
> historical narrative (closed slices, decisions log, session log) is archived in
> `docs/archive/handoff-history-2026-06-14.md`.

## TL;DR

**Status (2026-06-14): slice `sync-fixes` BUILT + integrated on `slice/sync-fixes` @ `71ad0f0`; READY FOR JUDGING (rule 4 — a FRESH session judges, NOT the one that dispatched).** Two disjoint bug-fix lanes from an interactive `sync` run, both COMPLETE, post-flight PASS (no builder commits, in-bounds writes only), merged `--no-ff` with no conflicts. Integration smoke on `slice/sync-fixes`: **398/1404/0/0/0, standardrb 0, 51 gems** (baseline `main` was 379/1334). Frozen gates: `docs/gates/sync-fixes.md`. Lane evidence: `docs/lanes/sync-fixes-{A,B}.md`. **NOT yet merged to `main` — that happens only on a PASS/CONTINUE verdict next session.**

- **Lane A (`ui-listing-order`) — COMPLETE.** `InteractiveReporter#render_sweep_tick` now flushes leftover `@pending_org_lines` as a contiguous block at the listing→sweep transition, so the last org's listing line (e.g. `✓ ioquatix 174 repo(s)`) stays with the org block instead of being reprinted after the sweep `⚠` lines. +1 regression test (fails pre-fix, passes post-fix). Touched only `ui/interactive_reporter.rb` + its test.

- **Lane B (`empty-repo`) — COMPLETE_WITH_CONCERNS.** Empty (no-commit) remotes no longer report `error`. `Status#unborn?` detects `# branch.oid (initial)`; `RepoPlan` short-circuits unborn repos before the `default_branch` probe (which fails `Cannot determine remote HEAD` on an empty remote — the root cause). New `SCM#sync_empty` (`ls-remote --heads` → `fetch` → `merge --ff-only`) returns `:empty` (remote also empty, no mutation) or `:fast_forwarded` (remote gained commits); engine maps both to `clean`. **Unborn + dirty (uncommitted local files) is NEVER mutated → `dirty` (no-data-loss / cardinal invariant).** Real failures still surface as `error`. +18 tests, all against REAL on-disk git.

- **⚠ FROZEN GATE-COMMAND DEFECT (architect's error, caught by Lane B PHASE 0 — judge must route around it).** The Lane B gate command in `docs/gates/sync-fixes.md` is `bundle exec ruby -Itest a.rb b.rb c.rb d.rb`. In Ruby, `ruby file1 file2 …` runs ONLY `file1`; the rest become `ARGV` (verified: `ruby /tmp/ta.rb /tmp/tb.rb` ran only ta.rb). So that command exercises only `status_test.rb` (9 runs), NOT all four suites. **The gate file is frozen and read-only (rule 3) — it was NOT edited.** When judging Lane B, measure GB1–GB5 via `bundle exec rake test` (G0, authoritative, subsumes all lane B tests) and/or each file run **individually**: `status_test.rb` 9·14·0·0·0 · `git_test.rb` 17·48·0·0·0 · `repo_plan_test.rb` 19·48·0·0·0 · `engine_test.rb` 42·259·0·0·0. Rule the four-file command **INVALID-as-written**; the underlying gates remain measurable and PASS in the lane report.

- **Lane B residual concerns (cosmetic, for the judge to weigh — not blockers):** (1) `:report_dirty` handler re-probes `default_branch` on an unborn dirty repo → one wasted `set-head -a` network call (harmless; GB4 still passes). (2) `sync_empty` resolves `default_branch` and the engine re-probes it after success → one redundant probe. Both match the spec as written; candidate CF if the judge wants them tightened.

**Prior status (still true): feature slices 1–6 + CLI-UX epic + cf-cleanup + state-hardening all JUDGED PASS and merged to `main`. CF1–CF12 + tty-screen CLOSED.**

- **CF12 — CLOSED (fixed inline 2026-06-14, not via the dispatch loop — human asked to fix the two small nits directly).** (a) `State::Lock.acquire` now runs `flock` *inside* the `begin/ensure` so a raising `flock` (EINTR/ENOLCK) can't leak the fd; the redundant-and-hazardous explicit `LOCK_UN` was dropped (`close` releases the lock via the OFD and can't be skipped by a raising unlock). (b) `lock.rb` docstring clarified: `LOCK_NB` is for launchd-daemon pile-up safety, not reactor yielding (the syscalls are ordinary blocking calls, sub-ms on local FS — same as the rest of `State::Store`). +1 regression test (`test_acquire_closes_fd_when_flock_raises`, spy-fd seam). Suite **379/1334/0/0/0**, lint 0; GA3 release tests still green (confirms `close`-only release).

- **Last judged — slice `state-hardening` (CF10 + CF11): JUDGED PASS, merged `--no-ff` → `main` @ `4556e7f` (2026-06-14, fresh judging session).** G0 + GA1–GA5 + GB1–GB4 all PASS, re-run against the verbatim frozen `docs/gates/state-hardening.md`. Integration smoke on `main`: **378/1332/0/0/0**, `standardrb` 0, 51 gems (no new gems). Cross-model adversarial pass on CF10 confirmed the **no-data-loss invariant holds on every exit path** (release on normal/Failure/raise/Interrupt; skip path never writes; no unlink race; lockfile created on first run; no intra-run serialization). CF10 (inter-process `flock` lock across the engine load→write span) + CF11 (`ensure`-clean write temp + dead-code removal) both CLOSED. Detail: `docs/lanes/state-hardening-{A,B}.md`; verdict snapshot in the archive.

## Pointers

- **PRD (build contract):** `docs/prd/repo-tender.md` · CLI-UX PRD `docs/prd/cli-ux.md`
- **Research (evidence ledger):** `docs/research/repo-tender.md`
- **Builder standing context:** `AGENTS.md`
- **Per-slice evidence:** `docs/lanes/<slice>.md` · **frozen gates:** `docs/gates/<slice>.md`
- **Full history (closed slices, decisions log, session log):** `docs/archive/handoff-history-2026-06-14.md`
- **Raw dispatch scratch (builder blocks, spike/repro scripts, raw research findings):** `docs/archive/architect-scratch-2026-06-14.tar.gz`. The `.architect/` working dir was cleared at teardown (gitignored scratch; 256MB of `*.jsonl` transcripts discarded). Any `.architect/<file>` path cited in the lane reports / research docs (e.g. `spike_interactive.rb`, `gc3_liveness_repro.rb`, `*.block.md`) now resolves to `tar xzf docs/archive/architect-scratch-2026-06-14.tar.gz`.

## Verification gate (exact commands)

```
bundle install
bundle exec rake test        # tests > 0, failures = 0, errors = 0, skips = 0
bundle exec standardrb       # exit 0
```

Baseline at `main`: **379/1334/0/0/0**, lint 0, 51 gems.

## Standing lessons (carried forward — not re-derivable from code)

- **Builder = Sonnet 4.6 via `claude -p`** (since the CLI-UX epic; slices 1–6 used minimax-m3 via `pi`). Canary before fan-out: `echo ok | claude -p --model claude-sonnet-4-6 --max-turns 1`.
- **Worktree isolation must be enforced in the block.** A past `pi` dispatch escaped its worktree and corrupted the main checkout (cwd not pinned). Bake the lane's worktree **absolute path** into the block as the repo root, forbid the main path, forbid all `git`. Post-flight always verifies `git -C <worktree> log <freeze>..` is empty (no builder commits).
- **High-stakes slices (schema/persistence/concurrency/API/security) get a cross-model adversarial pass at judgment** — a fresh-context reviewer prompted to break confidence on the invariants, file:line evidence only. (state-hardening CF10 followed this; it cleanly separated the cardinal invariant from two cosmetic nits — see CF12.)
- **No-data-loss is the cardinal invariant** (PRD §1): never mutate a dirty/diverged repo; state writes must not lose prior good rows.

## Open carry-forwards

**None open as numbered CFs.** CF1–CF12 + tty-screen all CLOSED. (Two cosmetic Lane B residuals listed in the TL;DR are candidate CFs the judge may open or wave through.)

## Next slice / open work

**`slice/sync-fixes` is BUILT and awaiting JUDGMENT (fresh session).** Procedure for the judging session:

1. `git diff f208d46..slice/sync-fixes` read in full against `docs/gates/sync-fixes.md` intent.
2. Run G0 (`bundle exec rake test` → ≥ 398, 0F/0E/0S), GL (`standardrb` 0), GG (51 gems). For Lane B GB1–GB5 use `rake test` + per-file runs (the four-file gate command is INVALID-as-written — see TL;DR).
3. **Cross-tier adversarial pass on the Lane B diff** (high-stakes: touches the no-data-loss cardinal invariant). The load-bearing property is GB4 — an unborn repo with uncommitted local files must NEVER be fetched/merged. Confirm with file:line evidence that no path reaches `sync_empty`/`merge --ff-only` when `status.unborn? && !status.clean?` (the `RepoPlan` guard routes those to `:report_dirty`).
4. Per-gate PASS/FAIL/INVALID, then one KILL/CONTINUE. On PASS/CONTINUE: merge `slice/sync-fixes --no-ff` → `main`, delete the lane branches (`lane/sync-fixes-A`, `lane/sync-fixes-B`), archive lane detail, update this TL;DR.

Dispatch record: freeze `f208d46`; builder run-logs at `.architect/wt/sync-fixes-{A,B}.last-run.jsonl` (gitignored); builder blocks at `.architect/wt/sync-fixes-{A,B}.block.md`.

## Teardown (2026-06-14) — PRD complete, loop wound down

The PRD is complete; the architect/builder loop is wound down for this project. Final cleanup:

- **`.architect/` scratch cleared.** Gitignored working dir (257MB). The ~1MB of durable text — builder dispatch blocks, the spike/repro scripts cited as gate evidence, raw research lane findings, freeze records — was archived to `docs/archive/architect-scratch-2026-06-14.tar.gz` (tracked) before deletion. The 256MB of `*.jsonl` builder transcripts were discarded (never cited as durable evidence; distilled outcomes already live in `docs/lanes/`).
- **Salvage branch archived as a tag.** `salvage/slice-4-raw-mixed` (deliberate unmerged forensic scrap from the Slice-4 isolation failure, superseded by the merged Slice 4) → tag **`archive/slice-4-raw-mixed`** (commit `fd9ece4` preserved, reachable, reversible) and the branch ref deleted.
- **Worktree refs pruned.** Only `main` remains as a branch.

To resume work later: spec a new slice per the loop; `.architect/` is recreated on first dispatch (it's gitignored scratch). `.claude/` is untracked project config, left in place.

---

*Branch hygiene 2026-06-14: `slice/state-hardening` merged to `main` and deleted post-judgment. Salvage scrap archived to tag `archive/slice-4-raw-mixed` and its branch deleted. Only `main` remains.*
