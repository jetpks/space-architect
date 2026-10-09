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
| `--model=VALUE` | `accounts/fireworks/models/glm-5p3-flash` | Researcher model override (any provider/tier). |
| `--max-turns=VALUE` | `40` | Max turns per researcher. |

`research wait` options:

| Option | Default | Description |
|--------|---------|-------------|
| `--[no-]quiet` | `false` | L0: suppress all output; exit status only. |
| `--level=N` | `1` | Verbosity: `1`=lifecycle, `2`=+text, `3`=+tools, `4`=+io. |
| `--[no-]thinking` | `false` | Show assistant thinking blocks. |
| `--[no-]jsonl` | `false` | Emit raw lane-tagged JSONL (mutually exclusive with `--level`/`--quiet`). |

## `architect jobs [SUBCOMMAND]`

Inspect and control jobs on a space-server (the ingest/runs server
space-architect-server). All four subcommands take `--host=URL` (base URL of
the space-server) and `--token=VALUE` (bearer token).

| Command | Description |
|---------|-------------|
| `jobs list` | List jobs for the authenticated user (owner-scoped, newest-first). |
| `jobs show ID` | Show a job's full JSON. |
| `jobs cancel ID` | Cancel a job. |
| `jobs watch ID` | Resolve a job's run and stream its live events (SSE) until `run_complete`. |

```sh
architect jobs list --host https://<server> --token <token>
architect jobs watch <id> --host https://<server> --token <token>
```

## `architect sessions [SUBCOMMAND]`

The session-sync rail (requires the **repo-tender** gem — a soft dependency;
without it these commands fail with a short error naming `gem install
repo-tender`). The task-level recipe is [install the session-sync
rail](../how-to/install-the-session-sync-rail.md).

### `architect sessions sync`

Scan pi/claude session files and upload new/grown conversations to a
space-server.

| Option | Default | Description |
|--------|---------|-------------|
| `--host=VALUE` | — | Base URL of the space-server. |
| `--token=VALUE` | `$SPACE_ARCHITECT_INGEST_TOKEN` | Bearer token; an explicit `--token` wins; an `op://` ref is resolved once via `op read`. |
| `--state-file=VALUE` | `$XDG_STATE_HOME/space-architect/session-sync.yaml` | Cursor YAML path. |
| `--pi-root=VALUE` | `~/.pi/agent/sessions` | Override the pi sessions root. |
| `--claude-root=VALUE` | `~/.claude/projects` | Override the claude projects root. |
| `--[no-]dry-run` | `false` | Report what would upload without uploading or recording the cursor. |

### `architect sessions agent install|status|uninstall`

| Command | Description |
|---------|-------------|
| `agent install` | Install the launchd agent that periodically runs `architect sessions sync`. Options: `--host`, `--token` (an `op://` ref is resolved once at install time; the raw value is stored in the plist's `EnvironmentVariables`, not argv), `--interval=SECONDS` (default `900`). |
| `agent status` | Report the launchd agent's loaded/running/last-exit state. |
| `agent uninstall` | Uninstall the agent (bootout + remove the plist). |
