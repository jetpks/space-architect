# Judge-phase commands ⚖️

Post-flight checks, evidence transcription, gate execution, and verdict
recording: `verify`, `evidence`, `gate`, `verdict`. All of these *report*;
the judgment itself is always the architect's, made in a fresh session.

## `architect verify ITERATION [SPACE]`

Post-flight mechanical lane checks — reports only, no judgment. Per lane:

- **(a)** frozen sections untouched since the freeze commit
- **(b)** the builder made no commits in the worktree (`git log <base>..` empty)
- **(c)** the builder's scratch report `build/<id>-<lane>/report.md` exists
- **(d)** the builder stayed in-bounds per the lane's declared touch set

```text
Lane   Check                           Result
docs   (a) frozen sections untouched   PASS
docs   (b) no builder commits          PASS
docs   (c) scratch report exists       PASS
docs   (d) in-bounds                   PASS
```

| Option | Default | Description |
|--------|---------|-------------|
| `--commit-mode=VALUE` | `space.yaml` `commit_mode`, else `strict` | Commit mode override (`strict` \| `conductor`) for this run. |

```sh
architect verify my-feature
```

## `architect evidence ITERATION [SPACE]`

Transcribe a lane's scratch report at `build/<id>-<lane>/report.md`
**verbatim** — byte-for-byte, no interpretation — into the `## Builder Report`
section of the iteration file and commit. Echoes the builder's `STATUS:` line
on completion.

| Option | Default | Description |
|--------|---------|-------------|
| `--lane=NAME` | — | Lane name (appends a `### <lane>` subsection; omit for a single-lane iteration). |

Plus the shared [commit-message options](spec.md#commit-messages).

```sh
architect evidence my-feature
architect evidence my-feature --lane lane-a
```

## `architect gate ITERATION [LANE] [SPACE]`

Run the iteration's frozen Acceptance Criteria gate commands and report
PASS/FAIL per gate. Gate commands are always read from the freeze commit —
never the working copy — so the criteria stay immutable.

Without a lane argument, gates run in `repos/<repo>` against the
currently-checked-out branch (typically `project/<slug>` after `architect
integrate`). With a lane name, gates run in that lane's worktree.

```text
── AC1: test -f docs/hello.md && … && echo HELLO_OK  (exit 0)  [PASS]
   dir: ~/architect/spaces/<id>/build/I01-hello-loop-docs/wt
HELLO_OK

Mechanical gate results above; the Acceptance-Criteria verdict — necessary, not
sufficient — remains the architect's.
```

Exits `1` when any gate fails, `0` otherwise.

```sh
architect gate my-feature
architect gate my-feature lane-a   # run in the lane worktree
```

## `architect verdict ITERATION DECISION [SPACE]`

Record the architect's verdict: writes the `## Verdict` prose to the iteration
file and records the decision (`continue` or `kill`) in `space.yaml`, committed
in one step. The verdict covers disagreement rulings (ACCEPT/REJECT/MODIFY +
one line each), per-AC PASS/FAIL/INVALID results, and the KILL/CONTINUE call
with the single decisive reason.

| Option | Default | Description |
|--------|---------|-------------|
| `--from=FILE` | — | Read the verdict body from this file. |
| `--body=TEXT` | — | Inline verdict body. |
| `--[no-]stdin` | `false` | Read the verdict body from stdin. |

Plus the shared [commit-message options](spec.md#commit-messages).

```sh
architect verdict my-feature continue --from verdict.md
architect verdict my-feature kill --body "AC2 gate failed: 0 tests found"
```

The verdict belongs to a **later, fresh session** than the one that dispatched
the builder — the dispatcher never grades the run it launched.
