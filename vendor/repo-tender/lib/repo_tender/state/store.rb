# frozen_string_literal: true

require "yaml"
require "fileutils"
require "time"
require "dry/monads"

module RepoTender
  module State
    # Machine-managed state at $XDG_STATE_HOME/repo-tender/state.yaml.
    # Never hand-edited (per PRD §3.2). Per-repo + per-org records with
    # a fixed status enum; the store validates the enum and timestamp
    # format on write.
    class Store
      extend Dry::Monads[:result]

      STATUSES = %w[clean dirty diverged detached wrong_branch missing error].freeze

      Repo = Data.define(:default_branch, :last_fetch_at, :last_synced_at, :status, :last_error) do
        def initialize(default_branch: nil, last_fetch_at: nil, last_synced_at: nil, status: nil, last_error: nil)
          super
        end

        def to_h_compact
          {
            "default_branch" => default_branch,
            "last_fetch_at" => format_time(last_fetch_at),
            "last_synced_at" => format_time(last_synced_at),
            "status" => status,
            "last_error" => last_error
          }.compact
        end

        private

        def format_time(t)
          t.respond_to?(:iso8601) ? t.iso8601 : t
        end
      end

      Org = Data.define(:last_listed_at, :repo_count, :last_error) do
        def initialize(last_listed_at: nil, repo_count: 0, last_error: nil)
          super
        end

        def to_h_compact
          {
            "last_listed_at" => format_time(last_listed_at),
            "repo_count" => repo_count,
            "last_error" => last_error
          }.compact
        end

        private

        # `last_listed_at` may arrive as a Time (fresh from the
        # engine) or as a String (round-tripped from YAML, since
        # `to_h_compact` always emits the iso8601 form on
        # write). Both forms are written as the same string on
        # the next emit; the helper accepts either.
        def format_time(t)
          return nil if t.nil?
          t.respond_to?(:iso8601) ? t.iso8601 : t
        end
      end

      def self.load(path)
        raw = read_yaml(path)
        Success(build_state(raw))
      end

      def self.write(path, state)
        validation = validate(state)
        return validation if validation.failure?

        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}"
        begin
          File.write(tmp, emit(state))
          File.rename(tmp, path)
        ensure
          File.delete(tmp) if File.exist?(tmp)
        end
        Success(state)
      end

      def self.validate(state)
        state.repos.each do |key, repo|
          unless STATUSES.include?(repo.status)
            return Failure({repos: {key => {status: ["must be one of: #{STATUSES.join(", ")}"]}}})
          end
        end
        Success(state)
      end

      def self.read_yaml(path)
        return {} unless File.exist?(path)
        # Time class permitted because state.yaml stores ISO8601
        # timestamps; Psych will deserialize them as Time when the
        # scalar is tagged. No other arbitrary classes allowed.
        YAML.safe_load_file(path, permitted_classes: [Symbol, Time], aliases: false) || {}
      end

      def self.build_state(raw)
        repos = (raw["repos"] || {}).each_with_object({}) do |(key, attrs), acc|
          acc[key] = Repo.new(
            default_branch: attrs["default_branch"],
            last_fetch_at: attrs["last_fetch_at"],
            last_synced_at: attrs["last_synced_at"],
            status: attrs["status"],
            last_error: attrs["last_error"]
          )
        end
        orgs = (raw["orgs"] || {}).each_with_object({}) do |(key, attrs), acc|
          acc[key] = Org.new(
            last_listed_at: attrs["last_listed_at"],
            repo_count: attrs["repo_count"] || 0,
            last_error: attrs["last_error"]
          )
        end
        State.new(repos: repos, orgs: orgs)
      end

      # State value object — top-level container.
      State = Data.define(:repos, :orgs) do
        def initialize(repos: {}, orgs: {})
          super
        end
      end

      def self.emit(state)
        payload = {
          "repos" => state.repos.each_with_object({}) { |(k, v), acc| acc[k] = v.to_h_compact },
          "orgs" => state.orgs.each_with_object({}) { |(k, v), acc| acc[k] = v.to_h_compact }
        }
        YAML.dump(payload, line_width: -1)
      end
    end
  end
end
