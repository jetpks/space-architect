# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (Sonnet 4.6 via `claude -p`) writes
> raw evidence; architect (Opus 4.8) writes rulings and verdicts. **Not in this
> file = didn't happen.** Keep this a short table of contents: TL;DR + pointers +
> open work. Finished-slice detail lives in `docs/lanes/<slice>.md`; the full
> historical narrative (closed slices, decisions log, session log) is archived in
> `docs/archive/handoff-history-2026-06-14.md`.

## TL;DR

**Status (2026-06-15): loop RE-OPENED — slice `clone-and-config` SPECCED + FROZEN + DISPATCHED (two lanes).** New human ask: one bug + three feature touches. PRD `docs/prd/clone-and-config.md`; frozen gates `docs/gates/clone-and-config.md` (G0/GL/GG global + GA1–GA5 Lane A + GB1–GB5 Lane B). Freeze baseline at `main` HEAD `31bb69c`: **408/1461/0/0/0**, standardrb 0, 53 gems. Scope: (1) **bug** — `Config::Store.emit` dumps symbol-keyed YAML (`:base_dir:`); fix to clean string-key YAML, omit default host / false flags / empty `ignored_repos`. **Verified the state file is NOT affected** (`State::Store#to_h_compact` already string-keyed) — answers the human's "haven't verified" note. (2) `ignored_repos` per-org exclusion list (model + contract + authoritative filter in `Forge::GitHub#parse_repos`). (3) `org add --ignored-repos` (forks/archived flags already exist). (4) new `clone NAME... [--into DIR]` command — macOS `cp -Rc` COW copy of evergreen repos, no-clobber, multi-repo. Lanes disjoint by file set: **Lane A** = config/forge/org-cli (items 1–3); **Lane B** = clone command (item 4). Human decisions locked: variadic clone + `--into` parent dir; "omit empty/default" YAML (drops default host too). **Verdict belongs to the NEXT session** (rule 4: never judge a run dispatched this session). Lane reports land at `docs/lanes/clone-and-config-{A,B}.md`.

**Prior status (2026-06-14): slice `interactive-status` JUDGED PASS → merged `--no-ff` to `main` @ `cfa90bd` (fresh judging session, rule 4 satisfied).** All 8 frozen gates re-run verbatim against `docs/gates/interactive-status.md`; integration smoke on `main`: **407/1458/0/0/0, standardrb 0, 53 gems** (baseline at freeze was 398/1404). Slice branch deleted. Lane evidence at `docs/lanes/interactive-status-01.md` (architect-reconstructed, marked as such); frozen gates at `docs/gates/interactive-status.md`. Scope delivered: (1) flash the most-recently-started in-flight repo on the rewritten sweep status line; (2) end-of-run breakdown + **real** pulled-commit count + added-repos list collapsing above `ADDED_LIST_THRESHOLD = 10`. Shared `repo_finished(ref, status, action:, commits:)` across all 4 reporters; `SCM::Git#fast_forward` Success payload symbol→Integer; engine maps each `plan.action`→realized action+commits.

**Per-gate verdicts (this session, measured by the architect on its own fresh runs):**
- **G0** `rake test` → 407/1458/0/0/0 → **PASS** (> 398 baseline, strictly grown +9).
- **GL** `standardrb` → exit 0 → **PASS**. · **GG** `bundle list | wc -l` → 53 → **PASS** (no new gems).
- **G1** flash verbs (checking/cloning/fast-forwarding/switching + `owner/repo-a`) appear; clear-on-finish verified in impl (`@in_flight.delete` → empty ⇒ no suffix) → **PASS**.
- **G2** breakdown (cloned 2 / fast-forwarded / 7 commit / up-to-date / dirty / error) + added-list (≤10, both refs) → **PASS**. · **G3** collapse `added 15 repos`, names absent → **PASS**.
- **G4** `git_test.rb` real temp repos+bare remote: `Success(N≥1)` behind, `Success(0)` up-to-date, divergence still `Failure` w/ `:reason`/`local_ahead`/`remote_ahead` → **PASS**.
- **G5** `engine_test.rb` RecordingReporter DI: ff'd→`action: :fast_forwarded, commits: 3`; cloned→`:cloned` → **PASS**.

**Cardinal no-data-loss invariant (PRD §1): HOLDS.** `scm/git.rb` changes only the Success *payload* (`:up_to_date`→`0`, `:fast_forwarded`→`right`); `merge --ff-only` + the divergence `Failure` branch are byte-for-byte untouched. `engine.rb` is purely additive — every observe-path still does the same nil-safe `default_branch` probe with no SCM mutation; the only structural change splits one combined `when` into per-status clauses. Opus 4.8 fresh-context diff read = the cross-tier adversarial pass; single-invariant slice, traced to file:line, no separate `claude -p` skeptic needed.

**Slice-level call: CONTINUE / PASS.**

**Process notes (weighed, did not fail the slice):** (1) the builder (`claude -p`) overflowed its 200k context after G4/G5 passed but before writing its lane report, so `docs/lanes/interactive-status-01.md` is **architect-reconstructed** and no **PHASE 0 disagreement record** persisted — a process gap, not a correctness defect (risk of a swallowed bad instruction is low precisely because the full diff was read independently and found faithful + complete). (2) **Waved through (won't-fix):** G1's final assertion uses `frames.any? { !include? }` rather than asserting `frames.last` lacks the ref — weaker than the gate's "next tick" intent, but behavior is verified correct in the impl; a test-strength nit on a wound-down loop.

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
- **A long-running `claude -p` builder can overflow its 200k context (`Prompt is too long`) and die *after* verification passes but *before* writing its lane report.** Happened on `interactive-status` (121 turns, ~47 min, 12.6M cumulative cache reads). Consequences: lane report must be architect-reconstructed and the PHASE 0 disagreement record is lost (it lived only in the discarded transcript). Mitigations for long lanes: keep the lane block tight, instruct the builder to write its lane report *and* its PHASE 0 record **early** (right after PHASE 0, append as it goes) rather than only at the end, and persist PHASE 0 to a committed-by-architect file, not just chat. At judging, a lost PHASE 0 record is a process gap, not an automatic FAIL — but it removes the silent-compliance audit, so the architect's own full diff-vs-intent read carries the weight.
- **Never freeze a multi-file `ruby a.rb b.rb c.rb` gate command.** Ruby runs only the first file; the rest become `ARGV`. The `sync-fixes` Lane B gate command was frozen this way and was INVALID-as-written (silently ran 9/87 tests). For multi-suite gates use `bundle exec rake test`, or one `ruby -Itest <file>` command **per** file, or `ruby -Itest -e 'Dir["..."].each{require ...}'`.

## Open carry-forwards

**None open as numbered CFs.** CF1–CF12 + tty-screen all CLOSED. The two cosmetic Lane B residuals were **waved through** at judgment (see TL;DR arbitration) — not opened as CFs.

## Next slice / open work

**IN FLIGHT — slice `clone-and-config` (2026-06-15).** Specced, gates frozen, two lanes dispatched off freeze commit (the commit that adds `docs/prd/clone-and-config.md` + `docs/gates/clone-and-config.md`). Worktrees: `.architect/wt/clone-and-config-A` (lane/clone-and-config-A) + `.architect/wt/clone-and-config-B` (lane/clone-and-config-B). **NEXT SESSION judges:** per-lane post-flight (no commits, in-bounds files only, gates clean), re-run G0/GL/GG + GA1–GA5 + GB1–GB5 verbatim, read the diff against the PRD intent (no-data-loss: GA2 emit must not change loaded value; GB3 no-clobber; GB1 source unchanged), then integrate passing lanes into `slice/clone-and-config` and judge there. Lane B touches `cli.rb` — Lane A does not; sets are disjoint (see gates file).

**Prior (closed): slice `interactive-status` JUDGED PASS and merged to `main` @ `cfa90bd` (2026-06-14).** The original PRD epic was complete and the loop was wound down (see Teardown below) — the loop is now re-opened for this follow-up batch.

`main` ahead of `origin/main` — leave the push to the human.

## Teardown (2026-06-14) — PRD complete, loop wound down

The PRD is complete; the architect/builder loop is wound down for this project. Final cleanup:

- **`.architect/` scratch cleared.** Gitignored working dir (257MB). The ~1MB of durable text — builder dispatch blocks, the spike/repro scripts cited as gate evidence, raw research lane findings, freeze records — was archived to `docs/archive/architect-scratch-2026-06-14.tar.gz` (tracked) before deletion. The 256MB of `*.jsonl` builder transcripts were discarded (never cited as durable evidence; distilled outcomes already live in `docs/lanes/`).
- **Salvage branch archived as a tag.** `salvage/slice-4-raw-mixed` (deliberate unmerged forensic scrap from the Slice-4 isolation failure, superseded by the merged Slice 4) → tag **`archive/slice-4-raw-mixed`** (commit `fd9ece4` preserved, reachable, reversible) and the branch ref deleted.
- **Worktree refs pruned.** Only `main` remains as a branch.

To resume work later: spec a new slice per the loop; `.architect/` is recreated on first dispatch (it's gitignored scratch). `.claude/` is untracked project config, left in place.

---

*Branch hygiene 2026-06-14: `slice/state-hardening` merged to `main` and deleted post-judgment. Salvage scrap archived to tag `archive/slice-4-raw-mixed` and its branch deleted. Only `main` remains.*
