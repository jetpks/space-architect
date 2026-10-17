# Subcommand groups 🗂️

The six subcommand namespaces `architect --help` lists under **Groups**. Usage
lines are the shipped binary's own.

## `architect brief [SUBCOMMAND]`

- `brief new [SPACE]` — write the durable project brief; see
  [Spec-phase commands](spec.md#architect-brief-new-space).

## `architect worktree [SUBCOMMAND]`

`worktree add|list|remove` — see
[Build-phase commands](build.md#architect-worktree-subcommand).

## `architect variant [SUBCOMMAND]`

Manage competing-lane variant sets — multiple `(harness, model)` lanes over
one byte-identical frozen spec, used to compare builder strategies or model
tiers head-to-head. Judge every variant against the same frozen AC before
promoting a winner.

| Command | Description |
|---------|-------------|
| `variant add REPO ITERATION [SPACE]` | Create a variant set: one worktree per `harness[:model]` pair. |
| `variant compare ITERATION [SPACE]` | Side-by-side view of all variants (read-only). |
| `variant promote ITERATION WINNER [SPACE]` | Promote one variant as the winner (e.g. `v02`); others are marked discarded. |

`variant add` options: `--pairs=PAIRS` (comma-separated `harness[:model]`
pairs, e.g. `pi,pi:accounts/fireworks/models/glm-5p3-flash`), `--base=REF`
(default repo HEAD), `--prompt=FILE` (fanned out byte-identical to each
variant).

```sh
architect variant add my-app my-feature --pairs "pi,pi:accounts/fireworks/models/glm-5p3-flash"
architect variant compare my-feature
architect variant promote my-feature v02
```

## `architect research [SUBCOMMAND]`

Fan out parallel **read-only** research lanes — detached `pi` researchers with
a git-write-denying guard — when an iteration needs facts the repo doesn't
already have. The task-level recipe is [run a research
fan-out](../how-to/run-a-research-fan-out.md).

| Command | Description |
|---------|-------------|
| `research dispatch PROMPTS` | Dispatch one detached researcher per prompt file (space-separated paths). |
| `research status [SPACE]` | Show the state of dispatched research runs. |
| `research wait [SPACE]` | Wait for all dispatched runs to complete, streaming their output. |

`research dispatch` options:

| Option | Default | Description |
|--------|---------|-------------|
| `--model=VALUE` | the pi default `accounts/fireworks/models/glm-5p3-flash` (researchers are not `architect.yaml`-routed; loudly informed when the default is used) | Researcher model override (any provider/tier). |
| `--max-turns=VALUE` | `40` | Max turns per researcher. |

`research wait` options:

| Option | Default | Description |
|--------|---------|-------------|
| `--[no-]quiet` | `false` | L0: suppress all output; exit status only. |
| `--level=N` | `1` | Verbosity: `1`=lifecycle, `2`=+text, `3`=+tools, `4`=+io. |
| `--[no-]thinking` | `false` | Show assistant thinking blocks. |
| `--[no-]jsonl` | `false` | Emit raw lane-tagged JSONL (mutually exclusive with `--level`/`--quiet`). |
