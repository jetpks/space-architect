# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (Sonnet 4.6 via `claude -p`) writes
> raw evidence; architect (Opus 4.8) writes rulings and verdicts. **Not in this
> file = didn't happen.** Keep this a short table of contents: TL;DR + pointers +
> open work. Finished-slice detail lives in `docs/lanes/<slice>.md`; the full
> historical narrative (closed slices, decisions log, session log) is archived in
> `docs/archive/handoff-history-2026-06-14.md`.

## TL;DR

**Status (2026-06-14): loop re-spun for slice `interactive-status` — DISPATCHED, awaiting builder + next-session judging.** Gates frozen at `docs/gates/interactive-status.md` (freeze base `6ea0711`, baseline 398/1404/0/0/0, lint 0, `bundle list` 53). Scope: (1) flash the in-flight repo on the rewritten sweep status line (via already-emitted `repo_started`/`repo_phase`); (2) richer end-of-run summary — aggregate git-stats breakdown + **real** pulled-commit count + added-repos list that collapses to a count above a volume threshold (`ADDED_LIST_THRESHOLD = 10`). One lane (`interactive-status-01`, main checkout) — the change is one cohesive `repo_finished` signature contract spanning SCM/engine/4 reporters; splitting would break lane independence. Design decisions confirmed with the human: real commit counts (touches `SCM::Git#fast_forward` Success payload: symbol→integer commits) + volume-threshold (not org-first-sync join). **Do not judge in this session (rule 4).**

**Prior status (2026-06-14): slice `sync-fixes` JUDGED PASS → merged `--no-ff` to `main` @ `585ccba` (fresh judging session, rule 4 satisfied).** Both lanes' gates re-run against the verbatim frozen `docs/gates/sync-fixes.md`; integration smoke on `main`: **398/1404/0/0/0, standardrb 0, 51 gems** (baseline was 379/1334). Lane + slice branches deleted. Lane evidence retained at `docs/lanes/sync-fixes-{A,B}.md`; frozen gates at `docs/gates/sync-fixes.md`.

**Per-gate verdicts (this session, measured by the architect):**
- **G0** `rake test` → 398/1404/0/0/0 → **PASS** (≥ 379 + new, strictly >379).
- **GL** `standardrb` → exit 0 → **PASS**. · **GG** 51 gems → **PASS** (unchanged).
- **GA1/GA2/GA3** `interactive_reporter_test.rb` 25 runs 0F/0E → **PASS** (org block contiguous, precedes sweep lines; pre-fix fail / post-fix pass confirmed in lane report).
- **GB1–GB5** measured per-file (`status` 9 · `git` 17 · `repo_plan` 19 · `engine` 42, all 0F/0E) + `rake test` → **PASS**.
- **Lane B four-file gate command → INVALID-as-written** (architect's freeze defect, caught by Lane B PHASE 0): `ruby a b c d` runs only `a`; `b c d` become `ARGV`. Gate file was **not** edited (rule 3 clean). Underlying gates measured via `rake` + per-file, all PASS.
- **GB4 (no-data-loss cardinal invariant) — traced to file:line:** `:sync_empty` is produced only at `repo_plan.rb:79` under `unborn? && clean?`; `@scm.sync_empty` (the only fetch+`merge --ff-only`) is called only at `engine.rb:374 when :sync_empty`. Unborn **+dirty** → `:report_dirty` (`engine.rb:388`, no SCM mutation). GB4 test asserts byte-identical file, `dirty`, nil error, HEAD still `(initial)`. Invariant holds.

**Slice-level call: CONTINUE / PASS.**

**Arbitration of the two Lane B residual concerns (judge's ruling):**
1. `:report_dirty` re-probes `default_branch` on unborn dirty → one harmless local `set-head -a` call. **WAVE THROUGH** (won't-fix) — no correctness/safety impact, GB4 passes; not worth a CF on a wound-down loop.
2. `sync_empty` + engine double-probe `default_branch` after success → one redundant read. **WAVE THROUGH** — harmless, matches spec as written.

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
- **Never freeze a multi-file `ruby a.rb b.rb c.rb` gate command.** Ruby runs only the first file; the rest become `ARGV`. The `sync-fixes` Lane B gate command was frozen this way and was INVALID-as-written (silently ran 9/87 tests). For multi-suite gates use `bundle exec rake test`, or one `ruby -Itest <file>` command **per** file, or `ruby -Itest -e 'Dir["..."].each{require ...}'`.

## Open carry-forwards

**None open as numbered CFs.** CF1–CF12 + tty-screen all CLOSED. The two cosmetic Lane B residuals were **waved through** at judgment (see TL;DR arbitration) — not opened as CFs.

## Next slice / open work

**In flight: slice `interactive-status` (DISPATCHED 2026-06-14).** Freeze base `6ea0711`; gates at `docs/gates/interactive-status.md`. One lane, dispatched in the main checkout (builder block at `.architect/interactive-status-01.block.md`); builder writes raw evidence to `docs/lanes/interactive-status-01.md`. **Next architect session:** post-flight (builder made no commits: `git log 6ea0711..` empty; `git diff` on `docs/gates/` clean; writes confined to the declared file set), then run G0–G5 verbatim and judge. Merge to `main` only on PASS/CONTINUE.

Declared file-touch set for the lane (writes outside this set FAIL the lane):
- `lib/repo_tender/scm/git.rb`, `lib/repo_tender/scm/client.rb`
- `lib/repo_tender/sync/engine.rb`
- `lib/repo_tender/ui/interactive_reporter.rb`, `lib/repo_tender/ui/reporter.rb`, `lib/repo_tender/ui/plain_reporter.rb`, `lib/repo_tender/ui/json_reporter.rb`
- `test/repo_tender/scm/git_test.rb`, `test/repo_tender/sync/engine_test.rb`, `test/repo_tender/ui/interactive_reporter_test.rb`, `test/repo_tender/ui/json_reporter_test.rb`, `test/repo_tender/ui/plain_reporter_test.rb`
- `docs/lanes/interactive-status-01.md` (lane report)

`main` not pushed to `origin` — leave that to the human.

## Teardown (2026-06-14) — PRD complete, loop wound down

The PRD is complete; the architect/builder loop is wound down for this project. Final cleanup:

- **`.architect/` scratch cleared.** Gitignored working dir (257MB). The ~1MB of durable text — builder dispatch blocks, the spike/repro scripts cited as gate evidence, raw research lane findings, freeze records — was archived to `docs/archive/architect-scratch-2026-06-14.tar.gz` (tracked) before deletion. The 256MB of `*.jsonl` builder transcripts were discarded (never cited as durable evidence; distilled outcomes already live in `docs/lanes/`).
- **Salvage branch archived as a tag.** `salvage/slice-4-raw-mixed` (deliberate unmerged forensic scrap from the Slice-4 isolation failure, superseded by the merged Slice 4) → tag **`archive/slice-4-raw-mixed`** (commit `fd9ece4` preserved, reachable, reversible) and the branch ref deleted.
- **Worktree refs pruned.** Only `main` remains as a branch.

To resume work later: spec a new slice per the loop; `.architect/` is recreated on first dispatch (it's gitignored scratch). `.claude/` is untracked project config, left in place.

---

*Branch hygiene 2026-06-14: `slice/state-hardening` merged to `main` and deleted post-judgment. Salvage scrap archived to tag `archive/slice-4-raw-mixed` and its branch deleted. Only `main` remains.*
