# FROZEN GATES — slice `clone-and-config`

> Frozen 2026-06-15 by the architect, **before** dispatch. READ-ONLY for
> everyone including builders — any edit to this file (caught by
> `git diff docs/gates/`) is an automatic slice FAIL. Verdicts are measured by
> the architect re-running these exact commands in a fresh session. Gate-pass
> is necessary, not sufficient — the architect also reads the diff against the
> PRD intent.

Freeze baseline at `main` HEAD `31bb69c`: **408 runs / 1461 assertions /
0 failures / 0 errors / 0 skips**, `standardrb` exit 0, `bundle list` = **53**
gems.

All test-file gates use **one `bundle exec ruby -Itest <file>` per file** (never
`ruby a.rb b.rb …` — Ruby runs only the first and the rest become ARGV; standing
lesson in HANDOFF). Run from the repo root.

---

## Global (both lanes)

- **G0 — full suite.** `bundle exec rake test`
  → PASS iff `failures = 0, errors = 0, skips = 0` AND runs **> 408** (both
  lanes add tests; the count must strictly grow).
- **GL — lint.** `bundle exec standardrb` → PASS iff exit `0`.
- **GG — no new gems.** `bundle list | wc -l` → PASS iff `53` (everything
  needed — yaml, fileutils, dry-*, pastel, dry-cli — is already a dependency;
  neither lane may add a gem).

---

## Lane A — config / forge / org-cli

### GA1 — clean YAML emit (item 1, the bug)

Deterministic emitter check the architect runs directly (no test harness):

```
bundle exec ruby -Ilib -rrepo_tender -rrepo_tender/config/model -rrepo_tender/config/store -e '
include RepoTender::Config
c = Config.new(
  base_dir: "~/src/evergreen", refresh_interval: 21600, concurrency: 8,
  repos: [RepoRef.new(host: "github.com", owner: "ruby", name: "ruby")],
  orgs: [
    OrgRef.new(host: "github.com", name: "socketry", ignored_repos: ["async"], include_forks: true),
    OrgRef.new(host: "github.com", name: "plain")
  ])
print Store.emit(c.to_h)'
```

PASS iff the emitted text satisfies ALL of:

1. **No symbol keys.** No line begins with `:` — `grep -c '^[[:space:]]*:' <out>`
   is `0`. No `:base_dir:` / `:host:` / `:name:` anywhere.
2. **Default host dropped.** The string `github.com` does **not** appear
   anywhere in the output (both entries use the default host).
3. **Top-level present & bare:** lines `base_dir:`, `refresh_interval:`,
   `concurrency:`, `repos:`, `orgs:` all present with bare string keys.
4. **Repo entry:** contains `owner: ruby` and `name: ruby`; contains **no**
   `host:` line.
5. **`socketry` org entry:** has `name: socketry`, an `ignored_repos:` block
   listing `async`, `include_forks: true`; has **no** `host:` line and **no**
   `include_archived:` line (false ⇒ omitted).
6. **`plain` org entry:** renders as just `name: plain` (no `host:`, no
   `include_archived:`, no `include_forks:`, no `ignored_repos:` — all
   default/empty ⇒ omitted).

### GA2 — config round-trip is lossless (no-data-loss, config side)

`bundle exec ruby -Itest test/repo_tender/config/store_test.rb`
→ PASS iff `0 failures, 0 errors` AND the suite includes an assertion proving:
`Store.load(write(Store.load(yaml)))` reproduces an **equal Config struct**
(`.to_h == .to_h`) for a config whose org has a **non-empty `ignored_repos`**, a
**default host** (omitted on write, restored to `"github.com"` on load), and a
mix of `include_*` true/false — i.e. dropping defaults on write does not change
the loaded value.

### GA3 — `ignored_repos` filter is authoritative (item 2)

`bundle exec ruby -Itest test/repo_tender/forge/github_test.rb`
→ PASS iff `0 failures, 0 errors` AND the suite proves, against a recorded
`gh --json` fixture (offline, deterministic), that `list_org` for an org whose
`ignored_repos` names one of the fixture's repos **excludes exactly that repo**
(by bare `name`) and returns all the others; and that a `nameWithOwner`-form
entry in `ignored_repos` also excludes its repo. An org with empty
`ignored_repos` excludes nothing new (existing fork/archived behavior intact).

### GA4 — `org add --ignored-repos` (item 3)

`bundle exec ruby -Itest test/repo_tender/cli/org_test.rb`
→ PASS iff `0 failures, 0 errors` AND the suite proves: `org add bigco
--ignored-repos monorepo,huge` persists an `OrgRef` with
`ignored_repos == ["monorepo", "huge"]` to the config (round-tripped through
`Config::Store`); the repeated form (`--ignored-repos a --ignored-repos b`)
yields `["a", "b"]`; and `org list` surfaces the ignored list for that org.
Existing org add/remove/list/idempotency assertions still pass.

### GA5 — contract validates `ignored_repos`

`bundle exec ruby -Itest test/repo_tender/config/contract_test.rb`
→ PASS iff `0 failures, 0 errors` AND the suite proves a malformed
`ignored_repos` (non-array, or an array with a non-string element) yields a
`Failure` with a field-level message under the org path, and a valid
`["x","y"]` passes.

---

## Lane B — `clone` command

### GB1 — COW copy works (item 4, happy path)

`bundle exec ruby -Itest test/repo_tender/cloner_test.rb`
→ PASS iff `0 failures, 0 errors` AND the suite proves, with a **real temp
base_dir tree** (`$BASE/github.com/owner/reponame` populated with files), that
`Cloner` copies it to `<into>/reponame` via `cp -Rc`: the destination exists and
contains the source's files; the **source is unchanged**; returns `Success`.

### GB2 — name resolution & ambiguity

Same file (`cloner_test.rb`) — PASS iff the suite proves: a bare `name`
resolves to the single matching `$BASE/*/*/name`; an **ambiguous** bare name
(two owners with the same repo name) returns `Failure` that names the candidates
and copies nothing; `owner/name` and `host/owner/name` qualify a match; an
unknown name returns `Failure` and copies nothing.

### GB3 — no-clobber (no-data-loss, copy target)

Same file (`cloner_test.rb`) — PASS iff the suite proves: when `<into>/reponame`
already exists, `Cloner` returns `Failure` and the pre-existing destination is
**byte-for-byte unchanged** (assert a sentinel file inside it is untouched).

### GB4 — CLI: multi-repo, `--into`, partial failure, exit codes

`bundle exec ruby -Itest test/repo_tender/cli/clone_test.rb`
→ PASS iff `0 failures, 0 errors` AND the suite proves (using the existing
`CLITestHelpers` temp-home + base_dir-via-config seam): `clone a b --into <tmp>`
copies **both**; a mix of one resolvable + one bad name copies the good one,
reports the bad one on `err`, and records an `Outcome` with `exit_code: 1`; all
names good ⇒ `exit_code: 0`; default `--into` is the current working directory.

### GB5 — command is registered

Same file (`clone_test.rb`) or a subprocess assertion — PASS iff `clone` is a
registered top-level command (appears in the top-level usage / `clone --help`
resolves to the command, not "command not found").

---

## What a PASS requires beyond green gates

- `git diff <freeze>.. -- docs/gates/` is empty (no gate tampering).
- Each lane's `git status` shows only files inside its declared touch set
  (below); an out-of-bounds write fails the lane.
- `git -C <worktree> log <freeze>..` is empty (builders never commit).
- The cardinal no-data-loss invariant holds on read of the diff: Lane A's
  emit change must not alter any **loaded** value (GA2); Lane B must never
  overwrite an existing directory (GB3) and never mutate a resolved source
  (GB1).

### Declared file-touch sets (overlap-checked, disjoint)

**Lane A** — `lib/repo_tender/config/model.rb`,
`lib/repo_tender/config/contract.rb`, `lib/repo_tender/config/store.rb`,
`lib/repo_tender/forge/github.rb`, `lib/repo_tender/cli/org.rb`,
`test/repo_tender/config/store_test.rb`,
`test/repo_tender/config/contract_test.rb`,
`test/repo_tender/forge/github_test.rb`, `test/repo_tender/cli/org_test.rb`.

**Lane B** — `lib/repo_tender/cli.rb` (append one `require`),
`lib/repo_tender/cli/clone.rb` (new), `lib/repo_tender/cloner.rb` (new),
`test/repo_tender/cloner_test.rb` (new),
`test/repo_tender/cli/clone_test.rb` (new).

No file appears in both sets. README and all user docs are touched by **neither**
lane (architect updates at integration).
