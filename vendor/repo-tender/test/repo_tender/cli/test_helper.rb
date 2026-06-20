# frozen_string_literal: true

require "stringio"
require "open3"
require "test_helper"

# CLI-specific test helpers. Reuses the Slice 1 helpers
# (with_temp_home, with_paths, with_trunk_repo, seed_initial_commit)
# from test/test_helper.rb — that file is MUST NOT TOUCH per
# docs/gates/slice-3.md, so the CLI-specific env-injection /
# command-invocation helpers live here.
module CLITestHelpers
  # Inject a temp-home env into Thread.current[:repo_tender_cli_env]
  # for the duration of the block. This is what the CLI's
  # `CLI.make_paths` reads (so Config::Store / State::Store resolve
  # under the test's temp home, not the real one).
  def with_cli_env
    with_temp_home do |env, home|
      Thread.current[:repo_tender_cli_env] = env
      yield(env, home)
    end
  ensure
    Thread.current[:repo_tender_cli_env] = nil
  end

  # Invoke a command class directly (bypassing Dry::CLI's dispatch)
  # with captured out/err StringIOs and a cleared Outcome stash.
  # Returns [out_io, err_io]; the Outcome is on
  # SpaceArchitect::Pristine::CLI.last_outcome.
  def invoke_command(command_class, **kwargs)
    SpaceArchitect::Pristine::CLI.last_outcome # drain
    Thread.current[:repo_tender_cli_outcome] = nil
    out = StringIO.new
    err = StringIO.new
    cmd = command_class.new
    cmd.instance_variable_set(:@out, out)
    cmd.instance_variable_set(:@err, err)
    cmd.call(**kwargs)
    [out, err]
  end

  # Spawn the real bin/repo-tender binary with a captured env
  # (so the CLI resolves under the test's temp home). Returns
  # the [stdout, stderr, status] triple from Open3.capture3.
  def run_cli_subprocess(env:, **opts)
    args = opts.fetch(:args, [])
    ruby = opts.fetch(:ruby, "ruby")
    Open3.capture3(env, ruby, "-Ilib", File.expand_path("../../../bin/repo-tender", __dir__), *args)
  end
end
