# frozen_string_literal: true

require "dry/struct"
require "dry/types"

module SpaceArchitect::Pristine
  module Config
    Types = Dry.Types()

    # Default host for repo/org entries. Per PRD §3.1, host is omitted in
    # the YAML when the user means github.com.
    DEFAULT_HOST = "github.com"
    # Per PRD §3.1, default refresh_interval is 6h. Stored as integer seconds.
    DEFAULT_REFRESH_INTERVAL = 6 * 3600
    DEFAULT_CONCURRENCY = 8

    class RepoRef < Dry::Struct
      transform_keys(&:to_sym)

      attribute :host, Types::String.default(DEFAULT_HOST)
      attribute :owner, Types::String
      attribute :name, Types::String
    end

    class OrgRef < Dry::Struct
      transform_keys(&:to_sym)

      attribute :host, Types::String.default(DEFAULT_HOST)
      attribute :name, Types::String
      attribute :include_archived, Types::Bool.default(false)
      attribute :include_forks, Types::Bool.default(false)
      attribute :ignored_repos, Types::Array.of(Types::String).default([].freeze)
    end

    # Top-level config. The on-disk schema per PRD §3.1:
    #   base_dir, refresh_interval, concurrency, repos, orgs.
    # `base_dir` has no struct-level default — the value is set from
    # Paths::DEFAULT_BASE_DIR at store-load time (see Config::Store).
    class Config < Dry::Struct
      transform_keys(&:to_sym)

      attribute :base_dir, Types::String
      attribute :refresh_interval, Types::Integer.constrained(gt: 0)
      attribute :concurrency, Types::Integer.constrained(gt: 0)
      attribute :repos, Types::Array.of(RepoRef).default([].freeze)
      attribute :orgs, Types::Array.of(OrgRef).default([].freeze)
    end
  end
end
