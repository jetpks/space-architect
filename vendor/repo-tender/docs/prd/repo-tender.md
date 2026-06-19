# PRD — repo-tender

**Date:** 2026-06-12 · **Author:** architect · **Status:** build-ready (build loop not yet started)
**Source research:** `docs/research/repo-tender.md` (evidence + version verification + discarded hallucinations)
**Decisions:** periodic launchd job (no resident daemon/IPC) · YAML config · Ruby 4.0.5 · macOS

> Build-loop note: PHASE 0 should challenge the **[CONFIRM]**-tagged claims below (single-source
> or version-sensitive). Everything else is verified — see the research doc's verification ledger.

---

## 1. Goal & non-goals

**Goal.** Keep local clones *evergreen* so a downstream "space" tool can clone them from the
local filesystem instantly instead of over the network.

**Evergreen (the invariant)**, per repo:
- **Clean** — no modified/staged/untracked/deleted/missing files per the SCM.
- **On default branch** — HEAD is the remote's default branch, *whatever it's named*
  (not assumed to be `main`).
- **Fresh** — the default branch is up to date with the remote, fetched within
  `refresh_interval` (default 6h).

**Layout.** `$BASE_DIR/:host/:owner/:repo` — e.g. `~/src/evergreen/github.com/ruby/ruby/`.
`$BASE_DIR` defaults to `~/src/evergreen/`.

**Scope.** A CLI (`repo-tender`) + a periodic launchd-invoked sync run. Track individual
repos and whole GitHub orgs (via `gh`). `git` is the only SCM, behind a generic interface.

**Non-goals.** No resident daemon, no UNIX socket, no IPC, no in-process scheduler/signal
supervision (launchd owns cadence + lifecycle). No web UI. No non-GitHub forges yet (but
the forge interface is decoupled). No push/write to remotes. **Never** auto-resolve a
dirty or diverged repo by destroying work.

---

## 2. Frozen tech stack (pinned, verified 2026-06-12)

| Concern | Choice | Constraint |
|---|---|---|
| Runtime | Ruby **4.0.5**, managed by mise | `mise.toml` pins it |
| Concurrency | `async` **~> 2.39** | fan-out one sync run |
| Subprocess | **stdlib `Open3.capture3`** inside an `Async` task | **no `async-process`** — Open3 is non-blocking via the Fiber scheduler → kqueue |
| CLI | `dry-cli` **~> 1.4** | nested subcommands via block `register` |
| Validation | `dry-validation` **~> 1.11** (`dry-schema ~> 1.16`) | `Contract` over the loaded config hash |
| Model | `dry-struct` **~> 1.8** (`dry-types ~> 1.9`) | immutable config/state structs |
| Outcomes | `dry-monads` **~> 1.10** | `Result` at operation boundaries |
| Paths | `xdg` **~> 10.2** (bkuhlmann) | config/state/data/cache/runtime homes |
| Config format | **YAML** (Psych, stdlib) | comment loss accepted (mitigated by config/state split) |
| Tests | **minitest** | terse, public-interface only, real temp git repos (no mocks) **[CONFIRM]** |

**Out:** `async-process` (stale, drops stderr/status), `async-container`/`Async::Loop`/signal
supervision (launchd owns lifecycle), `toml_kit` / TOML (YAML chosen), any `dry-*` gem not
from the dry-rb org.

---

## 3. Domain model

### 3.1 Config — `$XDG_CONFIG_HOME/repo-tender/config.yaml` (durable user intent)

```yaml
base_dir: ~/src/evergreen          # default if absent
refresh_interval: 6h               # "6h" / "90m" / integer seconds; default 6h
concurrency: 8                     # max parallel git/gh ops per run; default 8
repos:                             # individually tracked repos
  - host: github.com
    owner: ruby
    name: ruby
orgs:                              # whole-org tracking, expanded via gh at sync time
  - host: github.com
    name: socketry
    include_archived: false        # default false
    include_forks: false           # default false
```

- A repo's identity is `(host, owner, name)`; clone URL + on-disk path are **derived**, not stored.
- `host` defaults to `github.com` when omitted on a repo/org entry.
- The CLI rewrites this file on CRUD. Validation runs on every load *and* before every write.

### 3.2 State — `$XDG_STATE_HOME/repo-tender/state.yaml` (machine-managed; never hand-edited)

```yaml
repos:
  github.com/ruby/ruby:
    default_branch: trunk
    last_fetch_at: 2026-06-12T20:01:33Z
    last_synced_at: 2026-06-12T20:01:34Z
    status: clean            # clean | dirty | diverged | detached | wrong_branch | missing | error
    last_error: null
orgs:
  github.com/socketry:
    last_listed_at: 2026-06-12T20:00:10Z
    repo_count: 41
```

- Org-discovered repos are **state**, not config — keeps the user's config file stable and
  sidesteps YAML comment-loss on machine rewrites.
- Logs live in `$XDG_STATE_HOME/repo-tender/logs/`; **the process rotates its own logs**
  (launchd does not rotate, and external rotation can break the redirect fd).

### 3.3 Evergreen evaluation (per repo, local-first — minimize network)

1. **Present?** Path missing → action `clone`.
2. **Detached / wrong branch?** `git symbolic-ref --short HEAD` vs default branch → `wrong_branch`/`detached` (report; do not auto-switch a dirty tree).
3. **Clean?** `git status --porcelain=v2 --branch --untracked-files=normal` → any `1`/`2`/`u`/`?` line ⇒ `dirty` (report; never touch).
4. **Fresh?** `.git/FETCH_HEAD` mtime within `refresh_interval` ⇒ skip network entirely. **[CONFIRM mtime tolerance — it's a hint, not an API]**
5. **Behind?** `git rev-list --left-right --count <default>...origin/<default>`; if clean + on-default + right-count>0 and left-count==0 → `git fetch --prune --no-tags origin` then `git merge --ff-only origin/<default>`. Left-count>0 (local ahead/diverged) ⇒ `diverged` (report; **never** `reset --hard`).

Default-branch resolution: `git symbolic-ref --short refs/remotes/origin/HEAD` (local, no
network); if missing/stale → `git remote set-head origin -a` (network) once, then cache in
state. (A plain `fetch` does **not** update `origin/HEAD`.)

---

## 4. Project layout

```
bin/repo-tender                 # dry-cli entrypoint (executable)
lib/repo_tender.rb              # requires + version
lib/repo_tender/
  paths.rb                      # xdg wrapper: config_file, state_file, log_dir, base_dir
  shell.rb                      # Open3.capture3 wrapper → Result; assumes ambient Async task
  config/
    model.rb                    # dry-struct: Config, RepoRef, OrgRef
    contract.rb                 # dry-validation contract
    store.rb                    # load → validate → struct; struct → YAML write-back
  state/
    store.rb                    # XDG_STATE read/write (YAML)
  scm/
    client.rb                   # abstract interface (decouple SCM)
    git.rb                      # git-CLI implementation
    status.rb                   # parsed porcelain-v2 value object
  forge/
    client.rb                   # abstract interface (decouple forge)
    github.rb                   # gh-CLI org listing
  sync/
    engine.rb                   # orchestrates one run (Async + Barrier/Semaphore)
    repo_plan.rb                # evergreen evaluation → action
  launchd/
    plist.rb                    # generate StartInterval plist XML
    agent.rb                    # launchctl bootstrap/bootout/kickstart/print/list
  cli.rb                        # Dry::CLI::Registry
  cli/                          # one file per command group: repo, org, sync, status, daemon, config
repo-tender.gemspec · Gemfile · mise.toml · test/
```

Cross-cutting conventions:
- **Boundaries return `Result`** (`dry-monads`): `Shell`, `SCM::Git`, `Forge::GitHub`,
  `Config::Store`, `Sync::Engine`. CLI translates `Failure(...)` → stderr + nonzero exit.
  Exceptions only for programmer error, not expected failures (dirty repo, network down).
- **Async only where needed:** the sync engine wraps work in `Sync do … end`; CRUD/status
  commands are plain synchronous Ruby (no reactor).
- **External binaries** (`git`, `gh`, `mise`, `launchctl`) resolved via PATH at runtime;
  the plist supplies PATH / uses `mise exec`.
- Format with the project linter (`standardrb` or `rubocop` per builder choice) on every slice.

---

## 5. Slices (each independently shippable; gates are frozen acceptance criteria)

### Slice 1 — Foundation (paths · config · state · shell · SCM/forge clients)
**Builds:** `paths`, `config/*`, `state/store`, `shell`, `scm/{client,git,status}`, `forge/{client,github}`.

**Gates:**
1. `Config::Store` round-trips: load a YAML config, mutate via the struct, write back, reload → managed fields identical; unknown/comment lines may be lost (documented).
2. `Config::Contract` rejects: missing required fields, bad `refresh_interval`, non-integer `concurrency`, malformed repo/org entries → `Failure` with field-level messages.
3. `Paths` resolves config/state/log/base under XDG envs, honoring `$XDG_CONFIG_HOME`/`$XDG_STATE_HOME` overrides and the `~/src/evergreen` base default.
4. `Shell.run("git","--version", chdir:)` inside `Sync{}` returns `Success(stdout)`; a nonzero exit returns `Failure` carrying argv + stderr + status; **two concurrent `Shell.run`s in one `Sync{}` overlap** (proves non-blocking — assert wall-clock < sum of two `sleep`s via `Shell.run("sh","-c","sleep 0.3")`).
5. `SCM::Git` against a **real temp git repo + local bare remote** (no mocks): `status` parses clean vs dirty (modified, staged, untracked) correctly; `default_branch` returns the bare remote's HEAD even when named `trunk`; `current_branch`, `last_fetch_at`, `fetch`, `fast_forward`, `clone` behave; `fast_forward` refuses on divergence (returns `Failure`, no data loss).
6. `Forge::GitHub#list_org` parses `gh repo list <org> --json …` into `RepoRef`s; reads `.defaultBranchRef.name`; honors `include_archived`/`include_forks`. (Use a recorded JSON fixture so the test is offline + deterministic; one live smoke test allowed but not in CI.)

**[CONFIRM] in PHASE 0:** minitest vs rspec; exact `gh --json` field availability at installed `gh` 2.93.

---

### Slice 2 — Sync engine (evergreen logic + bounded async fan-out)
**Depends on:** Slice 1. **Builds:** `sync/repo_plan`, `sync/engine`.

**Gates** (all against real temp git repos with a local bare remote):
1. **Clean + behind** repo → `fetch` + `merge --ff-only` → now up to date; status `clean`.
2. **Fresh** repo (FETCH_HEAD mtime < refresh_interval) → **skipped, no network** (assert no fetch occurred, e.g. FETCH_HEAD mtime unchanged).
3. **Dirty** repo → left byte-for-byte untouched; status `dirty`; reported, not modified.
4. **Diverged** (local commits ahead) → status `diverged`; **no `reset --hard`**, working tree + local commits intact.
5. **Detached / wrong branch** → reported as such; clean tree may be switched back to default, dirty tree is left + reported (no forced switch).
6. **Missing** path → `clone` into `$BASE/:host/:owner/:repo`.
7. **Concurrency bound** respected: with `concurrency: 2` and 5 slow repos, at most 2 run at once (instrument via a counting semaphore probe or timing).
8. Engine writes per-repo results to `State::Store`; a single repo's failure (`Failure`) does not abort the run — others still process; the failure is recorded in state.
9. Idempotent: running the engine twice back-to-back makes no network calls on the second run (all fresh).

---

### Slice 3 — CLI surface + config CRUD
**Depends on:** Slices 1–2. **Builds:** `cli`, `cli/{repo,org,sync,status,config}`, `bin/repo-tender`.

**Commands:** `repo add|remove|list`, `org add|remove|list`, `sync [--repo …]`, `status`,
`config path|show`.

**Gates:**
1. `repo add github.com/ruby/ruby` persists the entry to `config.yaml` (validated before write); `repo list` shows it; `repo remove` deletes it; duplicate add is idempotent (no dup, clear message).
2. `org add github.com/socketry` persists; `org list` shows it; remove deletes.
3. Invalid input (`repo add not-a-ref`) → nonzero exit + a `Failure`-derived stderr message; config file unchanged.
4. `sync` invokes `Sync::Engine`; `sync --repo github.com/ruby/ruby` scopes to one repo.
5. `status` reads `State::Store` and renders a per-repo evergreen table (status + last_synced_at + default_branch).
6. `config path` prints the resolved config path; `config show` prints the effective (validated, defaults-applied) config.
7. Nested subcommand registration works (`repo add` dispatches to the right command, `repo` alone shows help).

---

### Slice 4 — launchd integration + daemon control
**Depends on:** Slice 3. **Builds:** `launchd/{plist,agent}`, `cli/daemon`, log rotation.

**Commands:** `daemon install|uninstall|start|stop|restart|status`.

**Gates:**
1. `Launchd::Plist` generates valid plist XML containing: `Label`, `ProgramArguments = [mise-path, exec, --, ruby-or-shim, <abs bin/repo-tender>, sync]`, `StartInterval = refresh_interval-in-seconds`, `RunAtLoad = true`, `ProcessType = Background`, absolute `StandardOutPath`/`StandardErrorPath` under the log dir — **`$HOME`/`~` resolved to absolute paths**, **no `KeepAlive`**.
2. `daemon install` writes the plist to `~/Library/LaunchAgents/<label>.plist` and `launchctl bootstrap gui/$UID <plist>`; `uninstall` does `launchctl bootout gui/$UID/<label>` and removes the file.
3. `daemon start`→bootstrap+enable, `stop`→bootout/disable, `restart`→`kickstart -k` (run now), `status`→parse `launchctl print`/`list` (loaded? running? last exit) + show last-run state.
4. mise resolution: the generated `ProgramArguments` run Ruby via `mise exec` (or a resolved shim path) with `MISE_CONFIG_FILE`/`WorkingDirectory` pinned so the right `mise.toml` is used (`mise activate` is **not** used — broken non-interactively).
5. Log rotation: the sync process rotates its own log when it exceeds a size/age threshold (timestamped files), since launchd won't.

**[CONFIRM] in PHASE 0:** several gates here are integration-level on a real Mac and may run
as a documented manual checklist rather than CI; `launchctl print` output is explicitly
"not API" (parse defensively, prefer `launchctl list` columns for machine checks).

---

## 6. Cross-slice risks / PHASE-0 challenge list

- **FETCH_HEAD mtime as freshness signal** — a hint, not a documented contract (backups/`touch`
  can move it). Tolerate skew; treat "can't determine" as stale and fetch. **[CONFIRM]**
- **`gh` macOS Keychain silent-fallback** — `gh` can drop to unauthenticated (60 req/hr) without
  erroring. `Forge::GitHub` should run `gh auth status` before bulk listing and surface a clear
  `Failure` if unauthenticated. **[CONFIRM single-source]**
- **`origin/HEAD` staleness** — set only at clone; re-`set-head -a` periodically and cache. Covered
  in the evergreen eval but flagged so PHASE 0 keeps it.
- **Async API surface** — we rely only on `Async`/`Sync`, `Async::Barrier`, `Async::Semaphore`
  (all long-stable). We deliberately avoid `Async::Loop`/`async-container` (version-sensitive,
  not needed for a periodic job).
- **Slicing** — Slices 1→2→3 are a hard dependency chain; Slice 4 depends on 3 but is otherwise
  independent. No two slices touch the same files, so they can be lane-split if parallelized later.

---

## 7. Definition of done (whole project)

`repo-tender daemon install` schedules a launchd job that, every `refresh_interval`, runs one
async sync sweep bringing every tracked repo (explicit + org-expanded) to the evergreen
invariant — cloning missing ones, fast-forwarding clean+behind ones, and reporting (never
mutating) dirty/diverged ones — with per-repo status queryable via `repo-tender status`, all
config CRUD persisted to validated YAML, and the whole thing reproducible from `mise.toml`.
