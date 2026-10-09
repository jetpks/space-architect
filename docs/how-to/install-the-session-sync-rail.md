# Install the session-sync rail 🛰️

You want your pi and Claude conversation transcripts uploaded to a
space-server automatically, on an interval, without running anything by hand.

The launchd agent the rail uses ships in the **repo-tender** gem — a soft
dependency of space-architect, deliberately absent from its gemspec. Without
it, every other `architect` command works; only the `architect sessions`
commands need the gem.

## 1. Install repo-tender

```sh
gem install repo-tender
```

## 2. Sync once, by hand (check your inputs first)

```sh
architect sessions sync --host https://<your-space-server> --token <token>
```

This scans `~/.pi/agent/sessions` and `~/.claude/projects` and uploads new or
grown conversations. Useful flags (see
[reference](../reference/groups.md#architect-sessions-sync)):

- `--dry-run` — report what would upload without uploading or moving the cursor
- `--pi-root` / `--claude-root` — override the scanned roots
- `--token` — bearer token; defaults to `$SPACE_ARCHITECT_INGEST_TOKEN`, and an
  `op://` ref is resolved once via `op read`
- the sync cursor lives at `$XDG_STATE_HOME/space-architect/session-sync.yaml`
  (override with `--state-file`)

## 3. Install the launchd agent

```sh
architect sessions agent install --host https://<your-space-server> --token <token>
```

The agent runs `architect sessions sync` on a `StartInterval` (900 seconds by
default; `--interval <seconds>` to change). The token is stored in the plist's
`EnvironmentVariables`, not argv; an `op://` ref is resolved once at install
time.

## 4. Check and remove

```sh
architect sessions agent status      # loaded / running / last-exit state
architect sessions agent uninstall   # bootout + remove the plist
```
