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
- **Slice 2 (Sync engine) — SPEC'D + GATES FROZEN, DISPATCHED 2026-06-13.**
  1 lane, main checkout off the freeze commit. Builder run UNJUDGED.
- **Next action (fresh architect session):** judge Slice 2 — (1) confirm the
  builder raised PHASE-0 disagreements (silent compliance = defect), (2) run
  `docs/gates/slice-2.md` G0–G12 yourself, (3) read the diff against PRD §3.3 /
  §5 + the no-data-loss invariant (PRD §1), (4) PASS/FAIL → KILL/CONTINUE. On
  PASS: merge the lane branch → `main`, then spec Slice 3.

## Pointers

- **PRD (build contract):** `docs/prd/repo-tender.md`
- **Research (evidence ledger):** `docs/research/repo-tender.md`
- **Builder standing context:** `AGENTS.md`
- **Slices:** PRD §5 — 1 Foundation ✅ → 2 Sync engine (current) → 3 CLI →
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
- `docs/gates/slice-2.md` — Slice 2, frozen at the Slice 2 freeze commit (below),
  BEFORE work began. Read-only.

## Current slice — Slice 2: Sync engine

- **Spec:** the dispatched builder block + `docs/gates/slice-2.md` (G0–G12) +
  PRD §3.3 / §5 Slice 2.
- **Builds:** `sync/repo_plan.rb`, `sync/engine.rb` (+ tests). **Extends:**
  `scm/{client,git}.rb` (new `switch` boundary), `forge/github.rb` +
  `forge/github_test.rb` (fix invalid `--no-source` argv, G11).
- **Lanes:** 1 lane (internal deps are sequential: repo_plan → engine; the SCM
  `switch` edit + forge fix are small and same-lane, so no parallel collision).
  Dispatched in the main checkout off the freeze commit.
- **Effort:** xhigh — correctness-critical async engine; no-data-loss invariant.
- **Report →** `docs/lanes/slice-2-01.md`.
- **Freeze commit:** the commit recording this section (post-flight:
  `git log <freeze>..` for builder commits must be empty; `git diff --name-only`
  only files in the Builds+Extends set; `git diff docs/gates/` clean).

Raw result column = **builder-reported (hearsay)**; verdict column filled by the
next session after running the gates itself.

| Gate | Threshold (short) | Builder-reported raw result | Architect verdict |
|------|-------------------|------------------------------|-------------------|
| G0 | suite green + lint clean, no new gems | _pending dispatch_ | _pending next session_ |
| G1 | clean+behind → ff → up-to-date, clean | _pending_ | _pending_ |
| G2 | fresh → no network (FETCH_HEAD unchanged) | _pending_ | _pending_ |
| G3 | dirty → byte-untouched + reported | _pending_ | _pending_ |
| G4 | diverged → no destruction, commits intact | _pending_ | _pending_ |
| G5 | wrong-branch: clean switched, dirty left | _pending_ | _pending_ |
| G6 | missing → clone to $BASE/host/owner/repo | _pending_ | _pending_ |
| G7 | concurrency:2 → max in-flight ≤ 2 | _pending_ | _pending_ |
| G8 | per-repo Failure isolated + state written | _pending_ | _pending_ |
| G9 | idempotent: 2nd run no network | _pending_ | _pending_ |
| G10 | org expansion + org-list Failure resilient | _pending_ | _pending_ |
| G11 | forge argv valid (no `--no-source`) | _pending_ | _pending_ |
| G12 | only in-scope files | _pending_ | _pending_ |

## Carry-forward items (architect-tracked)

| # | Item | Where it lands | From |
|---|------|----------------|------|
| CF1 | `refresh_interval` human durations (`6h`/`90m`) must parse at the **config-load layer** (PRD §3.1 documents them in the hand-editable config file), not just CLI input. Until done, PRD §3.1's `6h` example is load-incompatible. | **Slice 3** gate | Disagreement #1 ruling (MODIFY) |
| CF2 | Forge `--no-source` invalid `gh` flag → drop it; rely on authoritative `parse_repos` filter. | **Slice 2** gate G11 | Slice 1 judgment |

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
| 2026-06-13 | Forge `--no-source` fix folded into Slice 2 (G11) not a Slice 1 re-dispatch | Defect isn't on any Slice 1 execution path; the engine is where the forge first runs live |

## Next slice (architect decides after Slice 2 PASS)

Slice 3 — CLI surface + config CRUD (`cli`, `cli/{repo,org,sync,status,config}`,
`bin/repo-tender`). Depends on Slices 1–2. Must also land CF1 (duration parsing).

## Session log

| Date | Role | Slice | Commits | Gates P/F | Notes |
|------|------|-------|---------|-----------|-------|
| 2026-06-12 | architect | 1 | freeze (init) | pending | Ground + setup: git init, AGENTS.md, gates frozen, canary dispatched |
| 2026-06-13 | builder (m3) | 1 | none (UNJUDGED) | builder: 52/0/0 | Foundation built; preserved on slice/foundation @ a016eba; integrity PASS; 7 disagreements raised |
| 2026-06-13 | architect | 1 | a016eba (preserve) | G8 integrity PASS; rest pending | Post-flight integrity; did NOT judge gates (rule 4); deferred |
| 2026-06-13 | architect | 1 | 7569d95 (merge) | **G0–G8 PASS → CONTINUE** | Re-ran all gates; arbitrated 7 (6 ACCEPT, 1 MODIFY); merged to main; logged CF1/CF2 |
| 2026-06-13 | architect | 2 | freeze | n/a | Slice 2 spec'd, gates G0–G12 frozen, dispatched (1 lane) |
