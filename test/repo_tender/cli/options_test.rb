# frozen_string_literal: true

require_relative "test_helper"

# G5: non-TTY & --plain → plain; --json → JSON; no --daemon.
class CLIOptionsTest < Minitest::Test
  include TestHelpers
  include CLITestHelpers

  Mode = RepoTender::UI::Mode
  PlainReporter = RepoTender::UI::PlainReporter
  JsonReporter = RepoTender::UI::JsonReporter
  SyncRun = RepoTender::CLI::Sync::Run

  TtyIO = Struct.new(:tty_val) { def tty? = tty_val }

  # ---------------------------------------------------------------------------
  # G5: option registration
  # ---------------------------------------------------------------------------

  def test_sync_registers_plain_option
    assert_includes option_names, :plain
  end

  def test_sync_registers_json_option
    assert_includes option_names, :json
  end

  def test_sync_registers_no_color_option
    assert_includes option_names, :no_color
  end

  def test_sync_registers_quiet_option
    assert_includes option_names, :quiet
  end

  def test_daemon_is_not_a_recognized_option
    refute_includes option_names, :daemon, "--daemon must not be a recognized option"
  end

  # ---------------------------------------------------------------------------
  # G5: Mode resolution from flags
  # ---------------------------------------------------------------------------

  def test_non_tty_resolves_plain_format
    mode = Mode.resolve(flags: {}, env: {}, out: TtyIO.new(false))
    assert_equal :plain, mode.format
  end

  def test_plain_flag_forces_plain_on_tty
    mode = Mode.resolve(flags: {plain: true}, env: {}, out: TtyIO.new(true))
    assert_equal :plain, mode.format
  end

  def test_json_flag_resolves_json_format
    mode = Mode.resolve(flags: {json: true}, env: {}, out: TtyIO.new(false))
    assert_equal :json, mode.format
  end

  def test_tty_no_flags_resolves_pretty_format
    mode = Mode.resolve(flags: {}, env: {}, out: TtyIO.new(true))
    assert_equal :pretty, mode.format
  end

  # ---------------------------------------------------------------------------
  # G5: reporter type selected by mode
  # ---------------------------------------------------------------------------

  def test_json_mode_selects_json_reporter
    out = StringIO.new
    mode = Mode.resolve(flags: {json: true}, env: {}, out: out)
    reporter = (mode.format == :json) ? JsonReporter.new(out) : PlainReporter.new(out)
    assert_instance_of JsonReporter, reporter
  end

  def test_plain_mode_selects_plain_reporter
    out = StringIO.new
    mode = Mode.resolve(flags: {plain: true}, env: {}, out: out)
    reporter = (mode.format == :json) ? JsonReporter.new(out) : PlainReporter.new(out)
    assert_instance_of PlainReporter, reporter
  end

  def test_pretty_mode_selects_plain_reporter_in_slice_a
    out = StringIO.new
    mode = Mode.resolve(flags: {}, env: {}, out: TtyIO.new(true))
    reporter = (mode.format == :json) ? JsonReporter.new(out) : PlainReporter.new(out)
    assert_instance_of PlainReporter, reporter
  end

  # ---------------------------------------------------------------------------
  # G5: --daemon rejected at parse time (subprocess)
  # ---------------------------------------------------------------------------

  def test_daemon_flag_is_rejected_by_sync_subprocess
    Dir.mktmpdir("repo-tender-daemon-test-") do |home|
      env = {"HOME" => home}
      _stdout, stderr, status = run_cli_subprocess(env: env, args: ["sync", "--daemon"])
      refute status.success?, "--daemon should cause a non-zero exit"
      assert_includes stderr, "--daemon"
    end
  end

  private

  def option_names
    SyncRun.options.map(&:name)
  end
end
