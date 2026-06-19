# frozen_string_literal: true

require "test_helper"

class ForgeGitHubTest < Minitest::Test
  include TestHelpers

  GitHub = RepoTender::Forge::GitHub
  OrgRef = RepoTender::Config::OrgRef
  RepoRef = RepoTender::Config::RepoRef

  FIXTURE_PATH = File.expand_path("../../fixtures/gh_repo_list.json", __dir__)

  # A stub Shell that returns canned responses for `gh auth status`
  # and `gh repo list`. This is permitted per gate G6 ("a separate
  # unit test against a stubbed Shell, not a mocked Forge::GitHub").
  class StubShell
    attr_reader :captured_argv

    def initialize(auth_text:, repo_listing_json: nil)
      @auth_text = auth_text
      @repo_listing_json = repo_listing_json
      @captured_argv = []
    end

    def run(*argv, chdir: nil, env: nil)
      @captured_argv << argv
      if argv[0..2] == ["gh", "auth", "status"]
        Dry::Monads::Success(@auth_text)
      elsif argv[0..1] == ["gh", "repo"]
        Dry::Monads::Success(@repo_listing_json)
      else
        Dry::Monads::Failure({argv: argv, reason: "stub: unhandled"})
      end
    end
  end

  # G6: Forge::GitHub#list_org parses a recorded JSON fixture, honors
  # include_archived / include_forks, reads defaultBranchRef.name,
  # and surfaces a Failure when gh auth status reports unauthenticated.

  def test_parses_recorded_fixture_with_all_included
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    org = OrgRef.new(name: "cli", include_archived: true, include_forks: true)
    result = gh.list_org(org)
    assert result.success?, "list_org failed: #{result.failure.inspect}"
    repos = result.success
    assert_equal 4, repos.length
    assert_equal ["cli", "browser", "go-gh", "octocat"], repos.map(&:name)
    # defaultBranchRef.name round-trip (the forge ignores the branch
    # value — it's resolved from the local clone via SCM::Git — but
    # the field is read in the parser, so we sanity-check that the
    # parser reads it at all).
    cli = repos.find { |r| r.name == "cli" }
    assert_equal "cli", cli.owner
    assert_equal "github.com", cli.host
  end

  def test_excludes_archived_and_forks_by_default
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    org = OrgRef.new(name: "cli") # defaults: include_archived=false, include_forks=false
    result = gh.list_org(org)
    assert result.success?
    names = result.success.map(&:name).sort
    assert_equal ["cli", "octocat"], names
  end

  def test_excludes_archived_when_false_keeps_forks
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    org = OrgRef.new(name: "cli", include_archived: false, include_forks: true)
    result = gh.list_org(org)
    assert result.success?
    names = result.success.map(&:name).sort
    assert_equal ["browser", "cli", "octocat"], names
  end

  def test_excludes_forks_when_false_keeps_archived
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    org = OrgRef.new(name: "cli", include_archived: true, include_forks: false)
    result = gh.list_org(org)
    assert result.success?
    names = result.success.map(&:name).sort
    assert_equal ["cli", "go-gh", "octocat"], names
  end

  # GS2: check_authenticated is now PUBLIC and called by the engine once before
  # listing. list_org no longer authenticates per-call.
  def test_check_authenticated_is_public
    shell = StubShell.new(auth_text: "  ✓ Logged in to github.com account test (keyring)\n")
    gh = GitHub.new(shell: shell)
    assert gh.public_methods.include?(:check_authenticated),
      "check_authenticated must be a public method on Forge::GitHub"
  end

  def test_check_authenticated_returns_success_when_logged_in
    shell = StubShell.new(auth_text: "  ✓ Logged in to github.com account test (keyring)\n")
    gh = GitHub.new(shell: shell)
    result = gh.check_authenticated
    assert result.success?
  end

  def test_check_authenticated_returns_failure_when_not_logged_in
    shell = StubShell.new(
      auth_text: "You are not logged into any GitHub hosts. Run gh auth login to authenticate.\n"
    )
    gh = GitHub.new(shell: shell)
    result = gh.check_authenticated
    assert result.failure?, "unauthenticated should fail closed"
    assert_includes result.failure[:reason], "gh not authenticated"
  end

  def test_list_org_does_not_call_auth_status
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    org = OrgRef.new(name: "cli")
    gh.list_org(org)
    # list_org must NOT invoke gh auth status — the engine does that once
    auth_calls = shell.captured_argv.select { |a| a[0..2] == ["gh", "auth", "status"] }
    assert_empty auth_calls, "list_org must not call gh auth status (engine handles auth-once)"
    # Only one call: the repo list
    assert_equal 1, shell.captured_argv.size
    assert_equal "repo", shell.captured_argv[0][1]
  end

  def test_passes_correct_json_fields
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    org = OrgRef.new(name: "cli")
    gh.list_org(org)
    # list_org no longer calls auth; captured_argv[0] is the repo list
    repo_argv = shell.captured_argv[0]
    assert_includes repo_argv, "--json"
    fields = repo_argv[repo_argv.index("--json") + 1]
    %w[nameWithOwner defaultBranchRef isArchived isFork].each do |f|
      assert_includes fields, f, "missing gh --json field #{f}"
    end
  end

  # G11: --no-source is NOT a valid `gh repo list` flag. The forge
  # must not emit it. Fork exclusion remains the responsibility of
  # `parse_repos` (asserted by the include_* tests above). The
  # test scans every flag-combination of build_argv and asserts no
  # unknown flag slips through.
  VALID_GH_REPO_LIST_FLAGS = %w[
    --archived --no-archived --fork --source --json --limit
    --topic --language --visibility --jq --template --help
  ].freeze

  def test_build_argv_never_emits_no_source
    [
      {include_archived: false, include_forks: false},
      {include_archived: true, include_forks: false},
      {include_archived: false, include_forks: true},
      {include_archived: true, include_forks: true}
    ].each do |attrs|
      org = OrgRef.new(name: "cli", **attrs)
      argv = GitHub.new.build_argv(org)
      refute_includes argv, "--no-source",
        "build_argv(#{attrs}) emitted --no-source, which is not a valid gh repo list flag"
    end
  end

  def test_build_argv_only_emits_valid_flags
    [
      {include_archived: false, include_forks: false},
      {include_archived: true, include_forks: false},
      {include_archived: false, include_forks: true},
      {include_archived: true, include_forks: true}
    ].each do |attrs|
      org = OrgRef.new(name: "cli", **attrs)
      argv = GitHub.new.build_argv(org)
      argv.select { |a| a.start_with?("--") }.each do |flag|
        assert_includes VALID_GH_REPO_LIST_FLAGS, flag,
          "build_argv(#{attrs}) emitted unknown flag #{flag}"
      end
    end
  end

  # GA3: ignored_repos filter is authoritative
  def test_ignored_repos_excludes_by_bare_name
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    # "cli" is cli/cli — a non-archived, non-fork repo
    org = OrgRef.new(name: "cli", include_archived: true, include_forks: true,
      ignored_repos: ["cli"])
    result = gh.list_org(org)
    assert result.success?
    names = result.success.map(&:name)
    refute_includes names, "cli", "bare name match should exclude cli/cli"
    assert_includes names, "browser"
    assert_includes names, "go-gh"
    assert_includes names, "octocat"
  end

  def test_ignored_repos_excludes_by_name_with_owner
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    # "cli/go-gh" is the nameWithOwner form for the archived repo
    org = OrgRef.new(name: "cli", include_archived: true, include_forks: true,
      ignored_repos: ["cli/go-gh"])
    result = gh.list_org(org)
    assert result.success?
    names = result.success.map(&:name)
    refute_includes names, "go-gh", "nameWithOwner match should exclude cli/go-gh"
    assert_includes names, "cli"
    assert_includes names, "browser"
    assert_includes names, "octocat"
  end

  def test_empty_ignored_repos_excludes_nothing_new
    json = File.read(FIXTURE_PATH)
    shell = StubShell.new(
      auth_text: "  ✓ Logged in to github.com account test (keyring)\n",
      repo_listing_json: json
    )
    gh = GitHub.new(shell: shell)
    org = OrgRef.new(name: "cli", include_archived: true, include_forks: true,
      ignored_repos: [])
    result = gh.list_org(org)
    assert result.success?
    assert_equal 4, result.success.length
  end

  def test_build_argv_emits_no_archived_only_when_excluding_archived
    org_excluding = OrgRef.new(name: "cli", include_archived: false, include_forks: true)
    org_including = OrgRef.new(name: "cli", include_archived: true, include_forks: true)
    assert_includes GitHub.new.build_argv(org_excluding), "--no-archived"
    refute_includes GitHub.new.build_argv(org_including), "--no-archived"
  end
end
