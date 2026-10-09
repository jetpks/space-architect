# Spec-phase commands ✍️

Commands that author and lock an iteration: `new`, `section`, `rehearse`,
`freeze`, and the project brief (`brief new`). Usage lines are the shipped
binary's own; the space's git log is the loop's durable memory, so every
committing command takes the shared [commit-message options](#commit-messages).

## `architect new ITERATION [SPACE]`

Scaffold the next iteration file at `architecture/I<NN>-<ITERATION>.md` from
the iteration template. Allocates the next ordinal and records the iteration
in `space.yaml`.

```sh
architect new dry-cli-port
architect new dispatch-engine 20260531-name-of-space
architect new dry-cli-port -m "port the CLI off thor" --message-from why.md
```

Arguments: `ITERATION` (required, kebab-case), `SPACE` (optional, default
`$PWD`).

## `architect section ITERATION SECTION [SPACE]`

Write a section of the iteration file and commit it in one step. `SECTION` is
one of: `grounds`, `specification`, `acceptance-criteria`, `prompt`, `verdict`.

| Option | Default | Description |
|--------|---------|-------------|
| `--from=FILE` | — | Read the section body from this file. |
| `--body=TEXT` | — | Inline section body (one-liners). |
| `--[no-]stdin` | `false` | Read the section body from stdin. |
| `--[no-]append` | `false` | Append a `### <lane>` subsection instead of replacing. |
| `--lane=NAME` | — | Lane name for an appended `###` subsection. |
| `--[no-]force` | `false` | Write a frozen section (pre-dispatch only). |

Plus the [commit-message options](#commit-messages).

```sh
architect section my-feature specification --from spec.md -m "pull-based dispatcher seam"
architect section my-feature prompt --append --lane lane-a --from tmp/prompts/I01-lane-a.md
architect section my-feature verdict --from verdict.md
```

Refuses to write a frozen section (Grounds/Specification) once the iteration
is frozen, unless `--force` is passed — and `--force` is pre-dispatch only.

## `architect rehearse ITERATION [SPACE]`

Rehearse the **drafted** (unfrozen, working-tree) gates against the repo
checkout and report RED/GREEN/BROKEN/EMPTY — runs and reports, never judges.

| Verdict | Meaning |
|---------|---------|
| `RED` | clean non-zero — the gate discriminates |
| `GREEN` | passes on base — a declared regression guard, or a gate that measures nothing |
| `BROKEN` | a 127, shell syntax error, unexpected EOF, or timeout — advisory, because a correct RED can look broken; the tool names the suspicion, you confirm |
| `EMPTY` | no gates, or an untouched scaffold placeholder |

`freeze` requires a fresh rehearsal stamp keyed to the gates block's content —
editing a gate stales it. The stamp records that you looked, never that gates
passed: an all-RED and an all-GREEN run stamp identically.

| Option | Default | Description |
|--------|---------|-------------|
| `--record` | `false` | Emit a paste-able provenance block summarizing the run, shaped to drop into an Acceptance Criteria preamble. |

Every non-EMPTY rehearsal writes its full report (per-gate command, dir, exit
code, verdict, reason, complete stdout+stderr, scope-asymmetry findings) to a
file under `build/rehearse/` and prints that path; the terminal report is
bounded and ends with a summary block, so a `tail` of stdout captures the
whole outcome. Gates sharing an identical `(cmd, resolved dir)` execute once.

## `architect freeze ITERATION [SPACE]`

Freeze the iteration's frozen region (Grounds/Specification/Acceptance
Criteria) and record the freeze SHA in `space.yaml`. Refuses a
scaffold-placeholder Acceptance Criteria, and requires a fresh rehearsal stamp
unless skipped:

| Option | Default | Description |
|--------|---------|-------------|
| `--[no-]force` | `false` | Re-freeze even if the frozen region changed (pre-dispatch only). |
| `--skip-rehearse=REASON` | — | Skip the fresh-rehearsal requirement, recording REASON in space.yaml. |

```sh
architect freeze dry-cli-port
architect freeze dry-cli-port -m "AC pinned to BRIEF §3"
```

After the freeze, any change to the frozen region is an automatic iteration
FAIL; only Builder Prompt, Builder Report, and Verdict may be appended.

## `architect brief new [SPACE]`

Write the durable project brief at `architecture/BRIEF.md` and commit it. The
brief holds numbered §sections (§1 goal, §2 constraints, … §N definition of
done) that span all iterations; each iteration's Specification and Verdict
cites them as **BRIEF §N**. Author the body in a scratch file and pass
`--from` (or `--stdin`); called bare it scaffolds a placeholder template and
says so.

| Option | Default | Description |
|--------|---------|-------------|
| `--from=FILE` | — | Read the authored brief body from this file. |
| `--[no-]stdin` | `false` | Read the authored brief body from stdin. |
| `--[no-]force` | `false` | Overwrite an existing BRIEF.md. |

Plus the [commit-message options](#commit-messages).

```sh
architect brief new --from tmp/brief.md -m "founding contract for the migration"
architect brief new --force --from tmp/brief-v2.md   # overwrite an existing BRIEF.md
```

## Commit messages

Every committing command — `init`, `new`, `freeze`, `brief new`, `section`,
`verdict`, `evidence`, `merge`, `integrate` — takes the same two options:

| Option | Default | Description |
|--------|---------|-------------|
| `-m`, `--message=TEXT` | canonical message | Your first line completes the subject after a short canonical prefix (e.g. `I01 spec: <your subject>`); remaining lines become the commit body. |
| `--message-from=FILE` | — | Read the commit message from a file. Wins over `--message`; preferred for multiline bodies. |

Without either option the canonical message is used unchanged (e.g.
`I01: specification`). Prefixes: `init:`, `I<NN> scaffold:`, `I<NN> freeze:`,
`brief:`, `I<NN> grounds:`, `I<NN> spec:`, `I<NN> prompt:`, `I<NN> verdict:`,
`I<NN> evidence:`, `lane <lane>:`.
