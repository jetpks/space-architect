# Lane interactive-status-01 — raw evidence

> **Provenance note (architect):** the builder (`claude -p`, Sonnet 4.6) ran 121
> turns over ~47 min and terminated on `Prompt is too long` (200k context
> overflow; 12.6M cumulative cache reads) *after* its final G4/G5 verification
> passed but *before* it wrote this report. No builder commits were made; gates
> were not edited; all writes were confined to the declared lane file set. The
> numbers below are the **architect's own** gate runs on the resulting tree
> (rule 4: builder claims are hearsay; the architect runs the gates). Builder
> run-log: `.architect/interactive-status-01.last-run.jsonl`.

## Files changed (12)

| File | Change |
|------|--------|
| `lib/repo_tender/scm/git.rb` | `fast_forward` Success payload symbol→Integer (commits pulled; 0 = up to date) |
| `lib/repo_tender/scm/client.rb` | doc: `fast_forward` Success Integer contract |
| `lib/repo_tender/sync/engine.rb` | per-branch realized action + commit count; `repo_finished(..., action:, commits:)` |
| `lib/repo_tender/ui/interactive_reporter.rb` | in-flight flash suffix + end-of-run breakdown + added-repos block |
| `lib/repo_tender/ui/reporter.rb` | NullReporter + interface doc: new `repo_finished` signature |
| `lib/repo_tender/ui/plain_reporter.rb` | accept new kwargs; output byte-identical |
| `lib/repo_tender/ui/json_reporter.rb` | emit `action` + `commits` in repo_finished JSON |
| `test/repo_tender/scm/git_test.rb` | G4 tests (behind→N, up-to-date→0, divergence still Fails) |
| `test/repo_tender/sync/engine_test.rb` | RecordingReporter captures action/commits; G5 tests |
| `test/repo_tender/ui/interactive_reporter_test.rb` | G1/G2/G3 tests + line-count assertions updated |
| `test/repo_tender/ui/json_reporter_test.rb` | new signature |
| `test/repo_tender/ui/plain_reporter_test.rb` | new signature |

## Realized-action mapping implemented (engine.rb, verified against spec)

`:clone`→`:cloned`/`:error` · `:fast_forward`→`:fast_forwarded`(commits=N)/`:up_to_date`(0)/`:diverged`/`:error` ·
`:switch`→`:switched`/`:error` · `:sync_empty`→`:up_to_date`(0)/`:error` ·
`:skip_fresh`,`:up_to_date`→`:up_to_date` · `:report_dirty`→`:dirty` · `:report_diverged`→`:diverged` ·
`:report_wrong_branch`→`:wrong_branch` · `:report_detached`→`:detached` · `:report_error`→`:error`.
`commits` defaults 0; only set on successful `:fast_forward`.

## Gate runs (architect, on tree @ slice/interactive-status 1e2785a)

| Gate | Command | Result |
|------|---------|--------|
| G0 | `bundle exec rake test` | **407 runs, 1458 assertions, 0 failures, 0 errors, 0 skips** (baseline 398 → +9) |
| GL | `bundle exec standardrb` | exit **0** (no output) |
| GG | `bundle list \| wc -l` | **53** (no new gems) |

Per-gate test runs (verbatim from builder run-log final turn + re-confirmed by G0):

```
# G4 — test/repo_tender/scm/git_test.rb -n /test_g4_/
3 runs, 10 assertions, 0 failures, 0 errors, 0 skips

# G5 — test/repo_tender/sync/engine_test.rb -n /test_g5_.../
2 runs, 8 assertions, 0 failures, 0 errors, 0 skips
```

New test names (assert the gate requirements):
- G1 `test_g1_in_flight_verb_appears_and_clears_on_status_line` — checking/cloning/fast-forwarding/switching + `owner/repo-a` appear in render frames; a post-finish frame omits `owner/repo-a`.
- G2 `test_g2_end_summary_breakdown_and_added_repos_within_threshold` — `cloned 2`, `fast-forwarded`, `7`, `commit`, `up-to-date`, `dirty`, `error`; added block lists `acme/new-a`, `acme/new-b`.
- G3 `test_g3_added_repos_collapses_above_threshold` — `added N repos` present; individual `owner/repo-07` absent.
- G4 `test_g4_fast_forward_returns_commit_count_when_behind` / `_returns_zero_when_up_to_date` / `_fails_on_divergence_still`.
- G5 `test_g5_fast_forwarded_repo_reported_with_action_and_commits` (action `:fast_forwarded`, commits `3`) / `_cloned_..._action_cloned` / `_up_to_date_..._action_up_to_date`.

## Concerns

- **Lane report was not builder-authored** (context overflow). This document is architect-reconstructed; treat the implementation as builder-authored, the evidence as architect-run.
- No PHASE 0 disagreement record exists in this lane (the builder's early-turn plan/disagreements were in the now-discarded transcript; not separately persisted). Process gap to weigh at judging — silent compliance can't be confirmed either way for this lane.

STATUS: COMPLETE_WITH_CONCERNS (lane report architect-reconstructed after builder context overflow; PHASE 0 disagreement record not persisted)
</content>
