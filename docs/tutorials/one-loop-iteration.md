# Tutorial: one full loop iteration, end to end 🔁

You will run the Architect Loop once, on a scratch space, with a trivial
one-lane iteration: a headless builder adds one file to a scratch repo, you run
the frozen gate, record a verdict, and integrate. It takes about ten minutes,
almost all of it waiting for the builder.

What you need before starting:

- `space-architect` 9.0.0+ installed (`gem install space-architect`) — that
  brings the `architect` binary and the `space` binary (from the space-cadet
  gem).
- **pi** on your `PATH` and authenticated with a model provider — dispatch runs
  headless `pi` sessions (see the [reference](../reference/build.md) for the
  harness facts).
- A git repo the lane can work on, with at least one commit. Any small repo
  will do; below we use `-r org/repo` to clone one into the space at creation.
- git configured with a user name/email — the loop commits to the space repo
  and the target repo.

Why the loop is shaped this way (freeze, fresh-context builders, raw-evidence
reports) is [explained separately](../explanation/) — this tutorial stays on
the happy path.

## 1. Create the space 🪐

```sh
space init                                        # create XDG config + state files
space new "Docsmith Tutorial" -r org/repo         # clone the lane's repo into the space
cd ~/architect/spaces/<id>-docsmith-tutorial
```

You should see `Created <today>-docsmith-tutorial` and the space path. A space
is a plain directory with a `space.yaml` identity file — the loop finds it by
walking up from `$PWD`; there is no "current space" state to desync.

## 2. Scaffold the project 🏗️

```sh
architect init
```

```text
Project ready: ~/architect/spaces/<id>-docsmith-tutorial/architecture/ARCHITECT.md
```

This creates `architecture/ARCHITECT.md`, adds the `project:` block to
`space.yaml`, and writes a `SessionStart` hook that re-grounds fresh sessions.
Next, the durable project brief:

```sh
printf 'Goal: prove the Architect Loop end to end on a scratch repo.\n' > tmp/brief.md
architect brief new --from tmp/brief.md
```

```text
Brief ready: ~/architect/spaces/<id>-docsmith-tutorial/architecture/BRIEF.md
```

The brief's numbered §sections are the stable address space every later
iteration cites (`BRIEF §1`, …). [Reference](../reference/spec.md#architect-brief-new-space).

## 3. Write the iteration 📝

```sh
architect new hello-loop
```

```text
Iteration scaffolded: ~/architect/spaces/<id>-docsmith-tutorial/architecture/I01-hello-loop.md
```

The scaffold is a template with one section per loop phase. You author section
*bodies* in scratch files; `architect section` writes and commits them. First
the Specification — including the machine-readable ```lanes block that declares
the lane:

````sh
cat > tmp/spec.md <<'EOF'
- **Objective** — one lane adds `docs/hello.md` to repos/<repo> saying hello (BRIEF §1).
- **Output format** — raw report to build/I01-hello-loop-docs/report.md.
- **Tool guidance** — just write the file; no tests needed.
- **Boundaries** — touch only docs/hello.md in repos/<repo>.

```lanes
- name: docs
  repo: <repo>
  touch:
    - docs/hello.md
```
EOF
architect section hello-loop specification --from tmp/spec.md
````

```text
Committed ## Specification → 223cc762
 architecture/I01-hello-loop.md | 34 ++++++++--------------------------
 1 file changed, 8 insertions(+), 26 deletions(-)
```

Then the Acceptance Criteria — prose conditions plus a ```gates block of
runnable checks:

````sh
cat > tmp/ac.md <<'EOF'
**AC1.** repos/<repo> carries docs/hello.md saying hello.

```gates
- id: hello-doc-exists
  ac: AC1
  cmd: |-
    test -f docs/hello.md && grep -qi hello docs/hello.md && echo HELLO_OK
  cwd: repos/<repo>
  expect:
    exit_code: 0
    stdout_match: HELLO_OK
```
EOF
architect section hello-loop acceptance-criteria --from tmp/ac.md
````

```text
Committed ## Acceptance Criteria → ecbf8137
```

The full gates-block schema (fields, `expect` variants, cwd remapping) is in
the [reference](../reference/gates-and-lanes.md).

## 4. Rehearse the gates, then freeze ❄️

```sh
architect rehearse hello-loop
```

```text
── AC1 hello-doc-exists: test -f docs/hello.md && grep -qi hello docs/hello.md && echo HELLO_OK  (exit 1)  [RED]
   reason: exit_code 1 != 0
```

RED is the *good* pre-freeze answer: the gate fails on the untouched repo, so
it can discriminate pass from fail once the builder runs. (GREEN would mean the
gate passes already — a regression guard or a gate that measures nothing;
BROKEN and EMPTY are the other classifications.) Rehearsal runs and reports;
it never judges.

Now freeze — the frozen region (Grounds / Specification / Acceptance Criteria)
is committed and locked; any later change to it fails the iteration:

```sh
architect freeze hello-loop
```

```text
Frozen hello-loop at ecbf8137730ec67f8e5f0f3ff902614795118de6

Frozen Acceptance Criteria (quote these verbatim when judging):
…
```

## 5. Provision the lane and dispatch the builder 📡

```sh
architect provision hello-loop
```

```text
docs: ~/architect/spaces/<id>-docsmith-tutorial/build/I01-hello-loop-docs/wt (created)
```

Provision materializes each declared lane: a git worktree under
`build/I01-hello-loop-docs/wt` plus a `lane/I01-hello-loop-docs` branch. Write
the lane's prompt as a scratch file and dispatch:

```sh
cat > tmp/prompt-docs.md <<'EOF'
Create the file docs/hello.md in this repo with the single line: hello, loop!
Then write your raw report to the scratch report path given below.
Do not commit. End the report with a STATUS: line.
EOF
architect dispatch hello-loop docs --prompt tmp/prompt-docs.md --detach
```

```text
Prompt:  tmp/prompt-docs.md → ~/architect/spaces/<id>-docsmith-tutorial/build/I01-hello-loop-docs/prompt.md
PID:     57846
Run log: ~/architect/spaces/<id>-docsmith-tutorial/build/I01-hello-loop-docs/run.jsonl
Report:  ~/architect/spaces/<id>-docsmith-tutorial/build/I01-hello-loop-docs/report.md
Dispatched detached — poll ~/architect/spaces/<id>-docsmith-tutorial/build/I01-hello-loop-docs/report.md for completion
```

`--detach` returns immediately with the builder's PID; poll the report path
until it ends with a `STATUS:` line (a trivial lane finishes in under a minute;
omit `--detach` to stream in the foreground — `--timeout 14400` bounds a wedged
run either way). The builder works in the worktree, never edits the iteration
file, and never commits — the loop's guard denies git-write commands.

## 6. Post-flight checks and evidence 🧾

When the report is done:

```sh
architect verify hello-loop
```

```text
Lane   Check                           Result
docs   (a) frozen sections untouched   PASS
docs   (b) no builder commits          PASS
docs   (c) scratch report exists       PASS
docs   (d) in-bounds                   PASS
```

Four mechanical checks, reports only — judgment stays with you. Transcribe the
builder's raw report verbatim into the iteration file:

```sh
architect evidence hello-loop --lane docs
```

```text
Transcribed 13 lines → 1696a036
Builder STATUS: STATUS: DONE
```

## 7. Gate and verdict ⚖️

Run the frozen gates yourself — builder claims are hearsay:

```sh
architect gate hello-loop docs
```

```text
── AC1: test -f docs/hello.md && grep -qi hello docs/hello.md && echo HELLO_OK  (exit 0)  [PASS]
   dir: ~/architect/spaces/<id>-docsmith-tutorial/build/I01-hello-loop-docs/wt
HELLO_OK
```

Read the diff against the Specification's intent, then record the verdict:

```sh
cat > tmp/verdict.md <<'EOF'
No disagreements raised.

| AC# | Raw result | Brief § | Verdict |
|-----|------------|---------|---------|
| AC1 | gate PASS (HELLO_OK) | 1 | PASS |

CONTINUE — trivial lane, gates green.
EOF
architect verdict hello-loop continue --from tmp/verdict.md
```

```text
Verdict 'continue' recorded → d04e9083
```

## 8. Integrate 🌊

```sh
architect integrate hello-loop --lanes docs --teardown
```

```text
Merged docs → project/docsmith-tutorial (e35bd0ff)
Gates NOT run — run gates: `architect gate hello-loop`
```

The lane's work merged `--no-ff` into the stable `project/<slug>` branch and
the worktree was torn down. Run the gates cold on the integrated branch:

```sh
architect gate hello-loop
```

```text
── AC1: … (exit 0)  [PASS]
```

That is one full iteration: specified, frozen, built by a fresh headless
builder, mechanically verified, judged, integrated. The next `architect new`
allocates ordinal `I02` — the loop repeats. `architect status` shows the
project state at any point.

## Where to next 🧭

- **Parallel lanes, variant sets, conflict handling** —
  [run parallel lanes](../how-to/run-parallel-lanes.md)
- **Research fan-out before a spec** —
  [run a research fan-out](../how-to/run-a-research-fan-out.md)
- **Every command, flag, and file format** — [docs/reference](../reference/)
- **Why the loop trusts frozen gates and fresh contexts** —
  [docs/explanation](../explanation/)
