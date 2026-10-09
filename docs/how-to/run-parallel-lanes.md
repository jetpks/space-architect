# Run parallel lanes 🔀

One iteration, two to four builders at once — each in its own git worktree,
against its own declared file-touch set, integrated in order when they pass.

The architect owns the fan-out. Lanes are declared in the iteration's frozen
```lanes block, materialized by `architect provision`, and merged by
`architect integrate` — a builder never creates a worktree or merges.

## 1. Declare the lanes in the Specification

Author the Specification section with a ```lanes block — one entry per lane,
each with a `name`, the `repo` under `repos/`, and an enumerated `touch` set
(file globs this lane may write):

```lanes
- name: parser
  repo: my-app
  touch:
    - lib/my_app/parser.rb
    - test/my_app/parser_test.rb
- name: docs
  repo: my-app
  touch:
    - docs/guide.md
```

Keep the touch sets overlap-checked — the file sets of different lanes should
not intersect. A large tangled overlap means the lane plan is wrong (kill and
re-spec), not that the lanes should negotiate.

## 2. Freeze, then materialize all lanes at once

```sh
architect rehearse <iteration>
architect freeze <iteration>
architect provision <iteration>
```

`provision` reads the frozen lanes block and creates one worktree + lane branch
per entry (`build/<id>-<lane>/wt`, `lane/<id>-<lane>`). Useful flags:
`--lane <name>` to provision one lane only; `--force` to clear a stale,
unregistered worktree directory.

## 3. Dispatch one builder per lane

Author each lane's prompt in a scratch file, then dispatch:

```sh
architect dispatch <iteration> parser --prompt tmp/prompts/<id>-parser.md --detach
architect dispatch <iteration> docs   --prompt tmp/prompts/<id>-docs.md --detach
```

Each builder runs headless in its own worktree and streams to its own
`build/<id>-<lane>/run.jsonl`, reporting to `build/<id>-<lane>/report.md`.
Mind the effort knob per lane (`--effort <level>`) — routine, tightly
specified lanes can run below the default thinking budget.

## 4. Post-flight, per lane

```sh
architect verify <iteration>
architect evidence <iteration> --lane parser
architect evidence <iteration> --lane docs
```

`verify` runs four mechanical checks per lane — frozen sections untouched, no
builder commits, report exists, in-bounds against the declared touch set. It
reports; it does not judge.

## 5. Integrate the passing set, in order

```sh
architect integrate <iteration> --lanes parser,docs --teardown
```

Lanes merge `--no-ff`, in the order you list them, into the stable
`project/<slug>` branch; `--teardown` removes the worktrees and lane branches
afterwards. `integrate` stops at the first conflict — a merge conflict between
declared-disjoint lanes is a lane-plan defect, not something to hand-resolve
silently. Escape valves when you need them:

- `--accept-bounds REASON` — override an in-bounds failure when the frozen
  touch-set glob is itself the defect (never overrides the no-builder-commits
  check)
- `--force` — teardown-only: discard uncommitted work in a lane worktree

Then run the frozen gates cold (`architect gate <iteration>`) and record the
verdict (`architect verdict <iteration> continue|kill --from <file>`).

## Related

- **Competing approaches to one spec** — `architect variant add|compare|promote`
  runs several `(harness, model)` lanes over one byte-identical frozen spec:
  [reference](../reference/groups.md#architect-variant-subcommand)
- **The seam two lanes must share** — the parallel + fast-follow pattern:
  [DESIGN §5 / R8](../DESIGN.md)
