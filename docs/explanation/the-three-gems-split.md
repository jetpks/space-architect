# The three-gems split 🪑

Where `space`, `src`, and `architect` came from, why they no longer ship in
one gem, and who owns what. (The mechanical upgrade steps are in
[how-to: upgrade from the 8.x monolith](../how-to/upgrade-from-the-8x-monolith.md).)

## The monolith (≤ 8.x)

Through 8.x, `space-architect` shipped everything under one roof: the
`space`, `architect`, and `src` executables, plus **vendored** `Space::Core`
and `Space::Src` subtrees inside the gem itself. Three unrelated audiences —
people managing spaces, people tending evergreen checkouts, people running
the Architect Loop — installed one gem to get any of it, and every release of
one surface dragged the other two along.

## The 9.0.0 split

The 9.0.0 release (October 2026) carved the tools into their own gems and
made this gem consume them as libraries instead of vendoring them:

| Gem | Binary(s) | Library | Owns |
|-----|-----------|---------|------|
| **space-cadet** | `space` | `Space::Core` | the spaces substrate: config, state, XDG, the space store, copy-on-write provisioning, OCI pack/build/run |
| **repo-tender** | `repo-tender` (with the deprecated `src` shim) | `RepoTender` | evergreen clone tending; the launchd agent `architect sessions agent` drives |
| **space-architect** | `architect` | `Space::Architect` | the loop only: project state, the builder harness, dispatch, the research supervisor |

Dropped from this gem: the vendored `lib/space_core` / `lib/space_src`
subtrees, the `exe/space` and `exe/src` binaries, and the `architect space …`
/ `architect src …` forwarder intercepts — those invocations are ordinary
unknown commands now. This is accurate history, not a claim you can still
forward: don't reach for `architect space new`; call `space new`.

## Why split

- **Independent release cadence.** The substrate (spaces, provisioning) and
  the evergreen engine change on their own schedules; the loop's iterations
  shouldn't gate on either.
- **Honest dependencies.** space-architect hard-depends on space-cadet
  (`~> 9.1` — the loop's help header brands itself through the substrate's
  product-name seam) but only *softly* touches repo-tender: the session-sync
  launchd rail is the sole consumer, so repo-tender is deliberately absent
  from the gemspec and required lazily — without it, the sessions commands
  print a short error naming `gem install repo-tender` and everything else
  works.
- **One binary per concern.** Each gem's CLI documents and tests its own
  surface; the loop's reference doesn't have to explain `space pack` to
  someone who only wants evergreen checkouts.

## What moved with it

- **Config and state identity.** The substrate's config/state moved from the
  `space-architect` app dirs to `space-cadet` ones
  (`~/.config/space-cadet/config.yml`, state home likewise).
  space-cadet 9.1+ migrates the old files automatically on first run of
  `space` or `architect`; on 9.0.0 you move them by hand. The loop's own
  session-sync cursor stays under `space-architect`.
- **Own version line.** `Space::Architect::VERSION` is decoupled from
  `Space::Core::VERSION` — the gemspec, `architect version`, and the
  bug-report diagnostics derive from the loop's own constant.
- **Tests and mutation subjects.** The vendored tools' tests dropped with the
  code (their coverage lives in the two gems); the loop's suite runs against
  the gem-served `Space::Core`, and mutation testing subjects
  `GateEvaluator` and `GateLint` only.
