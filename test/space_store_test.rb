# frozen_string_literal: true

require_relative "test_helper"

class SpaceStoreTest < SpaceArchitectTest
  def test_create_space_with_date_prefixed_unique_id_and_structure
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    space = store.create("Name of Space")
    duplicate = store.create("Name of Space")

    assert_equal "20260531-name-of-space", space.id
    assert_equal "20260531-name-of-space-2", duplicate.id
    assert_nil store.state.current_space
    assert_equal ["20260531-name-of-space-2", "20260531-name-of-space"], store.state.recent

    assert_path_exists space.path.join(".space.yml")
    assert_path_exists space.path.join("README.md")
    assert_path_exists space.path.join("repos")
    assert_path_exists space.path.join("notes")
    assert_path_exists space.path.join("artifacts")
    assert_path_exists space.path.join("tmp")
    assert_path_exists space.path.join(".git")
    assert_equal "repos/\ntmp/\n", space.path.join(".gitignore").read
    assert_includes space.path.join("README.md").read, "## Organization"
    assert_includes space.path.join("README.md").read, "`repos/` contains cloned Git repositories"
    assert_includes space.path.join("README.md").read, "Use it instead of `/tmp` or"

    metadata = YAML.safe_load(space.path.join(".space.yml").read, aliases: false)
    assert_equal "Name of Space", metadata.fetch("title")
    assert_equal "active", metadata.fetch("status")
    assert_equal [], metadata.fetch("repos")
    assert_equal [], metadata.fetch("notes")
    assert_equal [], metadata.fetch("tickets")
    assert_equal [], metadata.fetch("tags")
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_create_makes_an_initial_commit_with_a_git_identity
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    space = with_env(
      "GIT_AUTHOR_NAME" => "Space Cadet",
      "GIT_AUTHOR_EMAIL" => "cadet@example.com",
      "GIT_COMMITTER_NAME" => "Space Cadet",
      "GIT_COMMITTER_EMAIL" => "cadet@example.com"
    ) { store.create("Committed Space") }

    head = system("git", "-C", space.path.to_s, "rev-parse", "--verify", "HEAD",
                  out: File::NULL, err: File::NULL)
    assert head, "expected an initial commit on HEAD"
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_create_with_git_false_skips_repository
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    space = store.create("No Git Space", git: false)

    refute_path_exists space.path.join(".git")
    refute_path_exists space.path.join(".gitignore")
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_list_sorts_by_date_prefixed_id
    setup = temp_env
    times = [
      Time.new(2026, 6, 2, 9, 0, 0, "-06:00"),
      Time.new(2026, 5, 31, 9, 0, 0, "-06:00"),
      Time.new(2026, 6, 1, 9, 0, 0, "-06:00")
    ]
    store = build_store(env: setup.fetch(:env), now: -> { times.shift })

    store.create("Third")
    store.create("First")
    store.create("Second")

    assert_equal [
      "20260531-first",
      "20260601-second",
      "20260602-third"
    ], store.list.map(&:id)
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_find_supports_exact_suffix_prefix_and_ambiguous_matches
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    first = store.create("Name of Space")
    store.create("Other Work")

    assert_equal first.id, store.find("20260531-name-of-space").id
    assert_equal first.id, store.find("name-of-space").id
    assert_equal first.id, store.find("20260531-name").id

    assert_raises(SpaceArchitect::AmbiguousSpaceError) { store.find("20260531") }
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_find_without_identifier_uses_nearest_space_from_pwd_and_ignores_state
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    first = store.create("First Space")
    second = store.create("Second Space")
    store.state.touch_current(second.id)
    nested = first.path.join("repos", "example")
    FileUtils.mkdir_p(nested)

    assert_equal first.id, store.find(nil, from: nested).id
    assert_equal first.id, store.current(from: nested).id
    assert_nil store.current_from_pwd(from: setup.fetch(:root))
    assert_raises(SpaceArchitect::CurrentSpaceMissingError) { store.find(nil, from: setup.fetch(:root)) }
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_status_validation_and_update
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Name of Space")

    space.update_status("done", now: fixed_time)
    reloaded = SpaceArchitect::Space.load(space.path)

    assert_equal "done", reloaded.status
    assert_raises(SpaceArchitect::InvalidStatusError) { reloaded.update_status("unknown") }
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_add_repos_limits_concurrent_clones
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Concurrent Clones")
    git_client = TrackingGitClient.new
    mise_client = TrackingMiseClient.new

    results = store.add_repos_to(
      space,
      (1..6).map { |index| "example-tools/repo-#{index}" },
      git_client: git_client,
      mise_client: mise_client
    )

    assert_equal 6, results.length
    assert_equal SpaceArchitect::SpaceStore::MAX_CONCURRENT_CLONES, git_client.max_active
    assert_operator git_client.clone_count, :>, git_client.max_active
    assert_equal 6, mise_client.trust_count
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_add_repos_prefers_evergreen_copy_and_falls_back_to_clone
    setup = temp_env
    evergreen = Pathname.new(setup.fetch(:root)).join("evergreen")
    FileUtils.mkdir_p(evergreen.join("github.com", "example-tools", "present", ".git"))

    config = SpaceArchitect::Config.new(
      env: setup.fetch(:env),
      data: { "version" => 1, "spaces_dir" => "~/src/spaces", "evergreen_dir" => evergreen.to_s }
    )
    state = SpaceArchitect::State.new(env: setup.fetch(:env))
    store = SpaceArchitect::SpaceStore.new(config: config, state: state, now: -> { fixed_time })
    space = store.create("Evergreen")
    git_client = TrackingGitClient.new

    store.add_repos_to(
      space,
      ["example-tools/present", "example-tools/absent"],
      git_client: git_client,
      mise_client: TrackingMiseClient.new
    )

    assert_equal [evergreen.join("github.com", "example-tools", "present").to_s], git_client.copied_sources
    assert_equal ["git@github.com:example-tools/absent.git"], git_client.cloned_urls
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_failing_clone_raises_clean_git_error_without_async_noise
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Fail Space", git: false)

    old_stderr = $stderr
    captured = StringIO.new
    $stderr = captured

    error = assert_raises(SpaceArchitect::GitError) do
      store.add_repos_to(space, ["example-tools/bad"],
                         git_client: FailingGitClient.new,
                         mise_client: TrackingMiseClient.new)
    end

    $stderr = old_stderr
    assert_match(/clone failed/, error.message)
    refute_match(/Task may have ended with unhandled exception/, captured.string)
    refute_match(/"severity":"warn"/, captured.string)
  ensure
    $stderr = old_stderr if old_stderr
    FileUtils.rm_rf(setup[:root]) if setup
  end

  class FailingGitClient
    def clone(url, _path)
      raise SpaceArchitect::GitError, "git clone failed for #{url}"
    end

    def copy(_source, _path)
      raise SpaceArchitect::GitError, "copy failed"
    end
  end

  class TrackingGitClient
    attr_reader :max_active, :clone_count, :cloned_urls, :copied_sources

    def initialize
      @active = 0
      @max_active = 0
      @clone_count = 0
      @cloned_urls = []
      @copied_sources = []
    end

    def clone(url, path)
      @active += 1
      @clone_count += 1
      @cloned_urls << url
      @max_active = [max_active, @active].max
      sleep 0.01
      FileUtils.mkdir_p(Pathname.new(path).join(".git"))
    ensure
      @active -= 1
    end

    def copy(source, path)
      @copied_sources << source.to_s
      FileUtils.mkdir_p(Pathname.new(path).join(".git"))
    end
  end

  class TrackingMiseClient
    attr_reader :trust_count

    def initialize
      @trust_count = 0
    end

    def trust(_path)
      @trust_count += 1
    end
  end
end
