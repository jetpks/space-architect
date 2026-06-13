# frozen_string_literal: true

require_relative "test_helper"

class CLIConfigTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  RepoTenderCLI = RepoTender::CLI

  # ---- G6: `config path` / `config show` ----

  def test_config_path_prints_resolved_config_file_path
    with_cli_env do |env, _home|
      out, _err = invoke_command(RepoTenderCLI::ConfigCmd::Path)
      assert_equal 0, RepoTenderCLI.last_outcome.exit_code
      expected = File.join(env["XDG_CONFIG_HOME"], "repo-tender", "config.yaml")
      assert_equal expected, out.string.chomp
    end
  end

  def test_config_show_prints_effective_config_with_defaults_applied
    with_cli_env do |_env, _home|
      out, _err = invoke_command(RepoTenderCLI::ConfigCmd::Show)
      assert_equal 0, RepoTenderCLI.last_outcome.exit_code
      # For an empty/absent config file, defaults are applied.
      # The store's default is concurrency: 8, refresh_interval:
      # 21600, base_dir: ~/src/evergreen. These must all appear.
      assert_includes out.string, "concurrency: 8"
      assert_includes out.string, "refresh_interval: 21600"
      assert_includes out.string, "src/evergreen"
    end
  end

  def test_config_show_displays_user_overrides
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      File.write(paths.config_file, <<~YAML)
        base_dir: /tmp/my-evergreen
        refresh_interval: 1800
        concurrency: 2
        repos: []
        orgs: []
      YAML

      out, _err = invoke_command(RepoTenderCLI::ConfigCmd::Show)
      assert_equal 0, RepoTenderCLI.last_outcome.exit_code
      # The base_dir value gets YAML-quoted because the path
      # contains characters YAML may want to escape; check for
      # the value's presence rather than the exact format.
      assert_includes out.string, "/tmp/my-evergreen"
      assert_includes out.string, "refresh_interval: 1800"
      assert_includes out.string, "concurrency: 2"
    end
  end

  def test_config_show_human_duration_normalizes_for_display
    # G8 integration proof via the CLI: a config.yaml with
    # `refresh_interval: 6h` must show as `refresh_interval: 21600`
    # in `config show` output.
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      File.write(paths.config_file, <<~YAML)
        refresh_interval: 6h
      YAML

      out, _err = invoke_command(RepoTenderCLI::ConfigCmd::Show)
      assert_equal 0, RepoTenderCLI.last_outcome.exit_code
      assert_includes out.string, "refresh_interval: 21600"
    end
  end

  def test_config_path_subprocess
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["config", "path"])
      assert status.success?
      expected = File.join(env["XDG_CONFIG_HOME"], "repo-tender", "config.yaml")
      assert_includes stdout, expected
    end
  end

  def test_config_show_subprocess_displays_defaults
    with_cli_env do |env, _home|
      stdout, _stderr, status = run_cli_subprocess(env: env, args: ["config", "show"])
      assert status.success?
      assert_includes stdout, "concurrency: 8"
      assert_includes stdout, "refresh_interval: 21600"
    end
  end
end
