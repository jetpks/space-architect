# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (minimax-m3 via pi) writes raw
> evidence; architect (Opus 4.8) writes rulings and verdicts. Not in this file =
> didn't happen. Keep this a short table of contents — archive finished-slice
> detail into the slice's lane report, not here.

## TL;DR

- **Goal:** keep local git clones evergreen (clean · on default branch · fresh)
  via a `dry-cli` binary + a periodic launchd `sync` sweep. macOS, GitHub-only.
- **Last slice:** Slice 1 (Foundation) — **BUILT 2026-06-13, UNJUDGED.** Builder
  run completed clean (exit 0); work preserved on branch `slice/foundation`
  (`a016eba`). Post-flight integrity PASSED. Gate verdict NOT yet rendered
  (hard rule 4 — never judge in the dispatching session).
- **Next action (fresh architect session):** on branch `slice/foundation`, (1)
  arbitrate the 7 Open Disagreements below (ACCEPT/REJECT/MODIFY each), (2) run
  `docs/gates/slice-1.md` G0–G8 yourself — `bundle install && bundle exec rake
  test && bundle exec standardrb` — and open each gate→test mapping (lane report
  §2) to confirm no-mock real-repo coverage, (3) read the diff `git diff
  main..slice/foundation` against PRD §3/§5 intent, (4) render PASS/FAIL →
  KILL/CONTINUE. On PASS/CONTINUE: `git checkout main && git merge --no-ff
  slice/foundation`, then spec Slice 2.

## Pointers

- **PRD (build contract):** `docs/prd/repo-tender.md`
- **Research (evidence ledger):** `docs/research/repo-tender.md`
- **Builder standing context:** `AGENTS.md`
- **Slices:** PRD §5 — 1 Foundation → 2 Sync engine → 3 CLI → 4 launchd.
  Hard dependency chain 1→2→3; 4 depends on 3. No two slices share files.

## Verification gate (exact commands)

```
bundle install
bundle exec rake test        # tests > 0, failures = 0, errors = 0
bundle exec standardrb       # exit 0
```

## Frozen contracts

- `docs/gates/slice-1.md` — frozen at the Slice 1 freeze commit (below), BEFORE
  work began. Read-only.

## Current slice

- **Spec:** Slice 1 Foundation — PRD §5 + `docs/gates/slice-1.md`.
- **Gates:** `docs/gates/slice-1.md` (G0–G8), frozen at `65f36c4`.
  Builder freeze base = the commit recording this SHA (post-flight:
  `git log <freeze>..` must be empty, `git status` only Slice 1 files).
- **Lanes:** 1 lane (greenfield foundation — shared skeleton + interdependent
  modules; not splittable without collision). Dispatched in the main checkout.
  Report → `docs/lanes/slice-1-01.md`.
- **Effort:** xhigh — large foundational API surface, correctness-critical.
- **Canary:** first dispatch in this environment.

Raw result column = **builder-reported (hearsay)**; verdict column filled by the
next session after running the gates itself.

| Gate | Threshold | Builder-reported raw result | Architect verdict |
|------|-----------|------------------------------|-------------------|
| G0 | suite green, lint clean, locked stack | `bundle install` exit 0 (48 gems); `rake test` → 52 runs, 152 assertions, 0 fail/err/skip; `standardrb` exit 0; mise pins ruby 4.0.5 | _pending next session_ |
| G1 | config round-trip, managed fields identical | `store_test.rb`: round-trip + emits-only-managed-fields | _pending_ |
| G2 | field-level reject of 5 bad-input cases | `contract_test.rb`: 7 tests (uses non-coercing `schema`, see disagreement #6) | _pending_ |
| G3 | XDG overrides + base default | `paths_test.rb`: 7 tests | _pending_ |
| G4 | non-blocking; 2× sleep 0.3 < 0.6s | `shell_test.rb`: overlap test + Failure-shape | _pending_ |
| G5 | real temp repo; trunk default; ff refuses on divergence | `git_test.rb` 12 runs/31 assertions; divergence → Failure, local commit+file intact | _pending_ |
| G6 | offline fixture; stub Shell not Forge | `github_test.rb`: 7 tests, recorded fixture, auth-status probe | _pending_ |
| G7 | state round-trip; 7-value enum | `state/store_test.rb`: 4 tests | _pending_ |
| G8 | only in-scope files | architect-verified ✓ (all in Builds set) | **PASS (integrity)** |

## Open disagreements (builder writes; architect rules)

Full reasoning in `docs/lanes/slice-1-01.md` §1. **All 7 pending arbitration by
the next session** — none ruled in the dispatching session.

| # | Builder's position | Spec's position | Evidence | Ruling |
|---|--------------------|-----------------|----------|--------|
| 1 | `refresh_interval` stored as Integer seconds in Slice 1; human durations (`6h`/`90m`) are a Slice 3 CLI-input concern | PRD §3.1 lists `"6h"`/`"90m"`/int seconds | PRD §3.1, gate G2 `"6x"` case | _pending_ |
| 2 | "missing required field" (G2) tested via nested `repos[].owner`, since every top-level field has a default | G2 says "missing required field" generically | gates G2; PRD §3.1 | _pending_ |
| 3 | round-trip preserves only managed top-level keys; comments+unknown keys lost (documented + test-covered) | G1 allows loss only if documented | gates G1; PRD §2 | _pending_ |
| 4 | `include_archived`/`include_forks` defaults live in dry-struct types, contract makes them optional | PRD §3.1 default false | PRD §3.1 | _pending_ |
| 5 | pin ALL PRD §2 gems now (incl. dry-cli, unused in Slice 1) for a day-1 locked stack | G0 lock reproducibility | PRD §2; gates G0 | _pending_ |
| 6 | contract uses non-coercing `schema do…end` not `params` (else `concurrency:"8"`/`8.5` silently coerce, defeating G2) | unspecified; G2 example `concurrency:"8"` | gates G2 | _pending_ |
| 7 | `Config::Store` update is immutable `cfg.new(...)` (dry-struct has no `with`); store exposes `update{}` + `Store.with` | unspecified; PRD §4 "CLI rewrites on CRUD" | dry-struct API | _pending_ |

**Requested PHASE-0 rulings (builder answered, architect to confirm):** minitest
CONFIRMED (minitest 6.0.6); standardrb CHOSEN (ships `standardrb` binary, zero-config);
`gh` 2.93 `--json` fields `defaultBranchRef`/`isArchived`/`isFork` VERIFIED LIVE.

## Decisions log (architect + human)

| Date | Decision | Why |
|------|----------|-----|
| 2026-06-12 | `git init` the repo; `.architect/` gitignored | Loop requires git (worktree isolation, freeze commits, post-flight log checks); raw lane scratch stays out of durable memory (docs/) |
| 2026-06-12 | `Gemfile.lock` committed | repo-tender is an installed application, not a published library; reproducibility is a DoD goal |
| 2026-06-12 | Slice 1 = 1 lane, main checkout, xhigh | Greenfield foundation: shared skeleton + interdependent modules can't be split disjointly; also the environment canary |

## Next slice (architect decides after Slice 1 PASS)

Slice 2 — Sync engine (`sync/repo_plan`, `sync/engine`). Depends on Slice 1.

## Session log

| Date | Role | Slice | Commits | Gates P/F | Notes |
|------|------|-------|---------|-----------|-------|
| 2026-06-12 | architect | 1 | freeze (init) | pending | Ground + setup: git init, AGENTS.md, gates frozen, canary dispatched |
| 2026-06-13 | builder (m3) | 1 | none (UNJUDGED) | builder: 52/0/0 | Foundation built; preserved on slice/foundation @ a016eba; integrity PASS; 7 disagreements raised |
| 2026-06-13 | architect | 1 | a016eba (preserve) | G8 integrity PASS; G0-G7 pending | Post-flight integrity verified; did NOT judge gates (rule 4); deferred to next session |
