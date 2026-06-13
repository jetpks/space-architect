# repo-tender — architecture research

**Date:** 2026-06-12 · **Author:** architect (Claude Opus 4.8) · **Status:** ready for PRD
**Method:** 6 background research lanes (minimax-m3 via `pi`, web+repo-grounded) +
orchestrator verification against RubyGems/GitHub/man pages. Raw lane findings in
`.architect/research/*.md`.

---

## Decisions locked (2026-06-12, user)

1. **Daemon shape → periodic launchd job** (not a resident socket daemon). launchd
   wakes `repo-tender` on a schedule; it syncs all repos concurrently under `async`,
   then exits. **No UNIX socket, no IPC, no in-process signal supervision.** The CLI
   reads/writes config and queries `launchctl` for status.
2. **Config format → YAML** (Psych, stdlib). Comment loss on machine rewrite is
   accepted; mitigated by splitting durable config from machine-managed state (§6).

**Consequences that override the research defaults below:**
- **Plist uses `StartInterval` (e.g. `21600` = 6h) + `RunAtLoad`, NOT `KeepAlive`.**
  `KeepAlive` is for *resident* processes; §8's "run forever, restart on crash" plist
  is the wrong template for a periodic job. Use the interval template in §8a.
- **`async-container` / `Controller` / `with_signal_handlers` / `Async::Loop.periodic`
  are no longer load-bearing.** launchd provides the 6h cadence; the process is
  short-lived. Keep §2's **`Async::Barrier` + `Async::Semaphore`** fan-out (still the
  core of one sync run); drop the supervisor/periodic/signal sections. A small SIGTERM
  handler to abort cleanly mid-sweep is nice-to-have, not required (a killed `git fetch`
  just leaves the repo stale, retried next cycle).
- **CLI `daemon` verbs map to launchctl** (§8c): `start`→`bootstrap`+`enable`,
  `stop`→`bootout`/`disable`, `restart`/run-now→`kickstart -k`, `status`→`launchctl
  print`/`list` + read the last-run state file in `$XDG_STATE_HOME`.
- **Make sync idempotent + cheap:** skip repos whose `.git/FETCH_HEAD` mtime is <6h
  (§5) so a manual `kickstart` doesn't re-fetch everything.

---

## BLUF (answer first)

Every major technology choice the user pre-selected **holds up** — with three
corrections and one open design question that the user should decide before we build:

1. **Don't add `async-process`.** Plain stdlib `Open3.capture3` inside an `Async`
   block is *already* non-blocking on the current stack — `Process.wait2` and pipe
   reads flow through Ruby's Fiber scheduler into kqueue (`EVFILT_PROC` /
   `EVFILT_READ`) on macOS. `async-process` exists but is stale (v1.4.0, last pushed
   2024-11-08) and its `capture` throws away stderr and exit status. **[VERIFIED]**

2. **Use `async-container`, not bare `async`, for the daemon's spine.** Core `async`
   does *not* trap signals and does *not* restart crashed children.
   `Async::Container::Controller` ships the correct signal-trap + supervised-restart
   logic (with the `restart && !stopping` gate that prevents infinite restart loops).
   Bare `async` means re-implementing — and likely re-breaking — ~20 lines the
   maintainer already got right. **[VERIFIED gems exist + adopted; exact internal
   API names MED]**

3. **There is no dry-rb config *persistence* gem.** `dry-configurable` is an
   in-process settings mixin with no file backing. The idiomatic stack is
   `dry-validation` (validate the loaded hash) + `dry-struct`/`dry-types` (model) +
   **a hand-rolled emitter you own** for write-back. Plan for ~1 small module of
   "serialize config struct → file", not a gem. **[VERIFIED]**

4. **OPEN DECISION — do we even need a long-running daemon, and if so, how does the
   CLI talk to it?** `mr`, `gita`, `ghq` all manage many repos with *no daemon* —
   config file is the contract, work runs on demand. A daemon is only justified by
   (a) FS-watch auto-sync, (b) expensive cached status, or (c) synchronous liveness
   queries. The user's stated goal ("evergreen copies refreshed ≤6h so `space` can
   local-clone fast") is satisfiable by a **periodic launchd job**, not necessarily a
   resident socket server. This is the one genuine fork in the road. See
   [§7 Open questions](#7-open-questions--what-to-decide-before-building).

Everything else (dry-cli nested subcommands, the `xdg` gem, git porcelain mechanics,
`gh repo list`, the LaunchAgent plist, mise-under-launchd) is a clean, verified fit.

---

## Brief (restated)

**Question.** How do we build `repo-tender` — a macOS, Ruby 4.0.5 daemon + CLI that
keeps *evergreen* local copies of git repos (clean tree · on the remote's default
branch · fetched within 6h) — using the socketry/async + dry-rb stacks, wrapping the
`git`/`gh` CLIs, XDG-compliant, repos laid out at `$BASE/:host/:user/:repo`
(default `$HOME/src/evergreen/`), with org-wide tracking via `gh`.

**Decision it informs.** Concrete library + API + command choices and the daemon
architecture, feeding the build loop.

**"Answered" =** per subsystem, the specific gem + version + idiomatic API as of
mid-2026, with primary citations, pitfalls flagged, and trade-offs surfaced (not
silently resolved).

**Verification key:** **[VERIFIED]** = ≥2 independent sources, one a primary I fetched
this session · **[MED]** = single credible primary, plausible, not independently
cross-checked · **[SUSPICIOUS]** = contradicted by a check · all gem versions below
were re-checked against `rubygems.org/api` on 2026-06-12.

---

## 1. Async subprocess execution — the flagged unknown

**Claim:** On `async ≥ 2.24`, running `git`/`gh` via stdlib `Open3.capture3` /
`IO.popen` *inside* an `Async`/`Sync` block is fully non-blocking — no helper gem,
no thread. Ruby's `Process.wait2` invokes `Fiber::Scheduler#process_wait`, which
`async`'s scheduler delegates to `IO::Event::Selector`; on macOS that's the KQueue
selector using `EVFILT_PROC | NOTE_EXIT` for the wait and `EVFILT_READ` for the pipe.
**[VERIFIED — async 2.39.0, io-event 1.16.2 confirmed on RubyGems; mechanism read
from `async/lib/async/scheduler.rb` + `io-event` kqueue.c by the lane]**

- **Implication:** Our git/gh client wraps `Open3.capture3([...])` directly. We get
  stdout **and** stderr **and** exit status (the three things `Async::Process.capture`
  drops), with one fewer dependency. The "spawn a thread per shell-out so the reactor
  doesn't block" advice from pre-2024 blogs is obsolete and would add GVL contention.
- **`async-process` status:** real, v1.4.0, **last pushed 2024-11-08** (~19mo stale),
  194k downloads. Its README still references `nio4r` (no longer in the stack). Not
  broken, but strictly worse than the scheduler hook. **Don't adopt.** **[VERIFIED]**
- **macOS caveat:** kqueue has a known `EINVAL` issue with **TTYs/ptys** (async #301).
  Irrelevant for `git`/`gh` whose stdout is a plain pipe — but means *don't* allocate a
  pty for these subprocesses.
- **What would change this:** if we needed to drive an *interactive* child (pty), the
  plain-pipe fast path wouldn't apply. We don't — `git`/`gh` are batch with `--json`/
  porcelain output.

## 2. Concurrency + daemon structure under async

**Claim:** The idiomatic "fan out M repos, sync at most K concurrently, collect all"
is **`Async::Barrier` + `Async::Semaphore`, with the semaphore constructed as a child
of the barrier** (`Async::Semaphore.new(K, parent: barrier)`), so block-exit/cancel
drains in-flight tasks. **There is no `Async::WaitGroup`** (the prompt guessed wrong);
`Async::Waiter` is deprecated in favour of `Async::Barrier`. **[VERIFIED pattern is in
two official guides; MED on the deprecation line]**

**Claim:** Core `async` traps no signals and has no crash-restart supervisor — both
live in **`async-container`** (`Async::Container::Controller`), whose v0.35.1 release
notes literally call out fixing "restart indefinitely on interrupt." The maintained
production shape is `async-service` (0.24.1, **1.25M downloads** — well-adopted) →
`async-container` → your `Async` app block. **[VERIFIED: async-container 0.35.1,
async-service 0.24.1 exist + adopted; exact internal method names (`with_signal_handlers`,
`Async::Loop`, `Task#cancel` rename in v2.38) are MED — single-source from a repo clone
I could not re-read; confirm in PHASE 0]**

- **Implication:** The daemon's outermost frame is a `Async::Container::Controller`
  subclass (or `async-service` Service), **not** a hand-rolled `Sync { trap … }`. This
  gives correct SIGTERM-drain / SIGHUP-reload / double-SIGINT-force-kill for free, plus
  systemd-style `Type=notify` readiness (not needed under launchd, but harmless).
- **Periodic sweep:** `Async::Loop.periodic(interval: 21_600)` (6h) is claimed built-in
  since async v2.37 and swallows+logs block exceptions so a crashed sweep doesn't kill
  the loop. **[MED — confirm `Async::Loop` exists at our pinned version; fallback is the
  documented `loop { work; task.sleep(interval) }`, which is rock-solid and version-proof]**
- **Dedicated scheduler gems are not ready:** `async-cron` 0.1.0 (880 downloads,
  abandoned stub), `async-background` 0.7.1 (~3.9k downloads, single maintainer). **Do
  not make either load-bearing.** **[VERIFIED via RubyGems]**
- **What would change this:** if we go the "periodic launchd job, no resident process"
  route (§7), most of this section evaporates — no supervisor, no in-process scheduler,
  no signal handling. That's the main reason §7 must be decided first.

## 3. dry-rb stack — CLI, config, validation

| Concern | Verdict | Version (verified 2026-06-12) |
|---|---|---|
| CLI w/ nested subcommands | **dry-cli, clean fit.** Arbitrary-depth nesting via block `register`. | `dry-cli 1.4.1` |
| Config *persistence* | **No dry gem does this.** Hand-roll the write-back. | `dry-configurable 1.4.0` (in-process only) |
| Validate loaded config | `Dry::Validation::Contract` (`params`/`json` schema) | `dry-validation 1.11.1`, `dry-schema 1.16.0` |
| In-memory model | `dry-struct` + `dry-types` | `dry-struct 1.8.1`, `dry-types 1.9.1` |
| Command outcomes | `Dry::Monads::Result` (`Success`/`Failure`) + `Do` notation | `dry-monads 1.10.0` |
| XDG paths | **`xdg` gem (bkuhlmann), well-maintained**, covers config/data/state/cache/runtime | `xdg 10.2.0` (pushed 2026-06-07) |

All versions **[VERIFIED]** against RubyGems. dry-cli unlimited nesting **[VERIFIED via
changelog #149]**.

- **Implication (the one gap):** CRUD commands (`repo add/remove`, `org add`) follow:
  load file → parse (YAML/JSON/TOML) → `dry-validation` contract → mutate `dry-struct`
  → **our own emitter** writes it back. Budget a small `Config::Store` module for the
  round-trip; don't shop for a gem.
- **Note:** anything named `dry-*` is **not** automatically official dry-rb (e.g.
  `dry-config` by alienfast is unrelated/stale). Pin to the dry-rb org's gems.

## 4. Config file format — round-trip & comments

**Claim:** Only **one** Ruby TOML gem preserves comments on rewrite, and it's
immature; everything else silently drops comments. **[VERIFIED with correction]**

- **Correction to the lane:** the "standout" comment-preserving gem is published as
  **`philiprehberger-toml_kit` v0.4.0** (not `toml_kit` — that name 404s on RubyGems),
  single-author, early. **Do not bet the design on it.** **[VERIFIED via RubyGems search]**
- YAML (Psych): comments **lost** on dump. JSON: no comments to lose. `toml-rb 4.2.0` /
  `tomlrb 2.0.4` / `tomlib 0.7.3`: comments **lost**. **[VERIFIED versions]**
- **Implication for format choice:** If a human-editable, comment-bearing config that
  survives machine rewrites matters → the honest options are *(a)* TOML + accept that no
  mature gem round-trips comments, *(b)* YAML + accept comment loss, or *(c)* **split
  the file**: keep human-authored intent the user rarely needs us to rewrite, and write
  machine-managed lists (e.g. org-discovered repos) to a *separate* state file we own
  outright (see §6). Option (c) sidesteps the comment problem entirely and is my
  recommendation to raise in the PRD. **What would change this:** if the user is fine
  editing JSON and never wants comments, JSON removes the whole question.

## 5. git + gh evergreen mechanics

All **[VERIFIED]** against git-scm docs / `gh` manual; the `gh` JSON shape and the
"default branch isn't `main`" point were live-checked (`gh repo list cli` → default
branch `trunk`).

- **Clean detection:** `git status --porcelain=v2 --branch`. Clean = zero lines
  starting `1`/`2`/`u`/`?`. v2 (not v1) because v2 encodes submodule state in the
  `<sub>` field and gives machine-stable `# branch.*` headers.
  - **Gotcha that changes design:** `--untracked-files` **defaults to `all`**, which
    recurses into untracked dirs (`node_modules/`, `.venv/`) → O(repo size) per check.
    For a scan across many repos, pass `--untracked-files=normal` explicitly. (And never
    `=no`, which hides a dirty root.) **[VERIFIED]**
- **Default branch:** prefer local, network-free `git symbolic-ref --short
  refs/remotes/origin/HEAD`; if missing/stale, `git remote set-head origin -a` (network)
  or one-shot `git ls-remote --symref origin HEAD`.
  - **Gotcha:** `origin/HEAD` is set only at **clone** time; a plain `git fetch` does
    *not* update it. If upstream changes its default branch post-clone, the local ref
    goes stale silently. Our tender loop must periodically `set-head -a`. **[VERIFIED]**
- **Staleness (≤6h):** mtime of `.git/FETCH_HEAD` (`stat -f %m` on macOS) — written on
  every fetch even when nothing changes. It's a hint, not a contract (backups can touch
  it). Ahead/behind without network: `git rev-list --left-right --count
  main...origin/main` → `0\t0` when current. **[VERIFIED mechanism; MED that FETCH_HEAD
  mtime is "blessed" — it isn't documented as API]**
- **Safe update (clean + on default):** `git fetch --prune --no-tags origin` then
  `git merge --ff-only origin/<default>`. **Never auto `git reset --hard`** — it
  silently destroys local commits. If `--ff-only` fails (diverged), surface it; don't
  auto-resolve. **[VERIFIED — this is the single biggest foot-gun]**
- **gh org enumeration:** `gh repo list <org> --limit 1000 --no-archived --source --json
  nameWithOwner,sshUrl,defaultBranchRef,pushedAt,isArchived,isFork`. `defaultBranchRef`
  is an object → read `.defaultBranchRef.name`. Per-page cap 1000; use `--paginate` (or
  `gh api graphql --paginate`) beyond that. Auth via `gh auth`; **5000 req/hr**
  authenticated vs **60/hr** unauthenticated — and there's a known macOS-Keychain
  silent-fail where `gh` drops to unauthenticated without erroring. Call `gh auth status`
  before bulk ops. **[VERIFIED fields live; MED on the Keychain bug — single issue]**

## 6. State vs config separation (XDG)

**Claim:** XDG 0.8 defines `CONFIG_HOME` (intent), `DATA_HOME`, `STATE_HOME` (persists
across restarts but not precious), `RUNTIME_DIR` (sockets/pipes, mode 0700). macOS does
**not** set `XDG_RUNTIME_DIR` by default. **[VERIFIED via freedesktop spec]**

- **Recommended split (raise in PRD):**
  - `$XDG_CONFIG_HOME/repo-tender/config.{toml,yaml,json}` — durable user intent:
    base dir, tracked repos, tracked orgs, refresh interval.
  - `$XDG_STATE_HOME/repo-tender/` — last-sync timestamps, per-repo status cache, logs
    (launchd does **not** rotate logs — §8 — so we own rotation here).
  - Socket (if any — §7) in `$XDG_RUNTIME_DIR/repo-tender/` if set, else
    `$XDG_STATE_HOME/repo-tender/` with a 0700 parent dir.
- This split also resolves the §4 comment problem: org-discovered repo lists are *state*
  (we rewrite them constantly), so they don't belong in the human-edited config file.

## 7. Daemon architecture + CLI↔daemon link — **the open decision**

This is the one place the research surfaces a real fork rather than a verified answer.

- **Precedent [VERIFIED]:** `mr` (Perl), `gita` (Python), `ghq` (Go) all manage many
  repos with **no daemon** — the config file (or directory layout) is the contract;
  work runs synchronously on invocation. Only `libvirt` in the comparison set runs a
  resident socket daemon (and uses two sockets: data + admin).
- **The principle [VERIFIED]:** a daemon is justified *only* by (a) FS-watch-driven
  auto-sync, (b) expensive cached status the CLI can't cheaply recompute, or (c)
  synchronous liveness queries. For "keep evergreen copies fresh ≤6h," none of these is
  obviously required — a **periodic launchd job** that wakes, syncs, and exits meets the
  spec and deletes the entire IPC question.
- **Three CLI↔daemon options if we *do* run resident** (increasing capability/complexity):
  1. **Config-watch** — CLI rewrites config; daemon watches via the `listen` gem
     (FSEvents on macOS). Push-only; CLI can't get a synchronous answer; `listen` has a
     long-standing macOS performance caveat (#342). **[MED]**
  2. **SIGHUP reload** — CLI runs `launchctl kill SIGHUP gui/$UID/<label>`; daemon
     traps HUP and re-reads config. One `trap`. Push-only. **[VERIFIED mechanism]**
  3. **UNIX socket** — daemon serves a line/JSON protocol; CLI connects for synchronous
     status/commands. Current socketry API is **`io-endpoint` v0.17.2**
     (`IO::Endpoint::UNIXEndpoint`); `async-io`'s old endpoint is **deprecated**. It
     already handles `flock` exclusivity + long-path symlinking. `falcon` (HTTP over the
     socket) is overkill unless we later want a web UI. **[VERIFIED io-endpoint 0.17.2]**
- **Recommendation to put to the user:** start with the **periodic launchd job + CLI
  that reads/writes config and queries `launchctl` for status** (options-0/2 territory),
  and add a resident socket **only** if a concrete need for synchronous status or
  sub-6h on-demand sync appears. This is the smallest thing that satisfies the stated
  goal and keeps the socketry investment (it still runs the sync sweep under `async`
  for concurrent git/gh fan-out).
- **Hard constraint [VERIFIED]:** whatever shape, **do not self-daemonize / double-fork**
  under launchd — launchd is the supervisor (Apple TN2083, "a launchd daemon must not
  daemonize itself"). No PID file needed; ask launchd by label.

## 8. macOS LaunchAgent + mise

All **[VERIFIED]** against launchd.info, `launchd.plist(5)`, `launchctl(1)`, mise docs.

- **Plist (§8a — DECIDED: periodic job):** `~/Library/LaunchAgents/<label>.plist`.
  For a periodic sync that runs every 6h and at login, then exits:
  `StartInterval=21600` + `RunAtLoad=true` + `ProcessType=Background` +
  `StandardOutPath`/`StandardErrorPath`. **Use `StartInterval`, NOT `KeepAlive`** —
  `KeepAlive` would restart the process the instant it exits (a busy-loop for a job
  meant to run and quit). `RunAtLoad` makes it sync once at login; `StartInterval`
  handles the 6h cadence thereafter. (`StartCalendarInterval` is the alternative if the
  user later wants wall-clock-aligned times instead of "every 6h since load.")
  *Resident-daemon alternative (not chosen):* `KeepAlive={SuccessfulExit:false,
  Crashed:true}` + `ThrottleInterval`. **No shell expansion** in the plist — the CLI
  must resolve `$HOME`/`~` to absolute paths at install time.
- **The mise/Ruby-under-launchd problem [VERIFIED, design-critical]:** launchd gives a
  minimal env. **`mise activate` is documented-broken in non-interactive contexts** —
  it relies on a prompt hook that never fires. Use **`mise exec -- ruby /abs/daemon.rb`**
  in `ProgramArguments` (or a full shim path `~/.local/share/mise/shims/ruby` + set
  `WorkingDirectory` to the project root so shims resolve the right `mise.toml`). Pin the
  config explicitly with `MISE_CONFIG_FILE` in `EnvironmentVariables` to avoid picking up
  the wrong `mise.toml` by CWD.
- **launchctl control (modern, NOT `load`/`unload`):** install =
  `launchctl bootstrap gui/$UID <plist>`; remove = `launchctl bootout gui/$UID/<label>`;
  restart = `launchctl kickstart -k gui/$UID/<label>`; status = `launchctl print
  gui/$UID/<label>` (human) or parse `launchctl list` columns (PID, last-exit, label).
  These are exactly the verbs the CLI's `daemon start/stop/restart/status` shells out to.
- **Logging [VERIFIED]:** launchd **never rotates** StandardOut/Err logs (they append
  forever) and external rotation can break the redirect fd. **The daemon must rotate its
  own logs** (or write timestamped files), under `$XDG_STATE_HOME/repo-tender/`.

---

## Disputes & corrections surfaced (not silently resolved)

- **`KeepAlive` breaks on daemon-initiated SIGTERM** — claimed by lanes 02/05 citing
  "openclaw/openclaw" issues. **[SUSPICIOUS]** The `openclaw/openclaw` repo is real but
  is a *game engine* (Captain Claw reimplementation); the cited issue numbers/topics
  don't match — these citations are **hallucinated**. The *adjacent* principle (don't
  self-daemonize; prefer in-process SIGHUP reload over self-kill) is independently sound
  via Apple TN2083 **[VERIFIED]**. Net: trust the principle, discard the "openclaw"
  evidence.
- **`async-process` "recommended for subprocesses"** (old blogs) vs **"use plain Open3"**
  (current source) — resolved by reading the scheduler source: current stack favours
  plain Open3. Reported in §1.
- **Periodic via core `Async::Loop` vs a gem** — docs say core; the (tiny, unadopted)
  `async-cron`/`async-background` gems disagree by existing. We side with core/`loop`.

## Load-bearing claims — verification ledger

| Claim | Status | Independent check |
|---|---|---|
| `Open3.capture3` non-blocking under Async | VERIFIED | async 2.39.0 + io-event 1.16.2 on RubyGems; scheduler `process_wait` mechanism |
| `async-process` stale (v1.4.0, 2024-11) | VERIFIED | RubyGems + GitHub pushed-at |
| dry gem versions (cli/schema/validation/monads/types/struct/configurable) | VERIFIED | RubyGems API, all 6 matched the lane exactly |
| `xdg` 10.2.0 maintained | VERIFIED | RubyGems + repo pushed 2026-06-07 |
| `io-endpoint` 0.17.2 current; async-io deprecated | VERIFIED | RubyGems |
| `gh repo list --json` fields + default-branch-≠-main | VERIFIED | live `gh repo list cli` → `trunk` |
| git porcelain-v2 / ff-only / origin-HEAD-only-at-clone | VERIFIED | git-scm docs |
| launchd plist keys + `mise activate` non-interactive failure | VERIFIED | launchd.plist(5), mise troubleshooting |
| Apple "must not daemonize under launchd" | VERIFIED | TN2083 fetched |
| `toml_kit` comment preservation | CORRECTED | real gem is `philiprehberger-toml_kit` v0.4.0, immature |
| "KeepAlive breaks on SIGTERM" (openclaw) | SUSPICIOUS | openclaw is a game; citations hallucinated |
| Exact async internal API names (`Async::Loop`, `Task#cancel` rename, `with_signal_handlers`) | MED | single-source from repo clone; confirm in PHASE 0 |

---

## 7. Open questions — what to decide before building

1. **Resident daemon vs periodic launchd job?** (§7) — *the* architectural fork.
   Recommendation: periodic job first; add a socket only on demonstrated need.
   *Resolves by:* user preference on whether sub-6h on-demand sync / live status from
   the CLI is a day-one requirement.
2. **Config file format?** (§4) — TOML (no mature comment round-trip), YAML (comment
   loss), or JSON (no comments). Recommendation: split human-config from machine-state
   (§6) so the question stops mattering, then pick whatever the user likes to hand-edit.
3. **One config file or config+state split?** (§6) — recommend split; confirm.
4. **Pin exact async API surface** — before relying on `Async::Loop`/`async-container`
   `Controller`, confirm method names at the pinned versions in PHASE 0 (the build
   loop's first challenge). Fallback idioms (`loop{ sleep }`, manual `Signal.trap`) are
   version-proof if the sugar isn't there.

---

## Citations (dated, tier-labelled)

**Primary**
- socketry/async — RubyGems `async` 2.39.0; scheduler/process_wait source [primary, 2026-04]
- socketry/io-event 1.16.2; kqueue selector source [primary, 2026-06]
- socketry/async-container 0.35.1, async-service 0.24.1 [primary, 2026]
- socketry/io-endpoint 0.17.2; async-io deprecation notice [primary, 2026-01]
- dry-rb: dry-cli 1.4.1, dry-configurable 1.4.0, dry-schema 1.16.0, dry-validation
  1.11.1, dry-monads 1.10.0, dry-types 1.9.1, dry-struct 1.8.1 — RubyGems + dry-rb.org
  [primary, 2026]
- bkuhlmann `xdg` 10.2.0 — RubyGems / alchemists.io [primary, 2026-06]
- git-scm.com — git-status (porcelain v2), git-remote, git-fetch/merge/rev-list [primary]
- cli.github.com — `gh repo list` manual; live `gh repo list cli` [primary, 2026-06]
- Apple TN2083 "Daemons and Agents"; launchd.plist(5); launchctl(1) [primary]
- mise-en-place troubleshooting + shims docs (mise.jdx.dev) [primary, 2026]
- freedesktop XDG Base Directory Spec 0.8 [primary]

**Secondary / corroborating**
- launchd.info tutorial; ss64 launchctl; keith.github.io xcode-man-pages [secondary]
- gita design doc; ghq / myrepos READMEs; libvirt daemons doc [secondary]

**Discarded**
- "openclaw/openclaw" launchd-SIGTERM issues — hallucinated; repo is a game engine
- `guard/listen` macOS perf caveat — real but only relevant if we choose config-watch

---

*Raw lane findings: `.architect/research/{01a,01b,02,03,04,05}-*.md` (gitignored-worthy).
Lane 01 was bisected into 01a (subprocess exec) + 01b (daemon structure) after the
combined lane died of context exhaustion 3× — a doc-heavy-lane failure mode.*
