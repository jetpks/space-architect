# frozen_string_literal: true

module RepoTender
  module SCM
    # Value object produced by parsing `git status --porcelain=v2
    # --branch --untracked-files=normal`. v2 is mandatory (per
    # AGENTS.md gotcha) so submodule state and rename detection are
    # stable.
    #
    # A working tree is "clean" iff the only porcelain-v2 lines are the
    # `# branch.*` header lines. Any `1`/`2`/`u`/`?`/`!` line is dirty.
    Status = Data.define(:clean, :branch, :upstream, :ahead, :behind, :detached, :entries) do
      def initialize(clean:, branch: nil, upstream: nil, ahead: 0, behind: 0, detached: false, entries: [])
        super
      end

      def clean? = clean

      def detached? = detached
    end
  end
end
