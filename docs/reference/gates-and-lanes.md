# The ```gates and ```lanes block formats 🧱

Two machine-readable YAML blocks live inside the iteration file, are linted at
write/freeze time, and are the frozen contracts the loop's machinery runs on.
Both are parsed from fenced blocks in the file — absent or empty blocks are
allowed (back-compat; an empty gates block draws a "prose-judged only"
warning), while malformed YAML or schema violations fail the command.

## The ```lanes block — the lane plan

Lives in the **Specification** section; the frozen source of truth that
`architect provision` materializes. One YAML list entry per lane:

```lanes
- name: lane-a            # lane name (required)
  repo: my-repo           # target repo under repos/ (required)
  touch:                  # every file this lane may write (required, non-empty) —
    - lib/my_repo/foo.rb  #   enumerate precisely; globs (`docs/**`) are legal but
    - lib/my_repo/bar.rb  #   lazy broad ones are how lanes collide
    - test/my_repo_test.rb
```

Lint rules (enforced at section-write and freeze time):

- each lane must have a non-empty `name` and `repo`
- `touch` must be a non-empty array of non-empty strings — each is a glob
  matched against changed paths (`File.fnmatch` with `FNM_PATHNAME`,
  `FNM_EXTGLOB`, `FNM_DOTMATCH`; a trailing `/**` also matches files directly
  under the directory)
- ill-formed YAML or a schema violation fails with an aggregated message

At freeze, each entry is written into `space.yaml` as
`project.iterations[…].lanes[]` (`name`, `repo`, `touch_set`). Note: an
empty/comment-only lanes block is legal and means a single-lane iteration
whose worktree is created by `architect worktree add` or `dispatch` itself.

## The ```gates block — runnable Acceptance Criteria

Lives in the **Acceptance Criteria** section, beneath the prose ACs. Each gate
backs one prose AC and is evaluated by `architect rehearse` (pre-freeze) and
`architect gate` (post-freeze, read from the freeze commit).

```gates
- id: suite-green         # unique slug within the iteration (required)
  ac: AC1                 # which prose AC this gate backs (required)
  cwd: repos/my-repo      # run dir, space-root-relative (optional)
  timeout: 300            # seconds (optional; must be positive)
  cmd: |-                 # block style by default — a plain scalar breaks on `: `
    bundle exec rake test && echo SUITE_OK
  expect:                 # at least one of: exit_code, stdout_match, threshold
    exit_code: 0
    stdout_match: SUITE_OK
```

Field contract:

| Field | Required | Contract |
|-------|----------|----------|
| `id` | yes | non-empty slug, unique within the iteration |
| `ac` | yes | the prose AC the gate backs |
| `cmd` | yes | non-empty shell command, run via `/bin/sh -c` |
| `cwd` | no | run dir, **space-root-relative**; a `cwd` under `repos/<repo>` is remapped into the lane worktree at judge time, one outside it passes through unchanged |
| `timeout` | no | positive number of seconds |
| `expect.exit_code` | one of three | integer |
| `expect.stdout_match` | one of three | string the gate's stdout must contain |
| `expect.threshold` | one of three | `match` (regexp with **exactly one capture group**), `op` (one of `>=`, `<=`, `>`, `<`, `==`, `!=`), `value` (number) — extracts the capture and compares |

Authoring guidance the tooling itself carries:

- `cmd` paths resolve against the **repo tree**; `cwd` is what's
  space-root-relative. A gate whose `cmd` carries a literal `repos/<name>/`
  prefix with no `cwd` draws a warning (usually a leftover space-root-relative
  path, but legal).
- `/bin/sh` (the gate runner's shell) has no `set -e`, so a multi-step `cmd`
  can exit 0 from an early branch — end it with `echo SENTINEL` +
  `stdout_match` so the sentinel proves the command reached its end.
- A presence-grep on prose is a **tripwire, never the proof** — write the
  criterion to say which.
- Gates that share an identical `(cmd, resolved dir)` execute once per run;
  each is still classified against its own `expect`.

## Rehearsal verdicts (pre-freeze)

`architect rehearse` runs drafted gates through the same execution path `gate`
uses and classifies each: **RED** (clean non-zero — discriminates), **GREEN**
(passes on base — declared regression guard or measures nothing), **BROKEN**
(127 / shell syntax error / unexpected EOF / timeout — advisory), **EMPTY**
(no active gates). `freeze` requires a fresh stamp keyed to the gates block's
content; `freeze --skip-rehearse REASON` records the deliberate skip. See
[Spec-phase commands](spec.md#architect-rehearse-iteration-space).
