# Lane B — `clone` command (slice `clone-and-config`)

## PHASE 0 — Plan + Reality Checks

### What I checked against reality

| Claim | File | Finding |
|---|---|---|
| `Shell.run` requires `Async::Task.current?` | `lib/repo_tender/shell.rb:24` | Confirmed — raises if no ambient task |
| CRUD commands are plain synchronous Ruby | `AGENTS.md` | Confirmed — no Sync{} in `repo`/`org`/`config` commands |
| Pattern for calling Shell.run from sync code | `lib/repo_tender/launchd/agent.rb:36-46` | `ShellRunner` inner class wraps Shell.run in Sync{} — canonical precedent |
| `cp -Rc` on APFS temp dir | Manual probe (ruby -e, Dir.mktmpdir) | Exit 0, dest created, source unchanged |
| `argument :names, type: :array` captures trailing positionals | PRD §4 research + dry-cli docs | Confirmed |
| Top-level single command registration | `lib/repo_tender/cli/sync.rb:149` | `Registry.register "sync", CLI::Sync::Run` — clone mirrors this |
| `config.base_dir` is a plain string | `lib/repo_tender/config/model.rb:42` | `Types::String` — expand with `File.expand_path` before globbing |

### Key decision: `Sync{}` wrapping

`Shell.run` raises unless inside an `Async::Task`. `clone` is a CRUD-style synchronous command (per AGENTS.md). Resolution: `Cloner` has an inner `ShellRunner` class (matching `Launchd::Agent::ShellRunner`) that wraps `Shell.run` in `Sync{}`. Default-injected; tests use the real one (no mocks — real `cp` in real temp dirs per gate GB1).

### Disagreements

None. The spec and reality align. The `Sync{}` wrapping is an implementation detail, not a spec gap — the `Launchd::Agent` precedent covers it exactly.

### Scope checked: no out-of-bounds touches

Lane B files only:
- `lib/repo_tender/cli.rb` — appended `require "repo_tender/cli/clone"`
- `lib/repo_tender/cli/clone.rb` — new
- `lib/repo_tender/cloner.rb` — new
- `test/repo_tender/cloner_test.rb` — new
- `test/repo_tender/cli/clone_test.rb` — new

---

## PHASE 2 — Implementation

### Files created/modified

| File | Action | Notes |
|---|---|---|
| `lib/repo_tender/cloner.rb` | new | Resolution + COW-copy boundary; ShellRunner wraps Shell.run in Sync{} |
| `lib/repo_tender/cli/clone.rb` | new | Thin argv→Cloner→Outcome layer; registers top-level `clone` command |
| `test/repo_tender/cloner_test.rb` | new | GB1/GB2/GB3: 9 tests, real temp dirs, no mocks |
| `test/repo_tender/cli/clone_test.rb` | new | GB4/GB5: 8 tests, CLITestHelpers seam |
| `lib/repo_tender/cli.rb` | modified | Appended `require "repo_tender/cli/clone"` (one line only) |

---

## Gate Results

| Gate | Command | Raw output |
|---|---|---|
| G0 full suite | `bundle exec rake test` | `425 runs, 1517 assertions, 0 failures, 0 errors, 0 skips` |
| GL lint | `bundle exec standardrb` | exit 0 |
| GG gem count | `bundle list \| wc -l` | `53` |
| GB1 COW copy | `bundle exec ruby -Itest test/repo_tender/cloner_test.rb` | `9 runs, 30 assertions, 0 failures, 0 errors, 0 skips` |
| GB2 resolution | (same file) | covered in 9 runs above |
| GB3 no-clobber | (same file) | covered in 9 runs above |
| GB4 CLI multi-repo | `bundle exec ruby -Itest test/repo_tender/cli/clone_test.rb` | `8 runs, 26 assertions, 0 failures, 0 errors, 0 skips` |
| GB5 registered | (same file) | `test_clone_registered_as_top_level_command` passes; `clone --help` exit 0 |

### cp -Rc probe (PHASE 0 verification)

```
ruby -e '
require "tmpdir"; require "fileutils"
Dir.mktmpdir do |base|
  src = File.join(base, "myrepo"); FileUtils.mkdir_p(src)
  File.write(File.join(src, "file.txt"), "hello cow")
  into = File.join(base, "into"); FileUtils.mkdir_p(into)
  dest = File.join(into, "myrepo")
  system("cp", "-Rc", src, dest, exception: true)
  puts "dest exists: #{File.directory?(dest)}"
  puts "file content: #{File.read(File.join(dest, "file.txt"))}"
  puts "src unchanged: #{File.read(File.join(src, "file.txt"))}"
end'

dest exists: true
file content: hello cow
src unchanged: hello cow
```

### No-data-loss invariant

- **GB1**: source `README.md` content asserted equal before and after copy.
- **GB3**: sentinel file `do not overwrite` asserted byte-for-byte unchanged after rejected clone; `new.txt` from source asserted absent in pre-existing dest.

---

STATUS: COMPLETE
