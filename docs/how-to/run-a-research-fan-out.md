# Run a research fan-out 🔭

An iteration needs facts the repo doesn't already have — an external API's
actual behavior, a library's breaking changes, what the changelog really
promised. Fan out parallel **read-only** researchers, verify their claims
yourself, and write the iteration's Grounds section from what survives.

Researchers gather; they never make recommendations. Verification of
load-bearing claims and Grounds authorship stay with the architect.

## 1. Write one narrow prompt file per question

Each prompt file answers exactly one non-overlapping question. Keep them
narrow — a researcher with a diffuse question returns diffuse text. Example
`tmp/prompts/01-official-api.prompt.md`:

```text
Determine <the one question>. Cite every finding with a URL, the date you
fetched it, and the exact quote or figure. Report disagreements between
sources instead of resolving them. If you cannot verify something, say
NOT FOUND — do not infer. Raw findings only; no recommendations.
```

## 2. Dispatch one detached researcher per file

```sh
architect research dispatch tmp/prompts/01-official-api.prompt.md tmp/prompts/02-changelog.prompt.md
```

Each researcher runs detached (headless `pi`, read-only by prompt contract —
the injected guard denies git writes), writing its JSONL event stream under
`build/research/<id>/`. Options: `--model <id>` (default:
`accounts/fireworks/models/glm-5p3-flash`) and `--max-turns <n>` (default 40).

## 3. Watch

```sh
architect research status      # snapshot: id, pid, state, model, last line
architect research wait        # block until all runs complete, streaming output
```

`wait` verbosity: `--level 1..4` (lifecycle → +text → +tools → +io),
`--thinking` to include assistant thinking blocks, `--quiet` for exit status
only, `--jsonl` for raw lane-tagged JSONL (mutually exclusive with
`--level`/`--quiet`).

## 4. Verify, then write Grounds

Read each researcher's final report, verify the load-bearing claims against
the cited sources yourself, and write the iteration's `## Grounds` section —
the distilled, cited facts that the Specification will build on:

```sh
architect section <iteration> grounds --from tmp/grounds.md
```

Grounds is committed with the iteration (repo memory); the raw researcher
output stays in gitignored scratch. The builder's PHASE 0 will challenge
Grounds like any other spec input — that is by design.

## When *not* to do this

Routine API checks belong to the builder's verify-against-reality discipline,
not to a fan-out. Reach for research lanes when the facts are genuinely
missing from the repo, nobody present has them, or the human asks. See
[DESIGN §5](../DESIGN.md) for the trigger discipline.
