# frozen_string_literal: true

require_relative "test_helper"

class SpaceStoreTest < SpaceArchitectTest
  def test_create_space_with_date_prefixed_unique_id_and_structure
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    result = store.create("Name of Space")
    duplicate_result = store.create("Name of Space")

    assert result.success?
    assert duplicate_result.success?
    space = result.value!
    duplicate = duplicate_result.value!

    assert_equal "20260531-name-of-space", space.id
    assert_equal "20260531-name-of-space-2", duplicate.id
    assert_nil store.state.current_space
    assert_equal ["20260531-name-of-space-2", "20260531-name-of-space"], store.state.recent

    assert_path_exists space.path.join("space.yaml")
    assert_path_exists space.path.join("README.md")
    assert_path_exists space.path.join("repos")
    assert_path_exists space.path.join("notes")
    assert_path_exists space.path.join("architecture")
    assert_path_exists space.path.join("tmp")
    assert_path_exists space.path.join("build")
    assert_path_exists space.path.join("build", ".keep")
    assert_path_exists space.path.join(".git")
    assert_equal "repos/\ntmp/\nbuild/\n!build/.keep\n", space.path.join(".gitignore").read
    assert_includes space.path.join("README.md").read, "## Organization"
    assert_includes space.path.join("README.md").read, "build/"
    assert_includes space.path.join("README.md").read, "`repos/` contains cloned Git repositories"
    assert_includes space.path.join("README.md").read, "Use it instead of `/tmp` or"

    metadata = YAML.safe_load(space.path.join("space.yaml").read, aliases: false)
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
    ) { store.create("Committed Space") }.value!

    head = system("git", "-C", space.path.to_s, "rev-parse", "--verify", "HEAD",
                  out: File::NULL, err: File::NULL)
    assert head, "expected an initial commit on HEAD"
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_create_with_git_false_skips_repository
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    space = store.create("No Git Space", git: false).value!

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

    first = store.create("Name of Space").value!
    store.create("Other Work")

    assert_equal first.id, store.find("20260531-name-of-space").value!.id
    assert_equal first.id, store.find("name-of-space").value!.id
    assert_equal first.id, store.find("20260531-name").value!.id

    result = store.find("20260531")
    assert result.failure?
    assert_kind_of Space::Core::AmbiguousSpaceError, result.failure
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_find_without_identifier_uses_nearest_space_from_pwd_and_ignores_state
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    first = store.create("First Space").value!
    second = store.create("Second Space").value!
    store.state.touch_current(second.id)
    nested = first.path.join("repos", "example")
    FileUtils.mkdir_p(nested)

    assert_equal first.id, store.find(nil, from: nested).value!.id
    assert_equal first.id, store.current(from: nested).value!.id
    assert store.current_from_pwd(from: setup.fetch(:root)).none?
    result = store.find(nil, from: setup.fetch(:root))
    assert result.failure?
    assert_kind_of Space::Core::CurrentSpaceMissingError, result.failure
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_current_from_pwd_returns_maybe
    setup = temp_env
    store = build_store(env: setup.fetch(:env))

    assert store.current_from_pwd(from: setup.fetch(:root)).none?

    space = store.create("A Space").value!
    result = store.current_from_pwd(from: space.path)
    assert result.some?
    assert_equal space.id, result.value!.id
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_status_validation_and_update
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Name of Space").value!

    space.update_status("done", now: fixed_time)
    reloaded = Space::Core::Space.load(space.path)

    assert_equal "done", reloaded.status
    assert_raises(Space::Core::InvalidStatusError) { reloaded.update_status("unknown") }
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_add_repos_limits_concurrent_clones
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Concurrent Clones").value!
    fake_scm = TrackingSCM.new
    mise_client = TrackingMiseClient.new

    add_result = store.add_repos_to(
      space,
      (1..6).map { |index| "example-tools/repo-#{index}" },
      scm: fake_scm,
      mise_client: mise_client
    )

    assert add_result.success?
    results = add_result.value!
    assert_equal 6, results.length
    assert_equal Space::Core::SpaceStore::MAX_CONCURRENT_CLONES, fake_scm.max_active
    assert_operator fake_scm.clone_count, :>, fake_scm.max_active
    assert_equal 6, mise_client.trust_count
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_add_repos_prefers_evergreen_copy_and_falls_back_to_clone
    setup = temp_env
    evergreen = Pathname.new(setup.fetch(:root)).join("evergreen")
    FileUtils.mkdir_p(evergreen.join("github.com", "example-tools", "present", ".git"))

    config = Space::Core::Config.new(
      env: setup.fetch(:env),
      data: { "version" => 1, "src_dir" => evergreen.to_s }
    )
    state = Space::Core::State.new(env: setup.fetch(:env))
    store = Space::Core::SpaceStore.new(config: config, state: state, now: -> { fixed_time })
    space = store.create("Evergreen").value!
    fake_scm = TrackingSCM.new
    fake_cloner = TrackingCloner.new

    store.add_repos_to(
      space,
      ["example-tools/present", "example-tools/absent"],
      scm: fake_scm,
      cloner: fake_cloner,
      mise_client: TrackingMiseClient.new
    )

    assert_equal 1, fake_cloner.calls.length
    assert_equal "github.com/example-tools/present", fake_cloner.calls.first[:name]
    assert_equal ["git@github.com:example-tools/absent.git"], fake_scm.cloned_urls
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_failing_clone_returns_failure_with_clean_git_error_without_async_noise
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Fail Space", git: false).value!

    old_stderr = $stderr
    captured = StringIO.new
    $stderr = captured

    result = store.add_repos_to(space, ["example-tools/bad"],
                                scm: FailingSCM.new,
                                mise_client: TrackingMiseClient.new)

    $stderr = old_stderr
    assert result.failure?
    assert_kind_of Space::Core::GitError, result.failure
    assert_match(/clone failed/, result.failure.message)
    refute_match(/Task may have ended with unhandled exception/, captured.string)
    refute_match(/"severity":"warn"/, captured.string)
  ensure
    $stderr = old_stderr if old_stderr
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_add_repos_via_real_engine_copies_evergreen_checkout
    setup = temp_env
    evergreen = Pathname.new(setup.fetch(:root)).join("evergreen")
    repo_src = evergreen.join("github.com", "test-owner", "test-repo")
    FileUtils.mkdir_p(repo_src)

    git_env = {
      "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
      "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com"
    }
    system("git", "-C", repo_src.to_s, "init", out: File::NULL, err: File::NULL)
    system(git_env, "git", "-C", repo_src.to_s, "commit", "--allow-empty", "-m", "init",
           out: File::NULL, err: File::NULL)

    config = Space::Core::Config.new(
      env: setup.fetch(:env),
      data: { "version" => 1, "src_dir" => evergreen.to_s }
    )
    state = Space::Core::State.new(env: setup.fetch(:env))
    store = Space::Core::SpaceStore.new(config: config, state: state, now: -> { fixed_time })
    space = store.create("Real Engine Test", git: false).value!

    store.add_repos_to(space, ["test-owner/test-repo"], mise_client: TrackingMiseClient.new)

    assert_path_exists space.path.join("repos", "test-repo", ".git")
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_add_repos_to_returns_failure_on_duplicate_destination
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    space = store.create("Dup Space", git: false).value!

    result = store.add_repos_to(space, ["foo/dup", "foo/dup"],
                                scm: TrackingSCM.new,
                                mise_client: TrackingMiseClient.new)

    assert result.failure?
    assert_kind_of Space::Core::RepoExistsError, result.failure
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_current_returns_failure_on_corrupt_metadata
    setup = temp_env
    store = build_store(env: setup.fetch(:env))
    corrupt_dir = File.join(setup[:root], "corrupt-space")
    FileUtils.mkdir_p(corrupt_dir)
    File.write(File.join(corrupt_dir, Space::Core::Space::METADATA_FILE), "just a string\n")

    result = store.current(from: corrupt_dir)

    assert result.failure?
    assert_kind_of Space::Core::Error, result.failure
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  class FailingSCM
    include Dry::Monads[:result]

    def clone(url, dest)
      Failure({url: url, dest: dest, stderr: "connection refused"})
    end
  end

  class TrackingSCM
    include Dry::Monads[:result]

    attr_reader :max_active, :clone_count, :cloned_urls

    def initialize
      @active = 0
      @max_active = 0
      @clone_count = 0
      @cloned_urls = []
    end

    def clone(url, dest)
      @active += 1
      @clone_count += 1
      @cloned_urls << url
      @max_active = [@max_active, @active].max
      sleep 0.01
      FileUtils.mkdir_p(File.join(dest, ".git"))
      Success(dest)
    ensure
      @active -= 1
    end
  end

  class TrackingCloner
    include Dry::Monads[:result]

    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(name:, into:)
      @calls << {name: name, into: into}
      dest = File.join(into, File.basename(name))
      FileUtils.mkdir_p(File.join(dest, ".git"))
      Success(dest)
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
