# Upgrade from the 8.x monolith ⬆️

You are on `space-architect` 8.x (or earlier), which shipped three binaries —
`space`, `architect`, and `src` — plus vendored `Space::Core`/`Space::Src`
subtrees. Since 9.0.0 the tools live in their own gems, and you want your
scripts and muscle memory to keep working.

## 1. Uninstall the 8.x gem first

```sh
gem uninstall space-architect
```

Uninstall **before** installing the new gems: the 8.x gem's `space` and `src`
executables collide with the ones the new gems ship.

## 2. Install the split gems

```sh
gem install space-architect          # the Architect Loop — pulls in space-cadet
gem install repo-tender              # optional: evergreen tending + the session-sync rail
```

What you now have:

| Binary | Ships from | Covers |
|--------|------------|--------|
| `architect` | space-architect | the loop only |
| `space` | space-cadet | spaces, provisioning, OCI packing |
| `repo-tender` (with the deprecated `src` shim) | repo-tender | evergreen clone tending |

Cross-check the attribution: `space` is **not** part of space-architect
anymore, and `src` is **not** part of space-cadet.

## 3. Config and state migrate (or move by hand)

space-cadet 9.1+ migrates the substrate's config and state from the old
8.x locations automatically on the first run of either `space` or `architect`:

- `~/.config/space-architect/config.yml` → `~/.config/space-cadet/config.yml`
- the state file likewise, under your state home

On space-architect/space-cadet **9.0.0** there is no auto-migration — move
those two files across by hand. The loop's own session-sync cursor stays where
it is.

## 4. Re-point scripts and aliases

- `architect space …` and `architect src …` **forwarders are gone** — they are
  ordinary unknown commands now (usage text, non-zero exit). Call `space …`
  and `src …` (repo-tender) directly.
- The `space` binary covers everything the old forwarder did (`space new`,
  `space list`, `space repo`, `space pack|build|run`, `space config`, …) — run
  `space --help` to see its surface.
- If a script vendored assumptions about `lib/space_core` inside
  space-architect, depend on the **space-cadet** gem (`require "space_core"`)
  instead; space-architect 9.x vendors nothing.

## 5. Verify

```sh
architect version    # ≥ 9.0.0, and no longer tied to Space::Core::VERSION
space --help         # space-cadet's own surface
```
