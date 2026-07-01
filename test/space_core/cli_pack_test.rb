# frozen_string_literal: true

require_relative "../test_helper"

class CLIPackTest < Space::ArchitectTest
  def test_pack_appears_in_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Core::CLI.call([], out, err)

    assert_match(/\bpack\b/, out.string, "space --help should list the pack command")
  end

  def test_pack_appears_in_architect_space_help
    out = StringIO.new
    err = StringIO.new
    Space::Architect::CLI.call(["space"], out, err)

    assert_match(/\bpack\b/, out.string, "architect space --help should list the pack command")
  end

  def test_pack_generates_three_files_in_default_location
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")
      out, = invoke("space", "new", "Pack CLI Test", "--no-git")
      space_id = out[/Created (\d{8}-pack-cli-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)

      Dir.chdir(space_path) do
        out, err = invoke("space", "pack")

        assert_empty err
        assert_match(/Generated OCI context/, out)
        assert_path_exists File.join(space_path, "build", "oci", "Dockerfile")
        assert_path_exists File.join(space_path, "build", "oci", "entrypoint.sh")
        assert_path_exists File.join(space_path, "build", "oci", "Dockerfile.dockerignore")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_pack_output_flag_overrides_directory
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")
      out, = invoke("space", "new", "Pack Output Test", "--no-git")
      space_id = out[/Created (\d{8}-pack-output-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)
      custom_out = Dir.mktmpdir("pack-custom-out")

      Dir.chdir(space_path) do
        out, err = invoke("space", "pack", "--output", custom_out)

        assert_empty err
        assert_match(/Generated OCI context/, out)
        assert_match(custom_out, out)
        assert_path_exists File.join(custom_out, "Dockerfile")
        assert_path_exists File.join(custom_out, "entrypoint.sh")
        assert_path_exists File.join(custom_out, "Dockerfile.dockerignore")

        refute_path_exists File.join(space_path, "build", "oci"),
                           "default output dir must not be created when --output is given"
      end
    ensure
      FileUtils.rm_rf(custom_out) if custom_out
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_pack_with_short_flag_o
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")
      out, = invoke("space", "new", "Pack Short Flag Test", "--no-git")
      space_id = out[/Created (\d{8}-pack-short-flag-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)
      custom_out = Dir.mktmpdir("pack-short-flag")

      Dir.chdir(space_path) do
        out, err = invoke("space", "pack", "-o", custom_out)

        assert_empty err
        assert_path_exists File.join(custom_out, "Dockerfile")
      end
    ensure
      FileUtils.rm_rf(custom_out) if custom_out
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_pack_is_pure_generation_no_built_image_artefacts
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")
      out, = invoke("space", "new", "Pack Pure Gen Test", "--no-git")
      space_id = out[/Created (\d{8}-pack-pure-gen-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)

      Dir.chdir(space_path) do
        out, err = invoke("space", "pack")

        assert_empty err
        # Only generated context files are created — no OCI image layers or build cache
        oci_dir = File.join(space_path, "build", "oci")
        assert_equal %w[Dockerfile.dockerignore Dockerfile entrypoint.sh].sort,
                     Dir.children(oci_dir).sort,
                     "only the three generated files should exist in the output dir"
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_architect_space_pack_runs_as_alias
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")
      out, = invoke("space", "new", "Architect Pack Test", "--no-git")
      space_id = out[/Created (\d{8}-architect-pack-test)/, 1]
      space_path = File.join(setup.fetch(:env)["HOME"], "architect", "spaces", space_id)

      Dir.chdir(space_path) do
        out = StringIO.new
        err = StringIO.new
        code = Space::Architect::CLI.call(["space", "pack"], out, err)

        assert_equal 0, code
        assert_match(/Generated OCI context/, out.string)
        assert_path_exists File.join(space_path, "build", "oci", "Dockerfile")
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_pack_fails_gracefully_outside_space
    setup = temp_env

    with_env(setup.fetch(:env)) do
      invoke("space", "init")

      Dir.chdir(setup.fetch(:env)["HOME"]) do
        out, err = invoke("space", "pack")

        assert_match(/No current space/, err + out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end
end
