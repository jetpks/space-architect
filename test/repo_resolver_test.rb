# frozen_string_literal: true

require_relative "test_helper"

class RepoResolverTest < SpaceArchitectTest
  def test_resolves_bare_repo_with_default_provider_and_organization
    resolver = build_resolver(default_organization: "example-org")

    reference = resolver.resolve("example-app")

    assert_equal "github.com", reference.provider
    assert_equal "example-org", reference.owner
    assert_equal "example-app", reference.name
    assert_equal "github.com/example-org/example-app", reference.full_name
    assert_equal "git@github.com:example-org/example-app.git", reference.clone_url
  end

  def test_resolves_owner_repo_with_default_provider
    resolver = build_resolver(default_organization: "example-org")

    reference = resolver.resolve("example-tools/async")

    assert_equal "github.com", reference.provider
    assert_equal "example-tools", reference.owner
    assert_equal "async", reference.name
    assert_equal "github.com/example-tools/async", reference.full_name
    assert_equal "git@github.com:example-tools/async.git", reference.clone_url
  end

  def test_resolves_provider_owner_repo
    resolver = build_resolver(default_organization: "example-org")

    reference = resolver.resolve("gitlab.com/example-org/api")

    assert_equal "gitlab.com", reference.provider
    assert_equal "example-org", reference.owner
    assert_equal "api", reference.name
    assert_equal "git@gitlab.com:example-org/api.git", reference.clone_url
  end

  def test_resolves_full_clone_urls_without_rewriting_url
    resolver = build_resolver(default_organization: "example-org")

    reference = resolver.resolve("https://gitlab.com/example-org/api.git")

    assert_equal "gitlab.com", reference.provider
    assert_equal "example-org", reference.owner
    assert_equal "api", reference.name
    assert_equal "https://gitlab.com/example-org/api.git", reference.clone_url
  end

  def test_can_generate_https_clone_urls
    resolver = build_resolver(default_organization: "example-org", git_clone_protocol: "https")

    reference = resolver.resolve("example-app")

    assert_equal "https://github.com/example-org/example-app.git", reference.clone_url
  end

  def test_bare_repo_requires_default_organization
    resolver = build_resolver(default_organization: nil)

    error = assert_raises(Space::Core::RepoResolutionError) { resolver.resolve("example-app") }
    assert_match(/default_organization/, error.message)
  end

  private

  def build_resolver(default_organization:, git_clone_protocol: "ssh")
    config = Space::Core::Config.new(
      env: {
        "HOME" => "/tmp/project-spaces-test-home",
        "XDG_CONFIG_HOME" => "/tmp/project-spaces-test-config",
        "XDG_STATE_HOME" => "/tmp/project-spaces-test-state"
      },
      data: {
        "default_provider" => "github.com",
        "default_organization" => default_organization,
        "git_clone_protocol" => git_clone_protocol
      }
    )
    Space::Core::RepoResolver.new(config)
  end
end
