# Releasing

Retraced from the v7.0.0 release (2026-08-14, PR #92, space
`20260813-architect-bug-smash-3-tokyo-drift`). Releases happen at project
landing time in the Architect Loop: every iteration judged, the project
branch ready to merge. The human runs every push and merge; the architect
prepares everything else. One release commit, one signed tag — automation
does the rest.

Where things live:

| Thing | Path |
|---|---|
| The one version constant | `lib/space_core/version.rb` (`Space::Core::VERSION`; `architect version` prints it) |
| Changelog | `CHANGELOG.md` (Keep a Changelog; link refs at the bottom) |
| Release automation | `.github/workflows/release.yml` (fires on `v*` tag push) |
| Local install task | `Rakefile` → `rake install` (`gem install --user-install --no-document`) |

## 0. Preconditions (in the space, before any release mechanics)

- Every iteration judged with a recorded verdict; the must-fix-before-landing
  list cleared. Small prose/comment corrections at landing are the human's
  call to commit directly to the project branch — not iteration-sized work —
  with the suite re-run green after. Check the diffstat against the expected
  line count after any scripted edit.
- Verify the BRIEF's definition-of-done in full: closed issues cited, suite at
  or above the project baseline, one project branch of `--no-ff` lane merges,
  zero builder commits anywhere in `main..project/<slug>`.

## 1. Release-prep commit (on the project branch)

The version bump is a landing concern — never in-iteration, never in a lane's
touch set.

1. Author the new `CHANGELOG.md` section — architect-written, drawn from the
   iteration verdicts and the integrated diff, citing the closed issues.
   Match the house style: read the previous version's section and the link
   refs at the bottom first.
2. Bump `lib/space_core/version.rb`.
3. `bundle install` — refreshes the `Gemfile.lock` version lines.
4. `bundle exec rake test` — green.
5. One commit, message from a file:
   `Release X.Y.Z: changelog, version bump, lockfile`.

## 2. Open the PR (human pushes)

The PR body is judgment output, written by the architect from the verdicts,
the integrated diff, and the BRIEF, to a fresh timestamped file in the
space (`build/land/<repo>-pr-body-<yyyymmdd-hhmm>.md`). The human runs:

```sh
cd <repo checkout>
git push -u origin project/<slug>
gh pr create \
  --base main \
  --head project/<slug> \
  --title "X.Y.Z — <one-line summary>" \
  --body-file <the body file>
```

Then verify the body attached in full (`gh pr view N --json body` — first and
last lines match the source file) and record the open PR in the space.

## 3. Merge (human) and confirm

Human merges the PR on GitHub (merge commit). Then:

```sh
git checkout main && git pull
grep VERSION lib/space_core/version.rb   # the bump is on main
```

## 4. Tag — annotated, signed, on the merge commit

Tag message in a file: subject `Release X.Y.Z: <one-line summary> (I01–I0N)`,
body optional. Then:

```sh
git tag -s vX.Y.Z -F <message file>
git tag -v vX.Y.Z                          # signature verifies
git push origin vX.Y.Z
git ls-remote --tags origin | grep vX.Y.Z  # tag is on the remote
```

## 5. Automation takes it from the tag

`release.yml` on the tag push: builds the gem, publishes to RubyGems via
trusted publishing (OIDC — no API token), smoke-tests an install from the
live index, and creates the GitHub Release with generated notes and the
`.gem` attached. Tags containing `.rc` / `.beta` / `.alpha` / `.pre` / `-`
are marked prerelease and never become "latest". No manual step here — watch
it land:

```sh
gh run watch
gh release view vX.Y.Z
```

## 6. Update the local CLI — and actually verify it

```sh
git checkout main && git pull   # the released tree, not a project branch
bundle exec rake install
architect version               # must print X.Y.Z
```

The verify line is not optional. Binstubs in `~/.gem/ruby/<abi>/bin` carry
the shebang of whichever ruby installed them and shadow the current mise
ruby's own bin dir on PATH; after a mise ruby upgrade, a stale binstub
silently keeps running the last gem the *old* ruby saw. This is exactly how
v7.0.0 shipped cleanly while the local `architect` kept answering `6.0.0`.
`rake install` targets the user gem home, which regenerates that binstub
under the current ruby.
