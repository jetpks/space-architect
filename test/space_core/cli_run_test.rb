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
