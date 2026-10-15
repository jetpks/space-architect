# Build-phase commands 🏗️

Commands that materialize lanes and run builders: `provision`, `dispatch`, and
the `worktree` group. Usage lines are the shipped binary's own.

## `architect provision ITERATION [SPACE]`

Materialize declared lanes (worktree + `lane/<id>-<lane>` branch) from the
frozen lane plan. Reads the frozen ```lanes block — one worktree per entry at
`build/<id>-<lane>/wt`.

Before cutting any worktree, provision fast-forwards each selected lane repo's
`project/<slug>` integration branch from the repo's default branch — local-only
and fast-forward-only, no fetch, no pull. When the two branches have diverged
(each holds commits the other lacks), provision refuses the entire run and
creates nothing: merge the default branch into `project/<slug>` deliberately, or
pin a base explicitly with `--base`. An explicit `--base` skips the sync
entirely and cuts exactly the given ref. A no-op sync (integration branch at or
ahead of the default branch) prints nothing; a moved branch is reported on
stdout, and the auto-materialize paths (dispatch/gate/integrate/verify hitting a
missing lane worktree) report theirs on stderr.

| Option | Default | Description |
|--------|---------|-------------|
| `--base=REF` | `project/<slug>` after a fast-forward sync from the repo's default branch (diverged → refusal); `--base` itself skips the sync | Base ref override — cuts exactly the given ref, no sync, no divergence refusal. |
| `--lane=NAME` | all declared lanes | Provision only this lane. |
| `--[no-]force` | `false` | Clear and re-create a stale (unregistered) worktree directory. Does not bypass the diverged-branch refusal. |

```sh
architect provision my-feature
architect provision my-feature --lane lane-a
```

## `architect dispatch ITERATION LANE [SPACE]`

Dispatch a builder for a lane: copies the `--prompt` file to the canonical
`build/<id>-<lane>/prompt.md`, runs a headless **pi** session in the lane's
worktree with the prompt on stdin, and streams the JSONL event log to
`build/<id>-<lane>/run.jsonl`, with the builder's report at
`build/<id>-<lane>/report.md`. Refuses to dispatch a missing, empty, or
still-stubbed prompt. Under the hood it runs:
`pi -p --mode json --model <model> --session-dir <run dir> --no-approve -e <builder-guard>`.

| Option | Default | Description |
|--------|---------|-------------|
| `--prompt=FILE` | — | Lane prompt source — copied byte-for-byte to `build/<id>-<lane>/prompt.md`. Omit to reuse an existing canonical prompt. |
| `--model=VALUE` | the lane's stored model, else `architect.yaml` builder role, else `space.yaml` `project.model`, else the pi default (last resort) | Builder model to pin — any provider/tier; pin a full id, not a floating alias. |
| `--max-turns=VALUE` | `200` | Max turns for the builder. |
| `--harness=VALUE` | lane entry, else `space.yaml` `project.harness`, else `pi` | Harness (`pi` is the only valid value; anything else is rejected with an actionable error). |
| `--effort` / `--thinking` / `--reasoning=VALUE` | — | Thinking/reasoning effort level — aliases of one another (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`). |
| `--force-effort` / `--force-thinking` / `--force-reasoning=VALUE` | — | Force the literal level onto the `--thinking` flag, skipping architect's validation (dispatch only; the binary's rejection is final). |
| `--[no-]quiet` | `false` | Suppress thinking-translation and harness run-time warn lines (liveness/push) on stderr. |
| `--[no-]detach` | `false` | Detach the builder process — returns immediately with a PID; poll the report for completion. Cannot combine with `--push-url`/`--push-host`. |
| `--timeout=SECONDS` | `14400` (4h) | Wall-clock timeout; the wedged builder's process group is killed (TERM → grace → KILL). `0` disables. Foreground only. |
| `--push-url=URL` | — | HTTP endpoint for streaming push (POST body to this URL). Requires `--push-token`. |
| `--push-host=URL` | — | Base URL of the ingest server; the CLI creates a run via `POST <host>/runs` and streams to `/runs/<id>/ingest`. Requires `--push-token`; mutually exclusive with `--push-url`. |
| `--push-token=TOKEN` | — | Bearer token for push endpoint authorization. |

The model resolution chain: the `--model` flag > the lane's stored model > the
`architect.yaml` builder role > `space.yaml` `project.model` > the pi default
`accounts/fireworks/models/glm-5p3-flash` — a loudly-informed last resort on
stderr. `architect.yaml` is loop-role routing config, resolved space-local
(`architect.yaml` at the space root) over global
(`$SPACE_ARCHITECT_GLOBAL_CONFIG`, else `~/.config/space-architect/architect.yaml`),
merged per role.

```sh
architect dispatch my-feature lane-a --prompt tmp/prompts/I01-lane-a.md
architect dispatch my-feature lane-a --detach          # returns a PID; poll report.md
architect dispatch my-feature lane-a --max-turns 100 --effort high
```

The dispatch pushes the builder's JSONL stream through a vendored
builder-guard extension that denies git-write subcommands before they run —
the architect CLI owns all commits.

## `architect worktree [SUBCOMMAND]`

Manage per-lane git worktrees under `build/`.

| Command | Description |
|---------|-------------|
| `worktree add REPO ITERATION LANE [SPACE]` | Create a worktree at `build/<id>-<lane>/wt` and record the lane in `space.yaml`. Idempotent — re-adding a lane reuses the existing worktree/branch and merges the new options in place. |
| `worktree list [SPACE]` | List active architect worktrees. |
| `worktree remove ITERATION LANE [SPACE]` | Remove the lane worktree. Refuses if the worktree holds uncommitted work — untracked files included; `--force` overrides and discards it. |

`worktree add` options:

| Option | Default | Description |
|--------|---------|-------------|
| `--base=REF` | repo HEAD | Base ref for the worktree (any git ref, including `project/<slug>`). |
| `--harness=VALUE` | `space.yaml` `project.harness`, else `pi` | Harness for the lane. |
| `--model=VALUE` | `architect.yaml` builder role, else `space.yaml` `project.model`, else the pi default (last resort) | Model for the lane; a trailing `:<level>` suffix (e.g. `foo:high`) is parsed into `--effort`. |
| `--effort` / `--thinking` / `--reasoning=VALUE` | — | Thinking/reasoning effort level (aliases). |
| `--[no-]quiet` | `false` | Suppress the thinking-translation inform line on stderr. |
| `--touch=GLOBS` | — | Comma-separated file globs the lane may touch. Recorded as the lane's `touch_set` and enforced by the in-bounds check (`architect verify`) and by `merge`. |
| `--[no-]force` | `false` | Clear and re-create a stale (unregistered) worktree directory. |

```sh
architect worktree add my-app dry-cli-port lane-a
architect worktree add my-app dry-cli-port lane-a --touch lib/my_app/**,test/my_app_test.rb
architect worktree list
architect worktree remove dry-cli-port lane-a
```

In the common flow you do not call `worktree add` by hand — `provision`
materializes the frozen lanes block. The subcommand remains for single-lane,
manual, or repair flows.
