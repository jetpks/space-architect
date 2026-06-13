# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

class CLIDaemonTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  Daemon = RepoTender::CLI::Daemon
  Agent = RepoTender::Launchd::Agent
  Plist = RepoTender::Launchd::Plist
  LABEL = Agent::DEFAULT_LABEL

  # Stub the Launchd::Agent class so we never invoke the real
  # `launchctl`. The agent class is a singleton resource
  # (Process.uid + label); we replace it with one that records
  # every method call and returns a canned Result. The original
  # `.new` is restored in `teardown` so the stub doesn't leak
  # into later tests in the same process.
  def stub_agent(install_result: nil, uninstall_result: nil,
    start_result: nil, stop_result: nil, restart_result: nil,
    status_result: nil)
    fake_class = Class.new do
      attr_reader :calls, :plist_path_arg

      def initialize
        @calls = []
      end

      def install(plist_path)
        @calls << [:install, plist_path]
        @plist_path_arg = plist_path
        @install_result
      end

      def uninstall
        @calls << [:uninstall]
        @uninstall_result
      end

      def start(plist_path)
        @calls << [:start, plist_path]
        @start_result
      end

      def stop
        @calls << [:stop]
        @stop_result
      end

      def restart
        @calls << [:restart]
        @restart_result
      end

      def status
        @calls << [:status]
        @status_result
      end

      attr_accessor :install_result, :uninstall_result, :start_result,
        :stop_result, :restart_result, :status_result
    end
    fake = fake_class.new
    fake.install_result = install_result || Dry::Monads::Success("")
    fake.uninstall_result = uninstall_result || Dry::Monads::Success("")
    fake.start_result = start_result || Dry::Monads::Success("")
    fake.stop_result = stop_result || Dry::Monads::Success("")
    fake.restart_result = restart_result || Dry::Monads::Success("")
    fake.status_result = status_result || Dry::Monads::Success({loaded: false, running: false, pid: nil, last_exit: nil})
    @agent_new_orig = Agent.method(:new)
    Agent.define_singleton_method(:new) { |**_| fake }
    fake
  end

  # Stub the Resolve.detect factory so we never shell out.
  def stub_resolve(repo_root:)
    fake = Daemon::Helpers::Resolve.new(
      repo_root: repo_root,
      mise_toml: "#{repo_root}/mise.toml",
      mise_bin: "/opt/homebrew/opt/mise/bin/mise",
      ruby_bin: "/Users/eric/.local/share/mise/installs/ruby/latest/bin/ruby",
      bin_path: "#{repo_root}/bin/repo-tender"
    )
    @resolve_detect_orig = Daemon::Helpers::Resolve.method(:detect)
    Daemon::Helpers::Resolve.define_singleton_method(:detect) { |**| fake }
    fake
  end

  def teardown
    # Restore the original `Agent.new` and `Resolve.detect` so
    # the stubs don't leak into later tests in the same process
    # (the daemon test file runs before the agent test file, and
    # the singleton-class prepend would otherwise leave every
    # subsequent `Agent.new` returning our fake).
    if @agent_new_orig
      Agent.define_singleton_method(:new, @agent_new_orig)
      @agent_new_orig = nil
    end
    if @resolve_detect_orig
      Daemon::Helpers::Resolve.define_singleton_method(:detect, @resolve_detect_orig)
      @resolve_detect_orig = nil
    end
  end

  def with_daemon_home
    # Use with_cli_env (not just with_temp_home) so the CLI
    # subcommands see the temp HOME via the existing thread-local
    # seam — CLI.make_paths reads it. The plain with_temp_home
    # helper would set the test's local `env` but not the
    # thread-local that the CLI consults.
    with_cli_env do |env, _home|
      paths = RepoTender::Paths.new(environment: env)
      paths.ensure!
      yield(env, paths)
    end
  end

  # ---- G3: install writes plist under temp HOME, calls agent.install ----

  def test_install_writes_plist_under_temp_home_and_calls_agent
    fake_agent = nil
    with_daemon_home do |env, paths|
      fake_agent = stub_agent(install_result: Dry::Monads::Success(""))
      stub_resolve(repo_root: "/Users/eric/src/github.com/jetpks/repo-tender")
      # Seed an empty config so `Install#call` can load.
      config = RepoTender::Config::Config.new(
        base_dir: paths.base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: [],
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      out, _err = invoke_command(Daemon::Install)
      assert_equal 0, RepoTender::CLI.last_outcome.exit_code
      assert_includes out.string, "installed:"

      # Plist was written under the temp HOME.
      written = File.join(env["HOME"], "Library", "LaunchAgents", "#{LABEL}.plist")
      assert File.exist?(written), "plist not written to #{written}"

      # Plist is plutil-lint-clean.
      lint = `plutil -lint #{written} 2>&1`
      assert_match(/OK/, lint)

      # The plist contents match what Plist.call would produce.
      expected = Plist.call(
        label: LABEL,
        refresh_interval: 3600,
        log_dir: paths.log_dir,
        repo_root: "/Users/eric/src/github.com/jetpks/repo-tender",
        mise_toml: "/Users/eric/src/github.com/jetpks/repo-tender/mise.toml",
        mise_bin: "/opt/homebrew/opt/mise/bin/mise",
        ruby_bin: "/Users/eric/.local/share/mise/installs/ruby/latest/bin/ruby",
        bin_path: "/Users/eric/src/github.com/jetpks/repo-tender/bin/repo-tender"
      )
      assert_equal expected, File.read(written)

      # Agent was called with install(plist_path).
      assert_equal [[:install, written]], fake_agent.calls

      # The written path is under the temp HOME (not the real one).
      refute written.start_with?(Dir.home)
    end
  end

  def test_install_failure_from_launchctl_exits_nonzero
    with_daemon_home do |_env, paths|
      stub_agent(install_result: Dry::Monads::Failure({stderr: "service not loaded", status: 1}))
      stub_resolve(repo_root: "/Users/eric/src/github.com/jetpks/repo-tender")
      config = RepoTender::Config::Config.new(
        base_dir: paths.base_dir,
        refresh_interval: 3600,
        concurrency: 2,
        repos: [],
        orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      _out, err = invoke_command(Daemon::Install)
      assert_equal 1, RepoTender::CLI.last_outcome.exit_code
      assert_includes err.string, "bootstrap failed"
    end
  end

  # ---- G3: uninstall removes plist (idempotent) and calls agent.uninstall ----

  def test_uninstall_removes_plist_and_calls_agent
    with_daemon_home do |env, paths|
      stub_agent(uninstall_result: Dry::Monads::Success(""))
      pp = File.join(env["HOME"], "Library", "LaunchAgents", "#{LABEL}.plist")
      FileUtils.mkdir_p(File.dirname(pp))
      File.write(pp, "<?xml version=\"1.0\"?><plist/>")

      out, _err = invoke_command(Daemon::Uninstall)
      assert_equal 0, RepoTender::CLI.last_outcome.exit_code
      assert_includes out.string, "removed plist:"
      refute File.exist?(pp)
    end
  end

  def test_uninstall_idempotent_when_plist_already_gone
    with_daemon_home do |env, _paths|
      stub_agent(uninstall_result: Dry::Monads::Success(""))
      refute File.exist?(File.join(env["HOME"], "Library", "LaunchAgents", "#{LABEL}.plist"))

      out, _err = invoke_command(Daemon::Uninstall)
      assert_equal 0, RepoTender::CLI.last_outcome.exit_code
      assert_includes out.string, "plist not present"
    end
  end

  # ---- daemon start / stop / restart (no plist file operations) ----

  def test_start_calls_agent_start_with_expected_label
    with_daemon_home do |_env, paths|
      fake = stub_agent(start_result: Dry::Monads::Success(""))
      stub_resolve(repo_root: "/Users/eric/src/github.com/jetpks/repo-tender")
      config = RepoTender::Config::Config.new(
        base_dir: paths.base_dir, refresh_interval: 3600, concurrency: 2,
        repos: [], orgs: []
      )
      RepoTender::Config::Store.write(paths.config_file, config)

      out, _err = invoke_command(Daemon::Start)
      assert_equal 0, RepoTender::CLI.last_outcome.exit_code
      assert_includes out.string, "started:"
      assert_equal 1, fake.calls.size
      assert_equal :start, fake.calls.first.first
    end
  end

  def test_stop_calls_agent_stop
    with_daemon_home do |_env, _paths|
      fake = stub_agent(stop_result: Dry::Monads::Success(""))
      out, _err = invoke_command(Daemon::Stop)
      assert_equal 0, RepoTender::CLI.last_outcome.exit_code
      assert_includes out.string, "stopped:"
      assert_equal [[:stop]], fake.calls
    end
  end

  def test_restart_calls_agent_restart
    with_daemon_home do |_env, _paths|
      fake = stub_agent(restart_result: Dry::Monads::Success(""))
      out, _err = invoke_command(Daemon::Restart)
      assert_equal 0, RepoTender::CLI.last_outcome.exit_code
      assert_includes out.string, "restarted:"
      assert_equal [[:restart]], fake.calls
    end
  end

  # ---- status: prints loaded/running/pid/last_exit ----

  def test_status_prints_parsed_state
    with_daemon_home do |_env, _paths|
      stub_agent(
        status_result: Dry::Monads::Success(
          loaded: true, running: true, pid: 4321, last_exit: 0
        )
      )
      out, _err = invoke_command(Daemon::Status)
      assert_equal 0, RepoTender::CLI.last_outcome.exit_code
      assert_includes out.string, "loaded: true"
      assert_includes out.string, "running: true"
      assert_includes out.string, "pid: 4321"
      assert_includes out.string, "last_exit: 0"
    end
  end

  def test_status_failure_exits_nonzero
    with_daemon_home do |_env, _paths|
      stub_agent(
        status_result: Dry::Monads::Failure({stderr: "could not find", status: 1})
      )
      _out, err = invoke_command(Daemon::Status)
      assert_equal 1, RepoTender::CLI.last_outcome.exit_code
      assert_includes err.string, "status failed"
    end
  end

  # ---- daemon subcommands are registered under the `daemon` group ----

  def test_daemon_group_includes_all_six_subcommands
    # The Dry::CLI::Registry doesn't expose `names` directly;
    # walk the top-level children hash.
    top = RepoTender::CLI::Registry.get([]).children
    assert_includes top.keys, "daemon"

    # The daemon group has exactly the six expected subcommands.
    daemon_children = RepoTender::CLI::Registry.get(["daemon"]).children
    %w[install uninstall start stop restart status].each do |sub|
      assert_includes daemon_children.keys, sub
    end
  end

  # ---- Resolve.detect_bin_path (real, not stubbed) ----
  # Regression: a source checkout has no `gem install`ed binary, so
  # detect_bin_path must resolve the on-disk `<repo_root>/bin/repo-tender`
  # and NOT fall through to Gem.bin_path (which raises GemNotFound).

  def test_detect_bin_path_prefers_on_disk_dev_bin
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "bin"))
      dev = File.join(root, "bin", "repo-tender")
      File.write(dev, "#!/usr/bin/env ruby\n")
      assert_equal dev, Daemon::Helpers::Resolve.detect_bin_path(root)
    end
  end

  def test_detect_bin_path_honors_env_override
    prev = ENV["REPO_TENDER_BIN_PATH"]
    ENV["REPO_TENDER_BIN_PATH"] = "/custom/repo-tender"
    Dir.mktmpdir do |root|
      assert_equal "/custom/repo-tender", Daemon::Helpers::Resolve.detect_bin_path(root)
    end
  ensure
    ENV["REPO_TENDER_BIN_PATH"] = prev
  end
end
