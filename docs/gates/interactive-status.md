# Gates — slice `interactive-status`

> Frozen by the architect (Opus 4.8) before dispatch. Quoted verbatim at
> judging. A builder edit to ANY file under `docs/gates/` (caught by
> `git diff`) is an automatic slice FAIL.
>
> **Freeze base:** `6ea0711` · **Baseline at freeze:** `rake test` →
> **398/1404/0/0/0**, `standardrb` exit 0, `bundle list` → **53** lines.

## Objective recap (what is being judged)

Two `InteractiveReporter` behaviors, plus the thin engine/SCM plumbing they
require:

1. **Flash the in-flight repo** on the rewritten status line during the sweep,
   driven by the already-emitted `repo_started` / `repo_phase` events.
2. **Richer end-of-run summary**: an aggregate-git-stats breakdown line
   (cloned / fast-forwarded + real commit count / up-to-date / dirty /
   diverged / errors) and an **added-repos** block that lists names below a
   volume threshold and collapses to a one-line count above it.

## Gate commands + thresholds

All commands run from the repo root with `bundle exec`.

### G0 — full suite green, strictly grown

```
bundle exec rake test
```

**PASS iff:** `runs > 398` AND `failures == 0` AND `errors == 0` AND
`skips == 0`. (New tests for G1–G5 must push runs strictly above the 398
baseline.)

### GL — lint clean

```
bundle exec standardrb
```

**PASS iff:** exit status `0` (no output).

### GG — no new gems

```
bundle list | wc -l
```

**PASS iff:** output is `53` (no runtime dependency added; `pastel` /
`tty-cursor` are already present).

### G1 — flash: in-flight repo appears on the status line, clears on finish

A test in `test/repo_tender/ui/interactive_reporter_test.rb` that drives the
reporter directly (StringIO `out`, real `Sync do |task|` attach) and asserts:

- After `repo_started("github.com/owner/repo-a")` + a render tick, the live
  status line contains `owner/repo-a` and the word `checking`.
- After `repo_phase("github.com/owner/repo-a", :cloning)` + a tick, the line
  contains `owner/repo-a` and `cloning`; for `:fast_forwarding` →
  `fast-forwarding`; for `:switching` → `switching`.
- After `repo_finished("github.com/owner/repo-a", "clean", action: :cloned)`
  the repo is no longer shown as in-flight (the next tick's status line does
  **not** contain `owner/repo-a` as an in-flight suffix once it is the only
  ref and it has finished).

**PASS iff:** the test exists and asserts all three, and passes.

### G2 — end summary: breakdown + commit count + added-repos list (≤ threshold)

A test that drives a mixed run: **2 cloned**, **1 fast-forwarded with 7
commits**, **1 up-to-date**, **1 dirty**, **1 error**, then `run_finished` +
`detach`, capturing the final `out` string. Asserts the post-run output
contains, as substrings (glyphs/spacing at the builder's discretion):

- `cloned` with count `2`
- `fast-forwarded`
- `7` and `commit` (the aggregate pulled-commit count)
- `up-to-date`
- `dirty` and `error` reflected (the existing non-clean/failed accounting stays
  correct)
- an **added-repos block** that lists both cloned refs by `owner/name`
  (because `2 <= threshold`).

**PASS iff:** the test exists and asserts the above, and passes.

### G3 — added-repos collapses above the volume threshold

A test that drives a run of **15 cloned repos** (count `> ADDED_LIST_THRESHOLD`,
which is `10`), then `detach`. Asserts the final output:

- contains a one-line summary with `15` and `repos` (e.g. `added 15 repos`), AND
- does **not** list the individual cloned `owner/name` lines (assert a specific
  cloned ref name, e.g. `owner/repo-07`, is absent from the added block).

**PASS iff:** the test exists and asserts both, and passes.

### G4 — SCM `fast_forward` returns the pulled-commit count

A test in `test/repo_tender/scm/git_test.rb` using real temp git repos + a
local bare remote (per AGENTS.md conventions — no mocks):

- A clone that is **N commits behind** its remote default branch →
  `SCM::Git.new.fast_forward(path, default)` returns
  `Success(N)` (the integer number of commits fast-forwarded, `N >= 1`).
- A clone already up to date → returns `Success(0)`.
- Divergence behavior is unchanged: still a `Failure` carrying `:reason`
  (`local_ahead`/`remote_ahead` keys preserved).

**PASS iff:** the test exists and asserts the integer return on both the
behind and up-to-date cases (and divergence still Fails), and passes.

### G5 — engine plumbs realized action + commits to `repo_finished`

Using the existing `RecordingReporter` seam in
`test/repo_tender/sync/engine_test.rb` (the `reporter:` constructor injection —
legitimate collaborator DI, not a stub of the class under test), updated to
capture the new `repo_finished` keyword args:

- A repo that gets fast-forwarded by N commits is reported with
  `action: :fast_forwarded` and `commits: N` (N matching the SCM result).
- A freshly cloned repo is reported with `action: :cloned`.

**PASS iff:** the test asserts both, and passes.

## Cardinal-invariant guard (read at judging, not a separate command)

The no-data-loss invariant (PRD §1) must be untouched: this slice adds only
**read/observe + display** behavior. `fast_forward` must still perform the same
`merge --ff-only` and return `Failure` on divergence — only its *Success
payload shape* changes (symbol → integer). The architect reads the
`scm/git.rb` and `engine.rb` diffs against this intent before the verdict; any
change to the dirty/diverged guard logic is an automatic FAIL regardless of
gate-pass.
</content>
</invoke>
