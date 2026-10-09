# Command Reference 📖

Every `architect` command, flag, and behavior, derived from the shipped
binary's own `--help` output (space-architect 9.0.0). The gem installs one
executable — `architect` — running the Architect Loop inside space-cadet's
task-scoped workspaces. The space surface is the **space-cadet** gem's `space`
binary; the evergreen surface is the **repo-tender** gem's `repo-tender`
binary (with the deprecated `src` shim) — see those gems for their references.

## Pages

| Page | Covers |
|------|--------|
| [Spec-phase commands](spec.md) | `new`, `section`, `rehearse`, `freeze`, `brief new` |
| [Build-phase commands](build.md) | `provision`, `dispatch`, `worktree add/list/remove` |
| [Judge-phase commands](judge.md) | `verify`, `evidence`, `gate`, `verdict` |
| [Land-phase commands](land.md) | `integrate`, `merge` |
| [Project commands](project.md) | `init`, `ground`, `status`, `sync`, `install-skills`, `bug-report` |
| [Subcommand groups](groups.md) | `variant`, `research`, `jobs`, `sessions` |
| [Gates and lanes block format](gates-and-lanes.md) | the fenced ```gates / ```lanes YAML blocks |
| [Space and project state](space-and-project-state.md) | `space.yaml` project block, `architecture/` file anatomy, XDG paths |

`architect help` (or bare `architect`, `architect --help`) lists everything
grouped by loop phase — **Spec · Build · Judge · Land · Project · Groups**, in
canonical order — and, inside an architect space, ends with a compact
loop-status block (project status + current iteration).

## Global options 🎨

These work on any command:

| Option | Values | Default | Description |
|--------|--------|---------|-------------|
| `--color` | `auto` `always` `never` | `auto` | Color output. `--colors` is accepted too. |

Color defaults to auto-detection: colorized when stdout is a TTY, plain
otherwise. Paths under your home directory display as `~/…` in
human-oriented output.

## Space resolution 🧭

Commands that take an optional `[SPACE]` argument resolve it in this order:

1. An explicit id or slug passed on the command line.
2. Otherwise, the nearest parent directory of `$PWD` containing a `space.yaml`.

Being *inside* a space is what makes it current — `space use` (the space-cadet
binary) records recent state and prints a path, but it never overrides
`$PWD`-based resolution.

## Exit codes 🚦

The CLI exits non-zero on failure — unknown space, ambiguous id, refusing to
overwrite without `--force`, a failed gate, and so on — with a clear message on
stderr. Specifics the code defines:

| Situation | Exit code |
|-----------|-----------|
| Success | `0` |
| `gate` with at least one failing gate | `1` |
| Any error surfaced as `ERROR: …` (Space::Core::Error) | non-zero |
| Interrupt (`SIGINT`/`Interrupt`) | `130` |
| A builder that hit its wall-clock `--timeout` | `124` (the builder's exit status; the dispatch itself reports it) |
