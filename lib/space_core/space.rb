# frozen_string_literal: true

require "yaml"
require "pathname"
require "time"

module Space::Core
  class Space
    METADATA_FILE = "space.yaml"
    VALID_STATUSES = %w[active paused done archived].freeze

    # Canonical space.yaml shape: registry under `project:` (renamed from the
    # pre-2.0 `architect:` key). Bumped from 1 in the release that did the
    # rename, since that release shipped no read-side alias for it.
    SCHEMA_VERSION = 2

    attr_reader :path, :data

    def self.load(path)
      metadata_path = Pathname.new(path).join(METADATA_FILE)
      raise NotFoundError, "No space metadata found at #{metadata_path}" unless metadata_path.exist?

      parsed = YAML.safe_load(metadata_path.read, aliases: false) || {}
      raise Error, "Space metadata must contain a YAML mapping: #{metadata_path}" unless parsed.is_a?(Hash)

      data = stringify_keys(parsed)
      normalize_schema!(data, metadata_path)
      new(Pathname.new(path), data)
    end

    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

    # Normalizes a parsed space.yaml hash to canonical schema v2, in place:
    #   - future version (> SCHEMA_VERSION) → raise, refuse to misread it.
    #   - `architect:` only (v1a) → becomes `project:`.
    #   - `project:` only (v1b or v2) → left as-is.
    #   - both present, `project:` empty and `architect:` non-empty → the
    #     corruption from the old silent-default read path; take `architect:`.
    #   - both present and non-empty: identical → keep; differing → raise
    #     rather than silently pick one and lose data.
    # Idempotent, so a canonical v2 space is a no-op through this method.
    def self.normalize_schema!(data, metadata_path)
      version = data["version"]
      if version.is_a?(Integer) && version > SCHEMA_VERSION
        raise Error,
          "space.yaml schema version #{version} is newer than this gem supports " \
          "(#{SCHEMA_VERSION}); upgrade space-architect: #{metadata_path}"
      end

      legacy = data.delete("architect")
      current = data["project"]

      data["project"] =
        if legacy.nil?
          current
        elsif current.nil? || empty_project_block?(current)
          legacy
        elsif legacy == current
          current
        else
          raise Error,
            "#{metadata_path} has both 'architect:' and 'project:' blocks with " \
            "conflicting content; resolve manually.\narchitect: #{legacy.inspect}\n" \
            "project: #{current.inspect}"
        end

      data["version"] = SCHEMA_VERSION
    end
    private_class_method :normalize_schema!

    def self.empty_project_block?(block)
      block.is_a?(Hash) && Array(block["iterations"]).empty? && block["current_iteration"].nil?
    end
    private_class_method :empty_project_block?

    def initialize(path, data)
      @path = Pathname.new(path)
      @data = data
    end

    def id
      data.fetch("id")
    end

    def title
      data.fetch("title")
    end

    def status
      data.fetch("status", "active")
    end

    def repos
      Array(data["repos"]).map do |repo|
        repo.is_a?(Hash) ? self.class.stringify_keys(repo) : { "name" => repo.to_s }
      end
    end

    def provision_scripts
      Array(data.dig("pack", "provision")).map(&:to_s)
    end

    def persist_paths
      Array(data.dig("pack", "persist")).map(&:to_s)
    end

    # Host env vars to forward into the container at `space run` (bare passthrough).
    # Declared per-space so payloads needing credentials run without a wall of flags.
    def run_env
      Array(data.dig("run", "env")).map(&:to_s)
    end

    def architect
      data["project"]
    end

    def architect=(val)
      data["project"] = val
    end

    def metadata_path
      path.join(METADATA_FILE)
    end

    def save
      AtomicWrite.write(metadata_path, YAML.dump(data))
      self
    end

    def update_status(status, now: Time.now)
      normalized = status.to_s.downcase
      unless VALID_STATUSES.include?(normalized)
        raise InvalidStatusError, "Invalid status '#{status}'. Expected one of: #{VALID_STATUSES.join(', ')}"
      end

      data["status"] = normalized
      data["updated_at"] = now.iso8601
      save
    end

    def add_repo(reference, relative_path:, now: Time.now)
      repo_data = repo_data_for(reference, relative_path:, now:)
      existing = repos.find do |repo|
        repo["full_name"] == repo_data["full_name"] ||
          repo["path"] == repo_data["path"] ||
          repo["name"] == repo_data["name"]
      end
      if existing
        raise RepoExistsError, "Repo '#{repo_data['full_name']}' already exists in #{id}"
      end

      data["repos"] = repos + [repo_data]
      data["updated_at"] = now.iso8601
      save
      repo_data
    end

    private

    def repo_data_for(reference, relative_path:, now:)
      {
        "provider" => reference.provider,
        "organization" => reference.owner,
        "name" => reference.name,
        "full_name" => reference.full_name,
        "clone_url" => reference.clone_url,
        "path" => relative_path.to_s,
        "added_at" => now.iso8601
      }
    end
  end
end
