# frozen_string_literal: true

require_relative "test_helper"

class CLITest < SpaceCadetTest
  def test_init_creates_xdg_files_and_default_spaces_dir
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      out, err = capture_io { SpaceCadet::CLI.start(["init"]) }

      assert_empty err
      assert_match(/Config:/, out)
      assert_path_exists File.join(env["XDG_CONFIG_HOME"], "space-cadet", "config.yml")
      assert_path_exists File.join(env["XDG_STATE_HOME"], "space-cadet", "state.yml")
      assert_path_exists File.join(env["HOME"], "src", "spaces")
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_core_cli_lifecycle
    setup = temp_env
    env = setup.fetch(:env)
    space_id = nil
    space_path = nil

    with_env(env) do
      capture_io { SpaceCadet::CLI.start(["init"]) }
      out, err = capture_io { SpaceCadet::CLI.start(["new", "Name of Space"]) }

      assert_empty err
      assert_match(/Created \d{8}-name-of-space/, out)
      space_id = out[/Created (\d{8}-name-of-space)/, 1]
      space_path = File.join(env["HOME"], "src", "spaces", space_id)
      assert_path_exists space_path

      out, = capture_io { SpaceCadet::CLI.start(["list"]) }
      list_date = "#{space_id[0, 4]}-#{space_id[4, 2]}-#{space_id[6, 2]}"
      assert_match(/Status {3,}Date {3,}Title {3,}Path/, out)
      refute_match(/Status {3,}ID\b/, out)
      assert_match(list_date, out)
      assert_match("Name of Space", out)
      assert_match("~/src/spaces/#{space_id}", out)
      refute_match(env["HOME"], out)
      refute_match(/\e\[/, out)

      Dir.chdir(space_path) do
        out, = capture_io { SpaceCadet::CLI.start(["path"]) }
        assert_equal "~/src/spaces/#{space_id}\n", out

        out, = capture_io { SpaceCadet::CLI.start(["show"]) }
        assert_match("ID:         #{space_id}", out)
        assert_match("Status:     active", out)

        out, = capture_io { SpaceCadet::CLI.start(["status", "done"]) }
        assert_match(/#{space_id} is done/, out)

        out, = capture_io { SpaceCadet::CLI.start(["current"]) }
        assert_match(space_id, out)
        assert_match("~/src/spaces/#{space_id}", out)
      end

      out, = capture_io { SpaceCadet::CLI.start(["show", "name-of-space"]) }
      assert_match("ID:         #{space_id}", out)
      assert_match("Status:     done", out)

      out, = capture_io { SpaceCadet::CLI.start(["use", "name-of-space"]) }
      assert_match(/Recent space: #{space_id}/, out)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_pwd_current_space_wins_over_recent_or_used_space
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      capture_io { SpaceCadet::CLI.start(["init"]) }
      first_out, = capture_io { SpaceCadet::CLI.start(["new", "Foo"]) }
      second_out, = capture_io { SpaceCadet::CLI.start(["new", "Qux"]) }
      first_id = first_out[/Created (\d{8}-foo)/, 1]
      second_id = second_out[/Created (\d{8}-qux)/, 1]
      first_path = File.join(env["HOME"], "src", "spaces", first_id)
      FileUtils.mkdir_p(File.join(first_path, "repos", "example"))

      capture_io { SpaceCadet::CLI.start(["use", second_id]) }

      Dir.chdir(File.join(first_path, "repos", "example")) do
        out, = capture_io { SpaceCadet::CLI.start(["current"]) }
        assert_match(first_id, out)
        refute_match(second_id, out)
      end
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_color_options_can_force_or_disable_colors
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      capture_io { SpaceCadet::CLI.start(["init"]) }
      capture_io { SpaceCadet::CLI.start(["new", "Color Test"]) }

      out, = capture_io { SpaceCadet::CLI.start(["list", "--color=always"]) }
      assert_match(/\e\[/, out)
      assert_match(/\e\[32mactive\e\[0m/, out)
      assert_match(/\e\[36m~\/src\/spaces\/\d{8}-color-test\e\[0m/, out)

      out, = capture_io { SpaceCadet::CLI.start(["--colors=never", "list"]) }
      refute_match(/\e\[/, out)
      assert_match(/Status {3,}Date {3,}Title {3,}Path/, out)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_shell_init_fish_prints_cd_wrapper
    out, err = capture_io { SpaceCadet::CLI.start(["shell", "init", "fish"]) }

    assert_empty err
    assert_match(/function space --wraps space/, out)
    assert_match(/case new use/, out)
    assert_match(/string replace -r "\^~\(\?=\/\|\\\$\)" \$HOME/, out)
    assert_match(/cd "\$__space_target"/, out)
    assert_match(/case "\*"\n\s+command space \$__space_args/, out)
  end

  def test_fish_install_writes_autoload_function
    setup = temp_env
    env = setup.fetch(:env)
    function_path = File.join(env["XDG_CONFIG_HOME"], "fish", "functions", "space.fish")
    completions_path = File.join(env["XDG_CONFIG_HOME"], "fish", "completions", "space.fish")

    with_env(env) do
      out, err = capture_io { SpaceCadet::CLI.start(["shell", "fish", "install"]) }

      assert_empty err
      assert_match("Installed fish integration: #{function_path}", out)
      assert_match("Installed fish completions: #{completions_path}", out)
      assert_match("Restart fish to load the integration in this terminal: exec fish", out)
      assert_path_exists function_path
      assert_path_exists completions_path
      assert_match(/function space --wraps space/, File.read(function_path))
      assert_match(/complete -c space/, File.read(completions_path))
      assert_match(/-s r -l repo/, File.read(completions_path))
      assert_match(/__space_cadet_complete_spaces/, File.read(completions_path))

      out, = capture_io { SpaceCadet::CLI.start(["shell", "fish", "install"]) }
      assert_match("Fish integration already installed: #{function_path}", out)
      assert_match("Fish completions already installed: #{completions_path}", out)

      out, = capture_io { SpaceCadet::CLI.start(["shell", "fish", "uninstall"]) }
      assert_match("Removed fish integration: #{function_path}", out)
      assert_match("Removed fish completions: #{completions_path}", out)
      refute_path_exists function_path
      refute_path_exists completions_path
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_fish_install_refuses_to_overwrite_existing_function
    setup = temp_env
    env = setup.fetch(:env)
    function_path = File.join(env["XDG_CONFIG_HOME"], "fish", "functions", "space.fish")
    FileUtils.mkdir_p(File.dirname(function_path))
    File.write(function_path, "function space\n    echo custom\nend\n")

    with_env(env) do
      error = assert_raises(SpaceCadet::Error) do
        SpaceCadet::ShellIntegration.install("fish", env: env)
      end
      assert_match(/Refusing to overwrite existing fish function/, error.message)

      out, = capture_io { SpaceCadet::CLI.start(["shell", "fish", "install", "--force"]) }
      assert_match(/(?:Installed|Updated) fish integration: #{Regexp.escape(function_path)}/, out)
      assert_match(/function space --wraps space/, File.read(function_path))
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_config_set_updates_repo_defaults
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      out, err = capture_io { SpaceCadet::CLI.start(["config", "set", "default_organization", "example-org"]) }

      assert_empty err
      assert_match("Set default_organization=example-org", out)

      out, = capture_io { SpaceCadet::CLI.start(["config", "show"]) }
      assert_match(/default_provider {3,}github\.com/, out)
      assert_match(/default_organization {3,}example-org/, out)

      config = YAML.safe_load(File.read(File.join(env["XDG_CONFIG_HOME"], "space-cadet", "config.yml")), aliases: false)
      assert_equal "example-org", config.fetch("default_organization")
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_repo_add_clones_resolved_repo_into_current_space_and_tracks_metadata
    setup = temp_env
    env = setup.fetch(:env)
    install_fake_git(setup)
    space_path = nil

    with_env(env.merge("PATH" => "#{setup.fetch(:git_bin)}:#{ENV.fetch('PATH')}",
                       "PROJECT_SPACES_GIT_LOG" => setup.fetch(:git_log),
                       "PROJECT_SPACES_MISE_LOG" => setup.fetch(:mise_log))) do
      capture_io { SpaceCadet::CLI.start(["config", "set", "default_organization", "example-org"]) }
      out, = capture_io { SpaceCadet::CLI.start(["new", "Repo Space"]) }
      space_id = out[/Created (\d{8}-repo-space)/, 1]
      space_path = File.join(env["HOME"], "src", "spaces", space_id)
      real_space_path = File.realpath(space_path)

      Dir.chdir(space_path) do
        out, err = capture_io { SpaceCadet::CLI.start(["repo", "add", "example-app"]) }

        assert_empty err
        assert_match("Added github.com/example-org/example-app", out)
        assert_match("~/src/spaces/#{space_id}/repos/example-app", out)
        assert_path_exists File.join(space_path, "repos", "example-app", ".git")

        assert_equal(
          "clone git@github.com:example-org/example-app.git #{File.join(real_space_path, 'repos', 'example-app')}",
          File.read(setup.fetch(:git_log)).strip
        )
        assert_equal(
          "trust --yes --quiet --cd #{File.join(real_space_path, 'repos', 'example-app')}",
          File.read(setup.fetch(:mise_log)).strip
        )

        metadata = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        repo = metadata.fetch("repos").first
        assert_equal "github.com/example-org/example-app", repo.fetch("full_name")
        assert_equal "repos/example-app", repo.fetch("path")
        assert_equal "git@github.com:example-org/example-app.git", repo.fetch("clone_url")

        out, = capture_io { SpaceCadet::CLI.start(["repo", "list"]) }
        assert_match(/Repo {3,}Path/, out)
        assert_match("github.com/example-org/example-app", out)
        assert_match("repos/example-app", out)
      end
    end
  ensure
    Dir.chdir("/") if space_path && Dir.pwd.start_with?(space_path)
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_repo_resolve_uses_default_provider_without_cloning
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      out, err = capture_io { SpaceCadet::CLI.start(["repo", "resolve", "example-tools/async", "gitlab.com/example-org/api"]) }

      assert_empty err
      assert_match(/Repo {3,}Clone URL/, out)
      assert_match("github.com/example-tools/async", out)
      assert_match("git@github.com:example-tools/async.git", out)
      assert_match("gitlab.com/example-org/api", out)
      assert_match("git@gitlab.com:example-org/api.git", out)
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_complete_prints_dynamic_completion_candidates
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      out, = capture_io { SpaceCadet::CLI.start(["new", "Completion Space"]) }
      space_id = out[/Created (\d{8}-completion-space)/, 1]

      out, err = capture_io { SpaceCadet::CLI.start(["shell", "complete", "spaces"]) }

      assert_empty err
      assert_includes out, "#{space_id}\tCompletion Space"

      out, = capture_io { SpaceCadet::CLI.start(["shell", "complete", "statuses"]) }
      assert_includes out, "active"
      assert_includes out, "archived"

      out, = capture_io { SpaceCadet::CLI.start(["shell", "complete", "config-keys"]) }
      assert_includes out, "default_provider"

      out, = capture_io { SpaceCadet::CLI.start(["shell", "complete", "config-values", "git_clone_protocol"]) }
      assert_includes out, "ssh"
      assert_includes out, "https"
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_repo_add_accepts_multiple_repos
    setup = temp_env
    env = setup.fetch(:env)
    install_fake_git(setup)
    space_path = nil

    with_env(env.merge("PATH" => "#{setup.fetch(:git_bin)}:#{ENV.fetch('PATH')}",
                       "PROJECT_SPACES_GIT_LOG" => setup.fetch(:git_log),
                       "PROJECT_SPACES_MISE_LOG" => setup.fetch(:mise_log))) do
      out, = capture_io { SpaceCadet::CLI.start(["new", "Multi Repo Space"]) }
      space_id = out[/Created (\d{8}-multi-repo-space)/, 1]
      space_path = File.join(env["HOME"], "src", "spaces", space_id)
      real_space_path = File.realpath(space_path)

      Dir.chdir(space_path) do
        out, err = capture_io do
          SpaceCadet::CLI.start(["repo", "add", "example-tools/alpha", "example-tools/beta"])
        end

        assert_empty err
        assert_match("Added github.com/example-tools/alpha", out)
        assert_match("Added github.com/example-tools/beta", out)
        assert_path_exists File.join(space_path, "repos", "alpha", ".git")
        assert_path_exists File.join(space_path, "repos", "beta", ".git")

        assert_equal [
          "clone git@github.com:example-tools/alpha.git #{File.join(real_space_path, 'repos', 'alpha')}",
          "clone git@github.com:example-tools/beta.git #{File.join(real_space_path, 'repos', 'beta')}"
        ], File.read(setup.fetch(:git_log)).split("\n").sort
        assert_equal [
          "trust --yes --quiet --cd #{File.join(real_space_path, 'repos', 'alpha')}",
          "trust --yes --quiet --cd #{File.join(real_space_path, 'repos', 'beta')}"
        ], File.read(setup.fetch(:mise_log)).split("\n").sort

        metadata = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
        assert_equal [
          "github.com/example-tools/alpha",
          "github.com/example-tools/beta"
        ], metadata.fetch("repos").map { |repo| repo.fetch("full_name") }
      end
    end
  ensure
    Dir.chdir("/") if space_path && Dir.pwd.start_with?(space_path)
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_new_accepts_repeatable_repo_options
    setup = temp_env
    env = setup.fetch(:env)
    install_fake_git(setup)

    with_env(env.merge("PATH" => "#{setup.fetch(:git_bin)}:#{ENV.fetch('PATH')}",
                       "PROJECT_SPACES_GIT_LOG" => setup.fetch(:git_log),
                       "PROJECT_SPACES_MISE_LOG" => setup.fetch(:mise_log))) do
      out, err = capture_io do
        SpaceCadet::CLI.start(["new", "New Repo Space", "-r", "example-tools/alpha", "--repo", "example-tools/beta"])
      end

      assert_empty err
      space_id = out[/Created (\d{8}-new-repo-space)/, 1]
      space_path = File.join(env["HOME"], "src", "spaces", space_id)

      assert_match("Queued example-tools/alpha", out)
      assert_match("Queued example-tools/beta", out)
      assert_match("Added github.com/example-tools/alpha", out)
      assert_match("Added github.com/example-tools/beta", out)
      assert_equal "~/src/spaces/#{space_id}", out.lines.last.chomp
      assert_path_exists File.join(space_path, "repos", "alpha", ".git")
      assert_path_exists File.join(space_path, "repos", "beta", ".git")

      assert_equal [
        "clone git@github.com:example-tools/alpha.git #{File.join(space_path, 'repos', 'alpha')}",
        "clone git@github.com:example-tools/beta.git #{File.join(space_path, 'repos', 'beta')}"
      ], File.read(setup.fetch(:git_log)).split("\n").sort
      assert_equal [
        "trust --yes --quiet --cd #{File.join(space_path, 'repos', 'alpha')}",
        "trust --yes --quiet --cd #{File.join(space_path, 'repos', 'beta')}"
      ], File.read(setup.fetch(:mise_log)).split("\n").sort

      metadata = YAML.safe_load(File.read(File.join(space_path, ".space.yml")), aliases: false)
      assert_equal [
        "github.com/example-tools/alpha",
        "github.com/example-tools/beta"
      ], metadata.fetch("repos").map { |repo| repo.fetch("full_name") }
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_new_initializes_git_repository_by_default
    setup = temp_env
    env = setup.fetch(:env)
    install_fake_git(setup)

    with_env(env.merge("PATH" => "#{setup.fetch(:git_bin)}:#{ENV.fetch('PATH')}",
                       "PROJECT_SPACES_GIT_LOG" => setup.fetch(:git_log))) do
      out, = capture_io { SpaceCadet::CLI.start(["new", "Git Space"]) }

      space_id = out[/Created (\d{8}-git-space)/, 1]
      space_path = File.join(env["HOME"], "src", "spaces", space_id)
      assert_path_exists File.join(space_path, ".git")
      assert_equal "repos/\ntmp/\n", File.read(File.join(space_path, ".gitignore"))
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  def test_new_no_git_skips_repository
    setup = temp_env
    env = setup.fetch(:env)

    with_env(env) do
      out, = capture_io { SpaceCadet::CLI.start(["new", "Plain Space", "--no-git"]) }

      space_id = out[/Created (\d{8}-plain-space)/, 1]
      space_path = File.join(env["HOME"], "src", "spaces", space_id)
      refute_path_exists File.join(space_path, ".git")
      refute_path_exists File.join(space_path, ".gitignore")
    end
  ensure
    FileUtils.rm_rf(setup[:root]) if setup
  end

  private

  def install_fake_git(setup)
    git_bin = File.join(setup.fetch(:root), "bin")
    git_log = File.join(setup.fetch(:root), "git.log")
    FileUtils.mkdir_p(git_bin)
    File.write(File.join(git_bin, "git"), <<~SH)
      #!/bin/sh
      if [ "$1" = "clone" ]; then
        dest=""
        for arg in "$@"; do
          dest="$arg"
        done
        printf "%s\\n" "$*" >> "$PROJECT_SPACES_GIT_LOG"
        mkdir -p "$dest/.git"
        exit 0
      fi

      # Space self-init (git -C <dir> init/add/commit). Succeed without logging
      # so clone-log assertions stay focused on repo clones.
      if [ "$1" = "-C" ]; then
        case "$3" in
          init) mkdir -p "$2/.git"; exit 0 ;;
          add|commit) exit 0 ;;
        esac
      fi

      echo "unexpected git command: $*" >&2
      exit 1
    SH
    FileUtils.chmod("+x", File.join(git_bin, "git"))
    File.write(File.join(git_bin, "mise"), <<~SH)
      #!/bin/sh
      if [ "$1" = "trust" ]; then
        if [ -n "$PROJECT_SPACES_MISE_LOG" ]; then
          printf "%s\\n" "$*" >> "$PROJECT_SPACES_MISE_LOG"
        fi
        exit 0
      fi

      echo "unexpected mise command: $*" >&2
      exit 1
    SH
    FileUtils.chmod("+x", File.join(git_bin, "mise"))

    setup[:git_bin] = git_bin
    setup[:git_log] = git_log
    setup[:mise_log] = File.join(setup.fetch(:root), "mise.log")
  end
end
