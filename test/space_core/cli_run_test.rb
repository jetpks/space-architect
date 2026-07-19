# frozen_string_literal: true

require_relative "../test_helper"

class CLIRunTest < Space::ArchitectTest
  def test_run_appears_in_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Core::CLI.call([], out, err)

    assert_match(/\brun\b/, out.string, "space --help should list the run command")
  end

  def test_run_appears_in_architect_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Architect::CLI.call(["space"], out, err)

    assert_match(/\brun\b/, out.string, "architect space --help should list the run command")
  end

  # `space run --help` must steer users to the `--` separator: a quoted multi-word
  # command arrives as one argv token and fails opaquely in-guest (#28).
  # dry-cli calls exit() for --help, so exercise it via subprocess (same pattern as
  # test_space_status_help_flags_show_help_and_exit_zero in cli_test.rb).
  def test_run_help_steers_to_dashdash_separator
    out = IO.popen(["bundle", "exec", "space", "run", "--help"], err: [:child, :out]) { |f| f.read }
    status = $?.exitstatus

    assert_equal 0, status, "space run --help must exit 0"
    assert_match(/`--`/, out, "run --help should mention the `--` separator")
    assert_match(/^  space run -- /, out, "run --help should show a `--` example in the Examples section")
  end

  # Drives Run#call all the way to the exec tail — the help tests never enter #call,
  # so they cannot catch a command that builds no argv (e.g. an unresolved constant).
  # Kernel.exec is the one irreducible side effect (it replaces the process), so it is
  # intercepted to capture the argv the command would have run.
  def test_run_builds_container_argv_and_reaches_exec
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")
      out, = invoke("space", "new", "Run CLI Test", "--no-git")
      space_id = out[/Created (\d{8}-run-cli-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)

      argv = Dir.chdir(space_path) do
        intercept_exec { invoke("space", "run", "echo", "ok") }
      end

      assert argv, "space run must reach Kernel.exec (constant resolves, argv built)"
      assert_equal %w[container run --rm], argv.first(3)
      assert_includes argv, "#{space_id}:latest"
      assert_equal %w[echo ok], argv.last(2)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  # --env forwards a present host var as a bare `-e VAR` before the image.
  def test_run_forwards_env_flag_into_container_argv
    setup = temp_env

    with_env(setup.fetch(:env).merge("FIREWORKS_API_KEY" => "fw_secret")) do
      invoke("space", "init")
      out, = invoke("space", "new", "Env Flag Test", "--no-git")
      space_id = out[/Created (\d{8}-env-flag-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)

      argv = Dir.chdir(space_path) do
        intercept_exec { invoke("space", "run", "--env", "FIREWORKS_API_KEY", "hermes") }
      end

      assert argv, "space run --env must reach Kernel.exec"
      idx = argv.index("-e")
      assert idx, "expected -e flag in argv"
      assert_equal "FIREWORKS_API_KEY", argv[idx + 1]
      assert_operator idx, :<, argv.index("#{space_id}:latest"), "-e must precede the image"
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  private

  # Replace Kernel.exec for the duration of the block (it would otherwise replace the
  # test process) and return the argv it was called with.
  def intercept_exec
    captured = nil
    singleton = Kernel.singleton_class
    original = Kernel.method(:exec)
    singleton.send(:remove_method, :exec)
    singleton.define_method(:exec) { |*argv| captured = argv; throw :execed }
    catch(:execed) { yield }
    captured
  ensure
    singleton.send(:remove_method, :exec)
    singleton.define_method(:exec, original)
  end
end
