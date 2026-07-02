# frozen_string_literal: true

require_relative "../test_helper"

class CLIBuildTest < Space::ArchitectTest
  def test_build_appears_in_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Core::CLI.call([], out, err)

    assert_match(/\bbuild\b/, out.string, "space --help should list the build command")
  end

  def test_build_appears_in_architect_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Architect::CLI.call(["space"], out, err)

    assert_match(/\bbuild\b/, out.string, "architect space --help should list the build command")
  end

  # Drives Build#call to the exec tail — verifies constant resolution, auto-pack, and argv shape.
  def test_build_autopacks_and_reaches_exec_with_correct_argv
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")
      out, = invoke("space", "new", "Build CLI Test", "--no-git")
      space_id = out[/Created (\d{8}-build-cli-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)

      # Give the space a git repo with a commit so OciBuilder can compute a version
      system("git", "-C", space_path, "init", "-b", "main", out: File::NULL, err: File::NULL)
      system("git", "-C", space_path, "config", "user.email", "test@example.com", out: File::NULL, err: File::NULL)
      system("git", "-C", space_path, "config", "user.name", "Test User", out: File::NULL, err: File::NULL)
      system("git", "-C", space_path, "add", ".", out: File::NULL, err: File::NULL)
      system("git", "-C", space_path, "commit", "-m", "init", out: File::NULL, err: File::NULL)

      argv = Dir.chdir(space_path) do
        intercept_exec { invoke("space", "build") }
      end

      assert argv, "space build must reach Kernel.exec (constant resolves, argv built)"
      assert_equal %w[container build -f], argv.first(3)
      assert_includes argv, "-t"
      assert_includes argv, "#{space_id}:latest"

      dockerfile = File.join(space_path, "build", "oci", "Dockerfile")
      assert File.exist?(dockerfile), "auto-pack must have generated build/oci/Dockerfile"
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  private

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
