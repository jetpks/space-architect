# Space Cadet Design

## Why this exists

`space-cadet` is a CLI for creating and managing task-scoped project workspaces. The workspace lifecycle should feel closer to a Jira ticket, investigation, or agentic work session than to a long-lived git branch.

The motivating workflow is modern agent-assisted development: several concurrent tasks may touch the same repositories, each task may need fresh clones, notes, prompts, logs, screenshots, or other ephemera, and sandboxed tools are more reliable when all task context lives under one obvious filesystem root.

## Core constraints

- A space is fundamentally a normal directory structure.
- The workspace root location is configurable and may be anywhere on the filesystem.
- App config and state follow the XDG base directory spec.
- Per-space identity lives inside the space itself so the directory is self-describing and portable.
- Space ids are date-prefixed for natural manual sorting, e.g. `20260531-name-of-space`.
- Creating a space from `space new "Name of Space"` should create that same date-prefixed id shape.
- Duplicate space names on the same date append counters, e.g. `20260531-name-of-space-2`.
- Spaces may grow over time by adding/removing repos, notes, tickets, tags, and other task metadata.
- The initial implementation should be boring and inspectable: YAML metadata, plain directories, no database.

## Directory shape

A space should look like this:

```text
~/src/spaces/20260531-name-of-space/
  .space.yml
  README.md
  repos/
  notes/
  artifacts/
```

The default containing directory is:

```text
~/src/spaces
```

but this is only a default and must remain configurable.

## XDG ownership

XDG config/state are for application-level concerns only.

Config defaults to:

```text
$XDG_CONFIG_HOME/space-cadet/config.yml
# fallback: ~/.config/space-cadet/config.yml
```

State defaults to:

```text
$XDG_STATE_HOME/space-cadet/state.yml
# fallback: ~/.local/state/space-cadet/state.yml
```

The source of truth for a space is its own `.space.yml`, not the XDG state file. XDG state is convenience/cache data and should be rebuildable or disposable.

## Current-space behavior

Commands that operate on a space should prefer explicit arguments. When no explicit space is supplied, they should resolve the current space from `$PWD` by walking upward until `.space.yml` is found.

This is intentional: if the user is inside `space:foo`, commands must apply to `foo`, not to some previously selected or recently used `space:qux`.

`space use` should not be the authority for implicit command targeting. It may record recent state and print a path, but PWD-based resolution wins.

## Metadata shape

Each space stores identity in `.space.yml`:

```yaml
version: 1
id: 20260531-name-of-space
title: Name of Space
status: active
created_at: 2026-05-31T13:48:00-06:00
updated_at: 2026-05-31T13:48:00-06:00
repos: []
notes: []
tickets: []
tags: []
```

Supported statuses are:

- `active`
- `paused`
- `done`
- `archived`

## CLI principles

- The executable is `space`; the gem/library is `space-cadet`.
- Output should be readable manually and useful in scripts where possible.
- `space path [SPACE]` prints only the path.
- `space ls` should be compact and human-readable.
- Paths under the user home should be displayed as `~/...` in human-oriented output.
- Color should default to auto-detection for TTY output and be overrideable with `--color=auto|always|never` or `--colors=auto|always|never`.
- Do not implement shell `cd` integration yet.

## Deferred intentionally

The initial design intentionally defers:

- Jira API integration.
- Repo cloning/management beyond establishing the future `repos/` location.
- Notes subcommands beyond establishing the future `notes/` location.
- Git branch or worktree automation.
- Agent-specific config generation.
- SQLite or background indexing.
- Shell integration for `cd`.
