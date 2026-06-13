# HANDOFF — repo-tender

> Repo memory for the Architect Loop. Builder (minimax-m3 via pi) writes raw
> evidence; architect (Opus 4.8) writes rulings and verdicts. Not in this file =
> didn't happen. Keep this a short table of contents — archive finished-slice
> detail into the slice's lane report, not here.

## TL;DR

- **Goal:** keep local git clones evergreen (clean · on default branch · fresh)
  via a `dry-cli` binary + a periodic launchd `sync` sweep. macOS, GitHub-only.
- **Last slice:** Slice 1 (Foundation) — **DISPATCHED 2026-06-12, pending
  judgment** (judged next session per hard rule 4 — never judge a run in the
  session that dispatched it).
- **Next action:** when the Slice 1 builder run completes, a fresh architect
  session runs `docs/gates/slice-1.md` G0–G8, reads `docs/lanes/slice-1-01.md`
  + the diff, and renders PASS/FAIL → KILL/CONTINUE.

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

| Gate | Command | Threshold | Raw result | Architect verdict |
|------|---------|-----------|------------|-------------------|
| G0 | `bundle exec rake test` / `standardrb` | suite green, lint clean | _pending_ | _next session_ |
| G1–G8 | see `docs/gates/slice-1.md` | per gate | _pending_ | _next session_ |

## Open disagreements (builder writes; architect rules)

| # | Builder's position | Spec's position | Evidence (real files) | Ruling |
|---|--------------------|-----------------|------------------------|--------|
| _none yet — builder PHASE 0 pending_ | | | | |

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
