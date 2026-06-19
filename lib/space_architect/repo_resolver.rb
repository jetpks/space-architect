# frozen_string_literal: true

require "uri"

module SpaceArchitect
  class RepoResolver
    SCP_LIKE_PATTERN = /\A(?:[^@\/]+@)?(?<provider>[^:\/]+):(?<path>.+)\z/
    URL_PATTERN = %r{\A[A-Za-z][A-Za-z0-9+\-.]*://}

    attr_reader :config

    def initialize(config)
      @config = config
    end

    def resolve(spec)
      value = spec.to_s.strip
      raise RepoResolutionError, "Repo cannot be blank" if value.empty?

      if url_like?(value)
        resolve_url(value)
      elsif (match = value.match(SCP_LIKE_PATTERN))
        reference_from_parts(
          provider: match[:provider],
          path_parts: split_repo_path(match[:path]),
          clone_url: value,
          source: value
        )
      else
        resolve_shorthand(value)
      end
    end

    private

    def resolve_url(value)
      uri = URI.parse(value)
      provider = uri.host
      path = uri.path.to_s.delete_prefix("/")
      raise RepoResolutionError, "Could not determine provider from '#{value}'" if provider.to_s.empty?

      reference_from_parts(
        provider: provider,
        path_parts: split_repo_path(path),
        clone_url: value,
        source: value
      )
    rescue URI::InvalidURIError
      raise RepoResolutionError, "Could not parse repo URL '#{value}'"
    end

    def resolve_shorthand(value)
      parts = split_repo_path(value)

      if parts.length == 1
        resolve_default_organization_repo(parts.first, value)
      elsif provider_like?(parts.first) && parts.length >= 3
        reference_from_parts(
          provider: parts.first,
          path_parts: parts[1..],
          clone_url: nil,
          source: value
        )
      else
        resolve_default_provider_repo(parts, value)
      end
    end

    def resolve_default_organization_repo(name, source)
      provider = require_default_provider(source)
      owner = config.default_organization
      unless owner
        raise RepoResolutionError,
              "Repo '#{source}' needs an organization. Set one with: space config set default_organization ORG"
      end

      reference(provider:, owner:, name:, clone_url: nil, source:)
    end

    def resolve_default_provider_repo(parts, source)
      provider = require_default_provider(source)
      reference_from_parts(provider:, path_parts: parts, clone_url: nil, source:)
    end

    def reference_from_parts(provider:, path_parts:, clone_url:, source:)
      if path_parts.length < 2
        raise RepoResolutionError, "Repo '#{source}' must include an organization and repo name"
      end

      name = path_parts.last
      owner = path_parts[0...-1].join("/")
      reference(provider:, owner:, name:, clone_url:, source:)
    end

    def reference(provider:, owner:, name:, clone_url:, source:)
      normalized_provider = normalize_provider(provider)
      normalized_owner = normalize_path_part(owner)
      normalized_name = normalize_repo_name(name)

      RepoReference.new(
        provider: normalized_provider,
        owner: normalized_owner,
        name: normalized_name,
        clone_url: clone_url || clone_url_for(normalized_provider, normalized_owner, normalized_name),
        source: source
      )
    end

    def clone_url_for(provider, owner, name)
      case config.git_clone_protocol
      when "ssh"
        "git@#{provider}:#{owner}/#{name}.git"
      when "https"
        "https://#{provider}/#{owner}/#{name}.git"
      end
    end

    def split_repo_path(value)
      normalized = value.to_s.strip.delete_prefix("/").delete_suffix("/")
      normalized = normalized.delete_suffix(".git")
      parts = normalized.split("/").reject(&:empty?)
      raise RepoResolutionError, "Repo '#{value}' must include a repo name" if parts.empty?

      parts
    end

    def require_default_provider(source)
      config.default_provider || raise(
        RepoResolutionError,
        "Repo '#{source}' needs a provider. Set one with: space config set default_provider PROVIDER"
      )
    end

    def normalize_provider(value)
      normalized = value.to_s.strip
      normalized = normalized.delete_prefix("https://")
      normalized = normalized.delete_prefix("http://")
      normalized = normalized.delete_prefix("ssh://")
      normalized = normalized.delete_suffix("/")
      raise RepoResolutionError, "Provider cannot be blank" if normalized.empty?

      normalized
    end

    def normalize_path_part(value)
      normalized = value.to_s.strip.delete_prefix("/").delete_suffix("/")
      raise RepoResolutionError, "Organization cannot be blank" if normalized.empty?

      normalized
    end

    def normalize_repo_name(value)
      normalized = value.to_s.strip.delete_suffix(".git")
      raise RepoResolutionError, "Repo name cannot be blank" if normalized.empty?

      normalized
    end

    def url_like?(value)
      value.match?(URL_PATTERN)
    end

    def provider_like?(value)
      value.include?(".") || value.include?(":") || value == "localhost"
    end
  end
end
