# Gates — CLI-UX: `sync-startup` (responsive, informed org expansion)

> FROZEN before dispatch. Read-only for everyone including the builder — any edit
> to a file under `docs/gates/` fails the slice. The architect re-runs these in a
> later session (rule 4). **HIGH-STAKES** (engine concurrency + no-data-loss org
> path / CF3 + forge auth + a reporter-interface signature change) → the judging
> session adds a cross-model adversarial diff pass before the verdict.
>
> **Why:** measured on the operator's real config, `Engine#expand_orgs` takes
> **35s** before `run_started` fires — 5 orgs listed **sequentially**, each doing a
> redundant `gh auth status` + `gh repo list` (`ioquatix` alone ~15s), with **no
> event emitted** during it, in any mode (so `--json` is silent too). This slice
> makes org expansion concurrent, authenticates once, and reports listing progress
> live — without weakening the engine's proven invariants.
>
> **Corrective freeze base:** `slice/ui-interactive` @ `<FREEZE3>` (carries the
> compact `InteractiveReporter`; recorded by the architect at dispatch).
> **Baseline at freeze:** `rake test` **316/1122/0/0/0**, `standardrb` 0, **3**
> tty gems (pastel, tty-cursor, tty-screen). **No new gems in this slice.**

## Frozen design (PHASE 0 challenges, but these are the intended seams)

- **Concurrency:** `expand_orgs` fans the per-org `gh repo list` calls out
  concurrently inside the engine's existing `Sync{}` task, bounded by an
  `Async::Semaphore` (reuse `config.concurrency` or a dedicated bound — builder's
  call, justify it), exactly like the repo sweep. Sequential → wall-time bounded by
  the slowest org, not the sum.
- **Auth once:** `Forge::GitHub#check_authenticated` (already exists, private)
  becomes a **public** `Forge::Client` method. `list_org` **no longer
  authenticates**. The engine calls `check_authenticated` **once** before the
  fan-out; on auth Failure it records **every** org as failed (CF3 preserved) and
  does not crash.
- **Listing events (reporter interface extension):** add
  `listing_started(total:)` (total = org count), `org_listed(ref, count:)` (one per
  org as it completes; `count: nil` on org-list failure), `listing_finished`.
  **`attach` drops its `total:` argument** — `attach(task)` is called **before**
  expansion so the render fiber is alive during listing; the repo total still
  arrives via the existing `run_started(total:)`. All four reporters implement the
  new methods (Null = no-ops).
- **Flush:** `PlainReporter`/`JsonReporter` flush so output is immediate when
  stdout is **not** a TTY (set `@out.sync = true` at construction, or flush per
  event — state which and assert it). This fixes the "silent then bursts" piping.

## How the architect measures these

Lane report `docs/lanes/sync-startup-01.md`: PHASE-0 plan + disagreements; a
**before/after real-config timing** of `expand_orgs` (the builder may use a
SlowForge harness in CI and report the production wall-time qualitatively, since a
real `gh` run isn't deterministic in CI); a gate→test mapping; verbatim
`rake test`/`standardrb`/diff output; proof the engine diff is confined to the
expansion/attach/listing seam. The architect re-runs the suite, opens each named
test (assert on real concurrency/events/state, not stubs of the unit under test),
reads the diff against the no-data-loss invariant + the Slice-2/4 org gates, and
runs a cross-model pass.

---

## GS0 — Suite green; no new gems; engine change confined [whole slice]

`bundle install` 0; `bundle exec rake test` **316 baseline + new, 0
fail/err/skip**; `standardrb` 0; gemspec/Gemfile.lock diff vs `<FREEZE3>` **empty**
(no new gems); `bin/repo-tender --help` exit 0, 5 groups. The `engine.rb` diff is
**confined** to org-expansion concurrency + `attach` timing + listing emission —
the repo-sweep fan-out (semaphore/barrier over `repos_to_process`), the
`process_one` logic, results assembly, and state write are **unchanged**.

## GS1 — Org expansion is CONCURRENT [new engine test, SlowForge]

With a **SlowForge** whose `list_org` sleeps ~`S` (mirror `engine_test.rb`'s
SlowSCM concurrency harness) over **N ≥ 4 orgs**: assert the run's max in-flight
`list_org` count is **> 1** (bounded by the semaphore), and wall-time is **≈ S ·
ceil(N/bound)**, i.e. strictly **< (N-1)·S** (proving fan-out, not sequential).
The existing repo-sweep concurrency gate (Slice-2 G7) stays green.

## GS2 — Authenticated exactly once [new test, recording forge]

A recording forge counts calls: across a run with **5 orgs**, `check_authenticated`
is invoked **exactly once** (not per org), and `list_org` does **not** invoke any
auth probe. On an auth **Failure**: every org is recorded failed with the auth
reason (CF3 prior `repo_count`/`last_listed_at` preserved), no `list_org` is
attempted, and the run completes (no crash, repos preserved).

## GS3 — No-data-loss / resilience invariants preserved [Slice-2 G10 + Slice-4 CF3 stay green]

The concurrency change must NOT weaken the org path:
- **one org's `list_org` Failure is isolated** — recorded, run does not abort,
  other orgs + repos proceed (Slice-2 **G10** test stays green, adapt additively);
- **CF3** — a failing org preserves the prior good `repo_count` + `last_listed_at`
  and sets `last_error` (Slice-4 **G6/G7** tests stay green);
- **discovered repo set + dedupe (explicit-wins)** is **identical** to the
  sequential baseline for the same inputs (order-independent — assert by set, and
  that an explicit repo still wins over an org-discovered duplicate);
- `state/store.rb` is **unchanged** (the `Org#last_error` schema already exists).

## GS4 — Listing reporter events in correct phase order [new test, recording reporter]

Interface gains `listing_started(total:)`, `org_listed(ref, count:)` (count nil on
failure), `listing_finished`; `attach(task)` drops `total:`. `NullReporter`
no-ops all of them (and existing engine tests using the default reporter stay
green — zero behavior change). A recording reporter over a real run observes the
**phase order**: `attach` → `listing_started(total: n_orgs)` → exactly one
`org_listed` per org (success `count` == that org's discovered repo count) →
`listing_finished` → `run_started(total: n_repos)` → repo pairs → `run_finished`
→ `detach`. (Pairing within a phase is set-based, not cross-org-ordered, since
listing is concurrent.)

## GS5 — Plain/Json flush + render listing events [new+existing unit]

- `PlainReporter`/`JsonReporter` make output immediate on a non-TTY (assert
  `@out.sync == true` after construction, **or** that the stream is flushed per
  event — state which). The existing Slice-A G4 plain/json gates stay green
  (Plain ANSI-free; Json one parseable object per line).
- Listing events render: Plain emits one ANSI-free line per `org_listed`
  (ref + count, or a failure marker); Json emits one parseable object per listing
  event with an event/type key.

## GS6 — InteractiveReporter two-phase, invariants carried [new+carried unit]

The compact `InteractiveReporter` shows **live per-org listing progress** during
expansion (e.g. `listing N orgs… ✓ socketry 182`), then transitions to the compact
**repo counter** during the sweep. Carried green: **GC1** (bounded output — listing
lines are also O(orgs), not O(repos)), **GC2** (counter/tallies), **GC3**
(live tick), **G1** (no Thread), **G4** (`^C` cursor-restore + exit-130), **G5**
(color gated by `mode.color`, built only when `mode.animate`). The render fiber is
alive across BOTH phases under one `attach`/`detach`.

## GS7 — File scope; no builder commits; no new gems [architect-checked]

`git diff --name-only <FREEZE3>..` only within the set below; `git log
<FREEZE3>..` no builder commits; no new gems; nothing under `docs/gates/` changed;
`state/store.rb`/`scm/*`/`shell.rb` byte-unchanged.

### Lane file set (frozen) — ONE lane (the interface + engine emission + all impls are interdependent)

**MAY TOUCH:**
- `lib/repo_tender/sync/engine.rb` (parallelize `expand_orgs`; `attach(task)` before
  expansion; emit `listing_started`/`org_listed`/`listing_finished`; auth-once
  orchestration) — **confined** to that seam.
- `lib/repo_tender/forge/client.rb` (declare `check_authenticated` in the interface)
- `lib/repo_tender/forge/github.rb` (make `check_authenticated` public; remove the
  per-`list_org` auth call)
- `lib/repo_tender/ui/reporter.rb` (interface doc + `NullReporter` new methods +
  `attach(task)` signature)
- `lib/repo_tender/ui/plain_reporter.rb`, `lib/repo_tender/ui/json_reporter.rb`
  (new methods + flush/sync)
- `lib/repo_tender/ui/interactive_reporter.rb` (two-phase: listing + sweep)
- `lib/repo_tender/cli/sync.rb` (only if reporter construction/`attach` wiring needs it)
- tests: `test/repo_tender/sync/engine_test.rb`, `test/repo_tender/forge/github_test.rb`,
  `test/repo_tender/ui/{reporter,plain_reporter,json_reporter,interactive_reporter}_test.rb`,
  `test/repo_tender/cli/sync_test.rb` — **additive** where existing tests encode
  invariants (G10/CF3/G4 assertions must remain).
- `docs/lanes/sync-startup-01.md` (report)

**MUST NOT TOUCH:** `lib/repo_tender/state/store.rb` (CF3 schema already supports
`last_error` — no schema change), `scm/*`, `shell.rb`, `sync/repo_plan.rb`,
`config/*`, `launchd/*`, `paths.rb`, `log_rotator.rb`, `cli.rb`, `cli/options.rb`,
`ui/mode.rb`, `cli/{repo,org,status,config,daemon}.rb`, `repo-tender.gemspec`,
`Gemfile`, `Gemfile.lock` (NO new gems), `test_helper.rb`, anything under
`docs/gates/`.
