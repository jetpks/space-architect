# frozen_string_literal: true

require "json"
require "space_src/forge/client"
require "space_src/shell"
require "space_src/config/model"

module Space::Src
  module Forge
    # `gh repo list <org> --json …` implementation of Forge::Client.
    #
    # Per AGENTS.md gotcha, `gh` can silently fall back to
    # unauthenticated (60 req/hr). We probe `gh auth status` once
    # (via the engine calling check_authenticated before listing)
    # and surface a clear Failure rather than risking the rate-limit wall.
    class GitHub < Client
      # Default page size for `gh repo list`. Matches gh's own --limit
      # cap; orgs with >1000 repos are out of scope for Slice 1.
      LIST_LIMIT = 1000

      def initialize(shell: Shell)
        @shell = shell
      end

      # Probe `gh auth status`. On stderr the unauthenticated case is
      # obvious: "You are not logged into any GitHub hosts." We treat
      # that exact phrase as Failure; otherwise Success.
      #
      # Public so the engine can call it once before fanning out org
      # listings. `list_org` no longer authenticates per-call.
      def check_authenticated
        # `gh auth status` writes a human-friendly summary to stdout
        # and exits 0 when authenticated, 1 when not. We also fail
        # when the binary is missing (status 127 from the shell).
        result = @shell.run("gh", "auth", "status")
        return result if result.failure?

        if result.success.include?("not logged into any GitHub hosts")
          Dry::Monads::Failure({reason: "gh not authenticated; run `gh auth login` first"})
        else
          Dry::Monads::Success(:authenticated)
        end
      end

      def list_org(org_ref)
        return Dry::Monads::Failure({org: org_ref.name, reason: "missing org name"}) if org_ref.name.nil? || org_ref.name.empty?

        argv = build_argv(org_ref)
        result = @shell.run(*argv)
        return result if result.failure?

        parsed = parse_repos(result.success, org_ref)
        Dry::Monads::Success(parsed)
      rescue JSON::ParserError => e
        Dry::Monads::Failure({org: org_ref.name, reason: "invalid JSON from gh", error: e.message})
      end

      def build_argv(org_ref)
        # G11 fix (Slice 2): `--no-source` is NOT a valid `gh repo list`
        # flag (`gh repo list --help` lists `--archived`, `--no-archived`,
        # `--fork`, `--source`, `--json`, `--limit`, `--topic`,
        # `--language`, `--visibility`, `--jq`, `--template` — no
        # `--no-source`). Fork exclusion is handled authoritatively in
        # `parse_repos` below (the `include_forks` filter), so we no
        # longer emit an advisory CLI flag for it. The existing G6
        # behavioral tests for `include_forks=false` still pass.
        argv = ["gh", "repo", "list", org_ref.name, "--json", "nameWithOwner,defaultBranchRef,isArchived,isFork", "--limit", LIST_LIMIT.to_s]
        argv << "--no-archived" unless org_ref.include_archived
        argv
      end

      private

      # Parses gh's JSON output into RepoRef structs, honoring
      # include_archived / include_forks (the CLI flags are advisory;
      # the filter is authoritative so a future gh flag rename
      # doesn't break us silently).
      def parse_repos(json_text, org_ref)
        rows = JSON.parse(json_text)
        ignored = org_ref.ignored_repos
        rows.map do |row|
          next if !org_ref.include_archived && row["isArchived"]
          next if !org_ref.include_forks && row["isFork"]

          owner, name = row.fetch("nameWithOwner").split("/", 2)
          next if ignored.include?(name) || ignored.include?(row.fetch("nameWithOwner"))
          # default_branch is state, not config — the SCM layer resolves
          # it on the local clone (see SCM::Git#default_branch).
          Config::RepoRef.new(
            host: org_ref.host,
            owner: owner,
            name: name
          )
        end.compact
      end
    end
  end
end
