# frozen_string_literal: true

require_relative "../test_helper"

class OciRunnerTest < Space::ArchitectTest
  def space_with(data, path = "/tmp/fake-space")
    Space::Core::Space.new(path, data)
  end

  def test_image_returns_space_id_colon_latest
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space)

    assert_equal "20260630-test:latest", runner.image
  end

  def test_command_minimal_no_env_no_persist_non_interactive
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)
    result = runner.command([])

    assert result.success?
    assert_equal ["container", "run", "--rm", "20260630-test:latest"], result.value!
  end

  def test_command_includes_interactive_flags_when_interactive_true
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: true)

    argv = runner.command([]).value!

    assert_equal "-i", argv[3]
    assert_equal "-t", argv[4]
  end

  def test_command_omits_interactive_flags_when_interactive_false
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)

    argv = runner.command([]).value!

    refute_includes argv, "-i"
    refute_includes argv, "-t"
  end

  def test_command_includes_bare_auth_flag_for_present_env_var
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(
      space: space,
      env: { "ANTHROPIC_API_KEY" => "sk-ant-supersecret" },
      interactive: false
    )

    argv = runner.command([]).value!
    idx = argv.index("-e")

    assert idx, "expected -e flag"
    assert_equal "ANTHROPIC_API_KEY", argv[idx + 1]
    refute_match(/=/, argv[idx + 1], "must be bare key, no =value on the command line")
  end

  def test_command_omits_auth_flag_for_absent_env_var
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)

    refute_includes runner.command([]).value!, "-e"
  end

  def test_command_omits_auth_flag_for_empty_env_var
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(
      space: space,
      env: { "ANTHROPIC_API_KEY" => "" },
      interactive: false
    )

    refute_includes runner.command([]).value!, "-e"
  end

  def test_command_includes_all_three_auth_vars_when_all_present
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(
      space: space,
      env: {
        "ANTHROPIC_API_KEY"       => "sk-ant-key",
        "CLAUDE_CODE_OAUTH_TOKEN" => "oauth-tok",
        "ANTHROPIC_BASE_URL"      => "https://proxy.example.com"
      },
      interactive: false
    )

    argv = runner.command([]).value!
    e_indices = argv.each_index.select { |i| argv[i] == "-e" }

    assert_equal 3, e_indices.size
    assert_includes argv, "ANTHROPIC_API_KEY"
    assert_includes argv, "CLAUDE_CODE_OAUTH_TOKEN"
    assert_includes argv, "ANTHROPIC_BASE_URL"
  end

  def test_command_includes_volume_mount_for_persist_path
    dir = Dir.mktmpdir
    space = space_with(
      { "id" => "20260630-test", "title" => "Test", "pack" => { "persist" => ["/root/.hermes"] } },
      dir
    )
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)

    argv = runner.command([]).value!
    v_idx = argv.index("-v")
    expected_host = Pathname.new(dir).join(".state/root/.hermes").to_s

    assert v_idx, "expected -v flag"
    assert_equal "#{expected_host}:/root/.hermes", argv[v_idx + 1]
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_command_omits_volume_flags_when_no_persist_paths
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)

    refute_includes runner.command([]).value!, "-v"
  end

  def test_command_returns_failure_for_relative_persist_path
    space = space_with(
      { "id" => "20260630-test", "title" => "Test", "pack" => { "persist" => ["relative/path"] } }
    )
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)
    result = runner.command([])

    assert result.failure?
    assert_equal "persist path 'relative/path' must be an absolute path", result.failure
  end

  def test_command_appends_extra_args_after_image
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)

    argv = runner.command(["bash", "-lc", "whoami"]).value!

    assert_equal ["bash", "-lc", "whoami"], argv.last(3)
    assert_equal "20260630-test:latest", argv[-4]
  end

  def test_host_dirs_returns_absolute_state_paths
    dir = Dir.mktmpdir
    space = space_with(
      { "id" => "20260630-test", "title" => "Test", "pack" => { "persist" => ["/root/.hermes"] } },
      dir
    )
    runner = Space::Core::OciRunner.new(space: space)

    assert_equal [Pathname.new(dir).join(".state/root/.hermes")], runner.host_dirs
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_host_dirs_empty_when_no_persist_paths
    space = space_with("id" => "20260630-test", "title" => "Test")
    runner = Space::Core::OciRunner.new(space: space)

    assert_equal [], runner.host_dirs
  end

  # AC2 full-argv proof: persist + ANTHROPIC_API_KEY + interactive
  def test_full_argv_with_persist_and_auth_interactive
    dir = Dir.mktmpdir
    space = space_with(
      { "id" => "20260630-hermes", "title" => "Hermes",
        "pack" => { "persist" => ["/root/.hermes"] } },
      dir
    )
    runner = Space::Core::OciRunner.new(
      space: space,
      env: { "ANTHROPIC_API_KEY" => "sk-ant-test" },
      interactive: true
    )
    expected_host = Pathname.new(dir).join(".state/root/.hermes").to_s

    assert_equal(
      ["container", "run", "--rm", "-i", "-t",
       "-e", "ANTHROPIC_API_KEY",
       "-v", "#{expected_host}:/root/.hermes",
       "20260630-hermes:latest"],
      runner.command([]).value!
    )
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # AC2 full-argv proof: no persist, empty env, non-interactive
  def test_full_argv_no_persist_no_env_non_interactive
    space = space_with("id" => "20260630-hermes", "title" => "Hermes")
    runner = Space::Core::OciRunner.new(space: space, env: {}, interactive: false)

    assert_equal(
      ["container", "run", "--rm", "20260630-hermes:latest"],
      runner.command([]).value!
    )
  end
end
