# frozen_string_literal: true

require "fileutils"
require "time"
require "repo_tender/scm/client"
require "repo_tender/scm/status"
require "repo_tender/shell"

module RepoTender
  module SCM
    # Git CLI implementation of SCM::Client. All subprocess work is
    # delegated to Shell.run (which requires an ambient Async::Task).
    class Git < Client
      # Resolve the bare remote's HEAD. First try the local
      # `origin/HEAD` symbolic ref; if missing/stale, do a one-shot
      # `git remote set-head origin -a` (network) to refresh it, then
      # re-read. This is the gotcha path from AGENTS.md: a plain
      # `git fetch` does NOT update `origin/HEAD`.
      def default_branch(path)
        symbolic = read_origin_head(path)
        return Dry::Monads::Success(symbolic) if symbolic

        refresh = Shell.run("git", "remote", "set-head", "origin", "-a", chdir: path)
        return refresh if refresh.failure?

        resolved = read_origin_head(path)
        if resolved
          Dry::Monads::Success(resolved)
        else
          Dry::Monads::Failure({path: path, reason: "could not resolve origin/HEAD after set-head -a"})
        end
      end

      def current_branch(path)
        # `git symbolic-ref --short HEAD` exits non-zero on detached HEAD.
        result = Shell.run("git", "symbolic-ref", "--short", "HEAD", chdir: path)
        if result.success?
          Dry::Monads::Success(result.success.strip)
        else
          # Detached HEAD is not a hard failure — report nil.
          head = Shell.run("git", "rev-parse", "--verify", "HEAD", chdir: path)
          if head.success?
            Dry::Monads::Success(nil)
          else
            Dry::Monads::Failure({path: path, reason: "no HEAD", stderr: result.failure[:stderr]})
          end
        end
      end

      def last_fetch_at(path)
        fetch_head = File.join(path, ".git", "FETCH_HEAD")
        return Dry::Monads::Success(nil) unless File.exist?(fetch_head)
        Dry::Monads::Success(Time.at(File.mtime(fetch_head).to_i))
      end

      def fetch(path)
        Shell.run("git", "fetch", "--prune", "--no-tags", "origin", chdir: path)
      end

      # `merge --ff-only` refuses on divergence. We additionally check
      # the rev-list left/right count first so we can surface a clean
      # "diverged" failure with diagnostic info, not just a git error
      # string.
      def fast_forward(path, default_branch)
        upstream = "origin/#{default_branch}"
        counts = Shell.run("git", "rev-list", "--left-right", "--count", "HEAD...#{upstream}", chdir: path)
        return counts if counts.failure?

        left, right = counts.success.strip.split("\t").map(&:to_i)
        if left > 0
          return Dry::Monads::Failure({
            path: path,
            reason: "diverged: local is #{left} commit(s) ahead of #{upstream}; not auto-resolving",
            local_ahead: left,
            remote_ahead: right
          })
        end

        if right == 0
          return Dry::Monads::Success(:up_to_date)
        end

        # Do the fetch (cheap; FETCH_HEAD mtime hint logic can skip this
        # later, but Slice 1 always fetches when asked to fast-forward).
        fetch_result = fetch(path)
        return fetch_result if fetch_result.failure?

        merge = Shell.run("git", "merge", "--ff-only", upstream, chdir: path)
        if merge.success?
          Dry::Monads::Success(:fast_forwarded)
        else
          # On --ff-only failure, git leaves the working tree and local
          # commits intact — the test asserts this.
          Dry::Monads::Failure({
            path: path,
            reason: "fast-forward failed (likely raced divergence)",
            stderr: merge.failure[:stderr]
          })
        end
      end

      def status(path)
        result = Shell.run("git", "status", "--porcelain=v2", "--branch", "--untracked-files=normal", chdir: path)
        return result if result.failure?

        parsed = parse_porcelain_v2(result.success)
        Dry::Monads::Success(parsed)
      end

      def clone(url, dest)
        parent = File.dirname(dest)
        FileUtils.mkdir_p(parent)
        result = Shell.run("git", "clone", url, dest)
        if result.success?
          Dry::Monads::Success(dest)
        else
          Dry::Monads::Failure({url: url, dest: dest, stderr: result.failure[:stderr]})
        end
      end

      # `git switch <branch>`. `git switch` aborts on a dirty tree by
      # default (man git-switch: "The operation is aborted however if
      # the operation leads to loss of local changes"), so a nonzero
      # exit here most likely means the caller violated the engine's
      # dirty-tree guard. We surface that as a Failure with the
      # captured stderr so the engine / log can diagnose it.
      def switch(path, branch)
        result = Shell.run("git", "switch", branch, chdir: path)
        if result.success?
          Dry::Monads::Success(branch)
        else
          Dry::Monads::Failure({path: path, branch: branch, reason: "git switch refused", stderr: result.failure[:stderr]})
        end
      end

      # Handle an unborn (empty) local clone. If the remote has no
      # branches, the repo is already a valid empty clone — return
      # Success(:empty) with no mutation. If the remote has gained
      # commits, fetch and fast-forward the unborn branch into them.
      #
      # `git ls-remote --heads origin` is the authoritative
      # empty-vs-error discriminator: exit 0 + empty stdout means the
      # remote truly has no branches; exit 0 + output means it has
      # commits; non-zero exit means a real network/probe error.
      def sync_empty(path)
        ls = Shell.run("git", "ls-remote", "--heads", "origin", chdir: path)
        return ls if ls.failure?

        return Dry::Monads::Success(:empty) if ls.success.strip.empty?

        fetch_result = fetch(path)
        return fetch_result if fetch_result.failure?

        branch_result = default_branch(path)
        return branch_result if branch_result.failure?

        upstream = "origin/#{branch_result.success}"
        merge = Shell.run("git", "merge", "--ff-only", upstream, chdir: path)
        if merge.success?
          Dry::Monads::Success(:fast_forwarded)
        else
          Dry::Monads::Failure({path: path, reason: "ff merge into unborn branch failed", stderr: merge.failure[:stderr]})
        end
      end

      private

      # `git symbolic-ref --short refs/remotes/origin/HEAD` returns
      # `origin/<branch>` (the short form of `refs/remotes/origin/<branch>`);
      # callers want the bare branch name. Returns nil when origin/HEAD
      # is unset.
      def read_origin_head(path)
        result = Shell.run("git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD", chdir: path)
        return nil unless result.success?
        line = result.success.strip
        return nil if line.empty?
        line.sub(%r{\Aorigin/}, "")
      end

      # Parse `git status --porcelain=v2 --branch --untracked-files=normal`.
      # v2 grammar (from the git-status man page):
      #   # branch.oid <commit-ish> | (initial)
      #   # branch.head <name> | (detached)
      #   # branch.upstream <upstream-branch>
      #   # branch.ab +<ahead> -<behind>
      #   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
      #   2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><TAB><origPath>
      #   u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
      #   ? <path>
      #   ! <path>
      def parse_porcelain_v2(output)
        branch = nil
        upstream = nil
        ahead = 0
        behind = 0
        detached = false
        unborn = false
        entries = []

        output.each_line do |raw|
          line = raw.chomp
          next if line.empty?
          case line
          when /\A# branch\.oid (.+)/
            unborn = (Regexp.last_match(1) == "(initial)")
          when /\A# branch\.head (.+)/
            branch = Regexp.last_match(1)
            detached = (branch == "(detached)")
          when /\A# branch\.upstream (.+)/
            upstream = Regexp.last_match(1)
          when /\A# branch\.ab \+(\d+) -(\d+)/
            ahead = Regexp.last_match(1).to_i
            behind = Regexp.last_match(2).to_i
          when /\A[12u?!]/
            entries << line
          end
        end

        Status.new(
          clean: entries.empty?,
          branch: branch,
          upstream: upstream,
          ahead: ahead,
          behind: behind,
          detached: detached,
          entries: entries,
          unborn: unborn
        )
      end
    end
  end
end
