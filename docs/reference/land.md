# Land-phase commands 🌊

Integrating judged-passing lanes: `integrate` (a set, in order) and `merge`
(one lane). Neither runs gates nor makes verdicts — those are the architect's,
before and after.

## `architect integrate ITERATION [SPACE]`

Integrate the architect-supplied set of passing lanes in order, merging each
`--no-ff` and stopping at the first conflict. The target is the stable
`project/<slug>` branch (slug derived from `space.title`) shared across all
iterations — `main` is never touched per-iteration. Calling `integrate` again
with a new `--lanes` set appends to the same `project/<slug>` branch.

| Option | Default | Description |
|--------|---------|-------------|
| `--lanes=NAMES` | (required) | Comma-separated passing lane names (you decide the set). |
| `--[no-]teardown` | `false` | Remove worktrees and delete per-lane `lane/<id>-<lane>` branches after merging. Never deletes `project/<slug>`. Refuses per lane holding uncommitted work (untracked included); `--force` overrides and discards. |
| `--commit-mode=VALUE` | `space.yaml` `commit_mode`, else `strict` | Commit mode override (`strict` \| `conductor`). |
| `--into=BRANCH` | `project/<slug>` | Merge into this branch instead of the slug-derived default. |
| `--accept-bounds=REASON` | — | Escape valve: override the in-bounds check for these lanes when the frozen touch-set glob is itself the defect, recording REASON in space.yaml (never overrides the no-builder-commits check). |
| `--[no-]force` | `false` | Teardown-only: discard uncommitted work in a lane worktree instead of refusing (never overrides the mechanical merge checks). |

Plus the shared [commit-message options](spec.md#commit-messages), applied to
each lane's working-tree commit.

```sh
architect integrate my-feature --lanes lane-a,lane-b
architect integrate my-feature --lanes lane-a,lane-b --teardown
```

On conflict, `integrate` stops — a merge conflict between declared-disjoint
lanes is a lane-plan disjointness defect: kill the conflicting lane and
re-spec; do not hand-resolve silently. The merge path itself is unaffected by
`--teardown` refusal, because each lane's work is committed before teardown.

After integrating, run the frozen gates cold (`architect gate <iteration>`) —
the merge output says so, and `gate` without a lane argument runs against the
integration branch.

## `architect merge ITERATION LANE [SPACE]`

Integrate **one** architect-judged-passing lane: commits the builder's
working-tree changes on the per-lane `lane/<id>-<lane>` branch, then merges
`--no-ff` into the target branch. Runs no gates and makes no verdict.

| Option | Default | Description |
|--------|---------|-------------|
| `--into=BRANCH` | `project/<slug>` | Merge into this branch instead of the slug-derived default. |
| `--commit-mode=VALUE` | `space.yaml` `commit_mode`, else `strict` | Commit mode override (`strict` \| `conductor`). |

Plus the shared [commit-message options](spec.md#commit-messages) — the lane's
working-tree commit lands in the repo's PR history under the `lane <lane>:`
prefix, so say what the lane did.

```sh
architect merge my-feature lane-a
architect merge my-feature lane-a -m "add the dispatcher seam"   # commits as "lane lane-a: add the dispatcher seam"
```

`merge` refuses a lane that left builder commits or wrote outside its declared
touch set, and aborts cleanly on a merge conflict.

> **Note:** landing is not a CLI command. At project end the architect writes
> the PR body to a fresh timestamped `build/land/<repo>-pr-body-<yyyymmdd-hhmm>.md`
> and presents the push + `gh pr create` block — see the architect skill's
> procedure and [RELEASING](../how-to/releasing.md) for the release path.
