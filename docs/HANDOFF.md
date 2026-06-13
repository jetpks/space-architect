# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (minimax-m3 via pi) writes raw
> evidence; architect (Opus 4.8) writes rulings and verdicts. Not in this file =
> didn't happen. Keep this a short table of contents — archive finished-slice
> detail into the slice's lane report, not here.

## TL;DR

- **Goal:** keep local git clones evergreen (clean · on default branch · fresh)
  via a `dry-cli` binary + a periodic launchd `sync` sweep. macOS, GitHub-only.
- **Slice 1 (Foundation) — DONE & MERGED 2026-06-13.** Architect re-ran all 9
  gates (G0–G8 PASS: `rake test` 52/152/0/0/0, `standardrb` 0, `bundle` 0),
  arbitrated the 7 disagreements (6 ACCEPT, 1 MODIFY), merged `slice/foundation`
  → `main` (`7569d95`), integration smoke green. One latent defect logged
  (forge `--no-source`), folded into Slice 2 (gate G11).
- **Slice 2 (Sync engine) — JUDGED PASS & MERGED 2026-06-13.** Architect re-ran
  all 13 gates (G0–G12 **PASS**: `rake test` 85/296/0/0/0, `standardrb` 0,
  `bundle` 0, no new gems), read the diff against PRD §3.3/§5 + the no-data-loss
  invariant (G3/G4/G5-dirty all assert byte-integrity), re-verified `gh` argv vs
  live `gh` 2.93 (CF2 closed), arbitrated all 8 disagreements (8 ACCEPT, 1 with
  a carry-forward CF3). Slice-level verdict **CONTINUE**. Merged
  `slice/sync-engine` → `main` (`--no-ff`; merge sha in session log), integration smoke green.
- **Slice 3 (CLI + config CRUD + CF1) — JUDGED PASS & MERGED 2026-06-13.**
  Full judgment over two sessions: a prior session judged G1–G9 PASS, G0 FAIL
  (partial) — top-level `--help`/`version`/bare exited 1 to stderr instead of 0
  to stdout (builder's "`--help`→exit 0" was false HEARSAY, rule 4 caught it) —
  and raised **CF4**. CF4 fixed inline @ `b4b2d98` (`CLI.run` intercepts the
  exact top-level argv forms before Dry::CLI, reusing `Dry::CLI::Usage`). This
  (fresh) session re-judged **G0 only** (rule 4 — fix's author ≠ judge): re-ran
  the suite (**152/575/0/0/0**), `standardrb` 0, `bundle` 0, no new gems, and the
  executable sub-clause itself — top-level `--help`/`version`/bare all exit **0**
  with usage→**stdout** (5 groups); leaf `sync --help` (0/stdout) + group `repo`
  (1/stderr, G7-accepted) un-regressed; read the CF4 diff (sound, minimal, touches
  only `cli.rb`+test). Protected set + `docs/gates/` diff-clean since freeze
  `3e72e16`; no builder commits. **G0 PASS → 10/10 → CONTINUE.** Merged
  `slice/cli` → `main` (`--no-ff` `87a3f4b`), integration smoke green. Full detail:
  `docs/lanes/slice-3-01.md`. **CF4 CLOSED.**
- **Next action (this/next session): spec & dispatch Slice 4 (launchd).**
  ⚠️ Blocked on a human decision first — see "Current slice" below: Slice 4 gates
  2/3 shell out `launchctl bootstrap/bootout/kickstart` against the human's REAL
  `gui/$UID` domain + `~/Library/LaunchAgents`. A builder must NOT do that
  unsupervised. Architect to confirm the test split (DI-unit gates in CI + a
  manual real-Mac smoke checklist) with the human before freezing gates. Fold in
  **CF3** (state `Org#last_error` + non-clobber) here or as its own state slice.

## Pointers

- **PRD (build contract):** `docs/prd/repo-tender.md`
- **Research (evidence ledger):** `docs/research/repo-tender.md`
- **Builder standing context:** `AGENTS.md`
- **Slices:** PRD §5 — 1 Foundation ✅ → 2 Sync engine ✅ → 3 CLI (current) →
  4 launchd. Hard dependency chain 1→2→3; 4 depends on 3.
- **Slice 1 detail (resolved):** `docs/lanes/slice-1-01.md` (full disagreement
  reasoning + gate→test mapping). Gates: `docs/gates/slice-1.md` (frozen).

## Verification gate (exact commands)

```
bundle install
bundle exec rake test        # tests > 0, failures = 0, errors = 0, skips = 0
bundle exec standardrb       # exit 0
```

## Frozen contracts

- `docs/gates/slice-1.md` — Slice 1, frozen at `65f36c4`. **JUDGED PASS, merged.**
- `docs/gates/slice-2.md` — Slice 2, frozen at `6889a12`. **JUDGED PASS, merged.**
- `docs/gates/slice-3.md` — Slice 3, frozen at `3e72e16`. **JUDGED PASS
  (G0–G9, over two sessions), merged `87a3f4b`.** CF4 (G0 fix) CLOSED.

## Slice 3 — CLI surface + config CRUD (+ CF1) (RESOLVED, archived)

Built (1 lane, freeze `3e72e16`, on `slice/cli`) → judged over two sessions →
merged `87a3f4b`. **G0–G9 all PASS.** Full detail (plan, 8 disagreements +
rulings, PHASE-0 rulings, gate→test mapping, verbatim output, file tree):
**`docs/lanes/slice-3-01.md`**. Gates frozen at `docs/gates/slice-3.md`. Notable:
- G1–G9 judged in the first judgment session (`33a130c`) — real on-disk
  config / real bare-remote repos / real subprocess exit, no mocks; diff read vs
  PRD §1/§3.1/§3.3/§5; all 8 disagreements ACCEPT (#1 +CF4, #5 top-level/group
  boundary). CF1 lands here (duration parses at the config-load layer). CF3
  deferred (orthogonal state-schema change).
- G0 FAILed there on the executable sub-clause (top-level `--help`/`version`
  exited 1/stderr; builder's "exit 0" was false HEARSAY) → **CF4**, fixed inline
  @ `b4b2d98`, then re-judged G0 PASS this (fresh) session per rule 4: suite
  152/575/0/0/0, lint 0, no new gems, top-level `--help`/`version`/bare all exit
  0 to stdout (5 groups), leaf/group un-regressed, CF4 diff sound. **CF4 CLOSED.**

## Slice 2 — Sync engine (RESOLVED, archived)

Built (1 lane, main checkout, freeze `6889a12`) → JUDGED PASS → merged to `main`.
Full detail (plan, disagreement reasoning, gate→test mapping, verbatim command
output, file tree): **`docs/lanes/slice-2-01.md`**. Gates frozen at
`docs/gates/slice-2.md`. Verdict table + rulings retained below for the record.

All verdicts rendered by the architect this session (gates re-run, named tests
opened and confirmed real-repo / DI-not-mock, diff read against PRD intent).

| Gate | Threshold (short) | Architect verdict (own check) |
|------|-------------------|-------------------------------|
| G0 | suite green + lint clean, no new gems | **PASS** — re-ran: `bundle` 0, `rake test` 85/296/0/0/0, `standardrb` 0, no new gems |
| G1 | clean+behind → ff → up-to-date, clean | **PASS** — real bare+clone; status clean; `remote.md` on disk |
| G2 | fresh → no network (FETCH_HEAD unchanged) | **PASS** — real repo; FETCH_HEAD mtime unchanged |
| G3 | dirty → byte-untouched + reported | **PASS** — bytes + HEAD identical; status dirty, last_error nil |
| G4 | diverged → no destruction, commits intact | **PASS** — diverged; local commit + file intact; no reset/merge |
| G5 | wrong-branch: clean switched, dirty left | **PASS** — 3 real-repo tests; dirty wrong_branch + detached left untouched |
| G6 | missing → clone to $BASE/host/owner/repo | **PASS** — clone at exact derived path; path derivation tested unmocked (url_builder = legit transport seam) |
| G7 | concurrency:2 → max in-flight ≤ 2 | **PASS** — SlowSCM `max_seen <= 2`, all 5 complete (DI on collaborator) |
| G8 | per-repo Failure isolated + state written | **PASS** — StubSCM Failure isolated→error+last_error; unhandled raise captured |
| G9 | idempotent: 2nd run no network | **PASS** — 2nd-run FETCH_HEAD mtime unchanged |
| G10 | org expansion + org-list Failure resilient | **PASS** — expand+dedupe(explicit wins)+Failure recorded (`last_listed_at: nil`); see #5 ruling + CF3 |
| G11 | forge argv valid (no `--no-source`) | **PASS** — argv valid set asserted; re-verified vs live `gh` 2.93; CF2 closed |
| G12 | only in-scope files | **PASS** — integrity-checked (all in Builds+Extends; no builder commits) |

**Slice-level verdict: 12/12 (G0–G12) PASS → CONTINUE.** No-data-loss invariant
(PRD §1) upheld. Merged to `main` (`--no-ff`; merge sha in session log).

## Slice 2 disagreements — RULED (full reasoning: `docs/lanes/slice-2-01.md` §1)

All 8 arbitrated this session against the diff + gate intent. **8 ACCEPT**; #5
accepted *with carry-forward CF3*.

| # | Builder's position (short) | Ruling |
|---|----------------------------|--------|
| 1 | `SCM#switch` thin `git switch`; dirty-guard in the plan (layered w/ git refusal) | **ACCEPT** — verified: plan returns `:report_wrong_branch`/`:report_detached` for dirty; `switch` surfaces git's refusal as `Failure`; G5 dirty+detached tests prove never-switched |
| 2 | "behind?" uses `SCM::Status#ahead/#behind` (porcelain `branch.ab`), no new boundary | **ACCEPT** — plan re-reads `status` after `fetch`; G1 (behind→ff) and G4 (ahead→diverged) prove correct post-fetch classification |
| 3 | freshness: nil/Failure/stale-mtime all ⇒ fetch; never skip on unreadable FETCH_HEAD | **ACCEPT** — matches gate G2 / PRD §6 intent; conservative direction |
| 4 | 10th action `:report_error` → `status: error` (spec listed 9) | **ACCEPT** — required by G8; keeps engine dispatch uniform |
| 5 | **org-list Failure encoded as `Org(last_listed_at: nil, repo_count: 0)`** (Org has no `last_error`; `state/store.rb` MUST NOT TOUCH) | **ACCEPT + CF3.** G10 "recorded in state" **holds**: `last_listed_at: nil` is a *distinguishable* failure marker (success always sets `last_listed_at: now`), and the run does not abort. Two non-blocking gaps → CF3: (a) no `last_error` text in state; (b) a transient failure clobbers the prior good `repo_count` via `prev.orgs.merge`. Previously-discovered *repos* are preserved (`prev.repos.dup`) — no repo data loss. |
| 6 | engine takes injected `url_builder:` (default HTTPS); tests inject `file://` | **ACCEPT** — G6's real subject (clone lands at exact derived **path**) is tested unmocked; `url_builder` only swaps transport for an offline clone, and is a legit future seam (ssh/token). URL is *derived* from the ref, not stored — gate satisfied |
| 7 | org expansion sequential (not fanned out) before the per-repo barrier | **ACCEPT** — gate doesn't require fan-out; simpler failure semantics |
| 8 | `:fast_forward` executed by existing `SCM#fast_forward` (own rev-list); plan only decides | **ACCEPT** — clean layer split; plan fetches once, `fast_forward`'s rev-list is read-only (no double network), G1 green |

**PHASE-0 rulings CONFIRMED:** repo_plan/engine seam (decision vs execution);
FETCH_HEAD tolerance (nil/Failure/stale → fetch, never skip on absent);
`switch` guard lives in the plan + layered with git's own refusal. "no
`--no-source`" claim **re-verified against live `gh` 2.93** (`--source` /
`--no-archived` exist; `--no-source` does not).

## Carry-forward items (architect-tracked)

| # | Item | Where it lands | From |
|---|------|----------------|------|
| CF1 | `refresh_interval` human durations (`6h`/`90m`) must parse at the **config-load layer** (PRD §3.1 documents them in the hand-editable config file), not just CLI input. Until done, PRD §3.1's `6h` example is load-incompatible. | **Slice 3** gate | Disagreement #1 ruling (MODIFY) |
| CF2 | Forge `--no-source` invalid `gh` flag → drop it; rely on authoritative `parse_repos` filter. | ✅ **CLOSED** — Slice 2 gate G11 PASS (argv valid, verified vs live `gh`). | Slice 1 judgment |
| CF3 | `State::Store::Org` should carry an org-list `last_error` (text), and an org-list `Failure` should **not** clobber the prior good `repo_count`/`last_listed_at` (currently `prev.orgs.merge` overwrites it with nil/0). Schema change to `state/store.rb`. Not a no-data-loss violation (repos are preserved); cosmetic state regression only. | **Slice 4** or a dedicated state slice (deferred — orthogonal to the CLI) | Slice 2 disagreement #5 ruling (ACCEPT) |
| CF4 | Top-level `repo-tender --help`, `repo-tender version`, and bare `repo-tender` must print usage/version to **stdout** and **exit 0** (gate G0). Were hitting Dry::CLI's no-leaf `Usage.call`→`exit(1)` path. | ✅ **CLOSED** — fixed inline @ `b4b2d98`, re-judged G0 PASS in a fresh session (rule 4) and merged to `main` (`87a3f4b`). Top-level `--help`/`version`/bare exit 0 to stdout; leaf/group un-regressed. | Slice 3 judgment (G0 FAIL) + disagreement #1 ruling |

## Slice 1 disagreements — RULED (full reasoning: `docs/lanes/slice-1-01.md` §1)

| # | Topic | Ruling |
|---|-------|--------|
| 1 | refresh_interval Integer-only in Slice 1, durations deferred | **MODIFY** — defer OK (no Slice 1 gate needs it); durations parse in the config-load layer at Slice 3 (CF1), not just CLI |
| 2 | "missing required field" via nested `repos[].owner` | **ACCEPT** — all top-level fields have legit defaults |
| 3 | round-trip preserves only managed keys; comments/unknown lost (documented + tested) | **ACCEPT** — exactly what G1 + PRD §2 allow |
| 4 | `include_archived`/`include_forks` defaults in dry-struct types | **ACCEPT** — single source of default, matches PRD §3.1 |
| 5 | pin ALL PRD §2 gems now | **ACCEPT** — serves G0 reproducibility |
| 6 | non-coercing `schema` not `params` | **ACCEPT** — correct; `params` would coerce `"8"`/`8.5` and defeat G2 |
| 7 | immutable update via `cfg.new(...)` + `Store.with` | **ACCEPT** — dry-struct idiom; no `with` exists |

**PHASE-0 rulings CONFIRMED:** minitest; standardrb; `gh` 2.93 `--json` fields
`defaultBranchRef`/`isArchived`/`isFork` (architect re-verified live).

## Decisions log (architect + human)

| Date | Decision | Why |
|------|----------|-----|
| 2026-06-12 | `git init` the repo; `.architect/` gitignored | Loop requires git (worktrees, freeze commits, post-flight log checks); raw scratch out of durable memory |
| 2026-06-12 | `Gemfile.lock` committed | repo-tender is an installed app, not a library; reproducibility is a DoD goal |
| 2026-06-12 | Slice 1 = 1 lane, main checkout, xhigh | Greenfield foundation can't be split disjointly; also the env canary |
| 2026-06-13 | Slice 2 extends `scm/{client,git}.rb` (add `switch`) | Branch-switch is core to the "on default branch" evergreen invariant (G5); single lane ⇒ no parallel collision touching Slice 1 files |
| 2026-06-13 | CF4 (G0 `--help`/`version` exit-0 fix) fixed HUMAN-INLINE, not via a corrective builder lane | Trivial ~5–10 line change in the `CLI.run` seam; skill says trivial fixes don't need the loop. Architect stays out of impl code (rule 1); a later session re-runs G0 and merges |
| 2026-06-13 | Forge `--no-source` fix folded into Slice 2 (G11) not a Slice 1 re-dispatch | Defect isn't on any Slice 1 execution path; the engine is where the forge first runs live |

## Next slice (architect decides after Slice 3 PASS)

Slice 4 — launchd integration + daemon control (`launchd/{plist,agent}`,
`cli/daemon`, log rotation). Depends on Slice 3. See PRD §5 Slice 4 (several
gates are integration-level on a real Mac — may run as a documented manual
checklist rather than CI). Also fold in **CF3** (state `Org#last_error` +
non-clobber) here or as its own small state-schema slice, architect's call.

## Session log

| Date | Role | Slice | Commits | Gates P/F | Notes |
|------|------|-------|---------|-----------|-------|
| 2026-06-12 | architect | 1 | freeze (init) | pending | Ground + setup: git init, AGENTS.md, gates frozen, canary dispatched |
| 2026-06-13 | builder (m3) | 1 | none (UNJUDGED) | builder: 52/0/0 | Foundation built; preserved on slice/foundation @ a016eba; integrity PASS; 7 disagreements raised |
| 2026-06-13 | architect | 1 | a016eba (preserve) | G8 integrity PASS; rest pending | Post-flight integrity; did NOT judge gates (rule 4); deferred |
| 2026-06-13 | architect | 1 | 7569d95 (merge) | **G0–G8 PASS → CONTINUE** | Re-ran all gates; arbitrated 7 (6 ACCEPT, 1 MODIFY); merged to main; logged CF1/CF2 |
| 2026-06-13 | architect | 2 | 6889a12 (freeze) | n/a | Slice 2 spec'd, gates G0–G12 frozen, dispatched (1 lane) |
| 2026-06-13 | builder (m3) | 2 | none (UNJUDGED) | builder: 85/296/0/0/0 | Sync engine built; preserved on slice/sync-engine @ a7cbeb2; integrity PASS; 8 disagreements raised |
| 2026-06-13 | architect | 2 | a7cbeb2 (preserve) | G12 integrity PASS; rest pending | Post-flight integrity; did NOT judge gates (rule 4); flagged JUDGMENT TARGETS #5/#6; deferred |
| 2026-06-13 | architect | 2 | be73b04 (merge) | **G0–G12 PASS → CONTINUE** | Re-ran all 13 gates; arbitrated 8 disagreements (8 ACCEPT, #5 +CF3); re-verified `gh` argv live (CF2 closed); read diff vs PRD §3.3/§5 + no-data-loss; merged `slice/sync-engine`→`main` |
| 2026-06-13 | architect | 3 | 3e72e16 (freeze) | n/a | Slice 3 spec'd, gates G0–G9 frozen (CF1 in, CF3 deferred), dispatched on slice/cli (1 lane, xhigh); main stays at eb57976 |
| 2026-06-13 | builder (m3) | 3 | none (UNJUDGED) | builder: 147/548/0/0/0 | CLI + config CRUD + CF1 built; 1st run hit step cap, finished via `--session-id slice-3` continue; preserved on slice/cli @ c4bb2c2; integrity PASS; 8 disagreements raised |
| 2026-06-13 | architect | 3 | c4bb2c2 (preserve) | G9 integrity PASS; rest pending | Post-flight integrity; did NOT judge gates (rule 4); flagged JUDGMENT TARGETS #1/#5; deferred |
| 2026-06-13 | architect | 3 | (judgment, no merge) | **G1–G9 PASS, G0 FAIL (partial) → CONTINUE** | Fresh session judged Slice 3: re-ran all gates, opened named tests (real config/repo/subprocess, no mocks), read diff vs PRD §1/§3.1/§3.3/§5, verified gates+protected files diff-clean. Arbitrated 8 (8 ACCEPT; #1+CF4, #5 boundary). G0 exec sub-clause FAILS (top-level `--help`/`version` exit 1, not 0) — builder HEARSAY false. NOT merged; CF4 raised to fix before merge |
| 2026-06-13 | architect (inline fix) | 3 | b4b2d98 (slice/cli) | suite 152/575/0/0/0, lint 0 | CF4 fixed inline at human direction: `CLI.run` intercepts top-level help/version → stdout/exit 0 (reuses Dry::CLI Usage); leaf/group behavior un-regressed; +5 subprocess regression tests. Did NOT self-judge G0 / merge (rule 4) — left for a fresh session |
| 2026-06-13 | architect | 3 | 87a3f4b (merge) | **G0 PASS (re-judge) → 10/10 → CONTINUE** | Fresh session re-judged G0 only (rule 4, fix author ≠ judge): re-ran suite 152/575/0/0/0, lint 0, no new gems; top-level `--help`/`version`/bare all exit 0 to stdout (5 groups); leaf `sync --help` 0/stdout + group `repo` 1/stderr un-regressed; read CF4 diff (sound, only cli.rb+test, no protected files); gates+protected set diff-clean since freeze; no builder commits. Merged `slice/cli`→`main` (`--no-ff`), integration smoke green. CF4 CLOSED. Slice 4 next (blocked on human launchctl-test-strategy decision) |
