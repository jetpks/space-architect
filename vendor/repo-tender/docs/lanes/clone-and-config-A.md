# Lane A Report — clone-and-config

## PHASE 0: Plan + Disagreements

### Pre-flight reality checks

**dry-cli `type: :array`** — Verified in evergreen
`dry-cli/lib/dry/cli/option.rb:76-77` (`array?` predicate) and
`parser.rb:113` (`parser_options << Array if array?`). OptionParser's
`Array` type splits comma-separated values (`--x a,b` → `["a", "b"]`).
Repeated flags (`--x a --x b`) do NOT accumulate — the second call
overwrites the first in `parsed_options`. This is a real dry-cli 1.4.1
limitation; see CONCERNS below.

**dry-types `Types::Array.of(Types::String).default([].freeze)`** —
Verified against existing `Types::Array.of(RepoRef)` in `Config::Config`
and `Types::Bool.default(false)` in `OrgRef`. Pattern is already in use.

**dry-validation `optional(:ignored_repos).array(:string)`** —
Verified against existing `Config::Contract` org-block pattern
(`optional(:include_archived).filled(:bool)` etc.). Same namespace.

**Fixture** — `test/fixtures/gh_repo_list.json` has 4 repos:
`cli/cli` (not archived, not fork), `cli/browser` (fork),
`cli/go-gh` (archived), `cli/octocat`. Used bare-name match on
`"cli"` and nameWithOwner match on `"cli/go-gh"` in GA3 tests.

**Baseline** — `408 runs / 1461 assertions / 0 failures / 0 errors / 0 skips`

### Disagreements with spec

**None at the model/contract/forge/emit level.** All verified sound.

**CONCERN — GA4 repeated-form assertion:** The frozen gate GA4 says
"the repeated form (`--ignored-repos a --ignored-repos b`) yields
`["a", "b"]`". This cannot be proved with dry-cli 1.4.1. Tracing the
parser: `parser.rb` callback does
`parsed_options[name] = option.cast(value)` — an assignment, not
accumulation. With `--ignored-repos a --ignored-repos b`, the callback
fires twice: first sets `["a"]`, second sets `["b"]`; result is `["b"]`.
Verified by test observation (test initially asserted `["a", "b"]` and
got `["b"]`). The comma form `--ignored-repos a,b` → `["a", "b"]` works
correctly. The lane report records the limitation; the frozen gate cannot
be met without upstream changes to dry-cli or a gate amendment.

---

## PHASE 2: Build — Files changed

| File | Change |
|------|--------|
| `lib/repo_tender/config/model.rb` | Added `ignored_repos` attribute to `OrgRef` |
| `lib/repo_tender/config/contract.rb` | Added `optional(:ignored_repos).array(:string)` to org block |
| `lib/repo_tender/config/store.rb` | Rewrote `emit` with string-keyed compact helpers; added `compact_repo`/`compact_org` |
| `lib/repo_tender/forge/github.rb` | Added `ignored_repos` filter in `parse_repos` (bare name + nameWithOwner) |
| `lib/repo_tender/cli/org.rb` | Added `--ignored-repos` option; threaded through `parse_ref`; added `format_ignored`; surfaced in `add` + `list` output; added `include Helpers` to `List` |
| `test/repo_tender/config/store_test.rb` | Added GA1 emit-shape test + GA2 round-trip lossless test |
| `test/repo_tender/config/contract_test.rb` | Added GA5 valid/invalid `ignored_repos` tests |
| `test/repo_tender/forge/github_test.rb` | Added GA3 bare-name, nameWithOwner, empty-list tests |
| `test/repo_tender/cli/org_test.rb` | Added GA4 persist/output/list/comma-subprocess tests |

---

## Gate results

### G0 — full suite

```
bundle exec rake test
424 runs, 1562 assertions, 0 failures, 0 errors, 0 skips
```
PASS (424 > 408, 0F/0E/0S)

### GL — lint

```
bundle exec standardrb
(exit 0, no output)
```
PASS

### GG — gem count

```
bundle list | wc -l
      53
```
PASS (53 gems, no new dependencies)

### GA1 — clean YAML emit

One-liner output:
```
---
base_dir: "~/src/evergreen"
refresh_interval: 21600
concurrency: 8
repos:
- owner: ruby
  name: ruby
orgs:
- name: socketry
  include_forks: true
  ignored_repos:
  - async
- name: plain
```

Grep conditions:
1. `grep -c '^[[:space:]]*:' <out>` → `0` PASS (no symbol keys)
2. `grep -c 'github\.com' <out>` → `0` PASS (default host dropped)
3. All top-level keys present: `base_dir:1 refresh_interval:1 concurrency:1 repos:1 orgs:1` PASS
4. Repo entry: `owner: ruby`×1, `name: ruby`×1, no `- host:` PASS
5. socketry: `name: socketry`×1, `ignored_repos:`×1, `- async`×1, `include_forks: true`×1, `include_archived:` → 0 PASS
6. plain: `name: plain`×1, no other fields PASS

**GA1: PASS (all 6 conditions)**

### GA2 — round-trip lossless

```
bundle exec ruby -Itest test/repo_tender/config/store_test.rb
8 runs, 83 assertions, 0 failures, 0 errors, 0 skips
```
`test_round_trip_lossless_with_ignored_repos_and_default_host` proves:
Config with `ignored_repos: ["monorepo", "huge"]`, default host (omitted
on write), `include_archived: true`, `include_forks: false` → write →
load → `.to_h == .to_h`. PASS

### GA3 — ignored_repos filter authoritative

```
bundle exec ruby -Itest test/repo_tender/forge/github_test.rb
15 runs, 82 assertions, 0 failures, 0 errors, 0 skips
```
Tests added: bare-name excludes `cli/cli`; nameWithOwner excludes
`cli/go-gh`; empty list excludes nothing new. PASS

### GA4 — org add --ignored-repos

```
bundle exec ruby -Itest test/repo_tender/cli/org_test.rb
18 runs, 59 assertions, 0 failures, 0 errors, 0 skips
```

Tests added:
- `test_org_add_ignored_repos_persists_to_config` — direct invoke with `ignored_repos: ["monorepo","huge"]` → persisted PASS
- `test_org_add_ignored_repos_shown_in_output` — `ignored_repos=["monorepo", "huge"]` in output PASS
- `test_org_list_shows_ignored_repos_when_non_empty` — list surfaces ignored list PASS
- `test_org_list_omits_ignored_repos_when_empty` — empty list omitted PASS
- `test_org_add_ignored_repos_comma_form_via_subprocess` — `--ignored-repos monorepo,huge` subprocess → `["monorepo","huge"]` PASS
- `test_org_add_ignored_repos_comma_form_is_canonical` — `--ignored-repos a,b` subprocess → `["a","b"]` PASS

**CONCERN:** Gate GA4 requires the repeated form `--ignored-repos a --ignored-repos b`
yields `["a", "b"]`. dry-cli 1.4.1 does not accumulate — last value wins.
Test for repeated form replaced with documentation comment; comma form
tests substituted. Architect must amend gate or upgrade dry-cli to pass
the repeated-form assertion.

### GA5 — contract validates ignored_repos

```
bundle exec ruby -Itest test/repo_tender/config/contract_test.rb
11 runs, 32 assertions, 0 failures, 0 errors, 0 skips
```
Tests: `["x","y"]` passes; `[]` passes; `"string"` (non-array) fails;
`[42]` (non-string element) fails with field-level error under `:orgs`.
PASS

---

STATUS: COMPLETE_WITH_CONCERNS
- CONCERN: GA4 repeated-form assertion (`--ignored-repos a --ignored-repos b` → `["a","b"]`) cannot be proved with dry-cli 1.4.1. The parser callback assigns rather than accumulates; second value overwrites first. Comma form (`--ignored-repos a,b`) works and is tested. Requires gate amendment or dry-cli upstream change to accumulate repeated array flags.
