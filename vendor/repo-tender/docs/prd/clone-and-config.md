# PRD — slice `clone-and-config`

> One bug + three feature touches batched into one slice, two disjoint lanes.
> Authority order (per AGENTS.md): `AGENTS.md` → `docs/prd/repo-tender.md` →
> this PRD → `docs/gates/clone-and-config.md`. Where this PRD restates the
> base PRD it does not override it; the cardinal no-data-loss invariant
> (base PRD §1) governs both lanes.

## Motivation

Four user-reported items from 2026-06-15:

1. **(bug)** The config writer emits Ruby-symbol-keyed YAML — `:base_dir: …`,
   `:host: github.com` — which is valid YAML but reads as machine droppings to
   a human editing `config.yaml`. We want normal-looking YAML.
2. **(feature)** Orgs sometimes contain a few truly enormous repos that should
   never be cloned by the evergreen sweep. We need a per-org `ignored_repos`
   exclusion list.
3. **(feature)** `org add` should accept the exclusion list on the CLI.
   (`--include-archived` / `--include-forks` already exist and already work —
   verified in `lib/repo_tender/cli/org.rb` + `lib/repo_tender/forge/github.rb`;
   the only missing piece is `--ignored-repos`.)
4. **(feature)** A `clone` command that uses macOS `cp -Rc` (APFS
   copy-on-write / clonefile) to make a near-instant copy of an evergreen repo
   into a working directory.

### Verified findings (architect, 2026-06-15, against HEAD `31bb69c`)

- **The symbol-key bug is config-only.** `Config::Store.emit`
  (`lib/repo_tender/config/store.rb:83`) builds a symbol-keyed `ordered` hash
  and `YAML.dump`s it; the nested `repos`/`orgs` arrays come from
  `config.to_h` (dry-struct, deep **symbol** keys). The **state store is already
  clean** — `State::Store#to_h_compact` returns **string**-keyed hashes and the
  top-level keys are strings (`"repos"`/`"orgs"`), so `state.yaml` does not have
  this bug. The user's "possibly the state file" is answered: **no, only
  config.yaml.** State store is OUT OF SCOPE.
- `dry-cli` supports `option :x, type: :array` (comma-separated `--x a,b` or
  repeated `--x a --x b`) and a variadic `argument :names, type: :array`
  (captures all trailing positionals) — both verified in the evergreen
  `dry-cli/lib/dry/cli/option.rb` + `parser.rb`. Both lanes' CLI shapes are
  buildable on the installed dry-cli.

## Decisions (locked by the human, 2026-06-15)

- **`clone` shape:** variadic, parent-dir-via-flag.
  `repo-tender clone NAME... [--into DIR]`. `NAME` is a repo name resolved
  against `base_dir`; `--into` is the destination **parent** directory
  (default `.`); each repo lands at `<into>/<name>`. Multi-repo is native.
- **Emitted YAML shape:** omit empty/default fields. Drop the default
  `host: github.com` (already the base-PRD §3.1 intent — host omitted when the
  user means github.com), drop `include_archived`/`include_forks` when `false`,
  drop `ignored_repos` when empty. All keys are bare strings (no `:` prefix).

## §1 — Config YAML emit (Lane A, item 1)

`Config::Store.emit` must produce human-clean YAML:

- **String keys, no symbol prefixes.** No line may begin with `:` and no key
  may render as `:name:`.
- **Omit default/empty fields** so a minimal config reads minimally:
  - top level: `base_dir`, `refresh_interval`, `concurrency` always present;
    `repos`/`orgs` omitted when empty (already the case).
  - each repo entry: omit `host` when it equals `Config::DEFAULT_HOST`
    (`"github.com"`); always emit `owner`, `name`.
  - each org entry: omit `host` when default; always emit `name`; omit
    `include_archived` when `false`; omit `include_forks` when `false`; omit
    `ignored_repos` when empty.
- **Round-trip must stay lossless at the struct level.** `Config::Store.load`
  re-applies struct defaults (host → `"github.com"`, flags → `false`,
  `ignored_repos` → `[]`), so dropping defaults on write and reloading must
  reproduce an equal `Config` struct. This is the config-side expression of the
  cardinal no-data-loss invariant: trimming the *serialization* must never
  change the *loaded value*.
- Stable key order is retained for diff-ability (base_dir, refresh_interval,
  concurrency, repos, orgs; within an entry: host?, owner/name, then flags).

Implementation note (non-binding): a small recursive `stringify` mirroring the
existing `symbolize` plus per-entry compaction is the natural shape. Do not
reach for a YAML-rewriting gem — the hand-rolled emitter is the documented
design (AGENTS.md gotcha: "no dry-rb config persistence gem").

## §2 — `ignored_repos` on org config (Lane A, item 2)

- `Config::OrgRef` gains `ignored_repos : Types::Array.of(Types::String)`
  defaulting to `[].freeze`, alongside the existing `include_archived` /
  `include_forks`.
- `Config::Contract` org schema gains
  `optional(:ignored_repos).array(:string)` — a non-array or non-string element
  must produce a field-level `Failure` (consistent with the existing org-entry
  validation contract, base gate G2).
- **The filter is authoritative in `Forge::GitHub#parse_repos`**, matching the
  existing pattern where `include_forks`/`include_archived` are enforced in the
  parser regardless of the advisory CLI flag. A repo row is excluded when its
  bare repo `name` **or** its full `nameWithOwner` appears in
  `org_ref.ignored_repos`. (Bare name is the natural thing a user types;
  `owner/name` is accepted as a convenience for exactness.)

## §3 — `org add --ignored-repos` (Lane A, item 3)

- Add `option :ignored_repos, type: :array, default: []` to
  `CLI::Org::Add`, threaded through `Org::Helpers.parse_ref` into the
  constructed `OrgRef`.
- `org list` (and the `add` success/already-tracked lines) should surface the
  ignored list when non-empty, in the same human/quiet/json-respecting style as
  the existing flag echoes.
- **Idempotency is unchanged:** `add` still matches on `(host, name)` only and
  short-circuits with "already tracked" if present (it does **not** mutate the
  flags/ignored list of an existing org). Changing an existing org's options is
  remove-then-re-add. This keeps the slice tight and the existing org tests
  green; the builder may raise this as a PHASE 0 disagreement and the architect
  will rule.

## §4 — `clone` command (Lane B, item 4)

`repo-tender clone NAME... [--into DIR]` — macOS COW copy of evergreen repos.

- **Resolution** (against `config.base_dir`, layout `$BASE/host/owner/name`):
  - bare `name` → match `$BASE/*/*/name`; **exactly one** match required.
  - `owner/name` → match `$BASE/*/owner/name`.
  - `host/owner/name` → exact `$BASE/host/owner/name`.
  - zero matches → `Failure` ("not found under base_dir …"), nothing copied.
  - multiple matches for a bare/owner-qualified name → `Failure` that **lists
    the candidates** and tells the user to qualify; nothing copied.
- **Destination:** parent dir = `--into` (default `"."`); final path =
  `File.join(into, name)` where `name` is the repo's leaf directory name.
- **Copy mechanism:** macOS `cp -Rc <src> <dest>` through `Shell.run` (the
  Result boundary; AGENTS.md: subprocesses go through `Open3.capture3` via
  `Shell`). `-c` is the clonefile/COW flag — macOS-only, consistent with the
  project's macOS-only constraint.
- **No-clobber (no-data-loss):** if the final dest already exists, return
  `Failure` and do **not** modify or overwrite it. This is the cardinal
  invariant applied to the copy target — `clone` never destroys an existing
  directory.
- **Multiple names:** each is resolved+copied independently; a per-name failure
  is reported and does not abort the others (engine-style isolation). Exit code
  is `1` if **any** name failed, else `0`.
- **Boundary shape:** a small tested `RepoTender::Cloner` boundary owns
  resolution + copy and returns `Result`; tested with **real temp dirs** (no
  mocks, per AGENTS.md). `CLI::Clone` is the thin argv→Cloner→Outcome
  translation layer and honors the shared `GlobalOptions` output modes.

## Out of scope (both lanes)

- State-store YAML (already clean — verified above).
- Making `org add` update an already-tracked org's options in place (§3).
- Non-macOS / non-APFS fallback for `cp -Rc` (project is macOS-only).
- Any change to the sync engine's behavior, the dedupe, or git mutation paths.
- README / user docs — the **architect** updates docs at integration so the two
  lanes stay file-disjoint (no README merge conflict).
