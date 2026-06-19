# color-rollout-01 — Slice C Lane Report

## PHASE 0: Plan + Disagreements

No disagreements with the spec. Verified before writing:

- `UI::Mode.resolve` signature and behavior confirmed in `lib/repo_tender/ui/mode.rb` — takes `flags:`, `env:`, `out:`, returns a struct with `.color`
- `Pastel.new(enabled: false)` is passthrough (no SGR) — confirmed by behavior; non-TTY StringIO → `mode.color = false` → passthrough
- `GlobalOptions` mixin confirmed in `lib/repo_tender/cli/options.rb` — adds `:plain`, `:json`, `:no_color`, `:quiet` options via `self.included`
- All existing tests use `invoke_command` which injects `StringIO.new` (tty? = false) → no color → existing string equality assertions unaffected
- `tty-screen` was the sole dependency to drop from the gemspec; `pastel` was already present
- `Config::Store.emit` returns YAML with trailing `\n`; the spec says `.chomp` before colorizing so `puts` adds back exactly one `\n` — verified this matches existing test assertions (`assert_includes out.string, "concurrency: 8"` — substring match, not exact)

## Design Decisions

- **Shared helper vs per-command Pastel**: per-command — no `palette.rb` helper. 5 small commands; shared helper is premature abstraction. Each command is 3 lines to set up mode+pastel.
- **Flag surface**: full `GlobalOptions` mixin in all targeted commands — same surface as `sync`, zero divergence from frozen seam.
- **Stderr errors**: NOT styled (`fail_with` unchanged) — out of scope per RC3 constraint; errors to stderr only.
- **`config show` trailing newline**: `.chomp` on emit output before colorizing, then `puts` adds back `\n`. This ensures `strip_sgr(pretty) == plain` byte-exactly.
- **`daemon install` mode resolution placement**: after `paths.ensure!` and config load (these must precede mode resolution since `out` is valid from the start but the paths seam must be exercised first), before the plist write and output.

## Gate → Test Mapping

| Gate | Test file | Test method(s) |
|------|-----------|----------------|
| RC0  | all | `bundle exec rake test` → 358 runs, 0 failures |
| RC1  | `test/repo_tender/cli/{repo,org,status,config,daemon}_test.rb` | `test_*_has_color_in_pretty_mode`, `test_daemon_stop_has_color_in_pretty_mode` |
| RC2  | `test/repo_tender/cli/status_test.rb` | `test_status_byte_identical_in_plain`, `test_status_color_in_pretty_mode` |
| RC3  | all command test files | `test_*_no_color_*` |
| RC4  | all existing tests | unmodified bodies; verified by rake test |
| RC5  | all new color tests | mode resolved via `UI::Mode.resolve` seam in each command |
| RC6  | `git diff --stat HEAD -- lib/repo_tender/ui/mode.rb ...` | empty (no output) |

## Verbatim Command Outputs

### bundle install (tail)
```
Bundle complete! 4 Gemfile dependencies, 51 gems now installed.
Use `bundle info [gemname]` to see where a bundled gem is installed.
```

### bundle exec rake test
```
358 runs, 1258 assertions, 0 failures, 0 errors, 0 skips
```

### bundle exec standardrb
(no output — clean)

### ruby -W:no-experimental -Ilib bin/repo-tender --help
```
Commands:
  repo-tender config [SUBCOMMAND]
  repo-tender daemon [SUBCOMMAND]
  repo-tender org [SUBCOMMAND]
  repo-tender repo [SUBCOMMAND]
  repo-tender status                              # Show the per-repo evergreen status table (from $XDG_STATE_HOME/repo-tender/state.yaml)
  repo-tender sync                                # Run one sync pass (use --repo to scope to a single tracked repo)
```

### git diff --name-only HEAD
```
Gemfile.lock
lib/repo_tender/cli/config.rb
lib/repo_tender/cli/daemon.rb
lib/repo_tender/cli/org.rb
lib/repo_tender/cli/repo.rb
lib/repo_tender/cli/status.rb
repo-tender.gemspec
test/repo_tender/cli/config_test.rb
test/repo_tender/cli/daemon_test.rb
test/repo_tender/cli/org_test.rb
test/repo_tender/cli/repo_test.rb
test/repo_tender/cli/status_test.rb
```

### git diff --stat HEAD -- <must-not-touch paths>
(empty — no output)

## RC2: Byte-Equality Demonstration

`:pretty` data line (raw):
```
"github.com/ruby/ruby\t\e[32mclean\e[0m\ttrunk\t2026-06-12T20:01:34Z\t2026-06-12T20:01:33Z\n"
```

Strip SGR:
```
"github.com/ruby/ruby\tclean\ttrunk\t2026-06-12T20:01:34Z\t2026-06-12T20:01:33Z\n"
```

`:plain` data line:
```
"github.com/ruby/ruby\tclean\ttrunk\t2026-06-12T20:01:34Z\t2026-06-12T20:01:33Z\n"
```

assert_equal ✓ (`stripped == plain: true`)

## STATUS: COMPLETE
