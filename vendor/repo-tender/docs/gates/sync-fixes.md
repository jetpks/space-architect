# Frozen gates — slice `sync-fixes`

Frozen 2026-06-14, before dispatch. Read-only for everyone (builders included);
any edit under `docs/gates/` is an automatic slice FAIL. The architect re-runs
every command here at judgment and compares against this verbatim text. Gate-pass
is necessary, not sufficient — the diff is also read against intent.

Two independent bugs, two disjoint lanes:

- **Lane A (`ui-listing-order`)** — the last org's listing line is reprinted
  after the sweep instead of staying with the org block.
- **Lane B (`empty-repo`)** — a repo with no commits (empty remote) reports
  `error`; it should count as `clean`/synced, and gain commits cleanly later.

## Baseline (measured on `main` @ freeze)

```
bundle exec rake test     => 379 runs, 1334 assertions, 0 failures, 0 errors, 0 skips
bundle exec standardrb    => exit 0
```

## Whole-slice gates (run after integration of both lanes)

- **G0 — full suite green.** `bundle exec rake test` →
  runs ≥ 379 + (new tests this slice), **0 failures, 0 errors, 0 skips.**
  Net run count strictly greater than 379 (both lanes add regression tests).
- **GL — lint clean.** `bundle exec standardrb` → **exit 0.**
- **GG — no new runtime gems.** `Gemfile.lock` gem count unchanged (51). No new
  dependency is required for either fix.

## Lane A gates — `ui-listing-order`

Command: `bundle exec ruby -Itest test/repo_tender/ui/interactive_reporter_test.rb`
→ 0 failures, 0 errors.

- **GA1 — ordering regression test exists and passes.** A new test drives
  `InteractiveReporter` through the listing→sweep transition with the LAST org's
  `org_listed` arriving in the gap before the phase flips to sweep (i.e. queued,
  then `run_started` fires before another listing tick drains it), followed by at
  least one non-clean `repo_finished` and `run_finished` → `detach`. It captures
  the full output stream (ANSI-stripped) and asserts the last org's persistent
  line appears **before** the first sweep `⚠` line **and** before the final
  summary line. The architect confirms (via `git stash` of the lib change, or by
  reading the pre-fix logic) that this test FAILS on the pre-fix
  `interactive_reporter.rb` and PASSES after.
- **GA2 — org lines are a contiguous block.** In that same captured output, all
  `org_listed` persistent lines (the `✓ <org>  N repo(s)` / `✗ <org>  FAILED`
  lines) appear consecutively, ahead of every sweep line and the summary — none
  interleaved after a sweep line.
- **GA3 — no regression to existing reporter behavior.** All pre-existing tests
  in `interactive_reporter_test.rb` still pass unchanged.

## Lane B gates — `empty-repo`

Commands:
`bundle exec ruby -Itest test/repo_tender/scm/status_test.rb test/repo_tender/scm/git_test.rb test/repo_tender/sync/repo_plan_test.rb test/repo_tender/sync/engine_test.rb`
→ 0 failures, 0 errors. All four suites green.

- **GB1 — `Status` detects an unborn/empty repo.** `SCM::Status` parsed from
  `git status --porcelain=v2 --branch` exposes that the repo has no commits when
  `# branch.oid` is `(initial)` (e.g. `Status#unborn?` → true), and is false for a
  normal SHA oid. Unit-tested both ways in `status_test.rb` against the real
  porcelain-v2 strings.
- **GB2 — empty remote ⇒ `clean`, not `error`.** Against a REAL empty bare remote
  cloned to a REAL empty working copy (no commits anywhere), a full sync (or
  `RepoPlan.call` + engine `process_one`) yields a state row with
  **`status: "clean"`** and **`last_error: nil`** — never `"error"`. Proven with
  real on-disk git (no stubbing of the SCM under test for the git-behavior
  assertion), in `git_test.rb` and/or `engine_test.rb`/`repo_plan_test.rb`.
- **GB3 — empty local + remote gains commits ⇒ pulled to `clean`.** Starting from
  an empty clone whose remote subsequently receives its first commit(s), a sync
  fast-forwards the working copy: after the run the clone contains the remote's
  files, `git log` resolves, `status` is clean, the state row is `status: "clean"`
  with a resolved `default_branch`. Proven with real on-disk git.
- **GB4 — no-data-loss on an unborn dirty tree.** An empty/unborn clone that has
  uncommitted local files (untracked or staged, so `status --porcelain=v2` is
  non-empty) is NEVER mutated: the run reports it as non-clean
  (`status: "dirty"`), performs no fetch/merge, and the local files are left
  byte-for-byte intact. Proven with real on-disk git (assert file contents before
  and after).
- **GB5 — real errors stay errors.** A genuine probe/network failure on a
  non-empty repo still produces `status: "error"` (the empty-repo path must not
  swallow real failures into `clean`). The empty-vs-error distinction is made on a
  deterministic signal (empty remote = `git ls-remote --heads origin` exits 0 with
  no output), not by treating every `default_branch` failure as "empty". Existing
  error-path tests remain green; add one asserting a non-empty repo's real failure
  is still `error`.

## Judgment procedure (architect, next session)

1. `git diff <freeze>..slice/sync-fixes` read in full against this file's intent.
2. Run G0, GL, GG, then the Lane A and Lane B command blocks; compare verbatim.
3. Lane B touches the no-data-loss cardinal invariant (PRD §1: never mutate a
   dirty/diverged repo). Run the cross-tier/cross-context adversarial pass on the
   Lane B diff (GB4 is the load-bearing safety property: unborn+dirty must never
   merge). file:line evidence only.
4. Per-gate PASS/FAIL/INVALID, then one KILL/CONTINUE with the decisive reason.
