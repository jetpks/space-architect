# frozen_string_literal: true

require "yaml"
require "pathname"
require "time"

module Space::Core
  class Space
    METADATA_FILE = "space.yaml"
    VALID_STATUSES = %w[active paused done archived].freeze

    attr_reader :path, :data

    def self.load(path)
      metadata_path = Pathname.new(path).join(METADATA_FILE)
      raise NotFoundError, "No space metadata found at #{metadata_path}" unless metadata_path.exist?

      parsed = YAML.safe_load(metadata_path.read, aliases: false) || {}
      raise Error, "Space metadata must contain a YAML mapping: #{metadata_path}" unless parsed.is_a?(Hash)

      new(Pathname.new(path), stringify_keys(parsed))
    end

    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(key, value), result| result[key.to_s] = value }
    end

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

    def architect
      data["architect"]
    end

    def architect=(val)
      data["architect"] = val
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
