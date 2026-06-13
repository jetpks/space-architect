# frozen_string_literal: true

require "dry/monads"

module RepoTender
  module SCM
    # Abstract SCM interface. The git CLI is the only implementation for
    # now (per AGENTS.md / PRD §1), but the sync engine + tests must
    # code to this interface so a future SCM is a drop-in.
    #
    # Every method returns a Dry::Monads::Result. Programmer error
    # (e.g. nil path) is a raise; expected failures (no .git, non-fast-
    # forward, network down) are Failure.
    class Client
      extend Dry::Monads[:result]

      # Parse the working-tree status of a repo on disk. Implementation
      # must read porcelain v2 (per AGENTS.md gotcha) and report a
      # `SCM::Status` value object.
      def status(path)
        raise NotImplementedError
      end

      # Returns the current branch name, or nil if HEAD is detached.
      def current_branch(path)
        raise NotImplementedError
      end

      # Returns the bare remote's HEAD (e.g. "main" or "trunk"). Must
      # work even when the default branch is not "main". May do a
      # one-shot network call (`git remote set-head origin -a`) to
      # refresh a stale `origin/HEAD`.
      def default_branch(path)
        raise NotImplementedError
      end

      # Returns the mtime of .git/FETCH_HEAD, or nil if absent. Treated
      # as a freshness hint (PRD §3.3 step 4 + gate G5).
      def last_fetch_at(path)
        raise NotImplementedError
      end

      # `git fetch --prune --no-tags origin`.
      def fetch(path)
        raise NotImplementedError
      end

      # `git merge --ff-only origin/<default>`. Returns Failure if the
      # local branch has diverged (left count > 0) — never resets.
      def fast_forward(path, default_branch)
        raise NotImplementedError
      end

      # `git clone <url> <path>`.
      def clone(url, path)
        raise NotImplementedError
      end
    end
  end
end
